///|
/// A schema written in SDL: `shop.g.mbt` holds its types and a `declare fn` for each resolver,
/// `resolvers.mbt` fills them in, and the answers come back through the usual executor.
///
///     moon run src/examples/27-schema-first
fn main {
  let schema = @moongql.Schema::new()
  let resolvers = @moongql.Resolvers::new()
  register(schema, resolvers)
  let ask = (query : String) => {
    println(@moongql.execute(schema, resolvers, query).stringify())
  }
  ask(
    "{ book(id: \"b1\") { title status author { name books(first: 1) { title } } } }",
  )
  ask(
    "{ search(text: \"Sol\") { __typename ... on Book { title } ... on Author { name } } }",
  )
  ask(
    "mutation { addBook(input: { title: \"Summa\", authorId: \"a2\" }) { id status } }",
  )
  ask(
    "mutation { addBook(input: { title: \"Lost\", authorId: \"zz\" }) { id } }",
  )
}
