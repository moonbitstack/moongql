// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A schema offered to an agent: one tool per root field, over the Model Context
/// Protocol, so a client that knows nothing about GraphQL can still read what the
/// endpoint knows.
///
/// The schema is the only description of the calls — a tool's name is the field's
/// name, its input schema is built from the field's arguments, and what it answers
/// is the field's value. Nothing is written twice, and a field added to the schema
/// appears as a tool the next time the server lists them.
///
/// The other half of the protocol is the escape hatch: `graphql_query` runs a
/// document the agent wrote, against the same schema, for the questions one flat
/// tool call cannot express.

///|
/// How much of a schema to offer. The defaults are the cautious end: no
/// mutations (a tool call is not a confirmation), two levels of selection, and at
/// most a dozen fields per level, which keeps an answer small enough to read.
pub(all) struct Exposure {
  /// Prepended to every tool name, so two schemas on one host do not collide.
  prefix : String
  /// Whether the mutation root is offered as tools, and whether `graphql_query`
  /// accepts a mutation document.
  mutations : Bool
  /// How many levels of fields a tool selects. A field whose type is composite
  /// selects its own fields until this depth is spent.
  depth : Int32
  /// How many fields one level may select, in schema order.
  width : Int32
}

///|
/// The preset: no mutations, two levels deep, twelve fields wide.
pub let exposure : Exposure = {
  prefix: "",
  mutations: false,
  depth: 2,
  width: 12,
}

///|
/// A schema and the resolvers behind it, offered over MCP.
pub struct Mcp {
  schema : @schema.Schema
  resolvers : @exec.Resolvers
  exposure : Exposure
}

///|
/// Offer `schema`, answered by `resolvers`, with `exposure` deciding how much of
/// it is visible.
pub fn Mcp::of(
  schema~ : @schema.Schema,
  resolvers~ : @exec.Resolvers,
  exposure~ : Exposure = exposure,
) -> Mcp {
  { schema, resolvers, exposure, }
}

///|
/// An MCP server with this schema attached, ready to be mounted: pass it to
/// `Server::to_asgi` for Streamable HTTP, or to `run_stdio` for a client that
/// starts it as a subprocess.
///
/// The instructions the server reports are the SDL, so an agent that reads them
/// can write documents for `graphql_query` without another round trip.
pub fn Mcp::server(
  self : Mcp,
  name~ : String,
  version~ : String = "1.0.0",
) -> @moonmcp.Server {
  let server = @moonmcp.Server::new(
    name,
    version~,
    instructions=self.schema.to_sdl(),
  )
  self.attach(server)
  server
}

///|
/// Add this schema's tools, and the SDL as a resource, to a server the caller
/// already holds. Registering onto a server of one's own is how a schema joins
/// the tools a program offers for other reasons.
pub fn Mcp::attach(self : Mcp, server : @moonmcp.Server) -> Unit {
  for f in root_fields(self.schema, "Query") {
    let field = f
    let description = match field.description {
      Some(d) => d
      None => "Query." + field.name
    }
    self.add_tool(server, "Query", field, description)
  }
  if self.exposure.mutations {
    for f in root_fields(self.schema, "Mutation") {
      let field = f
      let description = match field.description {
        Some(d) => d
        None => "Mutation." + field.name
      }
      self.add_tool(server, "Mutation", field, description)
    }
  }
  let query_tool = self.exposure.prefix + "graphql_query"
  let writes = self.exposure.mutations
  let tool = @moonmcp.Tool::new(
    query_tool,
    parameters=document_schema(),
    run_fn=async fn(args) raise @moonmcp.FastMCPError {
      let value = self.run_document(args, writes~) catch {
        e =>
          return @moonmcp.ToolResult::new(
            content=[@moonmcp.text_block("the request failed: \{e}")],
            is_error=true,
          )
      }
      tool_result(value)
    },
    description="Run a GraphQL document against this schema, with its variables. The server's instructions carry the schema in SDL.",
  ) catch {
    e => abort("graphql_query: \{e}")
  }
  server.add_tool(tool)
  server.resource(
    self.exposure.prefix + "graphql://schema",
    fn() { self.schema.to_sdl() },
    name="schema",
    description="The schema this server answers from, in SDL.",
    mime_type="application/graphql",
  )
}

///|
/// Register one root field as a tool: its arguments are the input schema, and the
/// value it answers is the result.
fn Mcp::add_tool(
  self : Mcp,
  server : @moonmcp.Server,
  root : String,
  field : @schema.Field,
  description : String,
) -> Unit {
  let tool = @moonmcp.Tool::new(
    self.exposure.prefix + field.name,
    parameters=self.input_schema(field),
    run_fn=async fn(args) raise @moonmcp.FastMCPError {
      let value = self.answer(root, field, args) catch {
        e =>
          return @moonmcp.ToolResult::new(
            content=[@moonmcp.text_block("the request failed: \{e}")],
            is_error=true,
          )
      }
      tool_result(value)
    },
    description~,
  ) catch {
    e => abort("\{field.name}: \{e}")
  }
  server.add_tool(tool)
}

///|
/// What a tool call answers: the JSON as the model reads it, marked as an error
/// when the response carries one — a GraphQL response with `errors` is a failed
/// call, and a client that reads `isError` should see it that way.
fn tool_result(value : Json) -> @moonmcp.ToolResult raise @moonmcp.FastMCPError {
  let text = @moonjson.dumps(value)
  match value {
    Object(m) => {
      let failed = m.get("errors") is Some(_)
      @moonmcp.ToolResult::new(
        content=[@moonmcp.text_block(text)],
        structured_content=m,
        is_error=failed,
      )
    }
    _ => @moonmcp.ToolResult::new(content=[@moonmcp.text_block(text)])
  }
}

///|
/// The tools of one root type, in the order the schema declares them.
fn root_fields(schema : @schema.Schema, root : String) -> Array[@schema.Field] {
  match schema.type_by_name(root) {
    Some(t) => t.fields
    None => []
  }
}

///|
/// Answer one tool call: build the document the field needs, run it, and hand
/// back the field's value — or the whole response when it failed, so the error
/// and the path to it arrive together.
async fn Mcp::answer(
  self : Mcp,
  root : String,
  field : @schema.Field,
  args : Map[String, Json],
) -> Json {
  let decls : Array[String] = []
  let calls : Array[String] = []
  let variables : Map[String, Json] = Map([])
  for i, a in field.args {
    let name = "a" + i.to_string()
    decls.push("$" + name + ": " + type_sdl(a.1))
    calls.push(a.0 + ": $" + name)
    // An argument the caller left out is left out of the variables too: a
    // missing variable is "not supplied", which is what lets the field's own
    // default apply, while an explicit null would override it.
    match args.get(a.0) {
      Some(v) => variables[name] = v
      None => ()
    }
  }
  let selection = self.selection(field.typ, self.exposure.depth)
  let call = if calls.is_empty() {
    field.name + " " + selection
  } else {
    field.name + "(" + calls.join(", ") + ") " + selection
  }
  let document = if decls.is_empty() {
    keyword(root) + " " + "{ " + call + " }"
  } else {
    keyword(root) + " tool(" + decls.join(", ") + ") { " + call + " }"
  }
  let answer = @exec.execute_async(
    self.schema,
    self.resolvers,
    document,
    variables~,
  )
  match answer {
    Object(m) =>
      match m.get("errors") {
        Some(_) => answer
        None =>
          match m.get("data") {
            Some(Object(data)) => data.get(field.name).unwrap_or(answer)
            _ => answer
          }
      }
    _ => answer
  }
}

///|
/// The operation keyword of a root type's document.
fn keyword(root : String) -> String {
  if root == "Query" {
    "query"
  } else {
    "mutation"
  }
}

///|
/// Run a document the caller wrote. Without `writes`, only a query operation is
/// accepted: a tool that runs arbitrary documents is not a reason to let one
/// mutate the data behind them.
async fn Mcp::run_document(
  self : Mcp,
  args : Map[String, Json],
  writes~ : Bool,
) -> Json {
  let document = match args.get("query") {
    Some(String(q)) => q
    _ => return failure("the `query` argument must be a string")
  }
  if !writes {
    let parsed : @lang.Document = @lang.parse(document) catch {
      e => return failure(@lang.refusal(e).message)
    }
    for def in parsed.definitions {
      if def is @lang.OperationDef(op) {
        if op.operation is @lang.Mutation {
          return failure(
            "this server exposes read-only tools; a mutation is not one of them",
          )
        }
      }
    }
  }
  let variables : Map[String, Json] = match args.get("variables") {
    Some(Object(v)) => v
    _ => Map([])
  }
  let operation_name : String? = match args.get("operationName") {
    Some(String(n)) => Some(n)
    _ => None
  }
  @exec.execute_async(
    self.schema,
    self.resolvers,
    document,
    variables~,
    operation_name?,
  )
}

///|
/// A refusal the agent can read and correct itself from.
fn failure(message : String) -> Json {
  jobj([("errors", Json([jobj([("message", Json(message))])]))])
}

///|
/// The input schema of a tool built from a field: one property per argument, and
/// the arguments without a default listed as required.
fn Mcp::input_schema(self : Mcp, field : @schema.Field) -> Json {
  let properties : Map[String, Json] = Map([])
  let required : Array[Json] = []
  for a in field.args {
    let mut schema = json_schema(self.schema, a.1)
    match a.1 {
      NonNull(_) =>
        if field.arg_defaults.get(a.0) is None {
          required.push(Json(a.0))
        }
      _ => ()
    }
    match field.arg_defaults.get(a.0) {
      Some(d) => schema = with_entry(schema, "default", d)
      None => ()
    }
    properties[a.0] = schema
  }
  let entries : Array[(String, Json)] = [
    ("type", Json("object")),
    ("properties", Json(properties)),
  ]
  if !required.is_empty() {
    entries.push(("required", Json(required)))
  }
  jobj(entries)
}

///|
/// The input schema of the document tool.
fn document_schema() -> Json {
  let properties = jobj([
    (
      "query",
      jobj([
        ("type", Json("string")),
        ("description", Json("A GraphQL document.")),
      ]),
    ),
    (
      "variables",
      jobj([
        ("type", Json("object")),
        ("description", Json("Values for the document's variables.")),
      ]),
    ),
    (
      "operationName",
      jobj([
        ("type", Json("string")),
        (
          "description",
          Json("Which operation to run, when the document has several."),
        ),
      ]),
    ),
  ])
  jobj([
    ("type", Json("object")),
    ("properties", Json(properties)),
    ("required", Json([Json("query")])),
  ])
}

///|
/// A JSON Schema for one input position of a GraphQL type.
fn json_schema(schema : @schema.Schema, t : @schema.GqlType) -> Json {
  match t {
    NonNull(inner) => json_schema(schema, inner)
    ListOf(inner) =>
      jobj([("type", Json("array")), ("items", json_schema(schema, inner))])
    Scalar(name) => scalar_schema(name)
    Named(name) =>
      match schema.enum_by_name(name) {
        Some(e) => {
          let values : Array[Json] = []
          for v in e.values {
            values.push(Json(v))
          }
          let entries : Array[(String, Json)] = [
            ("type", Json("string")),
            ("enum", Json(values)),
          ]
          match e.description {
            Some(d) => entries.push(("description", Json(d)))
            None => ()
          }
          jobj(entries)
        }
        None =>
          match schema.type_by_name(name) {
            Some(t) =>
              if t.kind is @schema.Input {
                input_object_schema(schema, t)
              } else {
                // An object type cannot be an input; the field could not have
                // been declared this way, so the schema is the one to blame.
                jobj([])
              }
            None => jobj([])
          }
      }
  }
}

///|
/// The JSON type behind a GraphQL scalar. A custom scalar is left unconstrained:
/// the schema says what it means, JSON Schema does not have to guess.
fn scalar_schema(name : String) -> Json {
  let kind = match name {
    "Int" => "integer"
    "Float" => "number"
    "Boolean" => "boolean"
    "String" | "ID" => "string"
    "Int64" => "integer"
    _ => ""
  }
  if kind == "" {
    jobj([])
  } else {
    jobj([("type", Json(kind))])
  }
}

///|
/// The JSON Schema of an input object: its fields' schemas, and the ones that
/// carry no default listed as required.
fn input_object_schema(schema : @schema.Schema, t : @schema.ObjectType) -> Json {
  let properties : Map[String, Json] = Map([])
  let required : Array[Json] = []
  for f in t.fields {
    let mut inner = json_schema(schema, f.typ)
    match f.description {
      Some(d) => inner = with_entry(inner, "description", Json(d))
      None => ()
    }
    match f.default_value {
      Some(d) => inner = with_entry(inner, "default", d)
      None => ()
    }
    properties[f.name] = inner
    match f.typ {
      NonNull(_) => if f.default_value is None { required.push(Json(f.name)) }
      _ => ()
    }
  }
  let entries : Array[(String, Json)] = [
    ("type", Json("object")),
    ("properties", Json(properties)),
  ]
  match t.description {
    Some(d) => entries.push(("description", Json(d)))
    None => ()
  }
  if !required.is_empty() {
    entries.push(("required", Json(required)))
  }
  jobj(entries)
}

///|
/// A type as SDL writes it: `[User!]!`.
fn type_sdl(t : @schema.GqlType) -> String {
  match t {
    Scalar(name) => name
    Named(name) => name
    NonNull(inner) => type_sdl(inner) + "!"
    ListOf(inner) => "[" + type_sdl(inner) + "]"
  }
}
