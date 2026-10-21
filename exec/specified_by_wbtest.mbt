///|
test "custom scalar specifiedByURL surfaces in introspection (@specifiedBy)" {
  let schema = @schema.Schema::new(query="Query")
  schema.scalar("DateTime", spec_url="https://scalars.graphql.org/datetime")
  schema.object("Query").field("now", Scalar("DateTime"))
  let q =
    #|{ __type(name: "DateTime") { name kind specifiedByURL } }
  let res = execute(schema, Resolvers::new(), q)
  guard res is Object(m) else { fail("response should be an object") }
  guard m.get("data") is Some(Object(data)) else { fail("data") }
  guard data.get("__type") is Some(Object(t)) else { fail("__type") }
  assert_eq(t.get("kind"), Some(Json("SCALAR")))
  assert_eq(
    t.get("specifiedByURL"),
    Some(Json("https://scalars.graphql.org/datetime")),
  )
  // A built-in scalar carries no spec URL.
  let res2 = execute(
    schema,
    Resolvers::new(),
    (
      #|{ __type(name: "String") { specifiedByURL } }
    ),
  )
  guard res2 is Object(m2) else { fail("response2") }
  guard m2.get("data") is Some(Object(d2)) else { fail("data2") }
  guard d2.get("__type") is Some(Object(t2)) else { fail("__type2") }
  assert_eq(t2.get("specifiedByURL"), Some(Json::null()))
}
