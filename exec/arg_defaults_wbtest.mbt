///|
/// A `Query.greet(greeting: String = "Hello"): String!` whose resolver echoes the
/// argument, so a query that omits `greeting` proves the default was applied.
fn greet_schema() -> (@schema.Schema, Resolvers) {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field_args(
    "greet",
    [("greeting", @schema.Scalar("String"))],
    NonNull(@schema.Scalar("String")),
    defaults=[("greeting", Json("Hello"))],
  )
  let r = Resolvers::new()
  r.field("Query", "greet", info => {
    let g = match info.arg("greeting") {
      String(s) => s
      Null => "null"
      _ => "?"
    }
    Json(g + ", world")
  })
  (s, r)
}

///|
test "an omitted field argument takes its declared default" {
  let (s, r) = greet_schema()
  let out = execute(s, r, "{ greet }")
  assert_eq(out.stringify(), "{\"data\":{\"greet\":\"Hello, world\"}}")
}

///|
test "a supplied field argument overrides its default" {
  let (s, r) = greet_schema()
  let out = execute(s, r, "{ greet(greeting: \"Hi\") }")
  assert_eq(out.stringify(), "{\"data\":{\"greet\":\"Hi, world\"}}")
}

///|
test "an explicit null is a value, not an omission — the default does not apply" {
  let (s, r) = greet_schema()
  let out = execute(s, r, "{ greet(greeting: null) }")
  assert_eq(out.stringify(), "{\"data\":{\"greet\":\"null, world\"}}")
}
