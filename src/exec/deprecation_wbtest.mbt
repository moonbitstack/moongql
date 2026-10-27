///|
/// A schema with one deprecated field (`Query.old`) and one deprecated enum
/// value (`Color.OLD`) to exercise `@deprecated` introspection and the
/// `includeDeprecated` filter.
fn dep_schema() -> @schema.Schema {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("alive", NonNull(@schema.Scalar("String")))
  q.field("old", Scalar("String"), deprecation_reason="use alive")
  q.field("color", Named("Color"))
  s.enum_("Color", ["RED", "GREEN", "OLD"], deprecated=[("OLD", "use RED")])
  s
}

///|
/// `fields(includeDeprecated: true)` lists deprecated fields with `isDeprecated`
/// and the reason; a live field reports `false` / null.
test "introspection fields includeDeprecated:true reports isDeprecated" {
  let q =
    #|{ __type(name: "Query") { fields(includeDeprecated: true) { name isDeprecated deprecationReason } } }
  let res = execute(dep_schema(), Resolvers::new(), q)
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"__type":{"fields":[{"name":"alive","isDeprecated":false,"deprecationReason":null},{"name":"old","isDeprecated":true,"deprecationReason":"use alive"},{"name":"color","isDeprecated":false,"deprecationReason":null}]}}}
    ),
  )
}

///|
/// Without `includeDeprecated`, deprecated fields are omitted from the result.
test "introspection fields omit deprecated by default" {
  let q =
    #|{ __type(name: "Query") { fields { name } } }
  let res = execute(dep_schema(), Resolvers::new(), q)
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"__type":{"fields":[{"name":"alive"},{"name":"color"}]}}}
    ),
  )
}

///|
/// `enumValues(includeDeprecated: true)` lists a deprecated value with its reason.
test "introspection enumValues includeDeprecated:true reports isDeprecated" {
  let q =
    #|{ __type(name: "Color") { enumValues(includeDeprecated: true) { name isDeprecated deprecationReason } } }
  let res = execute(dep_schema(), Resolvers::new(), q)
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"__type":{"enumValues":[{"name":"RED","isDeprecated":false,"deprecationReason":null},{"name":"GREEN","isDeprecated":false,"deprecationReason":null},{"name":"OLD","isDeprecated":true,"deprecationReason":"use RED"}]}}}
    ),
  )
}

///|
/// Without `includeDeprecated`, deprecated enum values are omitted.
test "introspection enumValues omit deprecated by default" {
  let q =
    #|{ __type(name: "Color") { enumValues { name } } }
  let res = execute(dep_schema(), Resolvers::new(), q)
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"__type":{"enumValues":[{"name":"RED"},{"name":"GREEN"}]}}}
    ),
  )
}

///|
/// The canonical introspection query graphql-core sends — which passes
/// `includeDeprecated: true` to `fields` and `enumValues` — now validates with no
/// "unknown argument" error.
test "canonical introspection query validates" {
  assert_eq(verr_text(dep_schema(), introspection_query), "")
}
