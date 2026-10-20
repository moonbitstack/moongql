///|
/// A client generating code off the schema needs the introspection system itself,
/// and an argument's default rendered as the GraphQL literal the spec asks for.
test "introspection answers for its own types and renders argument defaults" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field_args("search", [("limit", Scalar("Int"))], Scalar("String"), defaults=[
    ("limit", Json(23)),
  ])
  let r = Resolvers::new()
  let meta = execute(s, r, "{ __type(name: \"__Schema\") { name kind } }")
  assert_eq(meta.stringify().contains("__Schema"), true)
  let listed = execute(s, r, "{ __schema { types { name } } }").stringify()
  assert_eq(listed.contains("__Directive"), true)
  let defaults = execute(
    s, r, "{ __type(name: \"Query\") { fields { args { name defaultValue } } } }",
  ).stringify()
  assert_eq(defaults.contains("\"defaultValue\":\"23\""), true)
  let directives = execute(s, r, "{ __schema { directives { name } } }").stringify()
  assert_eq(directives.contains("specifiedBy"), true)
}
