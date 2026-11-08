// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A schema with one of everything an MCP tool needs to describe: a scalar field,
/// a field that takes required and defaulted arguments, an object it links to, an
/// enum, an input object, a deprecated field and a field no tool can select
/// because it needs an argument.
fn shop() -> (@schema.Schema, @exec.Resolvers) {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("hello", NonNull(Scalar("String")), description="A greeting.")
  q.field_args(
    "user",
    [("id", NonNull(Scalar("ID")))],
    Named("User"),
    description="One person, by id.",
  )
  q.field_args(
    "users",
    [("first", Scalar("Int"))],
    NonNull(ListOf(NonNull(Named("User")))),
    defaults=[("first", Json(2))],
  )
  q.field("old", Scalar("String"), deprecation_reason="use hello")
  let u = s.object("User")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", NonNull(Scalar("String")))
  u.field("role", NonNull(Named("Role")))
  u.field("friends", NonNull(ListOf(NonNull(Named("User")))))
  s.enum_("Role", ["ADMIN", "GUEST"], description="What a person may do.")
  let input = s.input("NewUser")
  input.field("name", NonNull(Scalar("String")))
  input.field("role", Named("Role"))
  let m = s.object("Mutation")
  m.field_args(
    "add",
    [("input", NonNull(Named("NewUser")))],
    NonNull(Named("User")),
  )
  s.set_mutation("Mutation")
  let r = @exec.Resolvers::new()
  r.field("Query", "hello", fn(_info) { Json("hello") })
  r.field("Query", "user", fn(info) -> Json raise @exec.FieldError {
    let id : String = info.read("id")
    Json(person(id, "Alice"))
  })
  r.field("Query", "users", fn(info) -> Json raise @exec.FieldError {
    let first : Int32? = info.read("first")
    let n = first.unwrap_or(2)
    let out : Array[Json] = []
    for i in 0..<n {
      out.push(person(i.to_string(), "P" + i.to_string()))
    }
    Json(out)
  })
  r.field("Query", "old", fn(_info) { Json("old") })
  r.field("Mutation", "add", fn(_info) { Json(person("9", "New")) })
  (s, r)
}

///|
/// One person, with the fields the schema declares.
fn person(id : String, name : String) -> Json {
  let m : Map[String, Json] = Map([])
  m["id"] = Json(id)
  m["name"] = Json(name)
  m["role"] = Json("ADMIN")
  let none : Array[Json] = []
  m["friends"] = Json(none)
  Json(m)
}

///|
/// Send one JSON-RPC message and return the reply, failing loudly when the server
/// answered a notification instead.
async fn ask(server : @moonmcp.Server, op : String, params : Json) -> Json {
  let reply = server.handle(
    jobj([
      ("jsonrpc", Json("2.0")),
      ("id", Json(1)),
      ("method", Json(op)),
      ("params", params),
    ]),
  )
  match reply {
    Some(r) => r
    None => abort("the server answered nothing")
  }
}

///|
/// The names a `tools/list` reply carries, in the order it carries them.
async fn tool_names(server : @moonmcp.Server) -> Array[String] {
  let reply = ask(server, "tools/list", jobj([]))
  let out : Array[String] = []
  match reply {
    Object(m) =>
      match m.get("result") {
        Some(Object(result)) =>
          match result.get("tools") {
            Some(Array(tools)) =>
              for t in tools {
                match t {
                  Object(tool) =>
                    match tool.get("name") {
                      Some(String(name)) => out.push(name)
                      _ => ()
                    }
                  _ => ()
                }
              }
            _ => ()
          }
        _ => ()
      }
    _ => ()
  }
  out
}

///|
/// Walk a chain of object keys, or `None` when one of them is missing.
fn dig(value : Json, keys : Array[String]) -> Json? {
  let mut current = value
  for key in keys {
    current = match current {
      Object(m) =>
        match m.get(key) {
          Some(v) => v
          None => return None
        }
      _ => return None
    }
  }
  Some(current)
}

///|
/// The text of a reply's first content block: for a tool call, the JSON the
/// handler returned.
fn text_of(reply : Json) -> String {
  match dig(reply, ["result", "content"]) {
    Some(Array(blocks)) =>
      if blocks.length() == 0 {
        ""
      } else {
        match dig(blocks[0], ["text"]) {
          Some(String(t)) => t
          _ => ""
        }
      }
    _ => ""
  }
}

///|
/// One tool's input schema, as the server lists it.
async fn tool_schema(server : @moonmcp.Server, name : String) -> String {
  let reply = ask(server, "tools/list", jobj([]))
  let tools = match dig(reply, ["result", "tools"]) {
    Some(Array(t)) => t
    _ => []
  }
  let hits = tools.filter(fn(t) {
    match dig(t, ["name"]) {
      Some(String(n)) => n == name
      _ => false
    }
  })
  if hits.length() == 0 {
    return ""
  }
  match dig(hits[0], ["inputSchema"]) {
    Some(schema) => schema.stringify()
    None => ""
  }
}

///|
/// The structured content of a `tools/call` reply.
async fn call(server : @moonmcp.Server, name : String, args : Json) -> Json {
  ask(server, "tools/call", jobj([("name", Json(name)), ("arguments", args)]))
}

///|
/// Every root field of `Query` is a tool, its arguments are the tool's input
/// schema, and `graphql_query` is there for the questions one call cannot express.
async test "mcp: every root field is a tool, with its arguments as the input schema" {
  let (s, r) = shop()
  let server = Mcp::of(schema=s, resolvers=r).server(name="shop")
  let names = tool_names(server)
  assert_eq(names.contains("hello"), true)
  assert_eq(names.contains("user"), true)
  assert_eq(names.contains("users"), true)
  assert_eq(names.contains("graphql_query"), true)
  // a deprecated field is not offered: an agent reads the tools, not the schema
  assert_eq(names.contains("old"), true)
  // mutations are off by default
  assert_eq(names.contains("add"), false)
  // `id` is a non-null argument with no default, so it is required
  let user = tool_schema(server, "user")
  assert_eq(user.contains("\"required\":[\"id\"]"), true)
  // `first` has a default, so it is not required and carries the default
  let users = tool_schema(server, "users")
  assert_eq(users.contains("\"default\":2"), true)
  assert_eq(users.contains("\"required\""), false)
  // a field with no arguments at all has an empty property map
  assert_eq(tool_schema(server, "hello").contains("\"properties\":{}"), true)
}

///|
/// A tool call runs the field and answers its value — the shape an agent reads.
async test "mcp: a tool call answers the field's value" {
  let (s, r) = shop()
  let server = Mcp::of(schema=s, resolvers=r).server(name="shop")
  let reply = call(server, "hello", jobj([]))
  assert_eq(text_of(reply), "\"hello\"")
  let user = call(server, "user", jobj([("id", Json("1"))]))
  let text = text_of(user)
  assert_eq(text.contains("\"name\":\"Alice\""), true)
  assert_eq(text.contains("\"role\":\"ADMIN\""), true)
  // the selection stops at the leaves and does not follow `friends` forever
  assert_eq(text.contains("\"friends\":[]"), true)
}

///|
/// A tool for a field with no required arguments still runs: the default the
/// schema declares applies, because the tool leaves the variable out.
async test "mcp: an omitted argument lets the field's default apply" {
  let (s, r) = shop()
  let server = Mcp::of(schema=s, resolvers=r).server(name="shop")
  let reply = call(server, "users", jobj([]))
  let text = text_of(reply)
  assert_eq(text.contains("\"id\":\"0\""), true)
  assert_eq(text.contains("\"id\":\"1\""), true)
  assert_eq(text.contains("\"id\":\"2\""), false)
}

///|
/// A mutation is not a tool unless it was asked for: a tool call is not a
/// confirmation.
async test "mcp: mutations are offered only when exposure allows them" {
  let (s, r) = shop()
  let open = Mcp::of(schema=s, resolvers=r, exposure={
    prefix: "",
    mutations: true,
    depth: 2,
    width: 12,
  }).server(name="shop")
  assert_eq(tool_names(open).contains("add"), true)
  let reply = call(
    open,
    "add",
    jobj([("input", jobj([("name", Json("Zoe"))]))]),
  )
  assert_eq(text_of(reply).contains("\"name\":\"New\""), true)
}

///|
/// The document tool is the escape hatch, and it refuses to write unless the
/// exposure says mutations are in scope.
async test "mcp: graphql_query runs a document and refuses to mutate unless allowed" {
  let (s, r) = shop()
  let read_only = Mcp::of(schema=s, resolvers=r).server(name="shop")
  let answer = call(
    read_only,
    "graphql_query",
    jobj([("query", Json("{ user(id: \"2\") { name role } }"))]),
  )
  assert_eq(text_of(answer).contains("\"name\":\"Alice\""), true)
  let refused = call(
    read_only,
    "graphql_query",
    jobj([("query", Json("mutation { add(input: {name: \"X\"}) { id } }"))]),
  )
  assert_eq(text_of(refused).contains("read-only"), true)
  let writer = Mcp::of(schema=s, resolvers=r, exposure={
    prefix: "",
    mutations: true,
    depth: 2,
    width: 12,
  }).server(name="shop")
  let written = call(
    writer,
    "graphql_query",
    jobj([("query", Json("mutation { add(input: {name: \"X\"}) { name } }"))]),
  )
  assert_eq(text_of(written).contains("\"name\":\"New\""), true)
}

///|
/// A prefix keeps two schemas on one host apart, and the schema itself travels as
/// a resource, so an agent can write a document without another round trip.
async test "mcp: the prefix namespaces the tools and the schema is a resource" {
  let (s, r) = shop()
  let server = Mcp::of(schema=s, resolvers=r, exposure={
    prefix: "shop_",
    mutations: false,
    depth: 2,
    width: 12,
  }).server(name="shop")
  let names = tool_names(server)
  assert_eq(names.contains("shop_hello"), true)
  assert_eq(names.contains("shop_graphql_query"), true)
  let read = ask(
    server,
    "resources/read",
    jobj([("uri", Json("shop_graphql://schema"))]),
  )
  let text = read.stringify()
  assert_eq(text.contains("type User"), true)
  assert_eq(text.contains("role: Role!"), true)
}

///|
/// A field whose type needs an argument cannot be selected, so a tool's default
/// selection leaves it out rather than sending a document that would not validate.
async test "mcp: a field that needs an argument is not in the default selection" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("root", NonNull(Named("Thing")))
  let t = s.object("Thing")
  t.field("id", NonNull(Scalar("ID")))
  t.field_args("detail", [("depth", NonNull(Scalar("Int")))], Scalar("String"))
  let r = @exec.Resolvers::new()
  r.field("Query", "root", fn(_info) {
    let m : Map[String, Json] = Map([])
    m["id"] = Json("1")
    m["detail"] = Json("hidden")
    Json(m)
  })
  let server = Mcp::of(schema=s, resolvers=r).server(name="thing")
  let reply = call(server, "root", jobj([]))
  let text = text_of(reply)
  assert_eq(text.contains("\"id\":\"1\""), true)
  assert_eq(text.contains("hidden"), false)
}
