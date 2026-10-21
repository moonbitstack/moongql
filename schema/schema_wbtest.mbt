///|
fn contains(haystack : String, needle : String) -> Bool {
  let hn = haystack.length()
  let nn = needle.length()
  if nn == 0 {
    return true
  }
  for i = 0; i + nn <= hn; i = i + 1 {
    let mut ok = true
    for j = 0; j < nn; j = j + 1 {
      if haystack[i + j] != needle[j] {
        ok = false
        break
      }
    }
    if ok {
      return true
    }
  }
  false
}

///|
test "code-first schema renders to SDL" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("hello", NonNull(Scalar("String")))
  let u = s.object("User")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", NonNull(Scalar("String")))
  u.field("tags", ListOf(NonNull(Scalar("String"))))
  q.field("user", Named("User"))
  let sdl = s.to_sdl()
  assert_eq(contains(sdl, "schema {\n  query: Query\n}"), true)
  assert_eq(contains(sdl, "type Query {"), true)
  assert_eq(contains(sdl, "hello: String!"), true)
  assert_eq(contains(sdl, "user: User"), true)
  assert_eq(contains(sdl, "type User {"), true)
  assert_eq(contains(sdl, "id: ID!"), true)
  assert_eq(contains(sdl, "tags: [String!]"), true)
}

///|
test "custom root query name" {
  let s = Schema::new(query="RootQuery")
  s.object("RootQuery").field("ping", NonNull(Scalar("Boolean")))
  assert_eq(contains(s.to_sdl(), "query: RootQuery"), true)
  assert_eq(contains(s.to_sdl(), "ping: Boolean!"), true)
}

///|
test "field arguments render as name(a: T, b: T): RetType" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field_args(
    "user",
    [("id", NonNull(Scalar("ID"))), ("verbose", Scalar("Boolean"))],
    Named("User"),
  )
  let sdl = s.to_sdl()
  assert_eq(contains(sdl, "user(id: ID!, verbose: Boolean): User"), true)
}

///|
test "input object type renders as input Name { .. }" {
  let s = Schema::new()
  let inp = s.input("UserInput")
  inp.field("name", NonNull(Scalar("String")))
  inp.field("age", Scalar("Int"))
  let sdl = s.to_sdl()
  assert_eq(contains(sdl, "input UserInput {"), true)
  assert_eq(contains(sdl, "name: String!"), true)
  assert_eq(contains(sdl, "age: Int"), true)
}

///|
test "enum type renders as enum Name { A B }" {
  let s = Schema::new()
  s.enum_("Color", ["RED", "GREEN", "BLUE"])
  let sdl = s.to_sdl()
  assert_eq(contains(sdl, "enum Color {"), true)
  assert_eq(contains(sdl, "RED"), true)
  assert_eq(contains(sdl, "GREEN"), true)
  assert_eq(contains(sdl, "BLUE"), true)
}

///|
test "interface type and object implements" {
  let s = Schema::new()
  let node = s.interface("Node")
  node.field("id", NonNull(Scalar("ID")))
  let user = s.object("User")
  user.implements("Node")
  user.field("id", NonNull(Scalar("ID")))
  user.field("name", NonNull(Scalar("String")))
  let sdl = s.to_sdl()
  assert_eq(contains(sdl, "interface Node {"), true)
  assert_eq(contains(sdl, "type User implements Node {"), true)
}

///|
test "object implementing multiple interfaces joins with &" {
  let s = Schema::new()
  let _ = s.interface("Node")
  let _ = s.interface("Timestamped")
  let e = s.object("Event")
  e.implements("Node")
  e.implements("Timestamped")
  e.field("id", NonNull(Scalar("ID")))
  assert_eq(
    contains(s.to_sdl(), "type Event implements Node & Timestamped {"),
    true,
  )
}

///|
/// A schema that has a mutation or subscription root must say so in its SDL —
/// printing only the query root describes a different schema from the one running.
test "to_sdl prints every root operation type" {
  let s = Schema::new(query="RootQuery")
  s.set_mutation("RootMutation")
  s.set_subscription("RootSubscription")
  let sdl = s.to_sdl()
  assert_eq(sdl.contains("query: RootQuery"), true)
  assert_eq(sdl.contains("mutation: RootMutation"), true)
  assert_eq(sdl.contains("subscription: RootSubscription"), true)
  // A query-only schema still prints just the one root.
  let plain = Schema::new()
  assert_eq(plain.to_sdl().contains("mutation:"), false)
}
