// `#gql.sdl`: the schema written first, in SDL, and everything around it generated.
//
// An object type's scalar and enum fields become a struct, and every other field becomes a
// `declare fn` for the user to fill in: root fields, fields with arguments and fields of an
// object type. The compiler then names whatever is missing. A struct the package declares
// itself takes the place of the generated one, which is where a value keeps what the schema
// does not show, such as the id behind a relation.

///|
let sdl_spec : @attr.Spec = @attr.Spec::new("gql.sdl").optional("file", Str)

///|
/// Schema text, and the expression that gives it to the generated code.
priv struct Source {
  text : String
  expr : String
  where_ : String
}

///|
/// The value of a `#|` string, which is the literal a schema is written in.
fn literal(expr : @syntax.Expr) -> String? {
  guard expr is MultilineString(elems~, ..) else { return None }
  let lines = []
  for elem in elems {
    guard elem is String(line) else { return None }
    lines.push(line)
  }
  Some(lines.join("\n"))
}

///|
/// The `#gql.sdl` among `attrs`.
fn sdl_attr(
  attrs : @list.List[@attribute.Attribute],
  file : String,
) -> @attribute.Attribute? raise {
  ignore(gql_attrs(attrs, file))
  for attr in @attr.under(attrs, "gql") {
    if @attr.name_of(attr) == Some("gql.sdl") {
      return Some(attr)
    }
  }
  None
}

///|
/// `path` beside the source file `file`.
fn beside(file : String, path : String) -> String {
  let cut = match (file.rev_find("/"), file.rev_find("\\")) {
    (Some(a), Some(b)) => Some(if a > b { a } else { b })
    (Some(a), None) | (None, Some(a)) => Some(a)
    (None, None) => None
  }
  match cut {
    Some(at) => file.view(end_offset=at + 1).to_owned() + path
    None => path
  }
}

///|
/// `text` with `\n` line endings: a checkout may turn the file's into `\r\n`, and the same schema
/// has to generate the same bytes on every system.
fn line_feeds(text : String) -> String {
  text.replace_all(old="\r\n", new="\n")
}

///|
/// The body of a `declare fn` that `#gql.sdl(file=...)` gives its text through, and the source.
fn file_source(
  attr : @attribute.Attribute,
  name : String,
  raw : @syntax.Impl,
  file : String,
  impls : Array[String],
) -> Source raise {
  let where_ = at(attr, file)
  guard sdl_spec.bind(attr).str("file") is Some(path) else {
    fail("\{where_}: `#gql.sdl` on a function names its `file`")
  }
  guard raw is TopFuncDef(decl_body=DeclNone, ..) else {
    fail("\{where_}: `#gql.sdl` goes on a `declare fn`, which it gives a body")
  }
  let text = line_feeds(
    @fs.read_file_to_string(beside(file, path)) catch {
      _ => fail("\{where_}: cannot read `\{path}`")
    },
  )
  impls.push("fn \{name}() -> String {\n  \{quoted(text)}\n}")
  { text, expr: "\{name}()", where_, }
}

///|
/// Every piece of schema text in the package.
fn sdl_sources(
  decls : Array[@gen.Decl],
  impls : Array[String],
) -> Array[Source] raise {
  let found = []
  for decl in decls {
    match decl {
      Other(file~, raw=TopLetDef(binder~, expr~, attrs~, ..)) =>
        if sdl_attr(attrs, file) is Some(attr) {
          let where_ = at(attr, file)
          if sdl_spec.bind(attr).str("file") is Some(_) {
            fail(
              "\{where_}: a `let` holds the text itself; `file` goes on a `declare fn`",
            )
          }
          guard literal(expr) is Some(text) else {
            fail("\{where_}: `#gql.sdl` reads a `#|` string")
          }
          found.push({ text, expr: binder.name, where_, })
        }
      Func(name~, attrs~, file~, raw~, ..) =>
        if sdl_attr(attrs, file) is Some(attr) {
          found.push(file_source(attr, name, raw, file, impls))
        }
      _ => ()
    }
  }
  found
}

///|
/// `gqlName` as a MoonBit identifier.
fn snake(name : String) -> String {
  let out = StringBuilder()
  for c in name {
    if c >= 'A' && c <= 'Z' {
      if !out.is_empty() {
        out.write_char('_')
      }
      out.write_char(c.to_ascii_lowercase())
    } else {
      out.write_char(c)
    }
  }
  let text = out.to_string()
  if reserved.contains(text) {
    text + "_"
  } else {
    text
  }
}

///|
/// The words a field may be called in GraphQL and an identifier may not in MoonBit.
let reserved : Array[String] = [
  "abstract", "alias", "and", "anyframe", "anytype", "as", "asm", "assert", "async",
  "atomic", "await", "break", "catch", "comptime", "const", "constructor", "continue",
  "declare", "defer", "derive", "do", "dyn", "dynclass", "dynobj", "else", "enum",
  "export", "extern", "false", "final", "finally", "fn", "for", "guard", "if", "impl",
  "import", "in", "include", "is", "lazy", "let", "local", "loop", "macro", "match",
  "member", "method", "module", "move", "mut", "namespace", "noasync", "noraise",
  "opaque", "orelse", "override", "package", "priv", "protected", "pub", "raise",
  "ref", "resume", "return", "sealed", "self", "static", "struct", "suberror", "super",
  "test", "threadlocal", "throw", "trait", "true", "try", "type", "typealias", "typeof",
  "unreachable", "unsafe", "use", "using", "var", "virtual", "void", "volatile",
  "where", "while", "with", "yield",
]

///|
/// The MoonBit type of a GraphQL type; `Json` for a custom scalar, whose shape is the user's.
fn moon_type(schema : @schema.Schema, ty : @schema.GqlType) -> String {
  let bare = (ty : @schema.GqlType) => {
    match ty {
      ListOf(inner) => "Array[\{moon_type(schema, inner)}]"
      Scalar("String" | "ID") => "String"
      Scalar("Int") => "Int32"
      Scalar("Int64") => "Int64"
      Scalar("Float") => "Double"
      Scalar("Boolean") => "Bool"
      Scalar(_) => "Json"
      Named(name) =>
        if schema.scalar_by_name(name) is Some(_) {
          "Json"
        } else {
          name
        }
      NonNull(inner) => moon_type(schema, inner)
    }
  }
  match ty {
    NonNull(inner) => bare(inner)
    other => bare(other) + "?"
  }
}

///|
/// The named type at the bottom of `ty`.
fn bottom(ty : @schema.GqlType) -> @schema.GqlType {
  match ty {
    NonNull(inner) | ListOf(inner) => bottom(inner)
    other => other
  }
}

///|
/// Whether a value of `ty` is data the parent can hold, rather than another object to resolve.
fn holds(schema : @schema.Schema, ty : @schema.GqlType) -> Bool {
  match bottom(ty) {
    Scalar(_) => true
    Named(name) =>
      schema.scalar_by_name(name) is Some(_) ||
      schema.enum_by_name(name) is Some(_)
    _ => false
  }
}

///|
/// The object types an interface or union stands for.
fn members_of(schema : @schema.Schema, name : String) -> Array[String] {
  for u in schema.unions {
    if u.name == name {
      return u.members
    }
  }
  schema.types
  .filter(t => t.kind == Object && t.interfaces.contains(name))
  .map(t => t.name)
}

///|
/// The impls of a type carried as keyed fields, `pairs` being (MoonBit field, GraphQL key).
fn keyed_impls(
  name : String,
  typename : String?,
  pairs : Array[(String, String)],
) -> String {
  let writes = pairs.map(p => {
    "\{quoted(p.1)}: @moongql.ToGql::to_gql(self.\{p.0})"
  })
  if typename is Some(n) {
    writes.insert(0, "\"__typename\": \{quoted(n)}")
  }
  let reads = pairs.map(p => "\{p.0}: @moongql.read(v, \{quoted(p.1)})")
  (
    $|pub impl @moongql.ToGql for \{name} with fn to_gql(self) {
    $|  { \{writes.join(", ")} }
    $|}
    $|
    $|pub impl @moongql.FromGql for \{name} with fn from_gql(v) {
    $|  \{name}::{ \{reads.join(", ")} }
    $|}
  )
}

///|
/// The struct and impls of an input type, whose every field is data.
fn input_type(
  schema : @schema.Schema,
  t : @schema.ObjectType,
  impls : Array[String],
) -> Unit {
  let fields = t.fields.map(f => {
    "\{snake(f.name)} : \{moon_type(schema, f.typ)}"
  })
  impls.push("pub(all) struct \{t.name} {\n  \{fields.join("\n")}\n}")
  impls.push(
    keyed_impls(t.name, None, t.fields.map(f => (snake(f.name), f.name))),
  )
}

///|
/// The `declare fn` of one field and the resolver that calls it. A root field has no value to be
/// asked on, so it takes none.
fn resolver(
  schema : @schema.Schema,
  owner : String,
  root : Bool,
  field : @schema.Field,
  out : Out,
) -> Unit {
  let params = if root { [] } else { ["self : \{owner}"] }
  let call = if root { [] } else { ["@moongql.FromGql::from_gql(info.parent)"] }
  for arg in field.args {
    let (name, ty) = arg
    let read = "info.read(\{quoted(name)})"
    if ty is NonNull(_) {
      params.push("\{snake(name)} : \{moon_type(schema, ty)}")
      call.push(read)
    } else {
      let bare = moon_type(schema, NonNull(ty))
      params.push("\{snake(name)}? : \{bare}")
      call.push("\{snake(name)}?=\{read}")
    }
  }
  let callee = snake(field.name)
  out.impls.push(
    "declare fn \{owner}::\{callee}(\{params.join(", ")}) -> \{moon_type(schema, field.typ)} raise",
  )
  let value = "\{owner}::\{callee}(\{call.join(", ")}) catch { e => raise @moongql.field_error(e) }"
  out.fields.push(
    "resolvers.field(\{quoted(owner)}, \{quoted(field.name)}, info => @moongql.ToGql::to_gql(\{value}))",
  )
}

///|
/// The struct of an object type, the package's own when it declares one, and a resolver for each
/// field the struct does not answer.
fn object_type(
  schema : @schema.Schema,
  t : @schema.ObjectType,
  bound : Map[String, Array[String]],
  out : Out,
) -> Unit {
  let plain = (f : @schema.Field) => {
    f.args.is_empty() &&
    (match bound.get(t.name) {
      Some(names) => names.contains(snake(f.name))
      None => holds(schema, f.typ)
    })
  }
  let kept = t.fields.filter(plain)
  let pairs = match bound.get(t.name) {
    Some(names) =>
      names.map(name => {
        let sdl = kept.filter(f => snake(f.name) == name)
        (name, if sdl is [f] { f.name } else { camel(name) })
      })
    None => kept.map(f => (snake(f.name), f.name))
  }
  if !bound.contains(t.name) {
    let fields = kept.map(f => "\{snake(f.name)} : \{moon_type(schema, f.typ)}")
    out.impls.push("pub(all) struct \{t.name} {\n  \{fields.join("\n")}\n}")
  }
  out.impls.push(keyed_impls(t.name, Some(t.name), pairs))
  for f in t.fields {
    if !plain(f) {
      resolver(schema, t.name, false, f, out)
    }
  }
}

///|
/// An interface or union as an enum over the object types it stands for.
fn abstract_of(
  schema : @schema.Schema,
  name : String,
  impls : Array[String],
) -> Unit {
  let members = members_of(schema, name)
  let cases = members.map(m => "\{m}(\{m})")
  let writes = members.map(m => "\{m}(v) => @moongql.ToGql::to_gql(v)")
  let reads = members.map(m => {
    "{ \"__typename\": String(\{quoted(m)}), .. } => \{m}(@moongql.FromGql::from_gql(v))"
  })
  impls.push(
    (
      $|pub(all) enum \{name} {
      $|  \{cases.join("\n")}
      $|}
      $|
      $|pub impl @moongql.ToGql for \{name} with fn to_gql(self) {
      $|  match self {
      $|    \{writes.join("\n")}
      $|  }
      $|}
      $|
      $|pub impl @moongql.FromGql for \{name} with fn from_gql(v) {
      $|  match v {
      $|    \{reads.join("\n")}
      $|    other => raise @moongql.ResolverError::expected(\{quoted(name)}, other)
      $|  }
      $|}
    ),
  )
}

///|
/// An enum, its constructors named after its values.
fn enum_of(e : @schema.EnumType, impls : Array[String]) -> Unit {
  let case_of = (value : String) => {
    match value.get_char(0) {
      Some(c) if c >= 'a' && c <= 'z' =>
        c.to_ascii_uppercase().to_string() +
        value.view(start_offset=1).to_owned()
      _ => value
    }
  }
  let writes = e.values.map(v => "\{case_of(v)} => \{quoted(v)}")
  let reads = e.values.map(v => "String(\{quoted(v)}) => \{case_of(v)}")
  impls.push(
    (
      $|pub(all) enum \{e.name} {
      $|  \{e.values.map(case_of).join("\n")}
      $|} derive(Eq, Debug)
      $|
      $|pub impl @moongql.ToGql for \{e.name} with fn to_gql(self) {
      $|  match self {
      $|    \{writes.join("\n")}
      $|  }
      $|}
      $|
      $|pub impl @moongql.FromGql for \{e.name} with fn from_gql(v) {
      $|  match v {
      $|    \{reads.join("\n")}
      $|    other => raise @moongql.ResolverError::expected(\{quoted(e.name)}, other)
      $|  }
      $|}
    ),
  )
}

///|
/// The plain structs of the package, by name, with their field names; a struct `#gql.type` has
/// claimed is code first and clashes with a type of the same name in the schema.
fn bindable(
  decls : Array[@gen.Decl],
  schema : @schema.Schema,
  where_ : String,
) -> Map[String, Array[String]] raise {
  let found : Map[String, Array[String]] = Map([])
  for decl in decls {
    if decl is Struct(name~, fields~, attrs~, file~, ..) &&
      schema.type_by_name(name) is Some(_) {
      if gql_attrs(attrs, file) is [_, ..] {
        fail(
          "\{where_}: `\{name}` is in the schema and also annotated; bind the struct by leaving its `#gql.*` off",
        )
      }
      found[name] = fields.map(f => f.name)
    }
  }
  found
}

///|
/// Everything `#gql.sdl` in the package generates, into `out`.
fn schema_first(decls : Array[@gen.Decl], out : Out) -> Unit raise {
  let sources = sdl_sources(decls, out.impls)
  guard sources is [first, ..] else { return }
  let text = sources.map(s => s.text).join("\n")
  let schema = @schema.Schema::of_sdl(text) catch {
    e => fail("\{first.where_}: \{e}")
  }
  let bound = bindable(decls, schema, first.where_)
  out.types.push(
    "schema.add_sdl(\{sources.map(s => s.expr).join(" + \"\\n\" + ")}) catch { e => abort(e.to_string()) }",
  )
  let roots = [schema.query]
  if schema.mutation is Some(name) {
    roots.push(name)
  }
  for t in schema.types {
    match t.kind {
      Input => input_type(schema, t, out.impls)
      Interface => abstract_of(schema, t.name, out.impls)
      Object =>
        if roots.contains(t.name) {
          out.impls.push("pub(all) struct \{t.name} {}")
          for f in t.fields {
            resolver(schema, t.name, true, f, out)
          }
        } else if schema.subscription == Some(t.name) {
          fail(
            "\{first.where_}: a `Subscription` in SDL is not generated; mark the function `#gql.subscription`",
          )
        } else {
          object_type(schema, t, bound, out)
        }
    }
  }
  for e in schema.enums {
    enum_of(e, out.impls)
  }
  for u in schema.unions {
    abstract_of(schema, u.name, out.impls)
  }
}
