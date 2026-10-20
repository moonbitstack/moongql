///|
/// Apollo Federation subgraph support (federation v1). A subgraph exposes three
/// things a gateway relies on: the `_service { sdl }` field returning the
/// subgraph's SDL with its federation directives, the `_entities(representations)`
/// resolver that turns a `{ __typename, <key fields> }` reference back into a full
/// object, and the `@key` / `@external` directives (plus `extend type` for a type
/// this subgraph does not own) that mark which types are entities and which fields
/// live elsewhere.
///
/// A `Federation` records the entity types and their reference resolvers; `apply`
/// installs the federation machinery onto a schema and its resolver map — the
/// `_Service` type, the `_Any` scalar, the `_Entity` union, and the two root
/// fields — so the ordinary executor runs a federated query with no special
/// casing.

///|
/// The reference resolver for an entity type: given a representation (a JSON
/// object carrying `__typename` and the entity's key fields) and the request
/// context, return the fully resolved entity as JSON. This is the subgraph's
/// answer to "you have a key, give me the object" — Apollo's `__resolveReference`.
pub type EntityResolver = (Json, Json) -> Json raise ResolverError

///|
/// One federated entity: its type `name`, the `key` field set (`@key(fields:)`),
/// whether the subgraph only `extends` a type it does not own, the names of its
/// `external` fields (`@external`, owned by another subgraph), and the reference
/// resolver that materialises it from a representation.
pub(all) struct EntityDef {
  name : String
  key : String
  extends : Bool
  external : Array[String]
  resolve : EntityResolver
}

///|
/// The federation configuration for a subgraph: the set of entity types it
/// contributes, whether it is a Federation **v2** subgraph (which opts in with an
/// `@link` to the federation spec and unlocks `@shareable` / `@inaccessible` /
/// `@override`), and the field-level federation directives it declares. Build it
/// with `new`, register entities with `entity`, mark fields with `shareable` /
/// `inaccessible` / `override_` / `requires` / `provides`, then `apply` it to a
/// schema and resolver map.
pub struct Federation {
  entities : Array[EntityDef]
  v2 : Bool
  field_dirs : Array[(String, String, AppliedDirective)]
}

///|
/// An empty federation config. Pass `v2=true` for a Federation v2 subgraph, whose
/// SDL opens with `extend schema @link(...)` importing the federation spec and
/// which may use the v2-only directives (`@shareable`, `@inaccessible`,
/// `@override`).
pub fn Federation::new(v2~ : Bool = false) -> Federation {
  { entities: [], v2, field_dirs: [], }
}

///|
/// The v2 `@link` onto the federation spec that heads a v2 subgraph's SDL, listing
/// the directive names the subgraph imports.
fn federation_link_directive() -> AppliedDirective {
  let imports : Array[Json] = [
    Json("@key"),
    Json("@shareable"),
    Json("@inaccessible"),
    Json("@override"),
    Json("@external"),
    Json("@requires"),
    Json("@provides"),
    Json("@extends"),
  ]
  AppliedDirective::new("link", args=[
    ("url", Json("https://specs.apollo.dev/federation/v2.3")),
    ("import", Json(imports)),
  ])
}

///|
/// Mark `type_name.field_name` `@shareable` — resolvable by more than one subgraph
/// (v2). Without it, a non-key field must be owned by exactly one subgraph.
pub fn Federation::shareable(
  self : Federation,
  type_name : String,
  field_name : String,
) -> Unit {
  self.field_dirs.push(
    (type_name, field_name, AppliedDirective::new("shareable")),
  )
}

///|
/// Mark `type_name.field_name` `@inaccessible` (v2) — present in this subgraph but
/// omitted from the composed public schema, and hidden from introspection.
pub fn Federation::inaccessible(
  self : Federation,
  type_name : String,
  field_name : String,
) -> Unit {
  self.field_dirs.push(
    (type_name, field_name, AppliedDirective::new("inaccessible")),
  )
}

///|
/// Declare that `type_name.field_name` is `@override`-taken from the subgraph
/// `from` (v2) — this subgraph now resolves the field the other used to own.
pub fn Federation::override_(
  self : Federation,
  type_name : String,
  field_name : String,
  from~ : String,
) -> Unit {
  self.field_dirs.push(
    (
      type_name,
      field_name,
      AppliedDirective::new("override", args=[("from", Json(from))]),
    ),
  )
}

///|
/// Declare that resolving `type_name.field_name` `@requires` the named external
/// key fields (`"weight size"`), which the gateway then includes in the entity
/// representation the `_entities` resolver receives.
pub fn Federation::requires(
  self : Federation,
  type_name : String,
  field_name : String,
  fields~ : String,
) -> Unit {
  self.field_dirs.push(
    (
      type_name,
      field_name,
      AppliedDirective::new("requires", args=[("fields", Json(fields))]),
    ),
  )
}

///|
/// Declare that resolving `type_name.field_name` `@provides` the named fields of
/// the returned entity, so the gateway can skip a round trip for them.
pub fn Federation::provides(
  self : Federation,
  type_name : String,
  field_name : String,
  fields~ : String,
) -> Unit {
  self.field_dirs.push(
    (
      type_name,
      field_name,
      AppliedDirective::new("provides", args=[("fields", Json(fields))]),
    ),
  )
}

///|
/// Register an entity type. `name` is the object type (which must also be
/// declared on the schema), `key` is its `@key` field set (`"id"`, or space-
/// separated `"upc sku"` for a compound key), `resolve` turns a representation
/// back into the object. Set `extends` when this subgraph extends a type owned by
/// another, and list `external` fields that other subgraphs own.
pub fn Federation::entity(
  self : Federation,
  name~ : String,
  key~ : String,
  resolve~ : EntityResolver,
  extends~ : Bool = false,
  external~ : Array[String] = [],
) -> Unit {
  self.entities.push({ name, key, extends, external, resolve, })
}

///|
/// The entity definition for a type name, if it is a registered entity.
fn Federation::entity_def(self : Federation, name : String) -> EntityDef? {
  for e in self.entities {
    if e.name == name {
      return Some(e)
    }
  }
  None
}

///|
/// The federation-internal type and field names, which the subgraph SDL omits —
/// a gateway adds them itself when composing.
fn is_federation_internal(name : String) -> Bool {
  name == "_Service" || name == "_Entity" || name == "_Any"
}

///|
/// Render the subgraph SDL: the schema as the developer wrote it, annotated with
/// `@key` on entity types (prefixed `extend` when the type is an extension),
/// `@external` on external fields, and with the federation-internal additions
/// (`_Service`, `_Entity`, `_Any`, and the `_service` / `_entities` root fields)
/// left out. This is what `_service { sdl }` returns.
pub fn Federation::sdl(self : Federation, schema : Schema) -> String {
  let mut out = ""
  if self.v2 {
    out = out +
      "extend schema\n  " +
      applied_directive_sdl(federation_link_directive()) +
      "\n\n"
  }
  for obj in schema.types {
    if is_federation_internal(obj.name) {
      continue
    }
    let ed = self.entity_def(obj.name)
    let extends = match ed {
      Some(e) => e.extends
      None => false
    }
    let external = match ed {
      Some(e) => e.external
      None => []
    }
    if extends {
      out = out + "extend "
    }
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
    match ed {
      Some(e) => out = out + " @key(fields: \"" + e.key + "\")"
      None => ()
    }
    out = out + " {\n"
    for f in obj.fields {
      if obj.name == schema.query &&
        (f.name == "_service" || f.name == "_entities") {
        continue
      }
      out = out + field_sdl(f)
      if str_in(external, f.name) {
        out = out + " @external"
      }
      out = out +
        applied_directives_sdl(
          schema.field_applied_directives(obj.name, f.name),
        )
      out = out + "\n"
    }
    out = out + "}\n\n"
  }
  for en in schema.enums {
    out = out + "enum " + en.name + " {\n"
    for v in en.values {
      out = out + "  " + v + "\n"
    }
    out = out + "}\n\n"
  }
  for un in schema.unions {
    if is_federation_internal(un.name) {
      continue
    }
    out = out + "union " + un.name + " = "
    for i, m in un.members {
      if i > 0 {
        out = out + " | "
      }
      out = out + m
    }
    out = out + "\n\n"
  }
  for sc in schema.scalars {
    if is_federation_internal(sc.name) {
      continue
    }
    out = out + "scalar " + sc.name + "\n\n"
  }
  out
}

///|
/// Read a representation's `__typename`, or `""` when it carries none.
fn representation_typename(rep : Json) -> String {
  match rep {
    Object(m) =>
      match m.get("__typename") {
        Some(String(tn)) => tn
        _ => ""
      }
    _ => ""
  }
}

///|
/// Stamp `__typename` onto a resolved entity so the executor's union completion
/// can pick the concrete member type. A non-object value passes through unchanged.
fn tag_typename(value : Json, typename : String) -> Json {
  match value {
    Object(m) => {
      m["__typename"] = Json(typename)
      Json(m)
    }
    _ => value
  }
}

///|
/// Install the federation machinery onto `schema` and `resolvers`: declare the
/// `_Any` scalar, the `_Service` type with its `sdl` field, and the `_Entity`
/// union over every registered entity type; add the `_service` and `_entities`
/// fields to the query root; and register the two resolvers. After this the schema
/// answers a federated query — `{ _service { sdl } }` and
/// `_entities(representations:)` — through the normal executor.
pub fn Federation::apply(
  self : Federation,
  schema : Schema,
  resolvers : Resolvers,
) -> Unit {
  if self.v2 {
    schema.apply_schema_directive(federation_link_directive())
  }
  for fd in self.field_dirs {
    schema.apply_field_directive(fd.0, fd.1, fd.2)
  }
  schema.scalar("_Any")
  let service = schema.object("_Service")
  service.field("sdl", NonNull(Scalar("String")))
  let members : Array[String] = []
  for e in self.entities {
    members.push(e.name)
  }
  schema.union("_Entity", members)
  match schema.type_by_name(schema.query) {
    Some(query) => {
      query.field("_service", NonNull(Named("_Service")))
      query.field_args(
        "_entities",
        [("representations", NonNull(ListOf(NonNull(Scalar("_Any")))))],
        NonNull(ListOf(Named("_Entity"))),
      )
    }
    None => ()
  }
  let fed = self
  // The fields go on the schema's query root, whatever it is named, so the
  // resolvers have to be registered against the same type.
  resolvers.field(schema.query, "_service", fn(_info) {
    jobj([("sdl", Json(fed.sdl(schema)))])
  })
  resolvers.field(schema.query, "_entities", info => {
    let reps = match info.arg("representations") {
      Array(items) => items
      _ => []
    }
    let out : Array[Json] = []
    for rep in reps {
      let tn = representation_typename(rep)
      match fed.entity_def(tn) {
        Some(ed) => out.push(tag_typename((ed.resolve)(rep, info.ctx), tn))
        None => out.push(Json::null())
      }
    }
    Json(out)
  })
}
