///|
/// Union types. `SearchResult = Book | Author` is selected through inline fragments,
/// and each element is discriminated by its `__typename` — the matching member's
/// fragment fields are the ones that complete. Introspection reports the union's
/// `possibleTypes`.
///
///     moon run src/examples/08-unions
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field("search", NonNull(ListOf(NonNull(Named("SearchResult")))))
  s.union("SearchResult", ["Book", "Author"])
  s.object("Book").field("title", NonNull(Scalar("String")))
  s.object("Author").field("name", NonNull(Scalar("String")))
  let r = @moongql.Resolvers::new()
  r.field("Query", "search", fn(_info) {
    [
      { "__typename": "Book", "title": "emm in Action" },
      { "__typename": "Author", "name": "lfanke" },
    ]
  })
  let query =
    #|{
    #|  search {
    #|    __typename
    #|    ... on Book { title }
    #|    ... on Author { name }
    #|  }
    #|}
  println(@moongql.execute(s, r, query).stringify())
  println(
    @moongql.execute(
      s, r, "{ __type(name: \"SearchResult\") { kind possibleTypes { name } } }",
    ).stringify(),
  )
}
