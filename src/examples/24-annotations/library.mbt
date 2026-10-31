///|
/// A struct's fields become the type's fields, named in camelCase. A skipped
/// field stays out of the schema but rides along, so a field method sees it.
#gql.type(description="Someone who writes books")
pub struct Author {
  id : Int64
  name : String
  #gql.skip
  email : String
}

///|
/// Constructors without payload are the enum's values.
#gql.enum(description="Where a book stands")
pub enum Status {
  Draft
  Published
} derive(Eq)

///|
#gql.type
pub struct Book {
  id : Int64
  title : String
  status : Status
  author_id : Int64
  #gql.field(name="isbn", deprecation_reason="ISBNs are going away")
  code : String?
}

///|
/// An input type: what a mutation takes.
#gql.input
pub struct NewBook {
  title : String
  author_id : Int64
  status : Status?
}

///|
#gql.type
pub struct Magazine {
  id : Int64
  title : String
  issue : Int32
}

///|
/// An enum whose constructors each wrap one `#gql.type` struct is an interface
/// those structs implement, with the fields `field=` names; each member must
/// have them, written the same way.
#gql.interface(field="id", field="title", description="Anything on the shelf")
pub enum Work {
  Printed(Book)
  Periodical(Magazine)
}

///|
/// Without fields of its own, the same enum is a union.
#gql.union
pub enum Hit {
  Writer(Author)
  Title(Book)
}

///|
/// A method marked `#gql.field` is a field of its type, resolved from the value
/// it is asked on; its parameters are the field's arguments.
#gql.field(description="Their books, at most `first`")
fn Author::books(self : Author, first? : Int32) -> Array[Book] {
  let mine = shelf.filter(b => b.author_id == self.id)
  match first {
    Some(n) if n < mine.length() => mine[:n].to_owned()
    _ => mine
  }
}

///|
#gql.field
fn Author::contact(self : Author) -> String {
  self.email
}

///|
#gql.field
fn Book::author(self : Book) -> Author? {
  writers.search_by(a => a.id == self.author_id).map(i => writers[i])
}

///|
/// Free functions marked `#gql.query` and `#gql.mutation` are root fields.
#gql.query
fn author(id : Int64) -> Author? {
  writers.search_by(a => a.id == id).map(i => writers[i])
}

///|
#gql.query(description="Every book, or those in one state")
fn books(status? : Status) -> Array[Book] {
  match status {
    Some(s) => shelf.filter(b => b.status == s)
    None => shelf
  }
}

///|
#gql.query
fn works() -> Array[Work] {
  shelf.map(b => Printed(b)) + issues.map(m => Periodical(m))
}

///|
#gql.query(description="Authors and titles that contain `text`")
fn search(text : String) -> Array[Hit] {
  writers.filter(a => a.name.contains(text)).map(a => Writer(a)) +
  shelf.filter(b => b.title.contains(text)).map(b => Title(b))
}

///|
/// A resolver that raises: any error becomes a field error, and a
/// `ResolverError` keeps its message as written.
#gql.mutation
fn add_book(input : NewBook) -> Book raise {
  if input.title == "" {
    raise @exec.ResolverError("a book needs a title")
  }
  let book : Book = {
    id: (shelf.length() + 1).to_int64(),
    title: input.title,
    status: input.status.unwrap_or(Draft),
    author_id: input.author_id,
    code: None,
  }
  shelf.push(book)
  book
}

///|
let writers : Array[Author] = []

///|
let shelf : Array[Book] = []

///|
let issues : Array[Magazine] = [{ id: 10, title: "Locus", issue: 754, }]

///|
/// The same two authors and three books before every run.
fn reset() -> Unit {
  writers.clear()
  writers.push({ id: 1, name: "Ursula", email: "ursula@example.com", })
  writers.push({ id: 2, name: "Ted", email: "ted@example.com", })
  shelf.clear()
  shelf.push({
    id: 1,
    title: "The Dispossessed",
    status: Published,
    author_id: 1,
    code: Some("978-0060512750"),
  })
  shelf.push({
    id: 2,
    title: "Lathe",
    status: Published,
    author_id: 1,
    code: None,
  })
  shelf.push({
    id: 3,
    title: "Exhalation",
    status: Draft,
    author_id: 2,
    code: None,
  })
}
