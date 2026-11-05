// The guide's examples written as calls on the schema and the resolver map.

///|
/// The data all three ways of writing the same server share.
let writers : Array[Json] = [
  { "id": Json("1"), "name": Json("Ursula") },
  { "id": Json("2"), "name": Json("Ted") },
]

///|
let shelf : Array[Json] = [
  { "id": Json("b1"), "title": Json("The Dispossessed"), "authorId": Json("1") },
  { "id": Json("b2"), "title": Json("Lathe"), "authorId": Json("1") },
  { "id": Json("b3"), "title": Json("Exhalation"), "authorId": Json("2") },
]

///|
/// The field a JSON object carries, or `null`.
fn key_of(value : Json, field : String) -> Json {
  match value {
    Object(m) => m.get(field).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
/// The schema, its resolvers and the subscription sources.
pub fn server() -> (@moongql.Schema, @moongql.Resolvers, @moongql.Subscribers) {
  shelf.truncate(3)
  let schema = @moongql.Schema::new()
  // guide:type
  let author = schema.object("Author", description="Someone who writes books")
  author.field("id", NonNull(Scalar("String")))
  author.field("name", NonNull(Scalar("String")))

  let book = schema.object("Book")
  book.field("id", NonNull(Scalar("String")))
  book.field("title", NonNull(Scalar("String")))
  // The author id is data on the type, and what `Author.books` is resolved from.
  book.field("authorId", NonNull(Scalar("String")))
  // end
  // guide:field
  author.field("books", NonNull(ListOf(NonNull(Named("Book")))))
  // end
  // guide:root
  let query = schema.object("Query")
  query.field_args(
    "author",
    [("id", NonNull(Scalar("String")))],
    Named("Author"),
  )
  query.field("books", NonNull(ListOf(NonNull(Named("Book")))))
  // end
  // guide:input
  let new_book = schema.input("NewBook")
  new_book.field("title", NonNull(Scalar("String")))
  new_book.field("authorId", NonNull(Scalar("String")))

  let mutation = schema.object("Mutation")
  mutation.field_args(
    "addBook",
    [("input", NonNull(Named("NewBook")))],
    NonNull(Named("Book")),
  )
  schema.set_mutation("Mutation")
  // end
  let subscription = schema.object("Subscription")
  // guide:subscription
  subscription.field("bookAdded", NonNull(Named("Book")))
  // end
  schema.set_subscription("Subscription")

  let resolvers = @moongql.Resolvers::new()
  // guide:field.register
  resolvers.field("Author", "books", info => {
    let id = key_of(info.parent, "id")
    Json(shelf.filter(b => key_of(b, "authorId") == id))
  })
  // end
  // guide:root.register
  resolvers.field("Query", "author", info => {
    let id = info.arg("id")
    match writers.iter().find_first(a => key_of(a, "id") == id) {
      Some(a) => a
      None => Json::null()
    }
  })
  resolvers.field("Query", "books", _info => Json(shelf.copy()))
  // end
  // guide:mutation
  resolvers.field("Mutation", "addBook", info => {
    let input = info.arg("input")
    let title = match key_of(input, "title") {
      String(t) => t
      _ => ""
    }
    if title == "" {
      raise @exec.FieldError("a book needs a title")
    }
    let book : Json = {
      "id": Json("b\{shelf.length() + 1}"),
      "title": Json(title),
      "authorId": key_of(input, "authorId"),
    }
    shelf.push(book)
    book
  })
  // end
  let subscribers = @moongql.Subscribers::new()
  subscribers.field("Subscription", "bookAdded", _info => shelf.copy())
  (schema, resolvers, subscribers)
}

///|
/// The same subgraph, joined to a gateway.
pub fn federated(
  schema : @moongql.Schema,
  resolvers : @moongql.Resolvers,
) -> Unit {
  // guide:federation
  let fed = @moongql.Federation::new(v2=true)
  fed.entity(name="Book", key="id", resolve=(rep, _ctx) => {
    let id = key_of(rep, "id")
    match shelf.iter().find_first(b => key_of(b, "id") == id) {
      Some(b) => b
      None => Json::null()
    }
  })
  // end
  fed.apply(schema, resolvers)
}
