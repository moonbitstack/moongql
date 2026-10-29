///|
/// Build a `User` object value as JSON for the resolver dataset.
fn juser(id : String, name : String, age : Int32) -> Json {
  let m : Map[String, Json] = Map([])
  m["id"] = Json(id)
  m["name"] = Json(name)
  m["age"] = Json(age)
  Json(m)
}

///|
/// A small schema: `Query { user(id: ID!): User, users: [User!]!,
/// mustFail: String! }`, `User implements Node { id, name, age }`, `Node { id }`.
fn demo_schema() -> @schema.Schema {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field_args(
    "user",
    [("id", @schema.NonNull(@schema.Scalar("ID")))],
    Named("User"),
  )
  q.field(
    "users",
    NonNull(@schema.ListOf(@schema.NonNull(@schema.Named("User")))),
  )
  q.field("mustFail", NonNull(@schema.Scalar("String")))
  let node = s.interface("Node")
  node.field("id", NonNull(@schema.Scalar("ID")))
  let user = s.object("User")
  user.implements("Node")
  user.field("id", NonNull(@schema.Scalar("ID")))
  user.field("name", NonNull(@schema.Scalar("String")))
  user.field("age", Scalar("Int"))
  s
}

///|
/// Resolvers for `demo_schema`: `Query.user` reads its `id` argument, `users`
/// returns the whole set, `mustFail` returns null to exercise non-null bubbling.
/// `User.*` fields fall back to the default resolver (read off the parent).
fn demo_resolvers() -> Resolvers {
  let r = Resolvers::new()
  r.field("Query", "user", fn(info) {
    let id = match info.arg("id") {
      String(s) => s
      _ => ""
    }
    if id == "1" {
      juser("1", "Alice", 30)
    } else if id == "2" {
      juser("2", "Bob", 25)
    } else {
      Json::null()
    }
  })
  r.field("Query", "users", fn(_info) {
    Json([juser("1", "Alice", 30), juser("2", "Bob", 25)])
  })
  r.field("Query", "mustFail", fn(_info) { Json::null() })
  r
}

///|
/// End-to-end execution of a real query carrying a variable, an alias, a named
/// fragment and an `@include` directive — the "can actually run" milestone.
test "execute a real query with variables, alias, fragment and @include" {
  let query =
    #|query GetUser($uid: ID!, $withAge: Boolean!) {
    #|  hero: user(id: $uid) {
    #|    ...UserFields
    #|    age @include(if: $withAge)
    #|  }
    #|}
    #|
    #|fragment UserFields on User {
    #|  id
    #|  name
    #|}
  let vars : Map[String, Json] = Map([])
  vars["uid"] = Json("1")
  vars["withAge"] = Json(true)
  let res = execute(demo_schema(), demo_resolvers(), query, variables=vars)
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"hero":{"id":"1","name":"Alice","age":30}}}
    ),
  )
}

///|
/// `@include(if: false)` (via a variable) omits the guarded field.
test "skip/include directives drop guarded fields" {
  let query =
    #|query GetUser($uid: ID!, $withAge: Boolean!) {
    #|  hero: user(id: $uid) {
    #|    id
    #|    name
    #|    age @include(if: $withAge)
    #|  }
    #|}
  let vars : Map[String, Json] = Map([])
  vars["uid"] = Json("2")
  vars["withAge"] = Json(false)
  let res = execute(demo_schema(), demo_resolvers(), query, variables=vars)
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"hero":{"id":"2","name":"Bob"}}}
    ),
  )
}

///|
/// A list field completes element-wise into a JSON array of objects.
test "list result of objects" {
  let query =
    #|{ users { name } }
  let res = execute(demo_schema(), demo_resolvers(), query)
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"users":[{"name":"Alice"},{"name":"Bob"}]}}
    ),
  )
}

///|
/// A default variable value is used when the request omits the variable, and a
/// nullable field that resolves null becomes JSON null with no error.
test "default variable value and nullable null" {
  let query =
    #|query ($uid: ID! = "99") {
    #|  user(id: $uid) { name }
    #|}
  let res = execute(demo_schema(), demo_resolvers(), query)
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"user":null}}
    ),
  )
}

///|
/// A non-null field resolving to null records an error and nulls the enclosing
/// object (here the whole operation data), per the non-null propagation rules.
test "non-null field returning null bubbles to an error" {
  let query =
    #|{ mustFail }
  let res = execute(demo_schema(), demo_resolvers(), query)
  assert_eq(
    res.stringify(),
    (
      #|{"data":null,"errors":[{"message":"Cannot return null for non-nullable field","locations":[{"line":1,"column":3}],"path":["mustFail"]}]}
    ),
  )
}

///|
/// `__typename` resolves to the concrete type name.
test "introspection __typename on the query root" {
  let res = execute(
    demo_schema(),
    demo_resolvers(),
    (
      #|{ __typename }
    ),
  )
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"__typename":"Query"}}
    ),
  )
}

///|
/// `__type(name:)` answers a type's kind and field names from the schema.
test "introspection __type resolves a type's fields" {
  let query =
    #|{ __type(name: "User") { name kind fields { name } } }
  let res = execute(demo_schema(), demo_resolvers(), query)
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"__type":{"name":"User","kind":"OBJECT","fields":[{"name":"id"},{"name":"name"},{"name":"age"}]}}}
    ),
  )
}

///|
/// `__schema` answers the root operation types and can nest into a field's
/// wrapped type via `ofType`.
test "introspection __schema root and ofType nesting" {
  let query =
    #|{
    #|  __schema { queryType { name } }
    #|  __type(name: "Query") {
    #|    fields {
    #|      name
    #|      type { kind ofType { kind name } }
    #|    }
    #|  }
    #|}
  let res = execute(demo_schema(), demo_resolvers(), query)
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"__schema":{"queryType":{"name":"Query"}},"__type":{"fields":[{"name":"user","type":{"kind":"OBJECT","ofType":null}},{"name":"users","type":{"kind":"NON_NULL","ofType":{"kind":"LIST","name":null}}},{"name":"mustFail","type":{"kind":"NON_NULL","ofType":{"kind":"SCALAR","name":"String"}}}]}}}
    ),
  )
}

///|
/// A field that does not exist on its type is a validation error and yields no
/// `data` key.
test "validation rejects an unknown field" {
  let res = execute(
    demo_schema(),
    demo_resolvers(),
    (
      #|{ user(id: "1") { nope } }
    ),
  )
  assert_eq(
    res.stringify(),
    (
      #|{"errors":[{"message":"Cannot query field 'nope' on type 'User'","locations":[{"line":1,"column":19}]}]}
    ),
  )
}

///|
/// A syntax error yields an `errors`-only response with a source location.
test "syntax error yields errors-only response" {
  let res = execute(demo_schema(), demo_resolvers(), "{ user(id: ) }")
  assert_eq(res.stringify().length() > 0 && res is Object(_), true)
  let has_data = match res {
    Object(m) => m.contains("data")
    _ => true
  }
  assert_eq(has_data, false)
}

///|
/// An inline fragment with a type condition contributes its fields when the
/// runtime object matches the condition.
test "inline fragment with type condition" {
  let query =
    #|{ user(id: "1") { id ... on User { name age } } }
  let res = execute(demo_schema(), demo_resolvers(), query)
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"user":{"id":"1","name":"Alice","age":30}}}
    ),
  )
}

///|
/// §6.1.2: a non-null variable with no value is a request error — the operation
/// never runs. It used to reach the resolver as null, which made a broken request
/// look like a successful one that found nothing.
test "a missing required variable is a request error" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field_args(
    "user",
    [("id", @schema.NonNull(@schema.Scalar("ID")))],
    Named("User"),
  )
  let u = s.object("User")
  u.field("id", NonNull(@schema.Scalar("ID")))
  let r = Resolvers::new()
  let reached : Array[Json] = []
  r.field("Query", "user", info => {
    reached.push(info.arg("id"))
    Json({ "id": "u1" })
  })
  let query = "query ($id: ID!) { user(id: $id) { id } }"
  let resp = execute(s, r, query, variables=Map([]))
  assert_eq(reached.length(), 0)
  let text = resp.stringify()
  assert_eq(text.contains("was not provided"), true)
  assert_eq(text.contains("\"data\""), false)
  // Supplied, it runs.
  let ok = execute(s, r, query, variables=Map([("id", Json("u1"))]))
  assert_eq(reached.length(), 1)
  assert_eq(ok.stringify().contains("\"errors\""), false)
}

///|
/// A resolver that raises on a non-null field leaves its own error and nulls
/// the parent; the null does not add a second error.
test "a raising non-null field reports its error once" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("boom", NonNull(Scalar("String")))
  q.field("fine", Scalar("String"))
  let r = Resolvers::new()
  r.field("Query", "boom", _ => raise ResolverError("broke"))
  r.field("Query", "fine", _ => Json::null())
  assert_eq(
    execute(s, r, "{ boom }").stringify(),
    (
      #|{"data":null,"errors":[{"message":"broke","locations":[{"line":1,"column":3}],"path":["boom"]}]}
    ),
  )
  assert_eq(execute(s, r, "{ fine }").stringify(), "{\"data\":{\"fine\":null}}")
}
