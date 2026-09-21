///|
/// A GraphQL type reference: a scalar (`String`, `Int`, `Boolean`, `Float`, `ID`),
/// a named object type, or a non-null / list wrapper around another type.
pub(all) enum GqlType {
  Scalar(String)
  Named(String)
  NonNull(GqlType)
  ListOf(GqlType)
} derive(Eq)

///|
/// Render a type reference to GraphQL SDL notation (`String!`, `[User!]`, ...).
fn type_sdl(t : GqlType) -> String {
  match t {
    Scalar(s) => s
    Named(n) => n
    NonNull(inner) => type_sdl(inner) + "!"
    ListOf(inner) => "[" + type_sdl(inner) + "]"
  }
}

///|
/// A field on an object type: a name, an ordered list of arguments (each a
/// `(name, type)` pair), and the field's return type. A field with no arguments
/// prints as `name: Type`; with arguments it prints as `name(a: A, b: B): Type`.
pub(all) struct Field {
  name : String
  args : Array[(String, GqlType)]
  typ : GqlType
  arg_defaults : Map[String, Json]
  deprecation_reason : String?
  description : String?
}

///|
/// Render a single field to SDL, including its argument list when non-empty.
fn field_sdl(f : Field) -> String {
  let mut out = "  " + f.name
  if f.args.length() > 0 {
    out = out + "("
    for i, arg in f.args {
      let (an, at) = arg
      if i > 0 {
        out = out + ", "
      }
      out = out + an + ": " + type_sdl(at)
    }
    out = out + ")"
  }
  out + ": " + type_sdl(f.typ)
}

///|
/// Which kind of composite type an `ObjectType` describes: an output `object`
/// (`type`), an `input` object, or an `interface`.
pub(all) enum TypeKind {
  Object
  Input
  Interface
} derive(Eq)

///|
/// A GraphQL composite type with an ordered set of fields. The same shape backs
/// output objects, input objects, and interfaces; `kind` selects the SDL keyword
/// and `interfaces` lists the interfaces an object implements.
pub(all) struct ObjectType {
  name : String
  fields : Array[Field]
  kind : TypeKind
  interfaces : Array[String]
  description : String?
}

///|
/// Add a field with no arguments to this type.
pub fn ObjectType::field(
  self : ObjectType,
  name : String,
  typ : GqlType,
  deprecation_reason? : String,
  description? : String,
) -> Unit {
  self.fields.push({
    name,
    args: [],
    typ,
    arg_defaults: Map([]),
    deprecation_reason,
    description,
  })
}

///|
/// Add a field carrying arguments to this type. Each argument is a `(name, type)`
/// pair and renders as `name(a: A, b: B): RetType`. `defaults` supplies default
/// values for arguments a query may omit (GraphQL field-argument defaults): an
/// absent argument takes its default, an explicitly-null one does not.
pub fn ObjectType::field_args(
  self : ObjectType,
  name : String,
  args : Array[(String, GqlType)],
  typ : GqlType,
  defaults? : Array[(String, Json)] = [],
  deprecation_reason? : String,
  description? : String,
) -> Unit {
  self.fields.push({
    name,
    args,
    typ,
    arg_defaults: Map(defaults),
    deprecation_reason,
    description,
  })
}

///|
/// Declare that this object type implements a named interface. Implemented
/// interfaces render as `type Name implements A & B { ... }`.
pub fn ObjectType::implements(self : ObjectType, name : String) -> Unit {
  self.interfaces.push(name)
}

///|
/// A GraphQL enum type: a name, an ordered list of value names, and each value's
/// `@deprecated` reason keyed by value name (mirroring `Field.arg_defaults`).
pub(all) struct EnumType {
  name : String
  values : Array[String]
  deprecations : Map[String, String]
  description : String?
  value_descriptions : Map[String, String]
}

///|
/// A GraphQL union type: a name and the ordered names of its member object types.
/// A value at a union position is resolved to one member via its `__typename`,
/// and only inline/named fragments on member types (plus `__typename`) may select
/// into it.
pub(all) struct UnionType {
  name : String
  members : Array[String]
}

///|
/// A custom scalar type with the two coercion hooks strawberry's `Scalar` carries:
/// `serialize` maps a resolved value to its output JSON, and `parse_value` maps an
/// input JSON value (an argument or variable) to the value a resolver sees. Both
/// default to identity when a scalar only renames an existing representation.
pub(all) struct ScalarType {
  name : String
  serialize : (Json) -> Json
  parse_value : (Json) -> Json
  spec_url : String?
}

///|
/// A code-first GraphQL schema: composite types (objects, inputs, interfaces),
/// enum types, plus the names of the root operation types. `query` is required;
/// `mutation` and `subscription` are optional (a schema without them cannot run
/// operations of that kind).
pub struct Schema {
  types : Array[ObjectType]
  enums : Array[EnumType]
  unions : Array[UnionType]
  scalars : Array[ScalarType]
  query : String
  mut mutation : String?
  mut subscription : String?
  // Applied directives (directive uses) recorded against a "Type.field" key, a
  // type name, and the schema itself, plus the definitions of user directives.
  field_directives : Map[String, Array[AppliedDirective]]
  type_directives : Map[String, Array[AppliedDirective]]
  schema_directives : Array[AppliedDirective]
  directive_defs : Array[DirectiveDef]
}

///|
/// Create an empty schema whose root query type is `query` (default `Query`),
/// with no mutation or subscription root until `set_mutation` / `set_subscription`
/// name them.
pub fn Schema::new(query? : String = "Query") -> Schema {
  {
    types: [],
    enums: [],
    unions: [],
    scalars: [],
    query,
    mutation: None,
    subscription: None,
    field_directives: Map([]),
    type_directives: Map([]),
    schema_directives: [],
    directive_defs: [],
  }
}

///|
/// Name the root mutation type; it must also be declared with `object`.
pub fn Schema::set_mutation(self : Schema, name : String) -> Unit {
  self.mutation = Some(name)
}

///|
/// Name the root subscription type; it must also be declared with `object`.
pub fn Schema::set_subscription(self : Schema, name : String) -> Unit {
  self.subscription = Some(name)
}

///|
/// Look up a declared composite type (object / input / interface) by name.
pub fn Schema::type_by_name(self : Schema, name : String) -> ObjectType? {
  for t in self.types {
    if t.name == name {
      return Some(t)
    }
  }
  None
}

///|
/// Look up a declared enum type by name.
pub fn Schema::enum_by_name(self : Schema, name : String) -> EnumType? {
  for e in self.enums {
    if e.name == name {
      return Some(e)
    }
  }
  None
}

///|
/// Declare a union type over the named member object types. Renders as
/// `union Name = A | B`.
pub fn Schema::union(
  self : Schema,
  name : String,
  members : Array[String],
) -> Unit {
  self.unions.push({ name, members, })
}

///|
/// Look up a declared union type by name.
pub fn Schema::union_by_name(self : Schema, name : String) -> UnionType? {
  for u in self.unions {
    if u.name == name {
      return Some(u)
    }
  }
  None
}

///|
/// Register a custom scalar with its `serialize` / `parse_value` hooks. Both
/// default to identity, which is enough for a scalar that only renames JSON it
/// already carries (a `DateTime` stored as an ISO string, say).
pub fn Schema::scalar(
  self : Schema,
  name : String,
  serialize? : (Json) -> Json = fn(x) { x },
  parse_value? : (Json) -> Json = fn(x) { x },
  spec_url? : String,
) -> Unit {
  self.scalars.push({ name, serialize, parse_value, spec_url, })
}

///|
/// Look up a registered custom scalar by name.
pub fn Schema::scalar_by_name(self : Schema, name : String) -> ScalarType? {
  for s in self.scalars {
    if s.name == name {
      return Some(s)
    }
  }
  None
}

///|
/// Look up a field on this type by its name.
pub fn ObjectType::field_by_name(self : ObjectType, name : String) -> Field? {
  for f in self.fields {
    if f.name == name {
      return Some(f)
    }
  }
  None
}

///|
/// The base named type a possibly-wrapped type refers to (unwrapping `!`/`[]`).
pub fn GqlType::named_base(self : GqlType) -> String {
  match self {
    Scalar(s) => s
    Named(n) => n
    NonNull(inner) => inner.named_base()
    ListOf(inner) => inner.named_base()
  }
}

///|
/// Declare an output object type and return it so fields can be added. The type
/// is registered by reference, so later `.field(...)` calls are seen.
pub fn Schema::object(
  self : Schema,
  name : String,
  description? : String,
) -> ObjectType {
  let o : ObjectType = {
    name,
    fields: [],
    kind: Object,
    interfaces: [],
    description,
  }
  self.types.push(o)
  o
}

///|
/// Declare an input object type and return it so fields can be added. Renders as
/// `input Name { ... }`.
pub fn Schema::input(
  self : Schema,
  name : String,
  description? : String,
) -> ObjectType {
  let o : ObjectType = {
    name,
    fields: [],
    kind: Input,
    interfaces: [],
    description,
  }
  self.types.push(o)
  o
}

///|
/// Declare an interface type and return it so fields can be added. Renders as
/// `interface Name { ... }`; objects declare conformance via `implements`.
pub fn Schema::interface(
  self : Schema,
  name : String,
  description? : String,
) -> ObjectType {
  let o : ObjectType = {
    name,
    fields: [],
    kind: Interface,
    interfaces: [],
    description,
  }
  self.types.push(o)
  o
}

///|
/// Declare an enum type with an ordered set of value names. Renders as
/// `enum Name { A B }` with one value per line. `deprecated` marks individual
/// values `@deprecated`, each a `(value, reason)` pair (as `field_args` takes
/// argument defaults), surfacing in introspection's `isDeprecated`.
pub fn Schema::enum_(
  self : Schema,
  name : String,
  values : Array[String],
  deprecated? : Array[(String, String)] = [],
  description? : String,
  descriptions? : Array[(String, String)] = [],
) -> Unit {
  self.enums.push({
    name,
    values,
    deprecations: Map(deprecated),
    description,
    value_descriptions: Map(descriptions),
  })
}

///|
/// The SDL keyword introducing a composite type of the given kind.
fn kind_keyword(k : TypeKind) -> String {
  match k {
    Object => "type"
    Input => "input"
    Interface => "interface"
  }
}

///|
/// Emit the schema as GraphQL SDL: a `schema { query: ... }` block, then one
/// block per composite type (`type` / `input` / `interface`, with `implements`
/// and field arguments), then one block per enum type.
pub fn Schema::to_sdl(self : Schema) -> String {
  let roots = StringBuilder()
  roots.write_string("schema {\n  query: " + self.query + "\n")
  // A schema that sets a mutation or subscription root has to say so, or its SDL
  // describes a different schema from the one that runs.
  if self.mutation is Some(m) {
    roots.write_string("  mutation: " + m + "\n")
  }
  if self.subscription is Some(sub) {
    roots.write_string("  subscription: " + sub + "\n")
  }
  roots.write_string("}\n\n")
  let mut out = roots.to_string()
  for obj in self.types {
    out = out + kind_keyword(obj.kind) + " " + obj.name
    if obj.interfaces.length() > 0 {
      out = out + " implements "
      for i, iface in obj.interfaces {
        if i > 0 {
          out = out + " & "
        }
        out = out + iface
      }
    }
    out = out + " {\n"
    for f in obj.fields {
      out = out + field_sdl(f) + "\n"
    }
    out = out + "}\n\n"
  }
  for en in self.enums {
    out = out + "enum " + en.name + " {\n"
    for v in en.values {
      out = out + "  " + v + "\n"
    }
    out = out + "}\n\n"
  }
  for un in self.unions {
    out = out + "union " + un.name + " = "
    for i, m in un.members {
      if i > 0 {
        out = out + " | "
      }
      out = out + m
    }
    out = out + "\n\n"
  }
  for sc in self.scalars {
    out = out + "scalar " + sc.name + "\n\n"
  }
  out
}

///|
pub extend GqlType with Eq::{not_equal, equal}

///|
pub extend TypeKind with Eq::{not_equal, equal}
