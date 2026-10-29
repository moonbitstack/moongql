///|
/// Declare every kind of type moongql supports — object, input, interface, enum,
/// union and custom scalar, with field arguments, `implements`, descriptions,
/// deprecations, default values and directives — then print the whole schema as
/// GraphQL SDL with `to_sdl`, and read it back with `Schema::of_sdl`. The SDL
/// carries everything the schema holds, so printing and reading is a round trip:
/// printing what came back is the same text. No execution here: this is the
/// code-first schema and the shape the printer emits.
///
///     moon run src/examples/01-sdl
#coverage.skip
fn main raise {
  let s = @moongql.Schema::new()
  s.set_mutation("Mutation")
  s.directive(
    "tag",
    locations=["OBJECT", "FIELD_DEFINITION"],
    args=[("name", NonNull(Scalar("String")))],
    is_repeatable=true,
  )
  let q = s.object("Query", description="The root of the graph.")
  q.field("me", Named("User"), description="Whoever is asking.")
  q.field_args(
    "search",
    [("filter", Named("UserFilter")), ("first", Scalar("Int"))],
    NonNull(ListOf(NonNull(Named("SearchResult")))),
    defaults=[("first", Json::number(10.0))],
    description="Search the graph.",
  )
  q.field(
    "legacy",
    Scalar("String"),
    deprecation_reason="use search",
    description="The old way.",
  )
  s.apply_field_directive(
    "Query",
    "legacy",
    @moongql.AppliedDirective::new("tag", args=[("name", Json("gone"))]),
  )
  s
  .object("Mutation")
  .field_args(
    "addUser",
    [("input", NonNull(Named("UserFilter")))],
    Named("User"),
  )
  let node = s.interface("Node", description="Anything with an id.")
  node.field("id", NonNull(Scalar("ID")))
  let user = s.object("User")
  user.implements("Node")
  user.field("id", NonNull(Scalar("ID")))
  user.field("name", NonNull(Scalar("String")))
  user.field("role", Named("Role"))
  user.field("joined", Named("DateTime"))
  let post = s.object("Post")
  post.field("title", NonNull(Scalar("String")))
  let filter = s.input("UserFilter", description="How to narrow a search.")
  filter.field("name", Scalar("String"))
  filter.field("role", Named("Role"))
  s.enum_(
    "Role",
    ["ADMIN", "USER", "GUEST"],
    deprecated=[("GUEST", "no longer issued")],
    description="What a user may do.",
    descriptions=[("ADMIN", "Everything.")],
  )
  s.union("SearchResult", ["User", "Post"], description="One search hit.")
  s.scalar(
    "DateTime",
    spec_url="https://scalars.example.dev/date-time",
    description="An ISO-8601 instant.",
  )
  let sdl = s.to_sdl()
  println(sdl)
  let again = @moongql.Schema::of_sdl(sdl).to_sdl()
  if again != sdl {
    abort("the round trip changed the SDL:\n\{again}")
  }
  println("printed then parsed back to the same SDL")
}
