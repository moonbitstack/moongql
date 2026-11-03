///|
/// The schema, first. Everything in `shop.g.mbt` follows from this text.
#gql.sdl
let shop_sdl : String =
  #|enum Status {
  #|  DRAFT
  #|  PUBLISHED
  #|}
  #|
  #|type Author {
  #|  id: ID!
  #|  name: String!
  #|  books(first: Int): [Book!]!
  #|}
  #|
  #|type Book {
  #|  id: ID!
  #|  title: String!
  #|  status: Status!
  #|  author: Author!
  #|}
  #|
  #|input NewBook {
  #|  title: String!
  #|  authorId: ID!
  #|}
  #|
  #|union Hit = Author | Book
  #|
  #|type Query {
  #|  book(id: ID!): Book
  #|  search(text: String!): [Hit!]!
  #|}
  #|
  #|type Subscription {
  #|  bookAdded(authorId: ID): Book!
  #|}

///|
/// A schema can also live in its own file; this one is read when the code is generated.
#gql.sdl(file="mutations.graphql")
declare fn mutations_sdl() -> String

///|
/// The package's own `Book`: the schema has no `authorId`, and `Book::author` needs one. Declaring
/// the struct is what keeps it; `shop.g.mbt` binds to this one instead of generating its own.
pub(all) struct Book {
  id : String
  title : String
  status : Status
  author_id : String
}
