///|
/// A Federation v2 subgraph: `User @key(fields: "id")` with a sensitive
/// `@inaccessible` `ssn`, and an extended `Product` carrying `@shareable name`,
/// `@override(from: "legacy") price`, an `@external weight`, and a
/// `@requires(fields: "weight") shippingEstimate` whose resolver reads the
/// external `weight` off the representation the gateway sends. `mark_inaccessible`
/// toggles the `@inaccessible` marker so a test can compare both directions.
fn federated_v2_setup(
  mark_inaccessible : Bool,
) -> (@schema.Schema, @exec.Resolvers) {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("me", Named("User"))
  let u = s.object("User")
  u.field("id", NonNull(@schema.Scalar("ID")))
  u.field("name", NonNull(@schema.Scalar("String")))
  u.field("ssn", Scalar("String"))
  let p = s.object("Product")
  p.field("upc", NonNull(@schema.Scalar("String")))
  p.field("name", NonNull(@schema.Scalar("String")))
  p.field("price", Scalar("Int"))
  p.field("weight", Scalar("Int"))
  p.field("shippingEstimate", Scalar("Int"))
  let r = @exec.Resolvers::new()
  r.field("Query", "me", _info => {
    jobj([
      ("id", Json("1")),
      ("name", Json("Ada")),
      ("ssn", Json("123-45-6789")),
    ])
  })
  let fed = Federation::new(v2=true)
  fed.entity(name="User", key="id", resolve=(rep, _ctx) => {
    let id = rep_str(rep, "id")
    jobj([("id", Json(id)), ("name", Json("User#" + id))])
  })
  fed.entity(name="Product", key="upc", extends=true, external=["weight"], resolve=(
    rep,
    _ctx,
  ) => {
    let upc = rep_str(rep, "upc")
    // @requires(fields: "weight"): the gateway includes the external weight in
    // the representation, and the resolver reads it to compute the estimate.
    let weight = rep_int(rep, "weight")
    jobj([("upc", Json(upc)), ("shippingEstimate", Json(weight * 2))])
  })
  fed.shareable("Product", "name")
  fed.override_("Product", "price", from="legacy")
  fed.requires("Product", "shippingEstimate", fields="weight")
  if mark_inaccessible {
    fed.inaccessible("User", "ssn")
  }
  fed.apply(s, r)
  (s, r)
}

///|
/// Read a string field off a representation JSON object, or `""`.
fn rep_str(rep : Json, key : String) -> String {
  match rep {
    Object(m) =>
      match m.get(key) {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
/// Read an integer field off a representation JSON object, or `0`.
fn rep_int(rep : Json, key : String) -> Int32 {
  match rep {
    Object(m) =>
      match m.get(key) {
        Some(Number(n, ..)) => n.to_int()
        _ => 0
      }
    _ => 0
  }
}

///|
/// Pull the `_service { sdl }` string out of an execution result.
fn service_sdl(res : Json) -> String {
  match res {
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
}

///|
/// A v2 subgraph's `_service { sdl }` opens with `extend schema @link(...)` onto
/// the federation spec and renders every v2 field directive: `@shareable`,
/// `@override(from:)`, `@requires(fields:)`, `@external`, and `@inaccessible`.
test "federation v2 SDL round-trips the v2 directives through _service" {
  let (s, r) = federated_v2_setup(true)
  let sdl = service_sdl(
    @exec.execute(
      s,
      r,
      (
        #|{ _service { sdl } }
      ),
    ),
  )
  assert_eq(sdl.contains("extend schema"), true)
  assert_eq(
    sdl.contains("@link(url: \"https://specs.apollo.dev/federation/v2.3\""),
    true,
  )
  assert_eq(sdl.contains("type User @key(fields: \"id\") {"), true)
  assert_eq(sdl.contains("ssn: String @inaccessible"), true)
  assert_eq(sdl.contains("name: String! @shareable"), true)
  assert_eq(sdl.contains("price: Int @override(from: \"legacy\")"), true)
  assert_eq(
    sdl.contains("shippingEstimate: Int @requires(fields: \"weight\")"),
    true,
  )
  assert_eq(sdl.contains("weight: Int @external"), true)
}

///|
/// MUTATION-VERIFY of the `@inaccessible` hiding, both directions: with the marker
/// the `ssn` field is absent from the introspected `User`, and without it the same
/// field is present. The non-inaccessible `name` field is always visible.
test "federation v2 @inaccessible hides a field from introspection" {
  let query =
    #|{ __type(name: "User") { fields { name } } }

  // Direction A: marked @inaccessible -> hidden from introspection.
  let (s1, r1) = federated_v2_setup(true)
  let hidden = @exec.execute(s1, r1, query).stringify()
  assert_eq(hidden.contains("\"name\":\"name\""), true)
  assert_eq(hidden.contains("\"name\":\"ssn\""), false)

  // Direction B: same schema without the marker -> ssn is introspectable again.
  let (s2, r2) = federated_v2_setup(false)
  let shown = @exec.execute(s2, r2, query).stringify()
  assert_eq(shown.contains("\"name\":\"ssn\""), true)
}

///|
/// An `@inaccessible` field is hidden from the public schema but still resolvable
/// within the subgraph — hiding is an introspection/composition concern, not an
/// execution one.
test "federation v2 @inaccessible field is still resolvable in the subgraph" {
  let (s, r) = federated_v2_setup(true)
  let res = @exec.execute(
    s,
    r,
    (
      #|{ me { name ssn } }
    ),
  )
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"me":{"name":"Ada","ssn":"123-45-6789"}}}
    ),
  )
}

///|
/// The "can actually run" entities milestone across v2: `_entities` resolves a
/// `Product` representation that carries its `@external` `weight` (per `@requires`)
/// and the resolver reads that external field to compute `shippingEstimate`.
/// MUTATION-VERIFY: a different `weight` yields a correspondingly different
/// estimate, so the resolver is provably honouring the representation's data.
test "federation v2 @requires resolver reads the external field" {
  let (s, r) = federated_v2_setup(true)
  let query =
    #|query ($reps: [_Any!]!) {
    #|  _entities(representations: $reps) {
    #|    ... on Product { upc shippingEstimate }
    #|  }
    #|}
  let run = fn(weight : Int32) -> String {
    let reps : Array[Json] = [
      jobj([
        ("__typename", Json("Product")),
        ("upc", Json("abc")),
        ("weight", Json(weight)),
      ]),
    ]
    let vars : Map[String, Json] = Map([("reps", Json(reps))])
    @exec.execute(s, r, query, variables=vars).stringify()
  }
  assert_eq(
    run(10),
    (
      #|{"data":{"_entities":[{"upc":"abc","shippingEstimate":20}]}}
    ),
  )
  // MUTATION-VERIFY (both directions): change the required external input, the
  // resolved output must change with it.
  assert_eq(
    run(25),
    (
      #|{"data":{"_entities":[{"upc":"abc","shippingEstimate":50}]}}
    ),
  )
}

///|
/// A v2 subgraph whose `Product` is tagged at the type level and on one field,
/// with a `shipping` field that reads the `@external weight` the gateway sends
/// rather than the entity resolver computing it.
fn tagged_setup() -> (@schema.Schema, @exec.Resolvers, Federation) {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("product", Named("Product"))
  let p = s.object("Product")
  p.field("upc", NonNull(@schema.Scalar("String")))
  p.field("weight", Scalar("Int"))
  p.field("shipping", Scalar("Int"))
  let r = @exec.Resolvers::new()
  // The entity resolver only knows the upc; `weight` arrives in the
  // representation, and `_entities` keeps it on the value this resolver returns.
  r.field("Product", "shipping", info => {
    match info.parent {
      Object(m) =>
        match m.get("weight") {
          Some(Number(n, ..)) => Json(n.to_int() * 2)
          _ => Json::null()
        }
      _ => Json::null()
    }
  })
  let fed = Federation::new(v2=true)
  fed.entity(name="Product", key="upc", extends=true, external=["weight"], resolve=(
    rep,
    _ctx,
  ) => jobj([("upc", Json(rep_str(rep, "upc")))]))
  fed.tag("Product", name="catalog")
  fed.tag_field("Product", "weight", name="measured")
  fed.requires("Product", "shipping", fields="weight")
  fed.apply(s, r)
  (s, r, fed)
}

///|
test "a tag sits on the type and the field of the subgraph SDL" {
  let (s, r, _) = tagged_setup()
  let sdl = service_sdl(@exec.execute(s, r, "{ _service { sdl } }"))
  assert_eq(
    sdl.contains("type Product @key(fields: \"upc\") @tag(name: \"catalog\") {"),
    true,
  )
  assert_eq(
    sdl.contains("weight: Int @external @tag(name: \"measured\")"),
    true,
  )
  // The directive is imported by the spec link, or a gateway cannot compose it.
  assert_eq(sdl.contains("Json(\"@tag\")"), false)
  assert_eq(sdl.contains("\"@tag\""), true)
}

///|
test "the representation's fields stay on the entity its resolvers read" {
  let (s, r, _) = tagged_setup()
  let reps : Array[Json] = [
    jobj([
      ("__typename", Json("Product")),
      ("upc", Json("abc")),
      ("weight", Json(7)),
    ]),
  ]
  let vars : Map[String, Json] = Map([("reps", Json(reps))])
  let res = @exec.execute(
    s,
    r,
    (
      #|query ($reps: [_Any!]!) { _entities(representations: $reps) { ... on Product { upc shipping } } }
    ),
    variables=vars,
  )
  assert_eq(
    res.stringify(),
    "{\"data\":{\"_entities\":[{\"upc\":\"abc\",\"shipping\":14}]}}",
  )
}

///|
test "check is silent on a subgraph the gateway can compose" {
  let (s, _, fed) = tagged_setup()
  assert_eq(fed.check(s).length(), 0)
  // The machinery `apply` installs is a valid schema too: _Any, _Service, the
  // _Entity union and the two root fields all hold up.
  assert_eq(s.check().length(), 0)
}

///|
test "check names a requires field the type does not declare" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("p", Named("Product"))
  let p = s.object("Product")
  p.field("upc", NonNull(@schema.Scalar("String")))
  p.field("shipping", Scalar("Int"))
  let r = @exec.Resolvers::new()
  let fed = Federation::new(v2=true)
  fed.entity(name="Product", key="upc", resolve=(rep, _ctx) => rep)
  fed.requires("Product", "shipping", fields="weight")
  fed.apply(s, r)
  let why = fed.check(s)
  assert_eq(why.length(), 1)
  assert_eq(
    why[0],
    "@requires on Product.shipping: 'Product' has no field 'weight', which `weight` names",
  )
}

///|
test "check reads a provides field set against what the field returns" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("p", Named("Product"))
  let p = s.object("Product")
  p.field("upc", NonNull(@schema.Scalar("String")))
  p.field("owner", Named("User"))
  let u = s.object("User")
  u.field("id", NonNull(@schema.Scalar("ID")))
  let r = @exec.Resolvers::new()
  let fed = Federation::new(v2=true)
  fed.entity(name="Product", key="upc", resolve=(rep, _ctx) => rep)
  fed.provides("Product", "owner", fields="id name")
  fed.apply(s, r)
  let why = fed.check(s)
  assert_eq(why.length(), 1)
  assert_eq(
    why[0],
    "@provides on Product.owner: 'User' has no field 'name', which `id name` names",
  )
}

///|
test "check reads a nested field set, and refuses one that is not a field set" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("p", Named("Product"))
  let p = s.object("Product")
  p.field("upc", NonNull(@schema.Scalar("String")))
  p.field("owner", Named("User"))
  let u = s.object("User")
  u.field("id", NonNull(@schema.Scalar("ID")))
  u.field("name", NonNull(@schema.Scalar("String")))
  let r = @exec.Resolvers::new()
  let fed = Federation::new(v2=true)
  fed.entity(name="Product", key="upc", resolve=(rep, _ctx) => rep)
  fed.provides("Product", "owner", fields="id owner { name }")
  fed.apply(s, r)
  let why = fed.check(s)
  assert_eq(why.length(), 1)
  assert_eq(
    why[0],
    "@provides on Product.owner: 'User' has no field 'owner', which `id owner { name }` names",
  )
  let (s2, _, fed2) = tagged_setup()
  let broken = Federation::new(v2=true)
  broken.entity(name="Product", key="upc", resolve=(rep, _ctx) => rep)
  broken.requires("Product", "shipping", fields="weight {")
  broken.apply(s2, @exec.Resolvers::new())
  assert_eq(broken.check(s2).length(), 1)
  assert_eq(
    broken.check(s2)[0],
    "@requires on Product.shipping: `fields: \"weight {\"` is not a field set",
  )
  ignore(fed2)
}
