///|
/// Read a string field off a representation object, or "".
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
/// Read an integer field off a representation object, or 0.
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
/// Apollo Federation v2. `Federation` layers subgraph metadata over a plain schema:
/// `entity` declares a `@key` type with a reference resolver, and `shareable` /
/// `override_` / `requires` / `provides` / `inaccessible` attach the v2 field
/// directives. `apply` installs the federation machinery, `sdl` prints the subgraph
/// SDL, and a gateway drives the subgraph through `_service { sdl }` and
/// `_entities(representations:)` — the latter resolving each `{ __typename, key }`
/// reference back into a full object.
///
///     moon run src/examples/20-federation
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field("me", Named("User"))
  let u = s.object("User")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", NonNull(Scalar("String")))
  u.field("ssn", Scalar("String"))
  let p = s.object("Product")
  p.field("upc", NonNull(Scalar("String")))
  p.field("name", NonNull(Scalar("String")))
  p.field("price", Scalar("Int"))
  p.field("weight", Scalar("Int"))
  p.field("shippingEstimate", Scalar("Int"))
  let r = @moongql.Resolvers::new()
  let fed = @moongql.Federation::new(v2=true)
  fed.entity(name="User", key="id", resolve=(rep, _ctx) => {
    let id = rep_str(rep, "id")
    { "id": Json(id), "name": Json("User#" + id) }
  })
  fed.entity(name="Product", key="upc", extends=true, external=["weight"], resolve=(
    rep,
    _ctx,
  ) => {
    let upc = rep_str(rep, "upc")
    let weight = rep_int(rep, "weight")
    { "upc": Json(upc), "shippingEstimate": Json(weight * 2) }
  })
  fed.shareable("Product", "name")
  fed.override_("Product", "price", from="legacy")
  fed.requires("Product", "shippingEstimate", fields="weight")
  fed.provides("Query", "me", fields="name")
  fed.inaccessible("User", "ssn")
  fed.apply(s, r)
  println(fed.sdl(s))
  println(@moongql.execute(s, r, "{ _service { sdl } }").stringify())
  let reps : Array[Json] = [
    { "__typename": "User", "id": "7" },
    { "__typename": "Product", "upc": "abc", "weight": 10 },
  ]
  let vars : Map[String, Json] = { "reps": Json(reps) }
  let query =
    #|query ($reps: [_Any!]!) {
    #|  _entities(representations: $reps) {
    #|    ... on User { id name }
    #|    ... on Product { upc shippingEstimate }
    #|  }
    #|}
  println(@moongql.execute(s, r, query, variables=vars).stringify())
}
