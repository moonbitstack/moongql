///|
/// Declare every kind of type moongql supports — object, input, interface, enum,
/// union and custom scalar, with field arguments and `implements` — then print the
/// whole schema as GraphQL SDL with `to_sdl`. No execution here: this is the
/// code-first schema and the shape the printer emits.
///
///     moon run src/examples/01-sdl
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field("me", Named("User"))
  q.field_args(
    "search",
    [("filter", Named("UserFilter"))],
    NonNull(ListOf(NonNull(Named("SearchResult")))),
  )
  let node = s.interface("Node")
  node.field("id", NonNull(Scalar("ID")))
  let user = s.object("User")
  user.implements("Node")
  user.field("id", NonNull(Scalar("ID")))
  user.field("name", NonNull(Scalar("String")))
  user.field("role", Named("Role"))
  user.field("joined", Named("DateTime"))
  let post = s.object("Post")
  post.field("title", NonNull(Scalar("String")))
  let filter = s.input("UserFilter")
  filter.field("name", Scalar("String"))
  filter.field("role", Named("Role"))
  s.enum_("Role", ["ADMIN", "USER", "GUEST"])
  s.union("SearchResult", ["User", "Post"])
  s.scalar("DateTime")
  println(s.to_sdl())
}
