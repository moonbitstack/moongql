///|
/// A schema declared with `#gql` annotations. `library.g.mbt` is generated from
/// `library.mbt` by `cmd/gql`; a project wires the generator as a dev_build rule
/// (see the README). The program checks that the generated `register` prints the
/// same SDL as the hand-written schema in `hand.mbt` and answers every query the
/// same way, then shows the answers.
///
///     moon run src/examples/24-annotations
fn same(what : String, generated : String, hand : String) -> Unit {
  if generated != hand {
    abort("\{what} differs:\n  generated: \{generated}\n  by hand:   \{hand}")
  }
}

///|
let introspection : String =
  #|{ __schema { types { name kind description
  #|  fields(includeDeprecated: true) { name description isDeprecated deprecationReason
  #|    args { name type { name kind ofType { name kind } } }
  #|    type { name kind ofType { name kind ofType { name kind ofType { name } } } } }
  #|  inputFields { name type { name kind ofType { name } } }
  #|  enumValues(includeDeprecated: true) { name } } } }

///|
fn built(
  fill : (@moongql.Schema, @moongql.Resolvers) -> Unit,
) -> (@moongql.Schema, @moongql.Resolvers) {
  let s = @moongql.Schema::new()
  let r = @moongql.Resolvers::new()
  fill(s, r)
  (s, r)
}

///|
#coverage.skip
fn main {
  let (gs, gr) = built(register)
  let (hs, hr) = built(hand_register)
  same("SDL", gs.to_sdl(), hs.to_sdl())
  println(gs.to_sdl())
  // The SDL printer leaves out descriptions; introspection carries them, with
  // deprecations and argument types.
  same(
    "introspection",
    @moongql.execute(gs, gr, introspection).stringify(),
    @moongql.execute(hs, hr, introspection).stringify(),
  )
  let queries = [
    "{ author(id: \"1\") { name contact books(first: 1) { title status isbn } } }",
    "{ books(status: Draft) { id title author { name } } }", "mutation { addBook(input: { title: \"Dune\", authorId: \"2\", status: Published }) { id title status author { name } } }",
    "mutation { addBook(input: { title: \"\", authorId: \"2\" }) { id } }", "{ author(id: \"1\") { email } }",
    "{ works { __typename id title ... on Book { status } ... on Magazine { issue } } }",
    "{ search(text: \"e\") { __typename ... on Author { name } ... on Book { title } } }",
  ]
  for q in queries {
    reset()
    let generated = @moongql.execute(gs, gr, q).stringify()
    reset()
    let hand = @moongql.execute(hs, hr, q).stringify()
    same(q, generated, hand)
    println(q)
    println("  " + generated)
  }
  println("")
  println("generated and hand-written schemas agree")
}
