///|
/// The other half of SDL printing: read a type-system document back into a
/// `Schema`, so that `Schema::of_sdl(s.to_sdl())` describes the schema it was
/// printed from. The reader shares the lexer with executable documents — the
/// type system is a superset of the same grammar — and reports a bad document
/// as the same `GqlSyntaxError` (with its line and column) that `parse` does.
///
/// It reads everything `to_sdl` writes: the `schema { ... }` block and its
/// directives, directive definitions, `type` / `input` / `interface` /
/// `enum` / `union` / `scalar` definitions, descriptions, `implements`,
/// argument default values, `@deprecated(reason:)` and applied directives.
/// What it cannot recover from a printed document — a custom scalar's
/// `serialize` / `parse_value` hooks, and a directive's `on_field` hook — comes
/// back as the identity, since those are MoonBit functions and not SDL.

///|
/// A cursor over the token stream the lexer produced.
priv struct SdlCursor {
  tokens : Array[@lang.Token]
  mut pos : Int32
}

///|
/// Tokenise `text` and stand at its first token.
fn SdlCursor::of(text : String) -> SdlCursor raise @lang.GqlSyntaxError {
  { tokens: @lang.tokenize(text), pos: 0, }
}

///|
/// The token at the cursor. The lexer always ends with an `Eof`, so there is
/// always one.
fn SdlCursor::peek(self : SdlCursor) -> @lang.Token {
  self.tokens[self.pos]
}

///|
/// Consume the token at the cursor and return it. `Eof` is never consumed, so a
/// reader that runs off the end sees it forever rather than overrunning.
fn SdlCursor::bump(self : SdlCursor) -> @lang.Token {
  let t = self.tokens[self.pos]
  if !(t.kind == @lang.Eof) {
    self.pos = self.pos + 1
  }
  t
}

///|
/// Whether the token at the cursor is `kind`.
fn SdlCursor::at(self : SdlCursor, kind : @lang.TokenKind) -> Bool {
  self.peek().kind == kind
}

///|
/// Whether the reader should keep taking elements: until `kind` closes the list,
/// or until the document ends (which the following `take` turns into an error).
fn SdlCursor::until(self : SdlCursor, kind : @lang.TokenKind) -> Bool {
  !(self.at(kind) || self.at(@lang.Eof))
}

///|
/// Consume the token at the cursor, or report what was expected there.
fn SdlCursor::take(
  self : SdlCursor,
  kind : @lang.TokenKind,
  what : String,
) -> @lang.Token raise @lang.GqlSyntaxError {
  let t = self.peek()
  if !(t.kind == kind) {
    raise @lang.GqlSyntaxError("expected " + what, t.line, t.col)
  }
  self.bump()
}

///|
/// Consume a `Name` and return its text, or report what was expected there.
fn SdlCursor::name(
  self : SdlCursor,
  what : String,
) -> String raise @lang.GqlSyntaxError {
  let t = self.take(@lang.Name, what)
  t.value
}

///|
/// Consume the keyword `word` if it is next, answering whether it was there.
fn SdlCursor::word(self : SdlCursor, word : String) -> Bool {
  let t = self.peek()
  if t.kind == @lang.Name && t.value == word {
    self.bump() |> ignore
    true
  } else {
    false
  }
}

///|
/// Consume a description — a string or block-string literal immediately before
/// the element it describes — or answer `None`. An empty description is no
/// description, which is how introspection reports one too.
fn SdlCursor::description(self : SdlCursor) -> String? {
  let t = self.peek()
  if t.kind == @lang.StringVal || t.kind == @lang.BlockStringVal {
    self.bump() |> ignore
    if t.value == "" {
      None
    } else {
      Some(t.value)
    }
  } else {
    None
  }
}

///|
/// Consume a constant value — a literal, an enum name, a list or an object —
/// as the JSON an `AppliedDirective` argument or an argument default carries.
/// An enum value is kept as its name, which is what `json_to_gql_literal`
/// prints back.
fn SdlCursor::value(self : SdlCursor) -> Json raise @lang.GqlSyntaxError {
  let t = self.bump()
  match t.kind {
    @lang.IntVal | @lang.FloatVal =>
      @json.parse(t.value) catch {
        _ => Json::null()
      }
    @lang.StringVal | @lang.BlockStringVal => Json(t.value)
    @lang.Name =>
      match t.value {
        "true" => Json(true)
        "false" => Json(false)
        "null" => Json::null()
        _ => Json(t.value)
      }
    @lang.BracketL => {
      let items : Array[Json] = []
      while self.until(@lang.BracketR) {
        items.push(self.value())
      }
      self.take(@lang.BracketR, "']' to close a list value") |> ignore
      Json(items)
    }
    @lang.BraceL => {
      let out : Map[String, Json] = Map([])
      while self.until(@lang.BraceR) {
        let k = self.name("an object field name")
        self.take(@lang.Colon, "':' before an object field value") |> ignore
        out[k] = self.value()
      }
      self.take(@lang.BraceR, "'}' to close an object value") |> ignore
      Json(out)
    }
    _ => raise @lang.GqlSyntaxError("expected a value", t.line, t.col)
  }
}

///|
/// Consume a type reference — `Name`, `[T]`, and any number of `!` — as the
/// `GqlType` the schema builder speaks. A name that is one of the five built-in
/// scalars becomes a `Scalar`; every other name is a reference to a declared
/// type.
fn SdlCursor::type_ref(self : SdlCursor) -> GqlType raise @lang.GqlSyntaxError {
  let mut t = if self.at(@lang.BracketL) {
    self.bump() |> ignore
    let inner = self.type_ref()
    self.take(@lang.BracketR, "']' to close a list type") |> ignore
    ListOf(inner)
  } else {
    let n = self.name("a type name")
    if is_builtin_scalar(n) {
      Scalar(n)
    } else {
      Named(n)
    }
  }
  if self.at(@lang.Bang) {
    self.bump() |> ignore
    t = NonNull(t)
  }
  t
}

///|
/// Consume an argument list `(a: A = v, b: B)`: the declarations in order, plus
/// each defaulted argument's value keyed by name.
fn SdlCursor::arguments(
  self : SdlCursor,
) -> (Array[(String, GqlType)], Map[String, Json]) raise @lang.GqlSyntaxError {
  let args : Array[(String, GqlType)] = []
  let defaults : Map[String, Json] = Map([])
  self.take(@lang.ParenL, "'(' to open an argument list") |> ignore
  while self.until(@lang.ParenR) {
    self.description() |> ignore
    let n = self.name("an argument name")
    self.take(@lang.Colon, "':' before an argument type") |> ignore
    let t = self.type_ref()
    if self.at(@lang.Equals) {
      self.bump() |> ignore
      defaults[n] = self.value()
    }
    self.directives() |> ignore
    args.push((n, t))
  }
  self.take(@lang.ParenR, "')' to close an argument list") |> ignore
  (args, defaults)
}

///|
/// Consume a directive list `@a @b(x: 1)`, each with its constant arguments.
fn SdlCursor::directives(
  self : SdlCursor,
) -> Array[AppliedDirective] raise @lang.GqlSyntaxError {
  let out : Array[AppliedDirective] = []
  while self.at(@lang.At) {
    self.bump() |> ignore
    let name = self.name("a directive name")
    let args : Array[(String, Json)] = []
    if self.at(@lang.ParenL) {
      self.bump() |> ignore
      while self.until(@lang.ParenR) {
        let n = self.name("a directive argument name")
        self.take(@lang.Colon, "':' before a directive argument value")
        |> ignore
        args.push((n, self.value()))
      }
      self.take(@lang.ParenR, "')' to close a directive argument list")
      |> ignore
    }
    out.push(AppliedDirective::new(name, args~))
  }
  out
}

///|
/// The `reason:` of a `@deprecated`, or the reason the specification gives an
/// `@deprecated` that states none.
fn deprecated_reason_of(d : AppliedDirective) -> String {
  let mut reason = "No longer supported"
  for a in d.args {
    if a.0 == "reason" {
      match a.1 {
        String(s) => reason = s
        _ => ()
      }
    }
  }
  reason
}

///|
/// The `url:` of a `@specifiedBy`.
fn specified_url_of(d : AppliedDirective) -> String {
  let mut url = ""
  for a in d.args {
    if a.0 == "url" {
      match a.1 {
        String(s) => url = s
        _ => ()
      }
    }
  }
  url
}

///|
/// Consume one definition — the unit a type-system document is made of — and
/// record it on `schema`. `extend` is accepted and merges into the type of the
/// same name, which is how a federated subgraph's SDL reads back.
fn SdlCursor::definition(
  self : SdlCursor,
  schema : Schema,
) -> Unit raise @lang.GqlSyntaxError {
  let description = self.description()
  let extends = self.word("extend")
  let t = self.peek()
  if !(t.kind == @lang.Name) {
    raise @lang.GqlSyntaxError(
      "expected a type system definition",
      t.line,
      t.col,
    )
  }
  match t.value {
    "schema" => {
      self.bump() |> ignore
      self.schema_def(schema)
    }
    "type" => {
      self.bump() |> ignore
      self.composite(schema, Object, description, extends)
    }
    "input" => {
      self.bump() |> ignore
      self.composite(schema, Input, description, extends)
    }
    "interface" => {
      self.bump() |> ignore
      self.composite(schema, Interface, description, extends)
    }
    "enum" => {
      self.bump() |> ignore
      self.enum_def(schema, description)
    }
    "union" => {
      self.bump() |> ignore
      self.union_def(schema, description)
    }
    "scalar" => {
      self.bump() |> ignore
      self.scalar_def(schema, description)
    }
    "directive" => {
      self.bump() |> ignore
      self.directive_def(schema)
    }
    _ =>
      raise @lang.GqlSyntaxError(
        "expected a type system definition, got '\{t.value}'",
        t.line,
        t.col,
      )
  }
}

///|
/// Consume `schema @dir { query: Q mutation: M }`.
fn SdlCursor::schema_def(
  self : SdlCursor,
  schema : Schema,
) -> Unit raise @lang.GqlSyntaxError {
  for d in self.directives() {
    schema.apply_schema_directive(d)
  }
  self.take(@lang.BraceL, "'{' to open the schema definition") |> ignore
  while self.until(@lang.BraceR) {
    let root = self.name("a root operation type")
    self.take(@lang.Colon, "':' before a root operation type") |> ignore
    let name = self.name("a root operation type name")
    match root {
      "query" => schema.query = name
      "mutation" => schema.set_mutation(name)
      "subscription" => schema.set_subscription(name)
      _ =>
        raise @lang.GqlSyntaxError(
          "expected query, mutation or subscription, got '\{root}'",
          self.peek().line,
          self.peek().col,
        )
    }
  }
  self.take(@lang.BraceR, "'}' to close the schema definition") |> ignore
}

///|
/// Consume a `type` / `input` / `interface` block: its name, `implements`,
/// directives and field definitions. An `extend` merges fields into the type of
/// the same name when one is already declared.
fn SdlCursor::composite(
  self : SdlCursor,
  schema : Schema,
  kind : TypeKind,
  description : String?,
  _extends : Bool,
) -> Unit raise @lang.GqlSyntaxError {
  let name = self.name("a type name")
  let interfaces : Array[String] = []
  if self.word("implements") {
    if self.at(@lang.Amp) {
      self.bump() |> ignore
    }
    interfaces.push(self.name("an interface name"))
    while self.at(@lang.Amp) {
      self.bump() |> ignore
      interfaces.push(self.name("an interface name"))
    }
  }
  for d in self.directives() {
    schema.apply_type_directive(name, d)
  }
  self.take(@lang.BraceL, "'{' to open type " + name) |> ignore
  let fields : Array[Field] = []
  while self.until(@lang.BraceR) {
    let fdesc = self.description()
    let fname = self.name("a field name")
    let mut fargs : Array[(String, GqlType)] = []
    let mut fdefaults : Map[String, Json] = Map([])
    if self.at(@lang.ParenL) {
      let (a, d) = self.arguments()
      fargs = a
      fdefaults = d
    }
    self.take(@lang.Colon, "':' before a field type") |> ignore
    let ftyp = self.type_ref()
    let mut deprecation_reason : String? = None
    let applied : Array[AppliedDirective] = []
    for d in self.directives() {
      if d.name == "deprecated" {
        deprecation_reason = Some(deprecated_reason_of(d))
      } else {
        applied.push(d)
      }
    }
    fields.push({
      name: fname,
      args: fargs,
      typ: ftyp,
      arg_defaults: fdefaults,
      deprecation_reason,
      description: fdesc,
    })
    for d in applied {
      schema.apply_field_directive(name, fname, d)
    }
  }
  self.take(@lang.BraceR, "'}' to close type " + name) |> ignore
  let target = match schema.type_by_name(name) {
    Some(t) => t
    None => {
      let o : ObjectType = {
        name,
        fields: [],
        kind,
        interfaces: [],
        description,
      }
      schema.types.push(o)
      o
    }
  }
  for i in interfaces {
    target.interfaces.push(i)
  }
  for f in fields {
    target.fields.push(f)
  }
}

///|
/// Consume an `enum` block: its values, with each value's description and
/// `@deprecated(reason:)`.
fn SdlCursor::enum_def(
  self : SdlCursor,
  schema : Schema,
  description : String?,
) -> Unit raise @lang.GqlSyntaxError {
  let name = self.name("an enum type name")
  for d in self.directives() {
    schema.apply_type_directive(name, d)
  }
  self.take(@lang.BraceL, "'{' to open enum " + name) |> ignore
  let values : Array[String] = []
  let deprecations : Map[String, String] = Map([])
  let value_descriptions : Map[String, String] = Map([])
  while self.until(@lang.BraceR) {
    let vdesc = self.description()
    let v = self.name("an enum value")
    let mut deprecated : String? = None
    for d in self.directives() {
      if d.name == "deprecated" {
        deprecated = Some(deprecated_reason_of(d))
      }
    }
    values.push(v)
    match deprecated {
      Some(r) => deprecations[v] = r
      None => ()
    }
    match vdesc {
      Some(x) => value_descriptions[v] = x
      None => ()
    }
  }
  self.take(@lang.BraceR, "'}' to close enum " + name) |> ignore
  match schema.enum_by_name(name) {
    Some(e) =>
      for v in values {
        e.values.push(v)
      }
    None =>
      schema.enums.push({
        name,
        values,
        deprecations,
        description,
        value_descriptions,
      })
  }
}

///|
/// Consume `union Name @dir = A | B`, tolerating a leading `|`.
fn SdlCursor::union_def(
  self : SdlCursor,
  schema : Schema,
  description : String?,
) -> Unit raise @lang.GqlSyntaxError {
  let name = self.name("a union type name")
  for d in self.directives() {
    schema.apply_type_directive(name, d)
  }
  self.take(@lang.Equals, "'=' before the union member types") |> ignore
  let members : Array[String] = []
  if self.at(@lang.Pipe) {
    self.bump() |> ignore
  }
  members.push(self.name("a union member type name"))
  while self.at(@lang.Pipe) {
    self.bump() |> ignore
    members.push(self.name("a union member type name"))
  }
  match schema.union_by_name(name) {
    Some(u) =>
      for m in members {
        u.members.push(m)
      }
    None => schema.unions.push({ name, members, description, })
  }
}

///|
/// Consume `scalar Name @specifiedBy(url: "...")`.
fn SdlCursor::scalar_def(
  self : SdlCursor,
  schema : Schema,
  description : String?,
) -> Unit raise @lang.GqlSyntaxError {
  let name = self.name("a scalar type name")
  let mut spec_url : String? = None
  for d in self.directives() {
    if d.name == "specifiedBy" {
      spec_url = Some(specified_url_of(d))
    } else {
      schema.apply_type_directive(name, d)
    }
  }
  schema.scalars.push({
    name,
    serialize: fn(x) { x },
    parse_value: fn(x) { x },
    spec_url,
    description,
  })
}

///|
/// Consume `directive @name(a: A) repeatable on LOCATION | LOCATION`. An
/// executable hook cannot come from text, so a definition read back carries
/// none.
fn SdlCursor::directive_def(
  self : SdlCursor,
  schema : Schema,
) -> Unit raise @lang.GqlSyntaxError {
  self.take(@lang.At, "'@' before a directive name") |> ignore
  let name = self.name("a directive name")
  let mut args : Array[(String, GqlType)] = []
  if self.at(@lang.ParenL) {
    let (a, _) = self.arguments()
    args = a
  }
  let is_repeatable = self.word("repeatable")
  if !self.word("on") {
    let t = self.peek()
    raise @lang.GqlSyntaxError(
      "expected 'on' before the locations",
      t.line,
      t.col,
    )
  }
  let locations : Array[String] = []
  locations.push(self.name("a directive location"))
  while self.at(@lang.Pipe) {
    self.bump() |> ignore
    locations.push(self.name("a directive location"))
  }
  schema.directive_defs.push({
    name,
    locations,
    args,
    is_repeatable,
    on_field: None,
  })
}

///|
/// Build a schema from a type-system document (SDL), the inverse of `to_sdl`.
/// A document that is not a well-formed type-system definition raises
/// `GqlSyntaxError` carrying the line and column of the token that stopped it.
///
/// The hooks SDL cannot carry come back as the identity: a custom scalar's
/// `serialize` / `parse_value`, and a directive definition's `on_field`.
///
/// ```mbt nocheck
/// let s = Schema::of_sdl(
///   (
///     #|schema { query: Query }
///     #|
///     #|"The root of everything."
///     #|type Query {
///     #|  "Greets you."
///     #|  hello(name: String = "world"): String!
///     #|}
///   ),
/// )
/// // s.type_by_name("Query") carries the description and the default value.
/// ```
pub fn Schema::of_sdl(text : String) -> Schema raise @lang.GqlSyntaxError {
  let cur = SdlCursor::of(text)
  let schema = Schema::new()
  while cur.until(@lang.Eof) {
    cur.definition(schema)
  }
  schema
}
