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
pub type EntityResolver = (Json, Json) -> Json raise @exec.FieldError

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
/// `@override` / `@tag`), and the type- and field-level federation directives it
/// declares. Build it with `new`, register entities with `entity`, mark fields
/// with `shareable` / `inaccessible` / `override_` / `requires` / `provides` /
/// `tag`, then `apply` it to a schema and resolver map.
pub struct Federation {
  entities : Array[EntityDef]
  v2 : Bool
  field_dirs : Array[(String, String, @schema.AppliedDirective)]
  type_dirs : Array[(String, @schema.AppliedDirective)]
}

///|
/// An empty federation config. Pass `v2=true` for a Federation v2 subgraph, whose
/// SDL opens with `extend schema @link(...)` importing the federation spec and
/// which may use the v2-only directives (`@shareable`, `@inaccessible`,
/// `@override`).
pub fn Federation::new(v2~ : Bool = false) -> Federation {
  { entities: [], v2, field_dirs: [], type_dirs: [], }
}

///|
/// The v2 `@link` onto the federation spec that heads a v2 subgraph's SDL, listing
/// the directive names the subgraph imports.
fn federation_link_directive() -> @schema.AppliedDirective {
  let imports : Array[Json] = [
    Json("@key"),
    Json("@shareable"),
    Json("@inaccessible"),
    Json("@override"),
    Json("@external"),
    Json("@requires"),
    Json("@provides"),
    Json("@tag"),
    Json("@extends"),
  ]
  @schema.AppliedDirective::new("link", args=[
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
    (type_name, field_name, @schema.AppliedDirective::new("shareable")),
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
    (type_name, field_name, @schema.AppliedDirective::new("inaccessible")),
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
      @schema.AppliedDirective::new("override", args=[("from", Json(from))]),
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
      @schema.AppliedDirective::new("requires", args=[("fields", Json(fields))]),
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
      @schema.AppliedDirective::new("provides", args=[("fields", Json(fields))]),
    ),
  )
}

///|
/// Mark the type `type_name` `@tag(name: tag_name)` (v2) — a label the router can
/// filter or route by. `@tag` is repeatable, so a type may carry several.
pub fn Federation::tag(
  self : Federation,
  type_name : String,
  name~ : String,
) -> Unit {
  self.type_dirs.push(
    (
      type_name,
      @schema.AppliedDirective::new("tag", args=[("name", Json(name))]),
    ),
  )
}

///|
/// Mark `type_name.field_name` `@tag(name: tag_name)` (v2), repeatable like the
/// type-level form.
pub fn Federation::tag_field(
  self : Federation,
  type_name : String,
  field_name : String,
  name~ : String,
) -> Unit {
  self.field_dirs.push(
    (
      type_name,
      field_name,
      @schema.AppliedDirective::new("tag", args=[("name", Json(name))]),
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
/// The fields a field set names on `type_name`, checked against the schema. Each
/// name is a field of the type it is written under, and a sub-selection is read
/// against that field's own type — which is what the gateway will ask this
/// subgraph to resolve, so a path that does not exist has to be caught here.
fn check_field_set(
  schema : @schema.Schema,
  type_name : String,
  entries : Array[FieldSetEntry],
  written : String,
  out : Array[String],
  where_ : String,
) -> Unit {
  let owner = match schema.type_by_name(type_name) {
    Some(t) => t
    None => {
      out.push("\{where_}: '\{type_name}' is not a type of this schema")
      return
    }
  }
  for e in entries {
    match owner.field_by_name(e.name) {
      None =>
        out.push(
          "\{where_}: '\{type_name}' has no field '\{e.name}', which `\{written}` names",
        )
      Some(f) =>
        if !e.children.is_empty() {
          let inner = f.typ.named_base()
          // A sub-selection only makes sense on a composite type.
          if schema.type_by_name(inner) is Some(_) {
            check_field_set(schema, inner, e.children, written, out, where_)
          } else {
            out.push(
              "\{where_}: '\{type_name}.\{e.name}' is '\{inner}', which has no fields to select",
            )
          }
        }
    }
  }
}

///|
/// Everything a subgraph has to get right before a gateway can compose it: an
/// `@requires` or `@provides` field set whose paths exist, the entity types the
/// subgraph registers, and the directives it declares. Answers one line per
/// problem, empty when there is none.
///
/// `@requires` needs nothing at run time beyond what the executor already does —
/// the gateway sends the named fields in the representation, and `_entities`
/// keeps them on the value the entity resolver returned, so the resolver of the
/// requiring field can read them. `@provides` needs nothing either: the fields
/// are resolved here like any others, and this check is what lets the gateway
/// rely on that.
pub fn Federation::check(
  self : Federation,
  schema : @schema.Schema,
) -> Array[String] {
  let out : Array[String] = []
  for e in self.entities {
    match schema.type_by_name(e.name) {
      None =>
        out.push(
          "entity '\{e.name}' is registered but not a type of this schema",
        )
      Some(t) =>
        for f in e.external {
          if t.field_by_name(f) is None {
            out.push(
              "entity '\{e.name}' marks '\{f}' external, but the type has no such field",
            )
          }
        }
    }
    let fields = read_field_set(e.key)
    match fields {
      Some(key) => check_field_set(schema, e.name, key, e.key, out, "@key")
      None =>
        out.push(
          "entity '\{e.name}': `@key(fields: \"\{e.key}\")` is not a field set",
        )
    }
  }
  for fd in self.field_dirs {
    let (type_name, field_name, dir) = fd
    if dir.name != "requires" && dir.name != "provides" {
      continue
    }
    let written = match dir.args.iter().find_first(a => a.0 == "fields") {
      Some((_, String(text))) => text
      _ => ""
    }
    let where_ = "@\{dir.name} on \{type_name}.\{field_name}"
    let owner = match schema.type_by_name(type_name) {
      Some(t) => t
      None => {
        out.push("\{where_}: '\{type_name}' is not a type of this schema")
        continue
      }
    }
    let field = match owner.field_by_name(field_name) {
      Some(f) => f
      None => {
        out.push("\{where_}: '\{type_name}' has no field '\{field_name}'")
        continue
      }
    }
    let entries = match read_field_set(written) {
      Some(e) => e
      None => {
        out.push("\{where_}: `fields: \"\{written}\"` is not a field set")
        continue
      }
    }
    // `@requires` names fields of the type being resolved — the externals the
    // gateway sends along. `@provides` names fields of what the field returns.
    let target = if dir.name == "requires" {
      type_name
    } else {
      field.typ.named_base()
    }
    check_field_set(schema, target, entries, written, out, where_)
  }
  out
}

///|
/// Render the subgraph SDL: the schema as the developer wrote it, annotated with
/// `@key` on entity types (prefixed `extend` when the type is an extension),
/// `@external` on external fields, and with the federation-internal additions
/// (`_Service`, `_Entity`, `_Any`, and the `_service` / `_entities` root fields)
/// left out. This is what `_service { sdl }` returns.
pub fn Federation::sdl(self : Federation, schema : @schema.Schema) -> String {
  let mut out = ""
  if self.v2 {
    out = out +
      "extend schema\n  " +
      @schema.applied_directive_sdl(federation_link_directive()) +
      "\n\n"
  }
  // A directive this subgraph defines is part of what it publishes, or the
  // gateway has no definition to compose against.
  for d in schema.directive_defs {
    out = out + @schema.directive_def_sdl(schema, d) + "\n\n"
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
    out = out + @schema.description_sdl(obj.description)
    out = out + @schema.kind_keyword(obj.kind) + " " + obj.name
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
    out = out +
      @schema.applied_directives_sdl(schema.type_applied_directives(obj.name))
    out = out + " {\n"
    for f in obj.fields {
      if obj.name == schema.query &&
        (f.name == "_service" || f.name == "_entities") {
        continue
      }
      out = out +
        @schema.description_sdl(f.description, indent=1) +
        @schema.field_sdl(schema, f)
      if str_in(external, f.name) {
        out = out + " @external"
      }
      out = out +
        @schema.applied_directives_sdl(
          schema.field_applied_directives(obj.name, f.name),
        )
      out = out + "\n"
    }
    out = out + "}\n\n"
  }
  for en in schema.enums {
    out = out + @schema.description_sdl(en.description)
    out = out +
      "enum " +
      en.name +
      @schema.applied_directives_sdl(schema.type_applied_directives(en.name)) +
      " {\n"
    for v in en.values {
      out = out +
        @schema.description_sdl(en.value_descriptions.get(v), indent=1)
      out = out + "  " + v
      match en.deprecations.get(v) {
        Some(r) =>
          out = out + " @deprecated(reason: \"" + @lang.escape_string(r) + "\")"
        None => ()
      }
      out = out + "\n"
    }
    out = out + "}\n\n"
  }
  for un in schema.unions {
    if is_federation_internal(un.name) {
      continue
    }
    out = out + @schema.description_sdl(un.description)
    out = out +
      "union " +
      un.name +
      @schema.applied_directives_sdl(schema.type_applied_directives(un.name)) +
      " = "
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
    out = out + @schema.description_sdl(sc.description)
    out = out +
      "scalar " +
      sc.name +
      @schema.applied_directives_sdl(schema.type_applied_directives(sc.name)) +
      "\n\n"
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
/// can pick the concrete member type, and keep every field the representation
/// carried that the resolver did not produce: those are the `@requires` fields,
/// which another subgraph owns and the gateway sent along for this one to read.
/// A non-object value passes through unchanged.
fn entity_from(value : Json, rep : Json, typename : String) -> Json {
  match value {
    Object(resolved) => {
      match rep {
        Object(sent) =>
          for key in sent.keys() {
            if key != "__typename" && resolved.get(key) is None {
              resolved[key] = sent[key]
            }
          }
        _ => ()
      }
      resolved["__typename"] = Json(typename)
      Json(resolved)
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
  schema : @schema.Schema,
  resolvers : @exec.Resolvers,
) -> Unit {
  if self.v2 {
    schema.apply_schema_directive(federation_link_directive())
  }
  for fd in self.field_dirs {
    schema.apply_field_directive(fd.0, fd.1, fd.2)
  }
  for td in self.type_dirs {
    schema.apply_type_directive(td.0, td.1)
  }
  schema.scalar("_Any")
  let service = schema.object("_Service")
  service.field("sdl", NonNull(@schema.Scalar("String")))
  let members : Array[String] = []
  for e in self.entities {
    members.push(e.name)
  }
  schema.union("_Entity", members)
  match schema.type_by_name(schema.query) {
    Some(query) => {
      query.field("_service", NonNull(@schema.Named("_Service")))
      query.field_args(
        "_entities",
        [
          (
            "representations",
            @schema.NonNull(
              @schema.ListOf(@schema.NonNull(@schema.Scalar("_Any"))),
            ),
          ),
        ],
        NonNull(@schema.ListOf(@schema.Named("_Entity"))),
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
        Some(ed) => out.push(entity_from((ed.resolve)(rep, info.ctx), rep, tn))
        None => out.push(Json::null())
      }
    }
    Json(out)
  })
}
