///|
/// What an annotated type became in the schema.
priv enum Shape {
  Object
  Input
  Enum
  Union
  Interface
} derive(Eq)

///|
/// An annotated type: its GraphQL name and shape.
priv struct Known {
  name : String
  shape : Shape
}

///|
/// The type inside `T?` or `Option[T]`, or `None` when `ty` is not optional.
fn inner_option(ty : String) -> String? {
  let ty = ty.trim(chars=" ")
  if ty.has_suffix("?") {
    Some(ty.view(end_offset=ty.length() - 1).trim(chars=" ").to_owned())
  } else {
    inside(ty, "Option")
  }
}

///|
/// `T` out of `Name[T]`.
fn inside(ty : StringView, name : String) -> String? {
  let ty = ty.trim(chars=" ")
  let open = name + "["
  if ty.has_prefix(open) && ty.has_suffix("]") {
    Some(
      ty
      .view(start_offset=open.length(), end_offset=ty.length() - 1)
      .trim(chars=" ")
      .to_owned(),
    )
  } else {
    None
  }
}

///|
/// The annotated output type at the core of `ty`, past `T?` and `Array[T]`:
/// what an argument or an input field cannot take.
fn output_core(ty : String, known : Map[String, Known]) -> String? {
  let base = inner_option(ty).unwrap_or(ty.trim(chars=" ").to_owned())
  match inside(base, "Array") {
    Some(item) => output_core(item, known)
    None =>
      match known.get(base) {
        Some({ shape: Object | Union | Interface, .. }) => Some(base)
        _ => None
      }
  }
}

///|
/// The scalar a MoonBit type stands for.
fn scalar_of(ty : String) -> String? {
  match ty {
    "String" => Some("String")
    "Int" | "Int32" => Some("Int")
    "Double" => Some("Float")
    "Bool" => Some("Boolean")
    "Int64" => Some("Int64")
    _ => None
  }
}

///|
fn builtin_scalar(name : String) -> Bool {
  name is ("String" | "Int" | "Float" | "Boolean" | "ID")
}

///|
/// The GraphQL type of a MoonBit type, as the `GqlType` it is written with:
/// `NonNull` unless `T?`, `ListOf` for `Array[T]`. `kind` names the innermost
/// type instead. Each custom scalar met lands in `scalars`. `None` for a type
/// that has no GraphQL counterpart.
fn graphql_type(
  ty : String,
  known : Map[String, Known],
  kind : String?,
  scalars : Map[String, Unit],
) -> String? {
  let (base, nullable) = match inner_option(ty) {
    Some(inner) => (inner, true)
    None => (ty.trim(chars=" ").to_owned(), false)
  }
  let named = match inside(base, "Array") {
    Some(item) =>
      match graphql_type(item, known, kind, scalars) {
        Some(t) => "ListOf(\{t})"
        None => return None
      }
    None => {
      let named = match kind {
        Some(k) => Some(k)
        None =>
          match known.get(base) {
            Some(k) => Some(k.name)
            None => scalar_of(base)
          }
      }
      guard named is Some(n) else { return None }
      if known.values().any(k => k.name == n) {
        "Named(\{quoted(n)})"
      } else {
        if !builtin_scalar(n) {
          scalars.set(n, ())
        }
        "Scalar(\{quoted(n)})"
      }
    }
  }
  Some(if nullable { named } else { "NonNull(\{named})" })
}

///|
/// `password_hash` as `passwordHash`; leading underscores stay.
fn camel(name : String) -> String {
  let out = StringBuilder()
  let mut up = false
  let mut lead = true
  for c in name {
    if c == '_' && !lead {
      up = true
    } else {
      out.write_char(if up { c.to_ascii_uppercase() } else { c })
      up = false
      lead = lead && c == '_'
    }
  }
  out.to_string()
}

///|
fn quoted(text : String) -> String {
  @quote.string(text).to_string()
}
