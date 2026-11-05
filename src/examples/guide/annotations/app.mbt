// The guide's examples written as `#gql` annotations.

///|
/// The data the three ways of writing the same server share.
let writers : Array[Author] = []

///|
let shelf : Array[Book] = []

///|
/// The same two authors and three books before every run, so the three ways
/// answer the same thing.
pub fn reset() -> Unit {
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
/// A struct's fields become the type's fields. `key=` makes it a federated
/// entity; `description=` is what introspection reports.
#gql.type(description="Someone who writes books")
pub struct Author {
  id : String
  name : String
}

///|
#gql.type(key="id")
pub struct Book {
  id : String
  title : String
  author_id : String
}
// end

// guide:field

///|
/// A method is a field of its type, asked on the value it belongs to.
#gql.field(description="Their books, in the order they were added")
fn Author::books(self : Author) -> Array[Book] {
  shelf.filter(b => b.author_id == self.id)
}
// end

// guide:root

///|
/// A free function is a root field; its parameters are the field's arguments.
#gql.query
fn author(id : String) -> Author? {
  writers.iter().find_first(a => a.id == id)
}

///|
#gql.query
fn books() -> Array[Book] {
  shelf.copy()
}
// end

// guide:input

///|
/// What a mutation takes: an input object is a struct too, and every field of it
/// is data the caller sends.
#gql.input
pub struct NewBook {
  title : String
  author_id : String
}
// end

// guide:mutation

///|
/// A resolver that declares `raise` may fail; the error becomes a field error in
/// the response, with the path and the place in the document.
#gql.mutation
fn add_book(input : NewBook) -> Book raise {
  if input.title == "" {
    raise @exec.FieldError("a book needs a title")
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
/// A subscription returns the events it produces, one array; every event becomes
/// one response payload.
#gql.subscription
fn book_added() -> Array[Book] {
  shelf.copy()
}
// end

// guide:federation

///|
/// With `key=` on the type, a reference function is all a subgraph needs to turn
/// a representation back into the object.
#gql.reference
fn book_by_id(id : String) -> Book? raise {
  shelf.iter().find_first(b => b.id == id)
}
// end

///|
/// The schema and its resolvers, built from the generated `register`.
pub fn server() -> (@moongql.Schema, @moongql.Resolvers, @moongql.Subscribers) {
  reset()
  let schema = @moongql.Schema::new()
  let resolvers = @moongql.Resolvers::new()
  let subscribers = @moongql.Subscribers::new()
  register(schema, resolvers)
  register_subscriptions(schema, resolvers, subscribers)
  (schema, resolvers, subscribers)
}

///|
/// The same subgraph, joined to a gateway.
pub fn federated(
  schema : @moongql.Schema,
  resolvers : @moongql.Resolvers,
) -> Unit {
  let fed = @moongql.Federation::new(v2=true)
  register_federation(fed)
  fed.apply(schema, resolvers)
}
