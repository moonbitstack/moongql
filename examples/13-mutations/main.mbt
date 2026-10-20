///|
/// Mutations. `set_mutation` names the mutation root type; its fields carry
/// resolvers keyed by `"Mutation.field"` exactly like queries. `addPost` reads an
/// input-object argument, appends to an in-memory store and returns the created
/// object — and a follow-up query reads the store back, so the write is observable.
///
///     moon run examples/13-mutations
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field(
    "posts",
    @moongql.NonNull(@moongql.ListOf(@moongql.NonNull(@moongql.Named("Post")))),
  )
  s.set_mutation("Mutation")
  let m = s.object("Mutation")
  m.field_args(
    "addPost",
    [("input", @moongql.NonNull(@moongql.Named("PostInput")))],
    @moongql.NonNull(@moongql.Named("Post")),
  )
  let post = s.object("Post")
  post.field("id", @moongql.NonNull(@moongql.Scalar("ID")))
  post.field("title", @moongql.NonNull(@moongql.Scalar("String")))
  let input = s.input("PostInput")
  input.field("title", @moongql.NonNull(@moongql.Scalar("String")))
  let store : Array[Json] = []
  let r = @moongql.Resolvers::new()
  r.field("Query", "posts", _info => Json(store))
  r.field("Mutation", "addPost", info => {
    let title = match info.arg("input") {
      Object(m) =>
        match m.get("title") {
          Some(String(t)) => t
          _ => ""
        }
      _ => ""
    }
    let created : Json = {
      "id": Json((store.length() + 1).to_string()),
      "title": Json(title),
    }
    store.push(created)
    created
  })
  println(
    @moongql.execute(
      s, r, "mutation { addPost(input: { title: \"emm\" }) { id title } }",
    ).stringify(),
  )
  println(
    @moongql.execute(
      s, r, "mutation { addPost(input: { title: \"hhh\" }) { id title } }",
    ).stringify(),
  )
  println(@moongql.execute(s, r, "{ posts { id title } }").stringify())
}
