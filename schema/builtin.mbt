///|
/// The five built-in scalar type names, which are leaves with no declaration.
pub fn is_builtin_scalar(name : String) -> Bool {
  name == "String" ||
  name == "Int" ||
  name == "Float" ||
  name == "Boolean" ||
  name == "ID"
}

///|
/// Whether `name` is an introspection meta-field (`__`-prefixed), which the spec
/// forbids as a subscription root field.
pub fn is_meta_field(name : String) -> Bool {
  name.length() >= 2 && name[0].to_int() == 95 && name[1].to_int() == 95
}

///|
/// The synthetic definition of an introspection type by name, or `None`. These
/// drive leaf-vs-composite completion when executing an introspection query.
pub fn introspection_type_def(name : String) -> ObjectType? {
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
          f.arg_defaults["includeDeprecated"] = Json(false)
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
