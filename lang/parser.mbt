///|
/// A recursive-descent GraphQL parser producing an executable `Document` AST. It
/// implements the executable half of the GraphQL grammar — operations
/// (query/mutation/subscription and the `{ ... }` shorthand), selection sets,
/// fields with aliases/arguments/directives, variable definitions with default
/// values, named and inline fragments, and directives — matching what
/// `graphql-core` (strawberry's parser) produces. Type-system (SDL) definitions
/// are handled by the code-first schema builder in `schema.mbt`.

///|
/// The parser holds a lexer and a one-token lookahead (`current`).
priv struct Parser {
  lexer : Lexer
  mut current : Token
}

///|
/// Create a parser over `source`, priming the first token.
fn Parser::new(source : String) -> Parser raise GqlSyntaxError {
  let lexer = Lexer::new(source)
  let current = lexer.next_token()
  { lexer, current, }
}

///|
/// Consume and return the current token, advancing to the next.
fn Parser::advance(self : Parser) -> Token raise GqlSyntaxError {
  let tok = self.current
  self.current = self.lexer.next_token()
  tok
}

///|
/// Whether the current token has kind `k`.
fn Parser::at(self : Parser, k : TokenKind) -> Bool {
  self.current.kind == k
}

///|
/// Whether the current token is a `Name` with text `s` (a keyword check).
fn Parser::at_keyword(self : Parser, s : String) -> Bool {
  self.current.kind is Name && self.current.value == s
}

///|
/// A human-readable description of a token kind, for error messages.
fn token_desc(k : TokenKind) -> String {
  match k {
    Name => "a name"
    IntVal => "an int value"
    FloatVal => "a float value"
    StringVal => "a string value"
    BlockStringVal => "a block string"
    Bang => "'!'"
    Dollar => "'$'"
    Amp => "'&'"
    ParenL => "'('"
    ParenR => "')'"
    Spread => "'...'"
    Colon => "':'"
    Equals => "'='"
    At => "'@'"
    BracketL => "'['"
    BracketR => "']'"
    BraceL => "'{'"
    BraceR => "'}'"
    Pipe => "'|'"
    Eof => "<eof>"
  }
}

///|
/// A short description of the current token, for "found X" diagnostics.
fn Parser::current_desc(self : Parser) -> String {
  match self.current.kind {
    Name => "name '" + self.current.value + "'"
    IntVal | FloatVal => "value '" + self.current.value + "'"
    StringVal | BlockStringVal => "a string"
    other => token_desc(other)
  }
}

///|
/// The current token's position, taken before the token is consumed so a node
/// records where it starts.
fn Parser::pos(self : Parser) -> Pos {
  { line: self.current.line, col: self.current.col, }
}

///|
/// Raise a syntax error at the current token's position (expression position:
/// the polymorphic return lets it stand in for any value).
fn[T] Parser::fail(self : Parser, msg : String) -> T raise GqlSyntaxError {
  raise GqlSyntaxError(msg, self.current.line, self.current.col)
}

///|
/// Raise a syntax error at the current token's position (statement position).
fn Parser::err(self : Parser, msg : String) -> Unit raise GqlSyntaxError {
  raise GqlSyntaxError(msg, self.current.line, self.current.col)
}

///|
/// Consume a token of kind `k`, or raise "expected ..., found ...".
fn Parser::expect(self : Parser, k : TokenKind) -> Token raise GqlSyntaxError {
  if self.at(k) {
    self.advance()
  } else {
    self.fail("expected " + token_desc(k) + ", found " + self.current_desc())
  }
}

///|
/// Consume the current `Name` token and return its text, or raise.
fn Parser::expect_name(self : Parser) -> String raise GqlSyntaxError {
  self.expect(Name).value
}

///|
/// Consume a `Name` token equal to the keyword `kw`, or raise.
fn Parser::expect_keyword(
  self : Parser,
  kw : String,
) -> Unit raise GqlSyntaxError {
  if self.at_keyword(kw) {
    self.advance() |> ignore
  } else {
    self.fail("expected '" + kw + "', found " + self.current_desc())
  }
}

///|
/// Parse a complete document: a sequence of executable definitions up to `Eof`.
fn Parser::parse_document(self : Parser) -> Document raise GqlSyntaxError {
  let definitions = []
  while !self.at(Eof) {
    definitions.push(self.parse_definition())
  }
  if definitions.length() == 0 {
    self.err("expected at least one definition")
  }
  { definitions, }
}

///|
/// Parse one top-level definition: an operation (long form or `{ ... }`
/// shorthand) or a fragment definition.
fn Parser::parse_definition(self : Parser) -> Definition raise GqlSyntaxError {
  if self.at(BraceL) {
    return OperationDef(self.parse_operation())
  }
  if self.at_keyword("query") ||
    self.at_keyword("mutation") ||
    self.at_keyword("subscription") {
    return OperationDef(self.parse_operation())
  }
  if self.at_keyword("fragment") {
    return FragmentDef(self.parse_fragment())
  }
  self.fail(
    "expected 'query', 'mutation', 'subscription', 'fragment' or '{', found " +
    self.current_desc(),
  )
}

///|
/// Parse an operation definition, including the anonymous query shorthand.
fn Parser::parse_operation(
  self : Parser,
) -> OperationDefinition raise GqlSyntaxError {
  let pos = self.pos()
  if self.at(BraceL) {
    let selection_set = self.parse_selection_set()
    return {
      operation: Query,
      name: None,
      variable_definitions: [],
      directives: [],
      selection_set,
      pos,
    }
  }
  let operation = match self.current.value {
    "query" => Query
    "mutation" => Mutation
    _ => Subscription
  }
  self.advance() |> ignore
  let name = if self.at(Name) { Some(self.advance().value) } else { None }
  let variable_definitions = self.parse_variable_definitions()
  let directives = self.parse_directives()
  let selection_set = self.parse_selection_set()
  { operation, name, variable_definitions, directives, selection_set, pos, }
}

///|
/// Parse `($v: T = default @dir, ...)`, or an empty list when absent.
fn Parser::parse_variable_definitions(
  self : Parser,
) -> Array[VariableDefinition] raise GqlSyntaxError {
  let defs = []
  if !self.at(ParenL) {
    return defs
  }
  self.advance() |> ignore
  while !self.at(ParenR) && !self.at(Eof) {
    let pos = self.pos()
    self.expect(Dollar) |> ignore
    let variable = self.expect_name()
    self.expect(Colon) |> ignore
    let typ = self.parse_type()
    let default_value = if self.at(Equals) {
      self.advance() |> ignore
      Some(self.parse_value(true))
    } else {
      None
    }
    let directives = self.parse_directives()
    defs.push({ variable, typ, default_value, directives, pos, })
  }
  self.expect(ParenR) |> ignore
  defs
}

///|
/// Parse a type reference: `Name`, `[Type]`, or either followed by `!`.
fn Parser::parse_type(self : Parser) -> TypeRef raise GqlSyntaxError {
  let mut t = if self.at(BracketL) {
    self.advance() |> ignore
    let inner = self.parse_type()
    self.expect(BracketR) |> ignore
    ListType(inner)
  } else {
    NamedType(self.expect_name())
  }
  if self.at(Bang) {
    self.advance() |> ignore
    t = NonNullType(t)
  }
  t
}

///|
/// Parse zero or more `@name(args)` directives.
fn Parser::parse_directives(
  self : Parser,
) -> Array[Directive] raise GqlSyntaxError {
  let ds = []
  while self.at(At) {
    let pos = self.pos()
    self.advance() |> ignore
    let name = self.expect_name()
    let arguments = self.parse_arguments(false)
    ds.push({ name, arguments, pos, })
  }
  ds
}

///|
/// Parse `(name: value, ...)`, or an empty list when absent. `const` forbids
/// variables in the values (used for default values and directive args in
/// variable definitions).
fn Parser::parse_arguments(
  self : Parser,
  const_ : Bool,
) -> Array[Argument] raise GqlSyntaxError {
  let args = []
  if !self.at(ParenL) {
    return args
  }
  self.advance() |> ignore
  while !self.at(ParenR) && !self.at(Eof) {
    let pos = self.pos()
    let name = self.expect_name()
    self.expect(Colon) |> ignore
    let value = self.parse_value(const_)
    args.push({ name, value, pos, })
  }
  self.expect(ParenR) |> ignore
  args
}

///|
/// Parse a non-empty selection set `{ selection+ }`.
fn Parser::parse_selection_set(
  self : Parser,
) -> Array[Selection] raise GqlSyntaxError {
  self.expect(BraceL) |> ignore
  let sels = []
  while !self.at(BraceR) && !self.at(Eof) {
    sels.push(self.parse_selection())
  }
  self.expect(BraceR) |> ignore
  if sels.length() == 0 {
    self.err("selection set must contain at least one selection")
  }
  sels
}

///|
/// Parse one selection: a field, a `...Name` fragment spread, or a
/// `... on Type { ... }` / `... { ... }` inline fragment.
fn Parser::parse_selection(self : Parser) -> Selection raise GqlSyntaxError {
  if self.at(Spread) {
    let pos = self.pos()
    self.advance() |> ignore
    if self.at_keyword("on") {
      self.advance() |> ignore
      let cond = self.expect_name()
      let directives = self.parse_directives()
      let sels = self.parse_selection_set()
      return InlineFragmentSel(Some(cond), directives, sels, pos)
    }
    if self.at(Name) {
      let name = self.advance().value
      let directives = self.parse_directives()
      return FragmentSpreadSel(name, directives, pos)
    }
    let directives = self.parse_directives()
    let sels = self.parse_selection_set()
    return InlineFragmentSel(None, directives, sels, pos)
  }
  FieldSel(self.parse_field())
}

///|
/// Parse a field: `alias: name(args) @dir { ... }` (alias and the trailing
/// selection set are optional).
fn Parser::parse_field(self : Parser) -> QueryField raise GqlSyntaxError {
  let pos = self.pos()
  let first = self.expect_name()
  let mut field_alias : String? = None
  let mut name = first
  if self.at(Colon) {
    self.advance() |> ignore
    field_alias = Some(first)
    name = self.expect_name()
  }
  let arguments = self.parse_arguments(false)
  let directives = self.parse_directives()
  let selection_set = if self.at(BraceL) {
    self.parse_selection_set()
  } else {
    []
  }
  { alias_: field_alias, name, arguments, directives, selection_set, pos, }
}

///|
/// Parse a fragment definition: `fragment Name on Type @dir { ... }`. The
/// fragment name must not be the reserved word `on`.
fn Parser::parse_fragment(
  self : Parser,
) -> FragmentDefinition raise GqlSyntaxError {
  let pos = self.pos()
  self.expect_keyword("fragment")
  if self.at_keyword("on") {
    self.err("fragment name must not be 'on'")
  }
  let name = self.expect_name()
  self.expect_keyword("on")
  let type_condition = self.expect_name()
  let directives = self.parse_directives()
  let selection_set = self.parse_selection_set()
  { name, type_condition, directives, selection_set, pos, }
}

///|
/// Parse an input value. `const` (used for default values) forbids `$variable`.
fn Parser::parse_value(
  self : Parser,
  const_ : Bool,
) -> Value raise GqlSyntaxError {
  match self.current.kind {
    Dollar => {
      if const_ {
        self.err("variable is not allowed in a constant value")
      }
      self.advance() |> ignore
      Variable(self.expect_name())
    }
    IntVal => IntValue(self.advance().value)
    FloatVal => FloatValue(self.advance().value)
    StringVal => StringValue(self.advance().value, false)
    BlockStringVal => StringValue(self.advance().value, true)
    Name =>
      match self.current.value {
        "true" => {
          self.advance() |> ignore
          BooleanValue(true)
        }
        "false" => {
          self.advance() |> ignore
          BooleanValue(false)
        }
        "null" => {
          self.advance() |> ignore
          NullValue
        }
        _ => EnumValue(self.advance().value)
      }
    BracketL => {
      self.advance() |> ignore
      let items = []
      while !self.at(BracketR) && !self.at(Eof) {
        items.push(self.parse_value(const_))
      }
      self.expect(BracketR) |> ignore
      ListValue(items)
    }
    BraceL => {
      self.advance() |> ignore
      let fields = []
      while !self.at(BraceR) && !self.at(Eof) {
        let k = self.expect_name()
        self.expect(Colon) |> ignore
        let v = self.parse_value(const_)
        fields.push((k, v))
      }
      self.expect(BraceR) |> ignore
      ObjectValue(fields)
    }
    _ => self.fail("expected a value, found " + self.current_desc())
  }
}

///|
/// Parse a GraphQL executable document from source text. This is the front half
/// of the executor: `parse(query).definitions` yields the operations and
/// fragments to validate and execute.
pub fn parse(source : String) -> Document raise GqlSyntaxError {
  let p = Parser::new(source)
  p.parse_document()
}
