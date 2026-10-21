///|
/// Operation variables and field aliases. `$uid` is bound from a variables map and
/// fed into an argument; the `hero:` alias renames the field in the response. The
/// second run omits `$uid` so its declared default fills in.
///
///     moon run examples/03-variables
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field_args("user", [("id", NonNull(Scalar("ID")))], Named("User"))
  let u = s.object("User")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", NonNull(Scalar("String")))
  let r = @moongql.Resolvers::new()
  r.field("Query", "user", fn(info) {
    match info.arg("id") {
      String("1") => { "id": "1", "name": "emm" }
      String("2") => { "id": "2", "name": "hhh" }
      _ => Json::null()
    }
  })
  let vars : Map[String, Json] = { "uid": "1" }
  println(
    @moongql.execute(
      s,
      r,
      "query ($uid: ID!) { hero: user(id: $uid) { id name } }",
      variables=vars,
    ).stringify(),
  )
  println(
    @moongql.execute(
      s, r, "query ($uid: ID! = \"2\") { user(id: $uid) { name } }",
    ).stringify(),
  )
}
