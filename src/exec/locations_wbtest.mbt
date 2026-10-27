///|
/// Error `locations` (GraphQL spec §7.1.2): every error that can be traced to a
/// point in the document reports the line and column of the node it is about.

///|
/// The line and column of the first location on the first error, or `(0, 0)` when
/// the response carries none.
fn first_location(res : Json) -> (Int32, Int32) {
  guard res is Object(m) else { return (0, 0) }
  guard m.get("errors") is Some(Array(errs)) else { return (0, 0) }
  guard errs[0] is Object(e) else { return (0, 0) }
  guard e.get("locations") is Some(Array(locs)) else { return (0, 0) }
  guard locs[0] is Object(l) else { return (0, 0) }
  let line = match l.get("line") {
    Some(Number(n, ..)) => n.to_int()
    _ => 0
  }
  let col = match l.get("column") {
    Some(Number(n, ..)) => n.to_int()
    _ => 0
  }
  (line, col)
}

///|
/// A field that does not exist is reported where it was written, not just by name.
test "a validation error names the line and column of the offending field" {
  let query =
    #|query Hero {
    #|  user(id: "1") {
    #|    nope
    #|  }
    #|}
  let res = execute(demo_schema(), demo_resolvers(), query)
  assert_eq(first_location(res), (3, 5))
}

///|
/// A field error carries the position of the field whose resolver failed.
test "a field error names the field that produced it" {
  let query =
    #|{
    #|  mustFail
    #|}
  let res = execute(demo_schema(), demo_resolvers(), query)
  assert_eq(first_location(res), (2, 3))
}

///|
/// A resolver error carrying its own `extensions` is located like any other.
test "a resolver error with extensions names its field" {
  let schema = @schema.Schema::new(query="Query")
  schema.object("Query").field("boom", Scalar("String"))
  let resolvers = Resolvers::new()
  resolvers.field("Query", "boom", _info => {
    raise ResolverErrorExt("kaboom", Map([("code", Json("qwq"))]))
  })
  let res = execute(
    schema,
    resolvers,
    (
      #|{
      #|  boom
      #|}
    ),
  )
  assert_eq(first_location(res), (2, 3))
}

///|
/// A subscription source that fails with its own `extensions` is located at the
/// root field it was registered for.
test "a subscription source error with extensions names the root field" {
  let subs = Subscribers::new()
  subs.field("Subscription", "ticks", _info => {
    raise ResolverErrorExt("no stream", Map([("code", Json("hhh"))]))
  })
  let payloads = execute_subscription(
    sub_schema(),
    Resolvers::new(),
    subs,
    (
      #|subscription {
      #|  ticks
      #|}
    ),
  )
  assert_eq(payloads.length(), 1)
  assert_eq(first_location(payloads[0]), (2, 3))
}

///|
/// An unknown argument points at the argument, not at the field it hangs off.
test "an argument error names the argument" {
  let query =
    #|{
    #|  user(id: "1", nope: 1) { name }
    #|}
  let res = execute(demo_schema(), demo_resolvers(), query)
  assert_eq(first_location(res), (2, 17))
}

///|
/// A directive error points at the `@`.
test "a directive error names the directive" {
  let query =
    #|{
    #|  users
    #|    @nope
    #|  { name }
    #|}
  let res = execute(demo_schema(), demo_resolvers(), query)
  assert_eq(first_location(res), (3, 5))
}

///|
/// An undefined variable is reported where it is used, which is the argument that
/// mentions it — a fragment's usages included.
test "an undefined variable names the argument that uses it" {
  let query =
    #|query Hero {
    #|  user(id: $uid) { name }
    #|}
  let res = execute(demo_schema(), demo_resolvers(), query)
  assert_eq(first_location(res), (2, 8))
}

///|
/// A missing required variable is reported at its declaration.
test "a missing variable value names its declaration" {
  let query =
    #|query Hero(
    #|  $uid: ID!
    #|) { user(id: $uid) { name } }
  let res = execute(demo_schema(), demo_resolvers(), query)
  assert_eq(first_location(res), (2, 3))
}

///|
/// A spread of a fragment that was never defined is reported at the `...`.
test "an unknown fragment names the spread" {
  let query =
    #|{
    #|  users {
    #|    ...Missing
    #|  }
    #|}
  let res = execute(demo_schema(), demo_resolvers(), query)
  assert_eq(first_location(res), (3, 5))
}

///|
/// A syntax error keeps reporting where the parse gave up.
test "a syntax error names where the parse stopped" {
  let query =
    #|{
    #|  users {
    #|}
  let res = execute(demo_schema(), demo_resolvers(), query)
  assert_eq(first_location(res), (3, 2))
}

///|
/// The first location of the first error whose message mentions `needle`, so a
/// test can name the rule it is about when several errors come back at once.
fn location_of(res : Json, needle : String) -> (Int32, Int32) {
  guard res is Object(m) else { return (0, 0) }
  guard m.get("errors") is Some(Array(errs)) else { return (0, 0) }
  for e in errs {
    guard e is Object(eo) else { continue }
    guard eo.get("message") is Some(String(msg)) else { continue }
    if msg.contains(needle) {
      return first_location(jobj([("errors", Json([e]))]))
    }
  }
  (0, 0)
}

///|
/// An explicit null for a non-null variable is reported at the declaration, the
/// same place as one that was never supplied.
test "a null for a non-null variable names its declaration" {
  let query =
    #|query Hero(
    #|  $uid: ID!
    #|) { user(id: $uid) { name } }
  let res = execute(
    demo_schema(),
    demo_resolvers(),
    query,
    variables=Map([("uid", Json::null())]),
  )
  assert_eq(first_location(res), (2, 3))
}

///|
/// A subscription root with no registered source names the field that has none.
test "a missing subscription source names the root field" {
  let payloads = execute_subscription(
    sub_schema(),
    Resolvers::new(),
    Subscribers::new(),
    (
      #|subscription {
      #|  ticks
      #|}
    ),
  )
  assert_eq(payloads.length(), 1)
  assert_eq(first_location(payloads[0]), (2, 3))
}

///|
/// The document-shape rules name the node they are about too: the second
/// declaration of a duplicated variable, the declaration of an unused one, the
/// `fragment` keyword of an unreachable fragment, the second operation of a
/// duplicated name, and the offending argument of a directive.
test "the document-shape rules name their node" {
  let dup =
    #|query Dup(
    #|  $a: ID!
    #|  $a: ID!
    #|) { user(id: $a) { name } }
  assert_eq(
    location_of(
      execute(demo_schema(), demo_resolvers(), dup),
      "Duplicate variable",
    ),
    (3, 3),
  )
  let unused =
    #|query Unused(
    #|  $a: ID!
    #|  $b: ID!
    #|) {
    #|  user(id: $a) { name }
    #|}
  assert_eq(
    location_of(
      execute(demo_schema(), demo_resolvers(), unused),
      "'$b' is never used",
    ),
    (3, 3),
  )
  let ghost =
    #|{
    #|  users { name }
    #|}
    #|
    #|fragment Ghost on User {
    #|  id
    #|}
  assert_eq(
    location_of(
      execute(demo_schema(), demo_resolvers(), ghost),
      "is never used",
    ),
    (5, 1),
  )
  let twice =
    #|query Same { users { name } }
    #|query Same { users { id } }
  assert_eq(
    location_of(
      execute(demo_schema(), demo_resolvers(), twice),
      "only one operation named",
    ),
    (2, 1),
  )
  let bad_dir =
    #|{
    #|  users
    #|    @skip(
    #|      if: true
    #|      nope: 1
    #|    )
    #|  { name }
    #|}
  assert_eq(
    location_of(
      execute(demo_schema(), demo_resolvers(), bad_dir),
      "Unknown argument 'nope'",
    ),
    (5, 7),
  )
}
