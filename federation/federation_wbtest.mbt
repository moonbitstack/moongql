///|
/// A federated schema: `User @key(fields: "id")` owned here, `Product` extended
/// with an external `upc` key and a locally-added `reviews` field. Returns the
/// schema, resolvers and federation config after `apply`.
fn federated_setup() -> (@schema.Schema, @exec.Resolvers) {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("me", Named("User"))
  let u = s.object("User")
  u.field("id", NonNull(@schema.Scalar("ID")))
  u.field("name", NonNull(@schema.Scalar("String")))
  let p = s.object("Product")
  p.field("upc", NonNull(@schema.Scalar("String")))
  p.field("reviews", ListOf(@schema.Scalar("String")))
  let r = @exec.Resolvers::new()
  let fed = Federation::new()
  fed.entity(name="User", key="id", resolve=(rep, _ctx) => {
    let id = match rep {
      Object(m) =>
        match m.get("id") {
          Some(String(s)) => s
          _ => ""
        }
      _ => ""
    }
    jobj([("id", Json(id)), ("name", Json("User#" + id))])
  })
  fed.entity(name="Product", key="upc", extends=true, external=["upc"], resolve=(
    rep,
    _ctx,
  ) => {
    let upc = match rep {
      Object(m) =>
        match m.get("upc") {
          Some(String(s)) => s
          _ => ""
        }
      _ => ""
    }
    jobj([("upc", Json(upc)), ("reviews", Json(["great", "ok"]))])
  })
  fed.apply(s, r)
  (s, r)
}

///|
/// `_service { sdl }` returns the subgraph SDL with `@key` on the entity types,
/// `extend` + `@external` on the extended one, and none of the federation-internal
/// additions.
test "_service returns the federated SDL" {
  let (s, r) = federated_setup()
  let res = @exec.execute(
    s,
    r,
    (
      #|{ _service { sdl } }
    ),
  )
  let sdl = match res {
    Object(m) =>
      match m.get("data") {
        Some(Object(d)) =>
          match d.get("_service") {
            Some(Object(sv)) =>
              match sv.get("sdl") {
                Some(String(x)) => x
                _ => ""
              }
            _ => ""
          }
        _ => ""
      }
    _ => ""
  }
  assert_eq(sdl.contains("type User @key(fields: \"id\") {"), true)
  assert_eq(sdl.contains("extend type Product @key(fields: \"upc\") {"), true)
  assert_eq(sdl.contains("upc: String! @external"), true)
  // the federation machinery is not part of the subgraph SDL
  assert_eq(sdl.contains("_Service"), false)
  assert_eq(sdl.contains("_entities"), false)
  assert_eq(sdl.contains("_Entity"), false)
}

///|
/// The "can actually run" entities milestone: `_entities(representations:)`
/// resolves each `{ __typename, key }` reference back into a full object, selected
/// through inline fragments on the member types. This is the exact `{ data }` a
/// gateway receives.
test "_entities resolves representations into entities" {
  let (s, r) = federated_setup()
  let reps : Array[Json] = [
    jobj([("__typename", Json("User")), ("id", Json("7"))]),
    jobj([("__typename", Json("Product")), ("upc", Json("abc"))]),
  ]
  let vars = jobj([("reps", Json(reps))])
  let query =
    #|query ($reps: [_Any!]!) {
    #|  _entities(representations: $reps) {
    #|    ... on User { id name }
    #|    ... on Product { upc reviews }
    #|  }
    #|}
  let variables : Map[String, Json] = match vars {
    Object(m) => m
    _ => Map([])
  }
  let res = @exec.execute(s, r, query, variables~)
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"_entities":[{"id":"7","name":"User#7"},{"upc":"abc","reviews":["great","ok"]}]}}
    ),
  )
}

///|
/// A representation whose `__typename` names no registered entity resolves to
/// null rather than failing the whole request.
test "_entities yields null for an unknown entity type" {
  let (s, r) = federated_setup()
  let reps : Array[Json] = [
    jobj([("__typename", Json("Unknown")), ("id", Json("1"))]),
  ]
  let variables : Map[String, Json] = Map([("reps", Json(reps))])
  let query =
    #|query ($reps: [_Any!]!) {
    #|  _entities(representations: $reps) { __typename }
    #|}
  let res = @exec.execute(s, r, query, variables~)
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"_entities":[null]}}
    ),
  )
}

///|
/// The `_Entity` union and `_Any` scalar show up in introspection once federation
/// is installed, so a gateway that introspects the subgraph sees the entity union.
test "federation types appear in introspection" {
  let (s, r) = federated_setup()
  let res = @exec.execute(
    s,
    r,
    (
      #|{ __type(name: "_Entity") { kind possibleTypes { name } } }
    ),
  )
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"__type":{"kind":"UNION","possibleTypes":[{"name":"User"},{"name":"Product"}]}}}
    ),
  )
}
