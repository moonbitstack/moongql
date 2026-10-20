///|
/// A hand-written GraphQL lexer over the source's Unicode scalars. It turns a
/// query string into the token stream defined by the GraphQL spec's lexical
/// grammar (§2 of the June-2018 / October-2021 spec): names, punctuators,
/// int/float/string values, with whitespace, commas, BOM and `#` comments
/// treated as ignored tokens. No dependency on `core/lexbuf` — pure logic that
/// runs on every backend.

///|
/// A syntax error raised by the lexer or parser, carrying a message and the
/// 1-based line/column where the offending token starts.
pub suberror GqlSyntaxError {
  GqlSyntaxError(String, Int32, Int32)
}

///|
/// Render a syntax error as `Syntax error at L:C: message`.
pub fn GqlSyntaxError::to_string(self : GqlSyntaxError) -> String {
  let GqlSyntaxError(msg, line, col) = self
  "Syntax error at " + line.to_string() + ":" + col.to_string() + ": " + msg
}

///|
/// Prints the line and column the parse gave up at, which is the whole point of
/// hand-writing the parser.
pub impl Show for GqlSyntaxError with fn output(self, logger) {
  logger.write_string(self.to_string())
}

///|
/// The lexical category of a token. Value-bearing kinds (`Name`, `IntVal`,
/// `FloatVal`, `StringVal`, `BlockStringVal`) carry their text in `Token::value`.
pub(all) enum TokenKind {
  Name
  IntVal
  FloatVal
  StringVal
  BlockStringVal
  Bang
  Dollar
  Amp
  ParenL
  ParenR
  Spread
  Colon
  Equals
  At
  BracketL
  BracketR
  BraceL
  BraceR
  Pipe
  Eof
} derive(Eq)

///|
/// A lexical token: its kind, its text (for value-bearing kinds; unescaped for
/// strings), and the 1-based line/column of its first character.
pub(all) struct Token {
  kind : TokenKind
  value : String
  line : Int32
  col : Int32
}

///|
/// True for the first character of a `Name`: `_`, `A`-`Z` or `a`-`z`.
fn is_name_start(c : Char) -> Bool {
  c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

///|
/// True for a continuation character of a `Name`: a name-start or a digit.
fn is_name_continue(c : Char) -> Bool {
  is_name_start(c) || (c >= '0' && c <= '9')
}

///|
/// True for an ASCII decimal digit.
fn is_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// The value of a hex digit, or `None` if `c` is not `[0-9A-Fa-f]`.
fn hex_value(c : Char) -> Int32? {
  if c >= '0' && c <= '9' {
    Some(c.to_int() - '0'.to_int())
  } else if c >= 'a' && c <= 'f' {
    Some(c.to_int() - 'a'.to_int() + 10)
  } else if c >= 'A' && c <= 'F' {
    Some(c.to_int() - 'A'.to_int() + 10)
  } else {
    None
  }
}

///|
/// The GraphQL lexer: the source as an array of scalars plus a cursor and
/// 1-based line/column tracking for diagnostics.
priv struct Lexer {
  chars : Array[Char]
  mut pos : Int32
  mut line : Int32
  mut col : Int32
}

///|
/// Create a lexer positioned at the start of `src`.
fn Lexer::new(src : String) -> Lexer {
  let chars = []
  for c in src {
    chars.push(c)
  }
  { chars, pos: 0, line: 1, col: 1, }
}

///|
/// The character at the cursor, or `None` at end of input.
fn Lexer::peek(self : Lexer) -> Char? {
  if self.pos < self.chars.length() {
    Some(self.chars[self.pos])
  } else {
    None
  }
}

///|
/// The character `n` positions ahead, or `None` past the end.
fn Lexer::peek_at(self : Lexer, n : Int32) -> Char? {
  let i = self.pos + n
  if i < self.chars.length() {
    Some(self.chars[i])
  } else {
    None
  }
}

///|
/// Consume and return the character at the cursor, advancing line/column.
/// A `\r\n` pair is counted as a single line terminator.
fn Lexer::advance(self : Lexer) -> Char {
  let c = self.chars[self.pos]
  self.pos = self.pos + 1
  if c == '\n' {
    self.line = self.line + 1
    self.col = 1
  } else if c == '\r' {
    if self.pos < self.chars.length() && self.chars[self.pos] == '\n' {
      self.pos = self.pos + 1
    }
    self.line = self.line + 1
    self.col = 1
  } else {
    self.col = self.col + 1
  }
  c
}

///|
/// Skip ignored tokens: BOM, whitespace, line terminators, commas and `#`
/// comments (to end of line).
fn Lexer::skip_ignored(self : Lexer) -> Unit {
  for ;; {
    match self.peek() {
      Some('\u{FEFF}')
      | Some(' ')
      | Some('\t')
      | Some('\n')
      | Some('\r')
      | Some(',') => self.advance() |> ignore
      Some('#') =>
        for ;; {
          match self.peek() {
            Some('\n') | Some('\r') | None => break
            Some(_) => self.advance() |> ignore
          }
        }
      _ => break
    }
  }
}

///|
/// Read a `Name` token starting at the cursor (cursor is on a name-start char).
fn Lexer::read_name(self : Lexer, line : Int32, col : Int32) -> Token {
  let sb = StringBuilder()
  for ;; {
    match self.peek() {
      Some(c) =>
        if is_name_continue(c) {
          sb.write_char(self.advance())
        } else {
          break
        }
      None => break
    }
  }
  { kind: Name, value: sb.to_string(), line, col, }
}

///|
/// Read an `IntValue` or `FloatValue` starting at the cursor. Enforces the
/// spec's numeric shape: no leading zeros, at least one digit after `.`/`e`,
/// and no name-start/`.`/digit immediately trailing the number.
fn Lexer::read_number(
  self : Lexer,
  line : Int32,
  col : Int32,
) -> Token raise GqlSyntaxError {
  let sb = StringBuilder()
  let mut is_float = false
  if self.peek() is Some('-') {
    sb.write_char(self.advance())
  }
  // Integer part.
  match self.peek() {
    Some('0') => {
      sb.write_char(self.advance())
      if self.peek() is Some(d) && is_digit(d) {
        raise GqlSyntaxError(
          "invalid number: unexpected digit after leading 0", line, col,
        )
      }
    }
    Some(c) if is_digit(c) =>
      for ;; {
        match self.peek() {
          Some(d) if is_digit(d) => sb.write_char(self.advance())
          _ => break
        }
      }
    _ => raise GqlSyntaxError("invalid number: expected a digit", line, col)
  }
  // Fractional part.
  if self.peek() is Some('.') {
    is_float = true
    sb.write_char(self.advance())
    if not_digit_ahead(self) {
      raise GqlSyntaxError(
        "invalid number: expected a digit after '.'", line, col,
      )
    }
    for ;; {
      match self.peek() {
        Some(d) if is_digit(d) => sb.write_char(self.advance())
        _ => break
      }
    }
  }
  // Exponent part.
  if self.peek() is Some('e') || self.peek() is Some('E') {
    is_float = true
    sb.write_char(self.advance())
    if self.peek() is Some('+') || self.peek() is Some('-') {
      sb.write_char(self.advance())
    }
    if not_digit_ahead(self) {
      raise GqlSyntaxError(
        "invalid number: expected a digit in exponent", line, col,
      )
    }
    for ;; {
      match self.peek() {
        Some(d) if is_digit(d) => sb.write_char(self.advance())
        _ => break
      }
    }
  }
  // A number must not be immediately followed by '.', a name-start or a digit.
  match self.peek() {
    Some(c) if c == '.' || is_name_start(c) || is_digit(c) =>
      raise GqlSyntaxError(
        "invalid number: unexpected trailing character", line, col,
      )
    _ => ()
  }
  {
    kind: if is_float {
      FloatVal
    } else {
      IntVal
    },
    value: sb.to_string(),
    line,
    col,
  }
}

///|
/// Whether the next character is not a digit (used to require a digit).
fn not_digit_ahead(lex : Lexer) -> Bool {
  match lex.peek() {
    Some(d) => !is_digit(d)
    None => true
  }
}

///|
/// Read a normal `"..."` string, decoding escape sequences. The cursor is on the
/// opening quote.
fn Lexer::read_string(
  self : Lexer,
  line : Int32,
  col : Int32,
) -> Token raise GqlSyntaxError {
  self.advance() |> ignore // opening quote
  let sb = StringBuilder()
  for ;; {
    match self.peek() {
      None | Some('\n') | Some('\r') =>
        raise GqlSyntaxError("unterminated string", line, col)
      Some('"') => {
        self.advance() |> ignore
        break
      }
      Some('\\') => {
        self.advance() |> ignore
        self.read_escape(sb, line, col)
      }
      Some(_) => sb.write_char(self.advance())
    }
  }
  { kind: StringVal, value: sb.to_string(), line, col, }
}

///|
/// Decode one escape sequence (the leading backslash already consumed) into `sb`.
fn Lexer::read_escape(
  self : Lexer,
  sb : StringBuilder,
  line : Int32,
  col : Int32,
) -> Unit raise GqlSyntaxError {
  match self.peek() {
    Some('"') => {
      self.advance() |> ignore
      sb.write_char('"')
    }
    Some('\\') => {
      self.advance() |> ignore
      sb.write_char('\\')
    }
    Some('/') => {
      self.advance() |> ignore
      sb.write_char('/')
    }
    Some('b') => {
      self.advance() |> ignore
      sb.write_char('\u{08}')
    }
    Some('f') => {
      self.advance() |> ignore
      sb.write_char('\u{0C}')
    }
    Some('n') => {
      self.advance() |> ignore
      sb.write_char('\n')
    }
    Some('r') => {
      self.advance() |> ignore
      sb.write_char('\r')
    }
    Some('t') => {
      self.advance() |> ignore
      sb.write_char('\t')
    }
    Some('u') => {
      self.advance() |> ignore
      self.read_unicode_escape(sb, line, col)
    }
    _ => raise GqlSyntaxError("invalid escape sequence", line, col)
  }
}

///|
/// Decode a `\uXXXX` (fixed 4 hex) or `\u{X...}` (variable, October-2021) escape.
fn Lexer::read_unicode_escape(
  self : Lexer,
  sb : StringBuilder,
  line : Int32,
  col : Int32,
) -> Unit raise GqlSyntaxError {
  if self.peek() is Some('{') {
    self.advance() |> ignore
    let mut code = 0
    let mut count = 0
    for ;; {
      match self.peek() {
        Some('}') => {
          self.advance() |> ignore
          break
        }
        Some(c) =>
          match hex_value(c) {
            Some(v) => {
              code = code * 16 + v
              count = count + 1
              self.advance() |> ignore
            }
            None => raise GqlSyntaxError("invalid unicode escape", line, col)
          }
        None => raise GqlSyntaxError("invalid unicode escape", line, col)
      }
    }
    if count == 0 {
      raise GqlSyntaxError("invalid unicode escape", line, col)
    }
    self.emit_code_point(sb, code, line, col)
  } else {
    let mut code = 0
    for _ in 0..<4 {
      match self.peek() {
        Some(c) =>
          match hex_value(c) {
            Some(v) => {
              code = code * 16 + v
              self.advance() |> ignore
            }
            None => raise GqlSyntaxError("invalid unicode escape", line, col)
          }
        None => raise GqlSyntaxError("invalid unicode escape", line, col)
      }
    }
    self.emit_code_point(sb, code, line, col)
  }
}

///|
/// Append the Unicode scalar for `code` to `sb`, rejecting out-of-range values.
fn Lexer::emit_code_point(
  self : Lexer,
  sb : StringBuilder,
  code : Int32,
  line : Int32,
  col : Int32,
) -> Unit raise GqlSyntaxError {
  ignore(self)
  match Int32::to_char(code) {
    Some(c) => sb.write_char(c)
    None => raise GqlSyntaxError("invalid unicode code point", line, col)
  }
}

///|
/// Read a `"""..."""` block string, honouring the `\"""` escape and applying the
/// spec's block-string dedent (`BlockStringValue`). The cursor is on the first
/// of the three opening quotes.
fn Lexer::read_block_string(
  self : Lexer,
  line : Int32,
  col : Int32,
) -> Token raise GqlSyntaxError {
  self.advance() |> ignore
  self.advance() |> ignore
  self.advance() |> ignore
  let raw = StringBuilder()
  for ;; {
    match self.peek() {
      None => raise GqlSyntaxError("unterminated block string", line, col)
      Some('"') =>
        if self.peek_at(1) is Some('"') && self.peek_at(2) is Some('"') {
          self.advance() |> ignore
          self.advance() |> ignore
          self.advance() |> ignore
          break
        } else {
          raw.write_char(self.advance())
        }
      Some('\\') =>
        // `\"""` escapes an inner triple-quote; any other backslash is literal.
        if self.peek_at(1) is Some('"') &&
          self.peek_at(2) is Some('"') &&
          self.peek_at(3) is Some('"') {
          self.advance() |> ignore
          raw.write_char(self.advance())
          raw.write_char(self.advance())
          raw.write_char(self.advance())
        } else {
          raw.write_char(self.advance())
        }
      Some(_) => raw.write_char(self.advance())
    }
  }
  {
    kind: BlockStringVal,
    value: dedent_block_string(raw.to_string()),
    line,
    col,
  }
}

///|
/// Split a string on line terminators (`\n`, `\r`, `\r\n`) into lines.
fn split_lines(s : String) -> Array[String] {
  let lines = []
  let cur = StringBuilder()
  let chars = []
  for c in s {
    chars.push(c)
  }
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if c == '\n' {
      lines.push(cur.to_string())
      cur.reset()
      i = i + 1
    } else if c == '\r' {
      lines.push(cur.to_string())
      cur.reset()
      if i + 1 < chars.length() && chars[i + 1] == '\n' {
        i = i + 2
      } else {
        i = i + 1
      }
    } else {
      cur.write_char(c)
      i = i + 1
    }
  }
  lines.push(cur.to_string())
  lines
}

///|
/// The number of leading space/tab characters in `line`.
fn leading_whitespace(line : String) -> Int32 {
  let mut n = 0
  for c in line {
    if c == ' ' || c == '\t' {
      n = n + 1
    } else {
      break
    }
  }
  n
}

///|
/// Whether `line` is only whitespace.
fn is_blank(line : String) -> Bool {
  leading_whitespace(line) == line.length()
}

///|
/// Drop the first `n` characters of `s` (used to strip common indentation).
fn drop_prefix(s : String, n : Int32) -> String {
  if n >= s.length() {
    ""
  } else {
    s[n:].to_owned()
  }
}

///|
/// Apply the GraphQL `BlockStringValue` algorithm: compute the common indent of
/// all lines after the first, strip it, then drop leading and trailing blank
/// lines, joining with `\n`.
fn dedent_block_string(raw : String) -> String {
  let lines = split_lines(raw)
  let mut common : Int32? = None
  for i, line in lines {
    if i == 0 {
      continue
    }
    let indent = leading_whitespace(line)
    if indent < line.length() {
      match common {
        None => common = Some(indent)
        Some(c) => if indent < c { common = Some(indent) }
      }
    }
  }
  let stripped = []
  for i, line in lines {
    if i == 0 {
      stripped.push(line)
    } else {
      match common {
        Some(c) => stripped.push(drop_prefix(line, c))
        None => stripped.push(line)
      }
    }
  }
  // Trim leading and trailing blank lines.
  let mut start = 0
  let mut end = stripped.length()
  while start < end && is_blank(stripped[start]) {
    start = start + 1
  }
  while end > start && is_blank(stripped[end - 1]) {
    end = end - 1
  }
  let sb = StringBuilder()
  for i = start; i < end; i = i + 1 {
    if i > start {
      sb.write_char('\n')
    }
    sb.write_string(stripped[i])
  }
  sb.to_string()
}

///|
/// Produce the next token, skipping ignored tokens first. Returns an `Eof` token
/// at end of input.
fn Lexer::next_token(self : Lexer) -> Token raise GqlSyntaxError {
  self.skip_ignored()
  let line = self.line
  let col = self.col
  match self.peek() {
    None => { kind: Eof, value: "", line, col, }
    Some(c) =>
      if is_name_start(c) {
        self.read_name(line, col)
      } else if is_digit(c) || c == '-' {
        self.read_number(line, col)
      } else if c == '"' {
        if self.peek_at(1) is Some('"') && self.peek_at(2) is Some('"') {
          self.read_block_string(line, col)
        } else {
          self.read_string(line, col)
        }
      } else {
        self.read_punctuator(line, col)
      }
  }
}

///|
/// Read a single-character punctuator or the three-character `...` spread.
fn Lexer::read_punctuator(
  self : Lexer,
  line : Int32,
  col : Int32,
) -> Token raise GqlSyntaxError {
  let c = self.advance()
  let kind = match c {
    '!' => Bang
    '$' => Dollar
    '&' => Amp
    '(' => ParenL
    ')' => ParenR
    ':' => Colon
    '=' => Equals
    '@' => At
    '[' => BracketL
    ']' => BracketR
    '{' => BraceL
    '}' => BraceR
    '|' => Pipe
    '.' => {
      if self.peek() is Some('.') && self.peek_at(1) is Some('.') {
        self.advance() |> ignore
        self.advance() |> ignore
        return { kind: Spread, value: "...", line, col, }
      }
      raise GqlSyntaxError("unexpected character '.'", line, col)
    }
    _ =>
      raise GqlSyntaxError(
        "unexpected character '" + c.to_string() + "'",
        line,
        col,
      )
  }
  { kind, value: "", line, col, }
}

///|
/// Tokenize an entire source string into a token array ending with `Eof`.
/// Primarily for tests and tooling; the parser pulls tokens on demand.
pub fn tokenize(src : String) -> Array[Token] raise GqlSyntaxError {
  let lex = Lexer::new(src)
  let out = []
  for ;; {
    let t = lex.next_token()
    out.push(t)
    if t.kind is Eof {
      break
    }
  }
  out
}

///|
pub extend GqlSyntaxError with Show::{output}

///|
pub extend TokenKind with Eq::{not_equal, equal}
