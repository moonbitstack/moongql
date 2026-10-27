///|
/// Interface types and `implements`. `Node` declares `id`; `User` implements it. A
/// field typed as the interface resolves its concrete type from the value's
/// `__typename`, so `... on User` contributes the User-only fields while `id` is
/// selected straight off the interface. The SDL shows `type User implements Node`.
///
///     moon run src/examples/07-interfaces
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field("node", Named("Node"))
  let node = s.interface("Node")
  node.field("id", NonNull(Scalar("ID")))
  let user = s.object("User")
  user.implements("Node")
  user.field("id", NonNull(Scalar("ID")))
  user.field("name", NonNull(Scalar("String")))
  let r = @moongql.Resolvers::new()
  r.field("Query", "node", fn(_info) {
    { "__typename": "User", "id": "1", "name": "emm" }
  })
  println(
    @moongql.execute(s, r, "{ node { __typename id ... on User { name } } }").stringify(),
  )
  println(s.to_sdl().contains("type User implements Node {"))
}
