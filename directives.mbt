///|
/// The directive extension points (GraphQL spec §3.13). moongql carries two kinds
/// of directive:
///
///   * **Applied directives** (`AppliedDirective`) — a directive *use* on a schema
///     element, recorded on the `Schema` against a `"Type.field"` key, a type name,
///     or the schema itself. Apollo Federation's `@key` / `@shareable` /
///     `@inaccessible` / `@override` and any user schema directive live here. They
///     surface in the subgraph SDL and can influence introspection (an
///     `@inaccessible` element is hidden).
///
///   * **Directive definitions** (`DirectiveDef`) — a directive *declaration*:
///     its name, valid locations, argument types, repeatability, and an optional
///     **executable hook** that transforms a resolved field value at run time. The
///     built-in `@skip` / `@include` are handled inline by the executor; a
///     user-defined directive registered here shows up in introspection and, if it
///     carries an `on_field` hook, alters the field's value during execution.

///|
/// A directive applied to a schema element: its `name` and its constant arguments
/// as ordered `(name, value)` pairs. Build one with `AppliedDirective::new`.
pub(all) struct AppliedDirective {
  name : String
  args : Array[(String, Json)]
}

///|
/// An applied directive with no arguments, or with the given constant arguments.
pub fn AppliedDirective::new(
  name : String,
  args? : Array[(String, Json)] = [],
) -> AppliedDirective {
  { name, args, }
}

///|
/// The run-time hook a user directive may carry: given the resolved field value
/// and the directive's coerced arguments, return the transformed value. This is
/// how a custom executable directive (`@upper`, `@default(value:)`, ...) alters a
/// resolved field, the moongql equivalent of a strawberry `SchemaDirective` with a
/// resolver-side effect.
pub type FieldDirectiveHook = (Json, Map[String, Json]) -> Json

///|
/// A directive definition: its `name`, the `locations` it may appear at (the
/// `__DirectiveLocation` enum values, e.g. `"FIELD"`, `"FIELD_DEFINITION"`), its
/// declared `args`, whether it `is_repeatable`, and an optional executable
/// `on_field` hook. A definition with locations that include executable ones and
/// an `on_field` hook is applied during execution; one with only type-system
/// locations is a pure schema directive (SDL + introspection only).
pub(all) struct DirectiveDef {
  name : String
  locations : Array[String]
  args : Array[(String, GqlType)]
  is_repeatable : Bool
  on_field : FieldDirectiveHook?
}

///|
/// Register a directive definition on the schema. `locations` lists where it may
/// be used (`"FIELD"`, `"FRAGMENT_SPREAD"`, `"INLINE_FRAGMENT"`, `"OBJECT"`,
/// `"FIELD_DEFINITION"`, ...); `args` declares its arguments; `on_field` — when
/// given and the directive targets fields — transforms the resolved value of any
/// field the directive is applied to. The directive then appears in introspection
/// (`__schema { directives }`) and is accepted by the validator.
pub fn Schema::directive(
  self : Schema,
  name : String,
  locations~ : Array[String],
  args? : Array[(String, GqlType)] = [],
  is_repeatable? : Bool = false,
  on_field? : FieldDirectiveHook,
) -> Unit {
  self.directive_defs.push({ name, locations, args, is_repeatable, on_field, })
}

///|
/// The registered directive definition named `name`, if any.
pub fn Schema::directive_def_by_name(
  self : Schema,
  name : String,
) -> DirectiveDef? {
  for d in self.directive_defs {
    if d.name == name {
      return Some(d)
    }
  }
  None
}

///|
/// Record an applied directive on the field `type_name.field_name`.
pub fn Schema::apply_field_directive(
  self : Schema,
  type_name : String,
  field_name : String,
  directive : AppliedDirective,
) -> Unit {
  let key = type_name + "." + field_name
  match self.field_directives.get(key) {
    Some(ds) => ds.push(directive)
    None => self.field_directives[key] = [directive]
  }
}

///|
/// Record an applied directive on the type `type_name`.
pub fn Schema::apply_type_directive(
  self : Schema,
  type_name : String,
  directive : AppliedDirective,
) -> Unit {
  match self.type_directives.get(type_name) {
    Some(ds) => ds.push(directive)
    None => self.type_directives[type_name] = [directive]
  }
}

///|
/// Record an applied directive on the schema itself (e.g. federation's `@link`).
pub fn Schema::apply_schema_directive(
  self : Schema,
  directive : AppliedDirective,
) -> Unit {
  self.schema_directives.push(directive)
}

///|
/// The directives applied to the field `type_name.field_name`.
pub fn Schema::field_applied_directives(
  self : Schema,
  type_name : String,
  field_name : String,
) -> Array[AppliedDirective] {
  match self.field_directives.get(type_name + "." + field_name) {
    Some(ds) => ds
    None => []
  }
}

///|
/// The directives applied to the type `type_name`.
pub fn Schema::type_applied_directives(
  self : Schema,
  type_name : String,
) -> Array[AppliedDirective] {
  match self.type_directives.get(type_name) {
    Some(ds) => ds
    None => []
  }
}

///|
/// Whether the field `type_name.field_name` carries the directive `name`.
pub fn Schema::field_has_directive(
  self : Schema,
  type_name : String,
  field_name : String,
  name : String,
) -> Bool {
  for d in self.field_applied_directives(type_name, field_name) {
    if d.name == name {
      return true
    }
  }
  false
}

///|
/// Whether the type `type_name` carries the directive `name`.
pub fn Schema::type_has_directive(
  self : Schema,
  type_name : String,
  name : String,
) -> Bool {
  for d in self.type_applied_directives(type_name) {
    if d.name == name {
      return true
    }
  }
  false
}

///|
/// Render a JSON value as a GraphQL literal, for printing an applied directive's
/// arguments into SDL (`@override(from: "accounts")`, `@key(fields: "id name")`).
fn json_to_gql_literal(j : Json) -> String {
  match j {
    Null => "null"
    True => "true"
    False => "false"
    String(s) => "\"" + escape_string(s) + "\""
    Number(n, repr~) =>
      match repr {
        Some(r) => r
        None => n.to_string()
      }
    Array(items) => {
      let mut out = "["
      for i, it in items {
        if i > 0 {
          out = out + ", "
        }
        out = out + json_to_gql_literal(it)
      }
      out + "]"
    }
    Object(m) => {
      let mut out = "{"
      let mut first = true
      for k, v in m {
        if not(first) {
          out = out + ", "
        }
        first = false
        out = out + k + ": " + json_to_gql_literal(v)
      }
      out + "}"
    }
  }
}

///|
/// Render one applied directive to SDL: `@name` or `@name(a: v, b: w)`.
fn applied_directive_sdl(d : AppliedDirective) -> String {
  if d.args.length() == 0 {
    return "@" + d.name
  }
  let mut out = "@" + d.name + "("
  for i, a in d.args {
    if i > 0 {
      out = out + ", "
    }
    out = out + a.0 + ": " + json_to_gql_literal(a.1)
  }
  out + ")"
}

///|
/// Render a whole applied-directive list, each prefixed with a space (empty for an
/// empty list), for appending after a field or type in SDL.
fn applied_directives_sdl(ds : Array[AppliedDirective]) -> String {
  let mut out = ""
  for d in ds {
    out = out + " " + applied_directive_sdl(d)
  }
  out
}

///|
/// The definition of a built-in executable directive (`@skip` / `@include`), or
/// `None` for a name that is not a built-in. The validator reads its locations and
/// its `if: Boolean!` argument; the executor evaluates the directive itself, so no
/// `on_field` hook is attached.
fn builtin_exec_directive(name : String) -> DirectiveDef? {
  match name {
    "skip" | "include" =>
      Some({
        name,
        locations: ["FIELD", "FRAGMENT_SPREAD", "INLINE_FRAGMENT"],
        args: [("if", NonNull(Scalar("Boolean")))],
        is_repeatable: false,
        on_field: None,
      })
    _ => None
  }
}
