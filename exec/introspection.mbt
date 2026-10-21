///|
/// GraphQL introspection (spec §4): answer `__schema`, `__type` and `__typename`
/// from the schema. The introspection type system (`__Schema`, `__Type`,
/// `__Field`, `__InputValue`, `__EnumValue`, `__Directive`) is defined here as
/// synthetic `ObjectType`s so the executor's normal field-completion machinery
/// can walk an introspection selection set, while the data is materialised as
/// JSON that the default resolver reads through.

///|
/// The introspection `__TypeKind` enum name for a type name in this schema.
fn Exec::type_kind(self : Exec, name : String) -> String {
  if @schema.is_builtin_scalar(name) {
    return "SCALAR"
  }
  match self.schema.type_by_name(name) {
    Some(t) =>
      match t.kind {
        Object => "OBJECT"
        Input => "INPUT_OBJECT"
        Interface => "INTERFACE"
      }
    None =>
      if self.schema.enum_by_name(name) is Some(_) {
        "ENUM"
      } else if self.schema.union_by_name(name) is Some(_) {
        "UNION"
      } else {
        "SCALAR"
      }
  }
}

///|
/// A shallow `__Type` reference: `{ kind, name, ofType: null }` with the detail
/// fields null. Used wherever introspection points at a type by reference
/// (`ofType`, `queryType`, a field's `type`, interface / possibleType entries).
fn Exec::named_type_ref(self : Exec, name : String) -> Json {
  jobj([
    ("kind", Json(self.type_kind(name))),
    ("name", Json(name)),
    ("description", Json::null()),
    ("fields", Json::null()),
    ("interfaces", Json::null()),
    ("possibleTypes", Json::null()),
    ("enumValues", Json::null()),
    ("inputFields", Json::null()),
    ("ofType", Json::null()),
  ])
}

///|
/// A `__Type` wrapper reference (`NON_NULL` / `LIST`) around `of_type`.
fn wrapper_ref(kind : String, of_type : Json) -> Json {
  jobj([
    ("kind", Json(kind)),
    ("name", Json::null()),
    ("description", Json::null()),
    ("fields", Json::null()),
    ("interfaces", Json::null()),
    ("possibleTypes", Json::null()),
    ("enumValues", Json::null()),
    ("inputFields", Json::null()),
    ("ofType", of_type),
  ])
}

///|
/// The introspection `__Type` reference for a possibly-wrapped `GqlType`,
/// nesting `ofType` for each `!` / `[]` wrapper.
fn Exec::type_ref_json(self : Exec, t : @schema.GqlType) -> Json {
  match t {
    NonNull(inner) => wrapper_ref("NON_NULL", self.type_ref_json(inner))
    ListOf(inner) => wrapper_ref("LIST", self.type_ref_json(inner))
    Scalar(n) => self.named_type_ref(n)
    Named(n) => self.named_type_ref(n)
  }
}

///|
/// Materialise a `__InputValue` for an argument or input field. `default` is the
/// GraphQL literal the spec asks for — a string, not the JSON value — because that
/// is what codegen and GraphiQL render back into a query.
fn Exec::input_value_json(
  self : Exec,
  name : String,
  typ : @schema.GqlType,
  default? : Json,
  description~ : String = "",
) -> Json {
  jobj([
    ("name", Json(name)),
    (
      "description",
      if description == "" {
        Json::null()
      } else {
        Json(description)
      },
    ),
    ("type", self.type_ref_json(typ)),
    (
      "defaultValue",
      match default {
        Some(d) => Json(@schema.json_to_gql_literal(d))
        None => Json::null()
      },
    ),
  ])
}

///|
/// Materialise a `__Field` for an output field.
fn Exec::field_json(self : Exec, f : @schema.Field) -> Json {
  let args : Array[Json] = []
  for a in f.args {
    let default = f.arg_defaults.get(a.0)
    args.push(self.input_value_json(a.0, a.1, default?))
  }
  jobj([
    ("name", Json(f.name)),
    ("description", reason_json(f.description)),
    ("args", Json(args)),
    ("type", self.type_ref_json(f.typ)),
    ("isDeprecated", Json(f.deprecation_reason is Some(_))),
    ("deprecationReason", reason_json(f.deprecation_reason)),
  ])
}

///|
/// A `deprecationReason` value: the reason string, or JSON null when not set.
fn reason_json(reason : String?) -> Json {
  match reason {
    Some(r) => Json(r)
    None => Json::null()
  }
}

///|
/// Filter a materialised `__Field` / `__EnumValue` list for a `fields` /
/// `enumValues` selection: unless `include` is set, drop entries carrying
/// `isDeprecated: true` (graphql-js `includeDeprecated` behaviour).
fn filter_deprecated(items : Json, included : Bool) -> Json {
  if included {
    return items
  }
  match items {
    Array(arr) => {
      let out : Array[Json] = []
      for it in arr {
        let deprecated = match it {
          Object(m) => m.get("isDeprecated") is Some(True)
          _ => false
        }
        if !deprecated {
          out.push(it)
        }
      }
      Json(out)
    }
    _ => items
  }
}

///|
/// Materialise the full `__Type` for a declared composite type (object / input
/// object / interface), including its fields, interfaces and possibleTypes.
fn Exec::composite_type_json(self : Exec, def : @schema.ObjectType) -> Json {
  let kind = match def.kind {
    Object => "OBJECT"
    Input => "INPUT_OBJECT"
    Interface => "INTERFACE"
  }
  let fields = if def.kind is Input {
    Json::null()
  } else {
    let fs : Array[Json] = []
    for f in def.fields {
      // @inaccessible fields are present in the subgraph but hidden from the
      // composed/public schema, so introspection must not report them.
      if self.schema.field_has_directive(def.name, f.name, "inaccessible") {
        continue
      }
      fs.push(self.field_json(f))
    }
    Json(fs)
  }
  let input_fields = if def.kind is Input {
    let fs : Array[Json] = []
    for f in def.fields {
      if self.schema.field_has_directive(def.name, f.name, "inaccessible") {
        continue
      }
      fs.push(self.input_value_json(f.name, f.typ))
    }
    Json(fs)
  } else {
    Json::null()
  }
  let interfaces = if def.kind is Input {
    Json::null()
  } else {
    let is_ : Array[Json] = []
    for i in def.interfaces {
      is_.push(self.named_type_ref(i))
    }
    Json(is_)
  }
  let possible_types = if def.kind is Interface {
    let ps : Array[Json] = []
    for t in self.schema.types {
      for i in t.interfaces {
        if i == def.name {
          ps.push(self.named_type_ref(t.name))
          break
        }
      }
    }
    Json(ps)
  } else {
    Json::null()
  }
  jobj([
    ("kind", Json(kind)),
    ("name", Json(def.name)),
    ("description", reason_json(def.description)),
    ("fields", fields),
    ("interfaces", interfaces),
    ("possibleTypes", possible_types),
    ("enumValues", Json::null()),
    ("inputFields", input_fields),
    ("ofType", Json::null()),
  ])
}

///|
/// Materialise the full `__Type` for an enum type.
fn Exec::enum_type_json(self : Exec, def : @schema.EnumType) -> Json {
  ignore(self)
  let vals : Array[Json] = []
  for v in def.values {
    let reason = def.deprecations.get(v)
    vals.push(
      jobj([
        ("name", Json(v)),
        ("description", reason_json(def.value_descriptions.get(v))),
        ("isDeprecated", Json(reason is Some(_))),
        ("deprecationReason", reason_json(reason)),
      ]),
    )
  }
  jobj([
    ("kind", Json("ENUM")),
    ("name", Json(def.name)),
    ("description", reason_json(def.description)),
    ("fields", Json::null()),
    ("interfaces", Json::null()),
    ("possibleTypes", Json::null()),
    ("enumValues", Json(vals)),
    ("inputFields", Json::null()),
    ("ofType", Json::null()),
  ])
}

///|
/// Materialise the full `__Type` for a union type: `kind = UNION` and
/// `possibleTypes` listing its members as type references.
fn Exec::union_type_json(self : Exec, def : @schema.UnionType) -> Json {
  let members : Array[Json] = []
  for m in def.members {
    members.push(self.named_type_ref(m))
  }
  jobj([
    ("kind", Json("UNION")),
    ("name", Json(def.name)),
    ("description", Json::null()),
    ("fields", Json::null()),
    ("interfaces", Json::null()),
    ("possibleTypes", Json(members)),
    ("enumValues", Json::null()),
    ("inputFields", Json::null()),
    ("ofType", Json::null()),
  ])
}

///|
/// Materialise the full `__Type` for a built-in or custom scalar.
fn scalar_type_json(name : String, spec_url? : String) -> Json {
  jobj([
    ("kind", Json("SCALAR")),
    ("name", Json(name)),
    ("description", Json::null()),
    ("fields", Json::null()),
    ("interfaces", Json::null()),
    ("possibleTypes", Json::null()),
    ("enumValues", Json::null()),
    ("inputFields", Json::null()),
    ("ofType", Json::null()),
    // The custom-scalar spec URL (← the `@specifiedBy` directive), null for the
    // built-in scalars.
    ("specifiedByURL", reason_json(spec_url)),
  ])
}

///|
/// Resolve `__type(name:)` to a fully-materialised `__Type`, or JSON null.
fn Exec::introspection_type_by_name(self : Exec, name : String) -> Json {
  // An @inaccessible type is hidden from the composed schema, so `__type(name:)`
  // reports it as absent.
  if self.schema.type_has_directive(name, "inaccessible") {
    return Json::null()
  }
  match self.schema.type_by_name(name) {
    Some(def) => return self.composite_type_json(def)
    None => ()
  }
  match self.schema.enum_by_name(name) {
    Some(def) => return self.enum_type_json(def)
    None => ()
  }
  match self.schema.union_by_name(name) {
    Some(def) => return self.union_type_json(def)
    None => ()
  }
  // The introspection types are types the server supports, so `__type(name:
  // "__Schema")` has to answer with one.
  match @schema.introspection_type_def(name) {
    Some(def) => return self.composite_type_json(def)
    None => ()
  }
  if @schema.is_builtin_scalar(name) {
    return scalar_type_json(name)
  }
  match self.schema.scalar_by_name(name) {
    Some(sc) => return scalar_type_json(name, spec_url?=sc.spec_url)
    None => ()
  }
  Json::null()
}

///|
/// The three standard built-in directives, materialised as `__Directive`s.
fn Exec::directives_json(self : Exec) -> Json {
  let field_locs : Array[Json] = [
    Json("FIELD"),
    Json("FRAGMENT_SPREAD"),
    Json("INLINE_FRAGMENT"),
  ]
  let bool_if : Array[Json] = [
    self.input_value_json("if", NonNull(@schema.Scalar("Boolean"))),
  ]
  let deprecated_reason : Array[Json] = [
    self.input_value_json(
      "reason",
      Scalar("String"),
      default=Json("No longer supported"),
    ),
  ]
  let directive = fn(
    name : String,
    locs : Array[Json],
    args : Array[Json],
  ) -> Json {
    jobj([
      ("name", Json(name)),
      ("description", Json::null()),
      ("locations", Json(locs)),
      ("args", Json(args)),
      ("isRepeatable", Json(false)),
    ])
  }
  let out : Array[Json] = [
    directive("include", field_locs, bool_if),
    directive("skip", field_locs, bool_if),
    directive(
      "deprecated",
      [
        Json("FIELD_DEFINITION"),
        Json("ARGUMENT_DEFINITION"),
        Json("INPUT_FIELD_DEFINITION"),
        Json("ENUM_VALUE"),
      ],
      deprecated_reason,
    ),
    directive("specifiedBy", [Json("SCALAR")], [
      self.input_value_json("url", NonNull(@schema.Scalar("String"))),
    ]),
  ]
  // User-registered directives (@upper, @auth, ...) show up alongside the built-ins.
  for d in self.schema.directive_defs {
    let locs : Array[Json] = []
    for l in d.locations {
      locs.push(Json(l))
    }
    let args : Array[Json] = []
    for a in d.args {
      args.push(self.input_value_json(a.0, a.1))
    }
    out.push(
      jobj([
        ("name", Json(d.name)),
        ("description", Json::null()),
        ("locations", Json(locs)),
        ("args", Json(args)),
        ("isRepeatable", Json(d.is_repeatable)),
      ]),
    )
  }
  Json(out)
}

///|
/// Materialise the `__schema` root: query/mutation/subscription roots, every
/// declared type (user composites, enums and the built-in scalars), and the
/// built-in directives.
fn Exec::introspection_schema(self : Exec) -> Json {
  let types : Array[Json] = []
  for t in self.schema.types {
    // @inaccessible types are hidden from the composed schema's type list.
    if self.schema.type_has_directive(t.name, "inaccessible") {
      continue
    }
    types.push(self.composite_type_json(t))
  }
  for e in self.schema.enums {
    if self.schema.type_has_directive(e.name, "inaccessible") {
      continue
    }
    types.push(self.enum_type_json(e))
  }
  for u in self.schema.unions {
    if self.schema.type_has_directive(u.name, "inaccessible") {
      continue
    }
    types.push(self.union_type_json(u))
  }
  for s in ["String", "Int", "Float", "Boolean", "ID"] {
    types.push(scalar_type_json(s))
  }
  // `types` is every type the server supports, which includes the introspection
  // system itself — a client generating code off the schema needs them.
  for
    name in [
      "__Schema", "__Type", "__Field", "__InputValue", "__EnumValue", "__Directive",
    ] {
    match @schema.introspection_type_def(name) {
      Some(def) => types.push(self.composite_type_json(def))
      None => ()
    }
  }
  for sc in self.schema.scalars {
    types.push(scalar_type_json(sc.name, spec_url?=sc.spec_url))
  }
  let mutation = match self.schema.mutation {
    Some(m) => self.named_type_ref(m)
    None => Json::null()
  }
  let subscription = match self.schema.subscription {
    Some(s) => self.named_type_ref(s)
    None => Json::null()
  }
  jobj([
    ("description", Json::null()),
    ("queryType", self.named_type_ref(self.schema.query)),
    ("mutationType", mutation),
    ("subscriptionType", subscription),
    ("types", Json(types)),
    ("directives", self.directives_json()),
  ])
}
