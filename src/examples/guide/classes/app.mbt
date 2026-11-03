// The guide's examples written as types: a struct per schema type, an `impl`
// that converts it, and a method per field.

///|
/// The data all three ways of writing the same server share.
let writers : Array[Author] = []

///|
let shelf : Array[Book] = []

///|
fn reset() -> Unit {
  writers.clear()
  writers.push({ id: "1", name: "Ursula", })
  writers.push({ id: "2", name: "Ted", })
  shelf.clear()
  shelf.push({ id: "b1", title: "The Dispossessed", author_id: "1", })
  shelf.push({ id: "b2", title: "Lathe", author_id: "1", })
  shelf.push({ id: "b3", title: "Exhalation", author_id: "2", })
}

// guide:type

///|
/// A struct holds the type's data; the two impls say how it crosses the wire,
/// under the names the schema uses.
pub(all) struct Author {
  id : String
  name : String
}

///|
pub impl @moongql.ToGql for Author with fn to_gql(self) {
  { "id": self.id, "name": self.name }
}

///|
pub impl @moongql.FromGql for Author with fn from_gql(v) {
  { id: @moongql.read(v, "id"), name: @moongql.read(v, "name"), }
}

///|
pub extend Author with @moongql.ToGql::{to_gql}

///|
pub extend Author with @moongql.FromGql::{from_gql}

///|
pub(all) struct Book {
  id : String
  title : String
  author_id : String
}

///|
pub impl @moongql.ToGql for Book with fn to_gql(self) {
  { "id": self.id, "title": self.title, "authorId": self.author_id }
}

///|
pub impl @moongql.FromGql for Book with fn from_gql(v) {
  {
    id: @moongql.read(v, "id"),
    title: @moongql.read(v, "title"),
    author_id: @moongql.read(v, "authorId"),
  }
}

///|
pub extend Book with @moongql.ToGql::{to_gql}

///|
pub extend Book with @moongql.FromGql::{from_gql}
// end

// guide:field

///|
/// A method is a field: it is asked on the value it belongs to, and whatever it
/// returns is turned back into JSON.
fn Author::books(self : Author) -> Array[Book] {
  shelf.filter(b => b.author_id == self.id)
}
// end

// guide:root

///|
/// The roots are types too — the operations hang off them.
pub(all) struct Query {}

///|
fn Query::author(id : String) -> Author? {
  writers.iter().find_first(a => a.id == id)
}

///|
fn Query::books() -> Array[Book] {
  shelf.copy()
}
// end

// guide:input

///|
/// What a mutation takes: a struct whose fields are the caller's to send.
pub(all) struct NewBook {
  title : String
  author_id : String
}

///|
pub impl @moongql.FromGql for NewBook with fn from_gql(v) {
  { title: @moongql.read(v, "title"), author_id: @moongql.read(v, "authorId"), }
}

///|
pub extend NewBook with @moongql.FromGql::{from_gql}
// end

// guide:mutation

///|
pub(all) struct Mutation {}

///|
fn Mutation::add_book(input : NewBook) -> Book raise {
  if input.title == "" {
    raise @exec.ResolverError("a book needs a title")
  }
  let book : Book = {
    id: "b\{(shelf.length() + 1)}",
    title: input.title,
    author_id: input.author_id,
  }
  shelf.push(book)
  book
}
// end

// guide:subscription

///|
pub(all) struct Subscription {}

///|
fn Subscription::book_added() -> Array[Book] {
  shelf.copy()
}
// end

///|
/// The schema, built from those declarations, with one registration per field
/// the executor has to call into.
pub fn server() -> (@moongql.Schema, @moongql.Resolvers, @moongql.Subscribers) {
  reset()
  let schema = @moongql.Schema::new()
  let author = schema.object("Author", description="Someone who writes books")
  author.field("id", NonNull(Scalar("String")))
  author.field("name", NonNull(Scalar("String")))
  author.field("books", NonNull(ListOf(NonNull(Named("Book")))))
  let book = schema.object("Book")
  book.field("id", NonNull(Scalar("String")))
  book.field("title", NonNull(Scalar("String")))
  book.field("authorId", NonNull(Scalar("String")))
  let query = schema.object("Query")
  query.field_args(
    "author",
    [("id", NonNull(Scalar("String")))],
    Named("Author"),
  )
  query.field("books", NonNull(ListOf(NonNull(Named("Book")))))
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
  let subscription = schema.object("Subscription")
  subscription.field("bookAdded", NonNull(Named("Book")))
  schema.set_subscription("Subscription")

  let resolvers = @moongql.Resolvers::new()
  // guide:field.register
  resolvers.field("Author", "books", info => {
    @moongql.ToGql::to_gql(
      Author::books(@moongql.FromGql::from_gql(info.parent)),
    )
  })
  // end
  // guide:root.register
  resolvers.field("Query", "author", info => {
    @moongql.ToGql::to_gql(Query::author(info.read("id")))
  })
  resolvers.field("Query", "books", _info => {
    @moongql.ToGql::to_gql(Query::books())
  })
  // end
  // guide:mutation.register
  resolvers.field("Mutation", "addBook", info => {
    let result = Mutation::add_book(info.read("input")) catch {
      e => raise @moongql.field_error(e)
    }
    @moongql.ToGql::to_gql(result)
  })
  // end
  // guide:subscription.register
  let subscribers = @moongql.Subscribers::new()
  subscribers.field("Subscription", "bookAdded", _info => {
    Subscription::book_added().map(b => @moongql.ToGql::to_gql(b))
  })
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
    let id : String = @moongql.read(rep, "id")
    match shelf.iter().find_first(b => b.id == id) {
      Some(b) => @moongql.ToGql::to_gql(b)
      None => Json::null()
    }
  })
  // end
  fed.apply(schema, resolvers)
}
