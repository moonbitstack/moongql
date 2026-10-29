// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A MoonBit value as a GraphQL result: async-graphql's `OutputType`. Implemented
/// for the built-in scalars, `Int64` (written as a string, since GraphQL's `Int`
/// is 32-bit), `Json`, `T?` and `Array[T]`; the `#gql` generator writes it for
/// each annotated type.
pub(open) trait ToGql {
  fn to_gql(Self) -> Json
}

///|
/// A MoonBit value read from an argument or a parent value: async-graphql's
/// `InputType`. A refusal is a `ResolverError` saying what was expected.
pub(open) trait FromGql {
  fn from_gql(Json) -> Self raise ResolverError
}

///|
/// The refusal of a value that is not a `want`, as every [`FromGql`] here writes
/// it: `expected Int, got "x"`.
pub fn ResolverError::expected(want : String, got : Json) -> ResolverError {
  ResolverError("expected \{want}, got \{got.stringify()}")
}

///|
fn refuse(got : Json, want : String) -> ResolverError {
  ResolverError::expected(want, got)
}

///|
pub impl ToGql for Json with fn to_gql(self) {
  self
}

///|
pub impl FromGql for Json with fn from_gql(v) {
  v
}

///|
pub impl ToGql for String with fn to_gql(self) {
  Json::string(self)
}

///|
pub impl FromGql for String with fn from_gql(v) {
  match v {
    String(s) => s
    other => raise refuse(other, "String")
  }
}

///|
pub impl ToGql for Bool with fn to_gql(self) {
  Json::boolean(self)
}

///|
pub impl FromGql for Bool with fn from_gql(v) {
  match v {
    True => true
    False => false
    other => raise refuse(other, "Boolean")
  }
}

///|
pub impl ToGql for Int32 with fn to_gql(self) {
  Json::number(self.to_double())
}

///|
/// Refuses a fraction or a number outside 32 bits, as the spec's `Int` does.
pub impl FromGql for Int32 with fn from_gql(v) {
  match v {
    Number(n, ..) if n == n.floor() && n >= -2147483648.0 && n <= 2147483647.0 =>
      n.to_int()
    other => raise refuse(other, "Int")
  }
}

///|
pub impl ToGql for Double with fn to_gql(self) {
  Json::number(self)
}

///|
pub impl FromGql for Double with fn from_gql(v) {
  match v {
    Number(n, ..) => n
    other => raise refuse(other, "Float")
  }
}

///|
pub impl ToGql for Int64 with fn to_gql(self) {
  Json::string(self.to_string())
}

///|
/// Reads the string `Int64` is written as, or a whole number.
pub impl FromGql for Int64 with fn from_gql(v) {
  match v {
    String(s) => @string.parse_int64(s) catch { _ => raise refuse(v, "Int64") }
    Number(n, ..) if n == n.floor() => n.to_int64()
    other => raise refuse(other, "Int64")
  }
}

///|
pub impl[T : ToGql] ToGql for T? with fn to_gql(self) {
  match self {
    Some(x) => x.to_gql()
    None => Json::null()
  }
}

///|
pub impl[T : FromGql] FromGql for T? with fn from_gql(v) {
  match v {
    Null => None
    v => Some(T::from_gql(v))
  }
}

///|
pub impl[T : ToGql] ToGql for Array[T] with fn to_gql(self) {
  Json::array(self.map(x => x.to_gql()))
}

///|
pub impl[T : FromGql] FromGql for Array[T] with fn from_gql(v) {
  match v {
    Array(xs) => xs.map(x => T::from_gql(x))
    other => raise refuse(other, "a list")
  }
}

///|
/// The argument `name` as any [`FromGql`] type; a missing argument reads as
/// `null`, so it is `None` for a `T?`. A refusal names the argument.
pub fn[T : FromGql] ResolveInfo::read(
  self : ResolveInfo,
  name : String,
) -> T raise ResolverError {
  T::from_gql(self.arg(name)) catch {
    ResolverError(m) => raise ResolverError("argument `\{name}`: \{m}")
    e => raise e
  }
}

///|
/// The member `key` of an object value as any [`FromGql`] type, the way a
/// generated input type reads its fields; a missing member reads as `null`. A
/// refusal names the member.
pub fn[T : FromGql] read(value : Json, key : String) -> T raise ResolverError {
  guard value is Object(m) else { raise refuse(value, "an object") }
  T::from_gql(m.get(key).unwrap_or(Json::null())) catch {
    ResolverError(msg) => raise ResolverError("field `\{key}`: \{msg}")
    e => raise e
  }
}

///|
/// Any error a resolver raised, as the field error it becomes; a
/// `ResolverError` passes through unchanged.
pub fn field_error(e : Error) -> ResolverError {
  match e {
    ResolverError(m) => ResolverError(m)
    ResolverErrorExt(m, ext) => ResolverErrorExt(m, ext)
    e => ResolverError(e.to_string())
  }
}
