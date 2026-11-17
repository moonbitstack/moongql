// The guide's examples written as SDL: the type system first, its resolvers
// registered by name afterwards.

///|
/// The data all four ways of writing the same server share.
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
  // guide:type
  let schema = @moongql.Schema::of_sdl(
    (
      #|"Someone who writes books."
      #|type Author {
      #|  id: ID!
      #|  name: String!
      #|  "Their books, in the order they were added"
      #|  books: [Book!]!
      #|}
      #|
      #|type Book {
      #|  id: ID!
      #|  title: String!
      #|  authorId: String!
      #|}
    ),
  ) catch {
    e => abort(e.to_string())
  }
  // end
  let resolvers = @moongql.Resolvers::new()
  // guide:field.register
  resolvers.field("Author", "books", info => {
    let id = key_of(info.parent, "id")
    Json(shelf.filter(b => key_of(b, "authorId") == id))
  })
  // end
  // guide:root
  schema.add_sdl(
    (
      #|type Query {
      #|  author(id: ID!): Author
      #|  books: [Book!]!
      #|}
    ),
  ) catch {
    e => abort(e.to_string())
  }
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
  // guide:input
  schema.add_sdl(
    (
      #|input NewBook {
      #|  title: String!
      #|  authorId: String!
      #|}
      #|
      #|type Mutation {
      #|  addBook(input: NewBook!): Book!
      #|}
    ),
  ) catch {
    e => abort(e.to_string())
  }
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
  // guide:subscription
  schema.add_sdl(
    (
      #|type Subscription {
      #|  bookAdded: Book!
      #|}
    ),
  ) catch {
    e => abort(e.to_string())
  }
  // end
  let subscribers = @moongql.Subscribers::new()
  // guide:subscription.register
  subscribers.field("Subscription", "bookAdded", _info => shelf.copy())
  // end
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
