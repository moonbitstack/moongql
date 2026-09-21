///|
/// GraphQL introspection (spec §4): answer `__schema`, `__type` and `__typename`
/// from the schema. The introspection type system (`__Schema`, `__Type`,
/// `__Field`, `__InputValue`, `__EnumValue`, `__Directive`) is defined here as
/// synthetic `ObjectType`s so the executor's normal field-completion machinery
/// can walk an introspection selection set, while the data is materialised as
/// JSON that the default resolver reads through.

///|
/// A synthetic introspection object type: a name and its `(field, type)` list.
fn intro_obj(name : String, fields : Array[(String, GqlType)]) -> ObjectType {
  let fs : Array[Field] = []
  for f in fields {
    fs.push({
      name: f.0,
      args: [],
      typ: f.1,
      arg_defaults: Map([]),
      deprecation_reason: None,
      description: None,
    })
  }
  { name, fields: fs, kind: Object, interfaces: [], description: None, }
}

///|
/// The synthetic definition of an introspection type by name, or `None`. These
/// drive leaf-vs-composite completion when executing an introspection query.
fn introspection_type_def(name : String) -> ObjectType? {
  let t = Scalar("String")
  let b = NonNull(Scalar("Boolean"))
  match name {
    "__Schema" =>
      Some(
        intro_obj("__Schema", [
          ("description", t),
          ("types", NonNull(ListOf(NonNull(Named("__Type"))))),
          ("queryType", NonNull(Named("__Type"))),
          ("mutationType", Named("__Type")),
          ("subscriptionType", Named("__Type")),
          ("directives", NonNull(ListOf(NonNull(Named("__Directive"))))),
        ]),
      )
    "__Type" => {
      let ty = intro_obj("__Type", [
        ("kind", NonNull(Named("__TypeKind"))),
        ("name", t),
        ("description", t),
        ("fields", ListOf(NonNull(Named("__Field")))),
        ("interfaces", ListOf(NonNull(Named("__Type")))),
        ("possibleTypes", ListOf(NonNull(Named("__Type")))),
        ("enumValues", ListOf(NonNull(Named("__EnumValue")))),
        ("inputFields", ListOf(NonNull(Named("__InputValue")))),
        ("ofType", Named("__Type")),
        ("specifiedByURL", t),
      ])
      // `fields` and `enumValues` take `includeDeprecated: Boolean = false` so a
      // client can opt deprecated members back into the result (spec §4.5).
      for fname in ["fields", "enumValues"] {
        if ty.field_by_name(fname) is Some(f) {
          f.args.push(("includeDeprecated", Scalar("Boolean")))
          f.arg_defaults["includeDeprecated"] = false.to_json()
        }
      }
      Some(ty)
    }
    "__Field" =>
      Some(
        intro_obj("__Field", [
          ("name", NonNull(Scalar("String"))),
          ("description", t),
          ("args", NonNull(ListOf(NonNull(Named("__InputValue"))))),
          ("type", NonNull(Named("__Type"))),
          ("isDeprecated", b),
          ("deprecationReason", t),
        ]),
      )
    "__InputValue" =>
      Some(
        intro_obj("__InputValue", [
          ("name", NonNull(Scalar("String"))),
          ("description", t),
          ("type", NonNull(Named("__Type"))),
          ("defaultValue", t),
        ]),
      )
    "__EnumValue" =>
      Some(
        intro_obj("__EnumValue", [
          ("name", NonNull(Scalar("String"))),
          ("description", t),
          ("isDeprecated", b),
          ("deprecationReason", t),
        ]),
      )
    "__Directive" =>
      Some(
        intro_obj("__Directive", [
          ("name", NonNull(Scalar("String"))),
          ("description", t),
          ("locations", NonNull(ListOf(NonNull(Named("__DirectiveLocation"))))),
          ("args", NonNull(ListOf(NonNull(Named("__InputValue"))))),
          ("isRepeatable", b),
        ]),
      )
    _ => None
  }
}

///|
/// The introspection `__TypeKind` enum name for a type name in this schema.
fn Exec::type_kind(self : Exec, name : String) -> String {
  if is_builtin_scalar(name) {
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
    ("kind", self.type_kind(name).to_json()),
    ("name", name.to_json()),
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
    ("kind", kind.to_json()),
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
fn Exec::type_ref_json(self : Exec, t : GqlType) -> Json {
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
  typ : GqlType,
  default? : Json,
  description? : String = "",
) -> Json {
  jobj([
    ("name", name.to_json()),
    (
      "description",
      if description == "" {
        Json::null()
      } else {
        description.to_json()
      },
    ),
    ("type", self.type_ref_json(typ)),
    (
      "defaultValue",
      match default {
        Some(d) => json_to_gql_literal(d).to_json()
        None => Json::null()
      },
    ),
  ])
}

///|
/// Materialise a `__Field` for an output field.
fn Exec::field_json(self : Exec, f : Field) -> Json {
  let args : Array[Json] = []
  for a in f.args {
    let default = f.arg_defaults.get(a.0)
    args.push(self.input_value_json(a.0, a.1, default?))
  }
  jobj([
    ("name", f.name.to_json()),
    ("description", reason_json(f.description)),
    ("args", args.to_json()),
    ("type", self.type_ref_json(f.typ)),
    ("isDeprecated", (f.deprecation_reason is Some(_)).to_json()),
    ("deprecationReason", reason_json(f.deprecation_reason)),
  ])
}

///|
/// A `deprecationReason` value: the reason string, or JSON null when not set.
fn reason_json(reason : String?) -> Json {
  match reason {
    Some(r) => r.to_json()
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
        if not(deprecated) {
          out.push(it)
        }
      }
      out.to_json()
    }
    _ => items
  }
}

///|
/// Materialise the full `__Type` for a declared composite type (object / input
/// object / interface), including its fields, interfaces and possibleTypes.
fn Exec::composite_type_json(self : Exec, def : ObjectType) -> Json {
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
    fs.to_json()
  }
  let input_fields = if def.kind is Input {
    let fs : Array[Json] = []
    for f in def.fields {
      if self.schema.field_has_directive(def.name, f.name, "inaccessible") {
        continue
      }
      fs.push(self.input_value_json(f.name, f.typ))
    }
    fs.to_json()
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
    is_.to_json()
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
    ps.to_json()
  } else {
    Json::null()
  }
  jobj([
    ("kind", kind.to_json()),
    ("name", def.name.to_json()),
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
fn Exec::enum_type_json(self : Exec, def : EnumType) -> Json {
  ignore(self)
  let vals : Array[Json] = []
  for v in def.values {
    let reason = def.deprecations.get(v)
    vals.push(
      jobj([
        ("name", v.to_json()),
        ("description", reason_json(def.value_descriptions.get(v))),
        ("isDeprecated", (reason is Some(_)).to_json()),
        ("deprecationReason", reason_json(reason)),
      ]),
    )
  }
  jobj([
    ("kind", "ENUM".to_json()),
    ("name", def.name.to_json()),
    ("description", reason_json(def.description)),
    ("fields", Json::null()),
    ("interfaces", Json::null()),
    ("possibleTypes", Json::null()),
    ("enumValues", vals.to_json()),
    ("inputFields", Json::null()),
    ("ofType", Json::null()),
  ])
}

///|
/// Materialise the full `__Type` for a union type: `kind = UNION` and
/// `possibleTypes` listing its members as type references.
fn Exec::union_type_json(self : Exec, def : UnionType) -> Json {
  let members : Array[Json] = []
  for m in def.members {
    members.push(self.named_type_ref(m))
  }
  jobj([
    ("kind", "UNION".to_json()),
    ("name", def.name.to_json()),
    ("description", Json::null()),
    ("fields", Json::null()),
    ("interfaces", Json::null()),
    ("possibleTypes", members.to_json()),
    ("enumValues", Json::null()),
    ("inputFields", Json::null()),
    ("ofType", Json::null()),
  ])
}

///|
/// Materialise the full `__Type` for a built-in or custom scalar.
fn scalar_type_json(name : String, spec_url? : String) -> Json {
  jobj([
    ("kind", "SCALAR".to_json()),
    ("name", name.to_json()),
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
  match introspection_type_def(name) {
    Some(def) => return self.composite_type_json(def)
    None => ()
  }
  if is_builtin_scalar(name) {
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
    "FIELD".to_json(),
    "FRAGMENT_SPREAD".to_json(),
    "INLINE_FRAGMENT".to_json(),
  ]
  let bool_if : Array[Json] = [
    self.input_value_json("if", NonNull(Scalar("Boolean"))),
  ]
  let deprecated_reason : Array[Json] = [
    self.input_value_json(
      "reason",
      Scalar("String"),
      default="No longer supported".to_json(),
    ),
  ]
  let directive = fn(
    name : String,
    locs : Array[Json],
    args : Array[Json],
  ) -> Json {
    jobj([
      ("name", name.to_json()),
      ("description", Json::null()),
      ("locations", locs.to_json()),
      ("args", args.to_json()),
      ("isRepeatable", false.to_json()),
    ])
  }
  let out : Array[Json] = [
    directive("include", field_locs, bool_if),
    directive("skip", field_locs, bool_if),
    directive(
      "deprecated",
      [
        "FIELD_DEFINITION".to_json(),
        "ARGUMENT_DEFINITION".to_json(),
        "INPUT_FIELD_DEFINITION".to_json(),
        "ENUM_VALUE".to_json(),
      ],
      deprecated_reason,
    ),
    directive("specifiedBy", ["SCALAR".to_json()], [
      self.input_value_json("url", NonNull(Scalar("String"))),
    ]),
  ]
  // User-registered directives (@upper, @auth, ...) show up alongside the built-ins.
  for d in self.schema.directive_defs {
    let locs : Array[Json] = []
    for l in d.locations {
      locs.push(l.to_json())
    }
    let args : Array[Json] = []
    for a in d.args {
      args.push(self.input_value_json(a.0, a.1))
    }
    out.push(
      jobj([
        ("name", d.name.to_json()),
        ("description", Json::null()),
        ("locations", locs.to_json()),
        ("args", args.to_json()),
        ("isRepeatable", d.is_repeatable.to_json()),
      ]),
    )
  }
  out.to_json()
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
    match introspection_type_def(name) {
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
    ("types", types.to_json()),
    ("directives", self.directives_json()),
  ])
}
