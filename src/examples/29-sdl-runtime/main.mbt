///|
/// A schema that lives as SDL text from the start. `Schema::of_sdl` reads the type
/// system at run time, `add_sdl` extends the schema already in use — `extend type
/// Query` adds a root field — and every resolver is a closure registered under
/// "Type.field". Nothing here is generated, so the schema can come from a string.
///
///     moon run src/examples/29-sdl-runtime
#coverage.skip
fn main {
  let authors : Array[Json] = [
    { "__typename": Json("Author"), "id": Json("a1"), "name": Json("Ursula") },
    { "__typename": Json("Author"), "id": Json("a2"), "name": Json("Ted") },
  ]
  let books : Array[Json] = [
    {
      "__typename": Json("Book"),
      "id": Json("b1"),
      "title": Json("The Dispossessed"),
      "genre": Json("FICTION"),
      "authorId": Json("a1"),
    },
    {
      "__typename": Json("Book"),
      "id": Json("b2"),
      "title": Json("Lathe"),
      "genre": Json("FICTION"),
      "authorId": Json("a1"),
    },
    {
      "__typename": Json("Book"),
      "id": Json("b3"),
      "title": Json("Exhalation"),
      "genre": Json("SCIENCE"),
      "authorId": Json("a2"),
    },
  ]
  // The type system, in the document the program starts from.
  let catalog : String =
    #|"""A book on the shelf."""
    #|type Book implements Node {
    #|  id: ID!
    #|  title: String!
    #|  genre: Genre!
    #|  author: Author!
    #|  "The blurb, once there is one."
    #|  blurb: String @deprecated(reason: "books are sold without one")
    #|}
    #|
    #|type Author implements Node {
    #|  id: ID!
    #|  name: String!
    #|}
    #|
    #|interface Node {
    #|  id: ID!
    #|}
    #|
    #|enum Genre {
    #|  FICTION
    #|  HISTORY
    #|  SCIENCE
    #|}
    #|
    #|union Hit = Book | Author
    #|
    #|type Query {
    #|  "One book, by id."
    #|  book(id: ID!): Book
    #|  "The books, narrowed to one genre."
    #|  books(genre: Genre): [Book!]!
    #|  "Books and authors together."
    #|  search(text: String!): [Hit!]!
    #|}
  let schema = @moongql.Schema::of_sdl(catalog) catch {
    e => abort(e.to_string())
  }
  let resolvers = @moongql.Resolvers::new()
  resolvers.field("Query", "book", info => {
    let id = info.arg("id")
    match books.iter().find_first(b => key_of(b, "id") == id) {
      Some(b) => b
      None => Json::null()
    }
  })
  resolvers.field("Query", "books", info => {
    let genre = info.arg("genre")
    Json(books.filter(b => genre is Null || key_of(b, "genre") == genre))
  })
  resolvers.field("Query", "search", info => {
    let text = match info.arg("text") {
      String(t) => t
      _ => ""
    }
    let hits : Array[Json] = []
    for b in books {
      if text_of(b, "title").contains(text) {
        hits.push(b)
      }
    }
    for a in authors {
      if text_of(a, "name").contains(text) {
        hits.push(a)
      }
    }
    Json(hits)
  })
  // A field of an object type is a resolver too, and it reads the parent the
  // executor hands it — here the author id the schema does not expose.
  resolvers.field("Book", "author", info => {
    let id = key_of(info.parent, "authorId")
    match authors.iter().find_first(a => key_of(a, "id") == id) {
      Some(a) => a
      None => raise @exec.FieldError("no author with id \{id.stringify()}")
    }
  })
  println(
    @moongql.execute(
      schema, resolvers, "{ book(id: \"b1\") { id title genre author { name } } }",
    ).stringify(),
  )
  println(
    @moongql.execute(schema, resolvers, "{ books(genre: SCIENCE) { title } }").stringify(),
  )
  // The union is selected through inline fragments: each value says which member
  // it is with `__typename`.
  println(
    @moongql.execute(
      schema, resolvers, "{ search(text: \"e\") { __typename ... on Book { title } ... on Author { name } } }",
    ).stringify(),
  )
  // A deprecated field still answers; nothing registered for it, so it is null.
  println(
    @moongql.execute(schema, resolvers, "{ book(id: \"b1\") { blurb } }").stringify(),
  )
  // A second document joins the schema already in use: a new input type, a root
  // field added to `Query` by `extend`, and the `Mutation` root the schema did not
  // have. `add_sdl` wires the mutation root by its default name.
  schema.add_sdl(
    (
      #|input NewBook {
      #|  title: String!
      #|  genre: Genre!
      #|  authorId: ID!
      #|}
      #|
      #|extend type Query {
      #|  "How many books are on the shelf."
      #|  bookCount: Int!
      #|}
      #|
      #|type Mutation {
      #|  addBook(input: NewBook!): Book!
      #|}
    ),
  ) catch {
    e => abort(e.to_string())
  }
  resolvers.field("Query", "bookCount", _info => Json(books.length()))
  resolvers.field("Mutation", "addBook", info => {
    let input = info.arg("input")
    let author_id = key_of(input, "authorId")
    for a in authors {
      if key_of(a, "id") == author_id {
        let book : Json = {
          "__typename": Json("Book"),
          "id": Json("b\{books.length() + 1}"),
          "title": key_of(input, "title"),
          "genre": key_of(input, "genre"),
          "authorId": author_id,
        }
        books.push(book)
        return book
      }
    }
    raise @exec.FieldError("no author with id \{author_id.stringify()}")
  })
  println(
    @moongql.execute(
      schema, resolvers, "mutation { addBook(input: { title: \"Summa\", genre: HISTORY, authorId: \"a2\" }) { id title genre } }",
    ).stringify(),
  )
  println(@moongql.execute(schema, resolvers, "{ bookCount }").stringify())
  // One print of the merged schema: both documents are in it.
  println(
    "the merged SDL carries the extension: \{schema.to_sdl().contains("bookCount: Int!")}",
  )
  // A document that stops mid-way is refused where it stopped, not dropped.
  let bad = refusal("type Query {\n  book(id: ID!):\n")
  println("a broken document -> \{bad}")
}

///|
/// What the reader says about a document that stops mid-way.
fn refusal(text : String) -> String {
  let parsed = Ok(@moongql.Schema::of_sdl(text)) catch {
    e => Err(e.to_string())
  }
  match parsed {
    Ok(_) => "accepted"
    Err(message) => message
  }
}

///|
/// The field a JSON object carries, or `null`.
fn key_of(value : Json, field : String) -> Json {
  match value {
    Object(m) => m.get(field).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
/// The string a JSON object carries under `field`, or the empty string.
fn text_of(value : Json, field : String) -> String {
  match key_of(value, field) {
    String(s) => s
    _ => ""
  }
}
