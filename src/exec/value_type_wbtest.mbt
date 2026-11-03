///|
/// Values of Correct Type (spec §5.6.1): a literal argument value must be
/// coercible to the argument's declared type, and so must a variable default.
test "literal argument values are type-checked against their argument type (5.6.1)" {
  let schema = @schema.Schema::new(query="Query")
  schema.enum_("Role", ["ADMIN", "USER"])
  schema.input("Filter").field("limit", Scalar("Int"))
  let q = schema.object("Query")
  q.field_args("count", [("n", @schema.Scalar("Int"))], Scalar("Int"))
  q.field_args("named", [("s", @schema.Scalar("String"))], Scalar("String"))
  q.field_args("pick", [("r", @schema.Named("Role"))], Scalar("String"))
  q.field_args("search", [("f", @schema.Named("Filter"))], Scalar("String"))

  // A string where an Int is expected is rejected.
  let bad = run_query_errors(schema, "{ count(n: \"hhh\") }")
  assert_eq(
    bad.contains(
      "argument 'n' of field 'count' expected type 'Int', found a string.",
    ),
    true,
  )
  // An enum literal outside the enum's values is rejected.
  let bad_enum = run_query_errors(schema, "{ pick(r: MODERATOR) }")
  assert_eq(
    bad_enum.contains(
      "argument 'r' of field 'pick': value 'MODERATOR' does not exist in enum 'Role'.",
    ),
    true,
  )
  // An input-object field of the wrong type is rejected, reported at the field.
  let bad_input = run_query_errors(schema, "{ search(f: { limit: \"hhh\" }) }")
  assert_eq(
    bad_input.contains(
      "field 'Filter.limit' expected type 'Int', found a string.",
    ),
    true,
  )
  // Well-typed values pass with no validation error.
  let ok = run_query_errors(
    schema, "{ count(n: 233) named(s: \"emm\") pick(r: ADMIN) search(f: { limit: 23 }) }",
  )
  assert_eq(ok.is_empty(), true)
}

///|
/// A variable's default value is a constant governed by §5.6.1 too.
test "variable default values are type-checked (5.6.1)" {
  let schema = @schema.Schema::new(query="Query")
  let q = schema.object("Query")
  q.field_args("count", [("n", @schema.Scalar("Int"))], Scalar("Int"))
  let bad = run_query_errors(
    schema, "query ($n: Int = \"qwq\") { count(n: $n) }",
  )
  assert_eq(
    bad.contains("variable '$n' expected type 'Int', found a string."),
    true,
  )
  let ok = run_query_errors(schema, "query ($n: Int = 66666) { count(n: $n) }")
  assert_eq(ok.is_empty(), true)
}

///|
/// Collect the `message` strings of every error a query produces, so a test can
/// assert on the presence (or absence) of a specific validation error.
fn run_query_errors(schema : @schema.Schema, query : String) -> Array[String] {
  let msgs : Array[String] = []
  let res = execute(schema, Resolvers::new(), query)
  guard res is Object(m) else { return msgs }
  match m.get("errors") {
    Some(Array(errs)) =>
      for e in errs {
        match e {
          Object(em) =>
            match em.get("message") {
              Some(String(s)) => msgs.push(s)
              _ => ()
            }
          _ => ()
        }
      }
    _ => ()
  }
  msgs
}

///|
/// An input object whose fields name defaults: a caller that leaves one out gets
/// it, the same value SDL and introspection report.
fn defaulted_input() -> (@schema.Schema, Resolvers) {
  let s = @schema.Schema::new()
  let filter = s.input("Filter")
  filter.field("limit", @schema.Scalar("Int"), default=Json(10))
  filter.field("title", @schema.Scalar("String"), default=Json("all"))
  let q = s.object("Query")
  q.field_args(
    "books",
    [("filter", NonNull(@schema.Named("Filter")))],
    NonNull(@schema.Scalar("String")),
  )
  let r = Resolvers::new()
  r.field("Query", "books", info => {
    let filter = info.arg("filter")
    match filter {
      Object(m) =>
        Json(
          "limit=" +
          json_scalar(m.get("limit")) +
          " title=" +
          json_scalar(m.get("title")),
        )
      _ => Json("no filter")
    }
  })
  (s, r)
}

///|
fn json_scalar(v : Json?) -> String {
  match v {
    Some(Number(n, ..)) => n.to_string()
    Some(String(s)) => s
    Some(Null) | None => "null"
    _ => "?"
  }
}

///|
test "a field of an input object falls back to its declared default" {
  let (s, r) = defaulted_input()
  let res = execute(s, r, "{ books(filter: {}) }")
  assert_eq(res.stringify(), "{\"data\":{\"books\":\"limit=10 title=all\"}}")
  // What the caller sent wins over the default.
  let res = execute(s, r, "{ books(filter: { limit: 3 }) }")
  assert_eq(res.stringify(), "{\"data\":{\"books\":\"limit=3 title=all\"}}")
}

///|
test "introspection reports an input field's default" {
  let (s, r) = defaulted_input()
  let res = execute(
    s, r, "{ __type(name: \"Filter\") { inputFields { name defaultValue } } }",
  )
  let text = res.stringify()
  assert_eq(text.contains("\"name\":\"limit\",\"defaultValue\":\"10\""), true)
  assert_eq(
    text.contains("\"name\":\"title\",\"defaultValue\":\"\\\"all\\\"\""),
    true,
  )
}
