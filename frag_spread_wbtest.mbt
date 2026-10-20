///|
test "fragment spread on an impossible type is rejected (spec 5.5.2.3)" {
  let schema = Schema::new(query="Query")
  schema.object("Dog").field("name", Scalar("String"))
  schema.object("Cat").field("meow", Scalar("String"))
  schema.object("Query").field("pet", Named("Dog"))
  // `pet` is a Dog, so an inline fragment `... on Cat` can never apply.
  let res = execute(
    schema,
    Resolvers::new(),
    (
      #|{ pet { ... on Cat { meow } } }
    ),
  )
  guard res is Object(m) else { fail("response should be an object") }
  guard m.get("errors") is Some(Array(errs)) else {
    fail("expected a validation error for the impossible spread")
  }
  let mut found = false
  for e in errs {
    match e {
      Object(em) =>
        if em.get("message") ==
          Some(
            Json(
              "Fragment cannot be spread here as objects of type 'Dog' can never be of type 'Cat'",
            ),
          ) {
          found = true
        }
      _ => ()
    }
  }
  assert_eq(found, true)
  // A fragment on the field's own type is accepted (no validation error).
  let ok = execute(
    schema,
    Resolvers::new(),
    (
      #|{ pet { ... on Dog { name } } }
    ),
  )
  guard ok is Object(okm) else { fail("ok response") }
  assert_eq(okm.get("errors"), None)
}
