///|
/// The same schema written without annotations: types built by hand, data
/// handed to the executor as JSON, and resolvers reading JSON back. The
/// annotated schema must print and answer exactly as this one does.
fn hand_register(s : @moongql.Schema, r : @moongql.Resolvers) -> Unit {
  s.scalar("Int64")
  let author = s.object("Author", description="Someone who writes books")
  author.field("id", NonNull(Scalar("Int64")))
  author.field("name", NonNull(Scalar("String")))
  s.enum_("Status", ["Draft", "Published"], description="Where a book stands")
  let book = s.object("Book")
  book.field("id", NonNull(Scalar("Int64")))
  book.field("title", NonNull(Scalar("String")))
  book.field("status", NonNull(Named("Status")))
  book.field("authorId", NonNull(Scalar("Int64")))
  book.field(
    "isbn",
    Scalar("String"),
    deprecation_reason="ISBNs are going away",
  )
  let input = s.input("NewBook")
  input.field("title", NonNull(Scalar("String")))
  input.field("authorId", NonNull(Scalar("Int64")))
  input.field("status", Named("Status"))
  let magazine = s.object("Magazine")
  magazine.field("id", NonNull(Scalar("Int64")))
  magazine.field("title", NonNull(Scalar("String")))
  magazine.field("issue", NonNull(Scalar("Int")))
  let work = s.interface("Work", description="Anything on the shelf")
  work.field("id", NonNull(Scalar("Int64")))
  work.field("title", NonNull(Scalar("String")))
  book.implements("Work")
  magazine.implements("Work")
  s.union("Hit", ["Author", "Book"])
  let query = s.object("Query")
  s.set_mutation("Mutation")
  let mutation = s.object("Mutation")
  author.field_args(
    "books",
    [("first", Scalar("Int"))],
    NonNull(ListOf(NonNull(Named("Book")))),
    description="Their books, at most `first`",
  )
  r.field("Author", "books", info => {
    let id = key_of(info.parent, "id")
    let mine = shelf.filter(b => Json::string(b.author_id.to_string()) == id)
    let mine = match info.arg("first") {
      Number(n, ..) if n.to_int() < mine.length() =>
        mine[:n.to_int()].to_owned()
      _ => mine
    }
    Json::array(mine.map(book_json))
  })
  author.field("contact", NonNull(Scalar("String")))
  r.field("Author", "contact", info => key_of(info.parent, "email"))
  book.field("author", Named("Author"))
  r.field("Book", "author", info => {
    let id = key_of(info.parent, "authorId")
    match writers.search_by(a => Json::string(a.id.to_string()) == id) {
      Some(i) => author_json(writers[i])
      None => Json::null()
    }
  })
  query.field_args(
    "author",
    [("id", NonNull(Scalar("Int64")))],
    Named("Author"),
  )
  r.field("Query", "author", info => {
    let id = info.arg("id")
    match writers.search_by(a => Json::string(a.id.to_string()) == id) {
      Some(i) => author_json(writers[i])
      None => Json::null()
    }
  })
  query.field_args(
    "books",
    [("status", Named("Status"))],
    NonNull(ListOf(NonNull(Named("Book")))),
    description="Every book, or those in one state",
  )
  r.field("Query", "books", info => {
    let picked = match info.arg("status") {
      String(s) => shelf.filter(b => status_name(b.status) == s)
      _ => shelf
    }
    Json::array(picked.map(book_json))
  })
  query.field("works", NonNull(ListOf(NonNull(Named("Work")))))
  r.field("Query", "works", _ => {
    Json::array(shelf.map(book_json) + issues.map(magazine_json))
  })
  query.field_args(
    "search",
    [("text", NonNull(Scalar("String")))],
    NonNull(ListOf(NonNull(Named("Hit")))),
    description="Authors and titles that contain `text`",
  )
  r.field("Query", "search", info => {
    let text = match info.arg("text") {
      String(t) => t
      _ => ""
    }
    Json::array(
      writers.filter(a => a.name.contains(text)).map(author_json) +
      shelf.filter(b => b.title.contains(text)).map(book_json),
    )
  })
  mutation.field_args(
    "addBook",
    [("input", NonNull(Named("NewBook")))],
    NonNull(Named("Book")),
  )
  r.field("Mutation", "addBook", info => {
    let input = info.arg("input")
    let title = match key_of(input, "title") {
      String(t) => t
      _ => ""
    }
    if title == "" {
      raise @exec.ResolverError("a book needs a title")
    }
    let author_id = match key_of(input, "authorId") {
      String(t) => @string.parse_int64(t) catch { _ => 0L }
      _ => 0L
    }
    let status = match key_of(input, "status") {
      String("Published") => Published
      _ => Draft
    }
    let created : Book = {
      id: (shelf.length() + 1).to_int64(),
      title,
      status,
      author_id,
      code: None,
    }
    shelf.push(created)
    book_json(created)
  })
}

///|
fn key_of(v : Json, key : String) -> Json {
  match v {
    Object(m) => m.get(key).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
fn status_name(s : Status) -> String {
  match s {
    Draft => "Draft"
    Published => "Published"
  }
}

///|
fn author_json(a : Author) -> Json {
  {
    "__typename": "Author",
    "id": Json::string(a.id.to_string()),
    "name": Json::string(a.name),
    "email": Json::string(a.email),
  }
}

///|
fn book_json(b : Book) -> Json {
  {
    "__typename": "Book",
    "id": Json::string(b.id.to_string()),
    "title": Json::string(b.title),
    "status": Json::string(status_name(b.status)),
    "authorId": Json::string(b.author_id.to_string()),
    "isbn": match b.code {
      Some(c) => Json::string(c)
      None => Json::null()
    },
  }
}

///|
fn magazine_json(m : Magazine) -> Json {
  {
    "__typename": "Magazine",
    "id": Json::string(m.id.to_string()),
    "title": Json::string(m.title),
    "issue": Json::number(m.issue.to_double()),
  }
}
