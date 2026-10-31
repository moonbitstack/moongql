///|
/// `#gql.*` on structs, enums, fields, methods and free functions, turned into
/// `register(schema, resolvers)` and the `ToGql`／`FromGql` of each annotated
/// type. An enum whose constructors each wrap one `#gql.type` struct is a union
/// or an interface over those structs.
priv struct Gql {}

///|
impl @gen.Generator for Gql with fn name(_) {
  "moongql"
}

///|
fn type_spec(name : String) -> @attr.Spec {
  @attr.Spec::new(name).optional("name", Str).optional("description", Str)
}

///|
let field_spec : @attr.Spec = @attr.Spec::new("gql.field")
  .optional("name", Str)
  .optional("description", Str)
  .optional("deprecation_reason", Str)
  .optional("kind", Str)

///|
fn root_spec(name : String) -> @attr.Spec {
  @attr.Spec::new(name)
  .optional("name", Str)
  .optional("description", Str)
  .optional("deprecation_reason", Str)
}

///|
/// `#gql.enum`, `#gql.union`, and `#gql.interface` with the fields it names.
fn enum_spec(name : String) -> @attr.Spec {
  if name == "gql.interface" {
    type_spec(name).many("field", Str)
  } else {
    type_spec(name)
  }
}

///|
let skip_spec : @attr.Spec = @attr.Spec::new("gql.skip")

///|
fn at(attr : @attribute.Attribute, file : String) -> String {
  "\{file}:\{attr.loc.start.lnum}:\{attr.loc.start.column()}"
}

///|
/// The `#gql.*` attributes among `attrs`, refusing one that does not parse.
fn gql_attrs(
  attrs : @list.List[@attribute.Attribute],
  file : String,
) -> Array[@attribute.Attribute] raise {
  for attr in attrs {
    if @attr.name_of(attr) is None && attr.raw.has_prefix("#gql.") {
      fail("\{at(attr, file)}: `\{attr.raw}` does not parse as an annotation")
    }
  }
  @attr.under(attrs, "gql")
}

///|
/// The one attribute among `found`, which must be one of `names`.
fn single(
  found : Array[@attribute.Attribute],
  names : Array[String],
  what : String,
  file : String,
) -> @attribute.Attribute? raise {
  for attr in found {
    guard @attr.name_of(attr) is Some(n) && names.contains(n) else {
      let n = @attr.name_of(attr).unwrap_or("?")
      fail("\{at(attr, file)}: `#\{n}` does not go on \{what}")
    }
  }
  match found {
    [] => None
    [one] => Some(one)
    [_, second, ..] => fail("\{at(second, file)}: one `#gql.*` per declaration")
  }
}

///|
/// The optional `name=`, `description=` and `deprecation_reason=` as labelled
/// arguments of a schema call.
fn labels(args : @attr.Args, keys : Array[String]) -> Array[String] {
  let out = []
  for key in keys {
    if args.str(key) is Some(v) {
      out.push("\{key}=\{quoted(v)}")
    }
  }
  out
}

///|
/// The generated file, built up declaration by declaration.
priv struct Out {
  known : Map[String, Known]
  // Each object's fields by GraphQL name, with the arguments and type they are
  // written with, for the interfaces built over them.
  field_types : Map[String, Map[String, (Array[String], String)]]
  scalars : Map[String, Unit]
  types : Array[String]
  // Unions and interfaces, registered once every object and its fields are.
  abstracts : Array[String]
  fields : Array[String]
  impls : Array[String]
  mut query : Bool
  mut mutation : Bool
}

///|
fn handle(name : String) -> String {
  "gql_" + camel(name).to_lower()
}

///|
/// A struct's fields: schema calls on `obj`, and the two conversions.
fn record(
  out : Out,
  name : String,
  known : Known,
  fields : Array[@gen.Field],
  public : Bool,
  where_ : String,
  file : String,
) -> Unit raise {
  let obj = handle(name)
  let writes = []
  let reads = []
  let keys : Map[String, Unit] = Map([])
  if known.shape == Object {
    writes.push("\"__typename\": \{quoted(known.name)}")
  }
  for field in fields {
    let attr = single(
      gql_attrs(field.attrs, file),
      ["gql.field", "gql.skip"],
      "a field",
      file,
    )
    let at_field = match attr {
      Some(a) => at(a, file)
      None => where_
    }
    let key = match attr {
      Some(a) if @attr.name_of(a) is Some("gql.skip") => {
        ignore(skip_spec.bind(a))
        field.name
      }
      _ => {
        let args = match attr {
          Some(a) => Some(field_spec.bind(a))
          None => None
        }
        let gql_name = match args {
          Some(a) => a.str("name").unwrap_or(camel(field.name))
          None => camel(field.name)
        }
        let kind = match args {
          Some(a) => a.str("kind")
          None => None
        }
        guard graphql_type(field.ty, out.known, kind, out.scalars) is Some(t) else {
          fail(
            "\{at_field}: field `\{field.name}`: `\{field.ty}` has no GraphQL type; give `#gql.field(kind=...)`",
          )
        }
        if known.shape == Input && output_core(field.ty, out.known) is Some(o) {
          fail(
            "\{at_field}: field `\{field.name}`: `\{o}` is an output type; an input field takes a `#gql.input` struct, an enum or a scalar",
          )
        }
        let extra = match args {
          Some(a) => labels(a, ["deprecation_reason", "description"])
          None => []
        }
        out.types.push(
          "\{obj}.field(\{[quoted(gql_name), t, ..extra].join(", ")})",
        )
        field_type(out, name, gql_name, [], t)
        gql_name
      }
    }
    if keys.contains(key) || key == "__typename" {
      fail("\{at_field}: `\{name}` has two fields called `\{key}`")
    }
    keys.set(key, ())
    writes.push("\{quoted(key)}: @moongql.ToGql::to_gql(self.\{field.name})")
    reads.push("\{field.name}: @moongql.read(v, \{quoted(key)})")
  }
  let vis = if public { "pub " } else { "" }
  out.impls.push(
    (
      $|\{vis}impl @moongql.ToGql for \{name} with fn to_gql(self) {
      $|  { \{writes.join(", ")} }
      $|}
      $|
      $|\{vis}impl @moongql.FromGql for \{name} with fn from_gql(v) {
      $|  \{name}::{ \{reads.join(", ")} }
      $|}
    ),
  )
}

///|
/// An enum of constructors without payload, as a GraphQL enum.
fn enumeration(
  out : Out,
  name : String,
  known : Known,
  raw : @syntax.Impl,
  args : @attr.Args,
  public : Bool,
  where_ : String,
) -> Unit raise {
  guard raw is TopTypeDef({ components: Variant(constrs), .. }) else {
    fail("\{where_}: `#gql.enum` goes on an enum")
  }
  let names = []
  for c in constrs {
    if c.args is Some(_) {
      fail(
        "\{where_}: `\{name}::\{c.name.name}` carries a payload; a GraphQL enum value does not",
      )
    }
    names.push(c.name.name)
  }
  let extra = labels(args, ["description"])
  out.types.push(
    "schema.enum_(\{[quoted(known.name), "[\{names.map(quoted).join(", ")}]", ..extra].join(", ")})",
  )
  let writes = names.map(n => "\{n} => \{quoted(n)}")
  let reads = names.map(n => "String(\{quoted(n)}) => \{n}")
  let vis = if public { "pub " } else { "" }
  out.impls.push(
    (
      $|\{vis}impl @moongql.ToGql for \{name} with fn to_gql(self) {
      $|  match self {
      $|    \{writes.join("\n")}
      $|  }
      $|}
      $|
      $|\{vis}impl @moongql.FromGql for \{name} with fn from_gql(v) {
      $|  match v {
      $|    \{reads.join("\n")}
      $|    other => raise @moongql.ResolverError::expected(\{quoted(known.name)}, other)
      $|  }
      $|}
    ),
  )
}

///|
fn field_type(
  out : Out,
  owner : String,
  gql_name : String,
  args : Array[String],
  t : String,
) -> Unit {
  match out.field_types.get(owner) {
    Some(m) => m[gql_name] = (args, t)
    None => out.field_types[owner] = Map([(gql_name, (args, t))])
  }
}

///|
/// The struct a constructor wraps, when it wraps exactly one, by plain name.
fn payload(c : @syntax.ConstrDecl) -> String? {
  guard c.args is Some(args) && args.to_array() is [param] else { return None }
  match param.ty {
    Name(constr_id={ id: Ident(name~), .. }, tys~, ..) if tys.is_empty() =>
      Some(name)
    _ => None
  }
}

///|
/// An enum whose constructors each wrap one `#gql.type` struct, as a union of
/// those object types, or as an interface they implement with the fields
/// `field=` names. A value converts by its constructor, and back by the
/// `__typename` its object carries.
fn abstract_type(
  out : Out,
  name : String,
  known : Known,
  raw : @syntax.Impl,
  args : @attr.Args,
  public : Bool,
  where_ : String,
) -> Unit raise {
  let what = if known.shape == Union { "union" } else { "interface" }
  guard raw is TopTypeDef({ components: Variant(constrs), .. }) else {
    fail("\{where_}: `#gql.\{what}` goes on an enum")
  }
  let members = []
  for c in constrs {
    guard payload(c) is Some(ty) &&
      out.known.get(ty) is Some({ shape: Object, name: gql_name, }) else {
      fail(
        "\{where_}: `\{name}::\{c.name.name}` does not wrap one `#gql.type` struct",
      )
    }
    members.push((c.name.name, ty, gql_name))
  }
  if members.is_empty() {
    fail("\{where_}: `\{name}` has no members")
  }
  let extra = labels(args, ["description"])
  if known.shape == Union {
    out.abstracts.push(
      "schema.union(\{[quoted(known.name), "[\{members.map(m => quoted(m.2)).join(", ")}]", ..extra].join(", ")})",
    )
  } else {
    let fields = args.strs("field")
    if fields.is_empty() {
      fail("\{where_}: `#gql.interface` names at least one `field`")
    }
    let iface = handle(name)
    out.abstracts.push(
      "let \{iface} = schema.interface(\{[quoted(known.name), ..extra].join(", ")})",
    )
    for field in fields {
      let mut written = None
      for m in members {
        guard out.field_types.get(m.1).bind(f => f.get(field)) is Some(sig) else {
          fail("\{where_}: `\{m.1}` has no field `\{field}`")
        }
        match written {
          Some(w) if w != sig =>
            fail(
              "\{where_}: field `\{field}` is not the same in every member of `\{name}`",
            )
          _ => written = Some(sig)
        }
      }
      let (args, t) = written.unwrap()
      out.abstracts.push(
        if args.is_empty() {
          "\{iface}.field(\{quoted(field)}, \{t})"
        } else {
          "\{iface}.field_args(\{quoted(field)}, [\{args.join(", ")}], \{t})"
        },
      )
    }
    for m in members {
      out.abstracts.push("\{handle(m.1)}.implements(\{quoted(known.name)})")
    }
  }
  let writes = members.map(m => "\{m.0}(v) => @moongql.ToGql::to_gql(v)")
  let reads = members.map(m => {
    "{ \"__typename\": String(\{quoted(m.2)}), .. } => \{m.0}(@moongql.FromGql::from_gql(v))"
  })
  let vis = if public { "pub " } else { "" }
  out.impls.push(
    (
      $|\{vis}impl @moongql.ToGql for \{name} with fn to_gql(self) {
      $|  match self {
      $|    \{writes.join("\n")}
      $|  }
      $|}
      $|
      $|\{vis}impl @moongql.FromGql for \{name} with fn from_gql(v) {
      $|  match v {
      $|    \{reads.join("\n")}
      $|    other => raise @moongql.ResolverError::expected(\{quoted(known.name)}, other)
      $|  }
      $|}
    ),
  )
}

///|
fn is_info(ty : String) -> Bool {
  ty is ("ResolveInfo" | "@moongql.ResolveInfo" | "@exec.ResolveInfo")
}

///|
/// A function's parameters as GraphQL arguments and the call reading each
/// from `info`. `self` is passed in as `self_`.
fn call_of(
  out : Out,
  params : ArrayView[@gen.Param],
  where_ : String,
) -> (Array[String], Array[String]) raise {
  let gql_args = []
  let call = []
  for param in params {
    guard param.name is Some(name) && param.ty is Some(ty) else {
      fail("\{where_}: every parameter needs a name and a type")
    }
    if is_info(ty) {
      call.push(
        match param.pass {
          Positional => "info"
          Labelled => "\{name}=info"
          Optional | Defaulted => "\{name}?=Some(info)"
        },
      )
      continue
    }
    let gql_name = camel(name)
    let optional = param.pass is (Optional | Defaulted)
    let arg_ty = if optional && inner_option(ty) is None {
      ty + "?"
    } else {
      ty
    }
    guard graphql_type(arg_ty, out.known, None, out.scalars) is Some(t) else {
      fail("\{where_}: parameter `\{name}`: `\{ty}` has no GraphQL type")
    }
    if output_core(ty, out.known) is Some(o) {
      fail(
        "\{where_}: parameter `\{name}`: `\{o}` is an output type; an argument takes a `#gql.input` struct, an enum or a scalar",
      )
    }
    gql_args.push("(\{quoted(gql_name)}, \{t})")
    let read = "info.read(\{quoted(gql_name)})"
    call.push(
      match param.pass {
        Positional => read
        Labelled => "\{name}=\{read}"
        Optional | Defaulted => "\{name}?=\{read}"
      },
    )
  }
  (gql_args, call)
}

///|
/// Whether a function declares that it raises.
fn raises(raw : @syntax.Impl) -> Bool {
  match raw {
    TopFuncDef(fun_decl={ error_type: NoErrorType | Noraise(..), .. }, ..) =>
      false
    _ => true
  }
}

///|
/// The schema call and the resolver of one function field on `obj`, whose
/// type the resolver map knows as `owner`.
fn function_field(
  out : Out,
  obj : String,
  owner : String,
  target : String,
  attr : @attribute.Attribute,
  args : @attr.Args,
  name : String,
  params : ArrayView[@gen.Param],
  returns : String?,
  raw : @syntax.Impl,
  file : String,
  self_type : String?,
) -> Unit raise {
  let where_ = at(attr, file)
  let gql_name = args.str("name").unwrap_or(camel(name))
  guard returns is Some(r) && r != "Unit" else {
    fail("\{where_}: a GraphQL field returns a value")
  }
  guard graphql_type(r, out.known, args.str("kind"), out.scalars) is Some(t) else {
    fail("\{where_}: `\{r}` has no GraphQL type; give `kind=`")
  }
  let (gql_args, call) = call_of(out, params, where_)
  if self_type is Some(ty) {
    field_type(out, ty, gql_name, gql_args, t)
  }
  let extra = labels(args, ["deprecation_reason", "description"])
  out.fields.push(
    if gql_args.is_empty() {
      "\{obj}.field(\{[quoted(gql_name), t, ..extra].join(", ")})"
    } else {
      "\{obj}.field_args(\{[quoted(gql_name), "[\{gql_args.join(", ")}]", t, ..extra].join(", ")})"
    },
  )
  let call = match self_type {
    Some(_) => "\{target}(\{["self_", ..call].join(", ")})"
    None => "\{target}(\{call.join(", ")})"
  }
  let value = "@moongql.ToGql::to_gql(\{call})"
  let value = if raises(raw) {
    "\{value} catch { e => raise @moongql.field_error(e) }"
  } else {
    value
  }
  let body = match self_type {
    Some(ty) =>
      "{ let self_ : \{ty} = @moongql.FromGql::from_gql(info.parent); \{value} }"
    None => value
  }
  let info = if self_type is Some(_) || params.length() > 0 {
    "info"
  } else {
    "_"
  }
  out.fields.push(
    "resolvers.field(\{owner}, \{quoted(gql_name)}, \{info} => \{body})",
  )
}

///|
/// First pass: the annotated types, so that a field may name one declared
/// further down.
fn collect(decls : Array[@gen.Decl], out : Out) -> Unit raise {
  for decl in decls {
    match decl {
      Struct(name~, attrs~, file~, ..) =>
        match
          single(
            gql_attrs(attrs, file),
            ["gql.type", "gql.input"],
            "a struct",
            file,
          ) {
          Some(attr) => {
            let full = @attr.name_of(attr).unwrap_or("")
            let args = type_spec(full).bind(attr)
            let shape = if full == "gql.type" { Object } else { Input }
            out.known.set(name, {
              name: args.str("name").unwrap_or(name),
              shape,
            })
          }
          None => ()
        }
      Enum(name~, attrs~, file~, ..) =>
        match
          single(
            gql_attrs(attrs, file),
            ["gql.enum", "gql.union", "gql.interface"],
            "an enum",
            file,
          ) {
          Some(attr) => {
            let full = @attr.name_of(attr).unwrap_or("")
            let args = enum_spec(full).bind(attr)
            out.known.set(name, {
              name: args.str("name").unwrap_or(name),
              shape: match full {
                "gql.union" => Union
                "gql.interface" => Interface
                _ => Enum
              },
            })
          }
          None => ()
        }
      _ => ()
    }
  }
}

///|
impl @gen.Generator for Gql with fn generate(_, decls) {
  let out : Out = {
    known: Map([]),
    field_types: Map([]),
    abstracts: [],
    scalars: Map([]),
    types: [],
    fields: [],
    impls: [],
    query: false,
    mutation: false,
  }
  collect(decls, out)
  let abstracts = []
  for decl in decls {
    match decl {
      Struct(name~, fields~, attrs~, public~, file~, ..) => {
        guard out.known.get(name) is Some(known) else {
          for field in fields {
            if gql_attrs(field.attrs, file) is [first, ..] {
              fail(
                "\{at(first, file)}: `\{name}` has no `#gql.type` or `#gql.input`, so its fields take no `#gql.*`",
              )
            }
          }
          continue
        }
        let attr = gql_attrs(attrs, file)[0]
        let full = @attr.name_of(attr).unwrap_or("")
        let args = type_spec(full).bind(attr)
        let call = if known.shape == Object { "object" } else { "input" }
        let extra = labels(args, ["description"])
        out.types.push(
          "let \{handle(name)} = schema.\{call}(\{[quoted(known.name), ..extra].join(", ")})",
        )
        record(out, name, known, fields, public, at(attr, file), file)
      }
      Enum(name~, public~, file~, raw~, ..) => {
        guard out.known.get(name) is Some(known) else { continue }
        let attr = gql_attrs(decl.attrs(), file)[0]
        if known.shape == Enum {
          let args = type_spec("gql.enum").bind(attr)
          enumeration(out, name, known, raw, args, public, at(attr, file))
        } else {
          abstracts.push((name, known, raw, attr, public, file))
        }
      }
      Func(owner~, name~, params~, returns~, is_async~, attrs~, file~, raw~, ..) => {
        let attr = match owner {
          Some(_) =>
            single(gql_attrs(attrs, file), ["gql.field"], "a method", file)
          None =>
            single(
              gql_attrs(attrs, file),
              ["gql.query", "gql.mutation"],
              "a free function",
              file,
            )
        }
        guard attr is Some(attr) else { continue }
        if is_async {
          fail("\{at(attr, file)}: a moongql resolver is synchronous")
        }
        match owner {
          Some(ty) => {
            guard out.known.get(ty) is Some({ name: type_name, shape: Object, }) else {
              fail(
                "\{at(attr, file)}: `\{ty}` has no `#gql.type`, so its methods are no fields",
              )
            }
            guard params is [{ name: Some("self"), .. }, .. rest] else {
              fail("\{at(attr, file)}: a field method takes `self` first")
            }
            let args = field_spec.bind(attr)
            function_field(
              out,
              handle(ty),
              quoted(type_name),
              "\{ty}::\{name}",
              attr,
              args,
              name,
              rest,
              returns,
              raw,
              file,
              Some(ty),
            )
          }
          None => {
            let full = @attr.name_of(attr).unwrap_or("")
            let args = root_spec(full).bind(attr)
            let obj = if full == "gql.query" {
              out.query = true
              "gql_query"
            } else {
              out.mutation = true
              "gql_mutation"
            }
            function_field(
              out,
              obj,
              "\{obj}.name",
              name,
              attr,
              args,
              name,
              params,
              returns,
              raw,
              file,
              None,
            )
          }
        }
      }
      Other(..) => ()
    }
  }
  for abs in abstracts {
    let (name, known, raw, attr, public, file) = abs
    let full = @attr.name_of(attr).unwrap_or("")
    abstract_type(
      out,
      name,
      known,
      raw,
      enum_spec(full).bind(attr),
      public,
      at(attr, file),
    )
  }
  if out.types.is_empty() && out.fields.is_empty() {
    return @quote.join([])
  }
  let setup = []
  for scalar in out.scalars.keys() {
    setup.push(
      "if schema.scalar_by_name(\{quoted(scalar)}) is None { schema.scalar(\{quoted(scalar)}) }",
    )
  }
  setup.append(out.types)
  setup.append(out.abstracts)
  if out.query {
    setup.push(
      "let gql_query = match schema.type_by_name(schema.query) { Some(t) => t; None => schema.object(schema.query) }",
    )
  }
  if out.mutation {
    setup.push(
      (
        $|let gql_mutation = match schema.mutation {
        $|  Some(n) => match schema.type_by_name(n) { Some(t) => t; None => schema.object(n) }
        $|  None => { schema.set_mutation("Mutation"); schema.object("Mutation") }
        $|}
      ),
    )
  }
  setup.append(out.fields)
  let source =
    $|pub fn register(schema : @moongql.Schema, resolvers : @moongql.Resolvers) -> Unit {
    $|  \{setup.join("\n")}
    $|}
    $|
    $|\{out.impls.join("\n\n")}
  @quote.items(source).render()
}
