///|
/// A package whose schema is `sdl`, and the rest of its source.
fn with_sdl(sdl : String, rest~ : String = "") -> String {
  let lines = sdl.split("\n").map(line => "  #|" + line.to_owned()).to_array()
  "#gql.sdl\nlet schema_text : String =\n\{lines.join("\n")}\n\n\{rest}"
}

///|
test "scalars and enums are struct fields, the rest are resolvers" {
  let code = generate(
    with_sdl(
      (
        #|enum Status { DRAFT LIVE }
        #|type Author { id: ID! books(first: Int): [Book!]! }
        #|type Book { id: ID! title: String status: Status! rating: Float! author: Author! }
        #|type Query { book(id: ID!): Book }
      ),
    ),
  )
  assert_true(
    code.contains(
      flat(
        "pub(all) struct Book { id : String\ntitle : String?\nstatus : Status\nrating : Double\n}",
      ),
    ),
  )
  assert_true(code.contains(flat("pub(all) struct Author { id : String\n}")))
  assert_true(
    code.contains(flat("declare fn Book::author(self : Book) -> Author raise")),
  )
  assert_true(
    code.contains(
      flat(
        "declare fn Author::books(self : Author, first? : Int32) -> Array[Book] raise",
      ),
    ),
  )
}

///|
test "a root field takes no value, and its type stands for the operation" {
  let code = generate(
    with_sdl(
      (
        #|type Query { book(id: ID!, tag: String): String! }
        #|type Mutation { publish(id: ID!): Boolean! }
      ),
    ),
  )
  assert_true(code.contains(flat("pub(all) struct Query {  }")))
  assert_true(code.contains(flat("pub(all) struct Mutation {  }")))
  assert_true(
    code.contains(
      flat("declare fn Query::book(id : String, tag? : String) -> String raise"),
    ),
  )
  assert_true(
    code.contains(
      flat("declare fn Mutation::publish(id : String) -> Bool raise"),
    ),
  )
  assert_true(
    code.contains(
      flat("Query::book(info.read(\"id\"), tag?=info.read(\"tag\"))"),
    ),
  )
}

///|
test "the schema text reaches the schema, and a failing resolver becomes a field error" {
  let code = generate(with_sdl("type Query { a: Int! }"))
  assert_true(code.contains(flat("schema.add_sdl(schema_text)")))
  assert_true(code.contains(flat("e => raise @moongql.field_error(e)")))
}

///|
test "an input is a struct of every field, under the names in the schema" {
  let code = generate(
    with_sdl(
      (
        #|input NewBook { title: String! authorId: ID! tags: [String!] }
        #|type Query { add(input: NewBook!): Int! }
      ),
    ),
  )
  assert_true(
    code.contains(
      flat(
        "pub(all) struct NewBook { title : String\nauthor_id : String\ntags : Array[String]?\n}",
      ),
    ),
  )
  assert_true(
    code.contains(flat("\"authorId\": @moongql.ToGql::to_gql(self.author_id)")),
  )
  assert_true(code.contains(flat("author_id: @moongql.read(v, \"authorId\")")))
  assert_true(!code.contains(flat("\"__typename\": \"NewBook\"")))
}

///|
test "a union and an interface are enums over their members" {
  let code = generate(
    with_sdl(
      (
        #|interface Work { id: ID! }
        #|type Book implements Work { id: ID! }
        #|type Film implements Work { id: ID! }
        #|type Song { id: ID! }
        #|union Hit = Book | Song
        #|type Query { a: Work b: Hit }
      ),
    ),
  )
  assert_true(
    code.contains(flat("pub(all) enum Work { Book(Book)\nFilm(Film)\n}")),
  )
  assert_true(
    code.contains(flat("pub(all) enum Hit { Book(Book)\nSong(Song)\n}")),
  )
  assert_true(code.contains(flat("\"__typename\": \"Song\"")))
  assert_true(
    code.contains(
      flat(
        "{ \"__typename\": String(\"Film\"), .. } => Film(@moongql.FromGql::from_gql(v))",
      ),
    ),
  )
}

///|
test "enum values keep their names on the wire" {
  let code = generate(
    with_sdl("enum Mode { fast SLOW }\ntype Query { m: Mode! }"),
  )
  assert_true(code.contains(flat("pub(all) enum Mode { Fast\nSLOW\n}")))
  assert_true(code.contains(flat("Fast => \"fast\"")))
  assert_true(code.contains(flat("String(\"fast\") => Fast")))
  assert_true(code.contains(flat("String(\"SLOW\") => SLOW")))
}

///|
test "a custom scalar is Json, and Int64 is Int64" {
  let code = generate(
    with_sdl(
      (
        #|scalar Stamp
        #|scalar Int64
        #|type Query { at: Stamp! n: Int64! }
      ),
    ),
  )
  assert_true(code.contains(flat("declare fn Query::at() -> Json raise")))
  assert_true(code.contains(flat("declare fn Query::n() -> Json raise")))
}

///|
test "a field named after a keyword gets a usable name" {
  let code = generate(
    with_sdl(
      "type Thing { type: String! method: Int! }\ntype Query { t: Thing! }",
    ),
  )
  assert_true(code.contains(flat("type_ : String\nmethod_ : Int32")))
  assert_true(
    code.contains(flat("\"type\": @moongql.ToGql::to_gql(self.type_)")),
  )
}

///|
test "a struct in the package takes the place of the generated one" {
  let code = generate(
    with_sdl(
      "type Book { id: ID! title: String! author: String! }\ntype Query { b: Book }",
      rest=(
        #|pub struct Book {
        #|  id : String
        #|  title : String
        #|  author_id : String
        #|}
      ),
    ),
  )
  assert_true(!code.contains(flat("pub(all) struct Book")))
  assert_true(
    code.contains(flat("\"authorId\": @moongql.ToGql::to_gql(self.author_id)")),
  )
  assert_true(
    code.contains(flat("declare fn Book::author(self : Book) -> String raise")),
  )
  assert_true(!code.contains(flat("declare fn Book::title")))
}

///|
test "a struct answers a field with arguments only through a resolver" {
  let code = generate(
    with_sdl(
      "type Book { title(upper: Boolean): String! }\ntype Query { b: Book }",
      rest="pub struct Book {\n  title : String\n}",
    ),
  )
  assert_true(
    code.contains(
      flat("declare fn Book::title(self : Book, upper? : Bool) -> String raise"),
    ),
  )
}

///|
test "a package may mix the schema with code-first fields" {
  let code = generate(
    with_sdl(
      "type Query { a: Int! }",
      rest=(
        #|#gql.query
        #|pub fn ping() -> String {
        #|  "pong"
        #|}
      ),
    ),
  )
  let sdl = code.find(flat("schema.add_sdl(schema_text)")).unwrap()
  let query = code.find("letgql_query").unwrap()
  assert_true(sdl < query)
  assert_true(code.contains(flat("gql_query.field(\"ping\"")))
}

///|
test "an annotated struct with a name in the schema is refused" {
  let why = refused(
    with_sdl(
      "type Book { id: ID! }\ntype Query { b: Book }",
      rest="#gql.type\npub struct Book {\n  id : String\n}",
    ),
  )
  assert_true(why.contains("`Book` is in the schema and also annotated"))
}

///|
test "a subscription in SDL says what to do instead" {
  let why = refused(
    with_sdl("type Query { a: Int! }\ntype Subscription { b: Int! }"),
  )
  assert_true(why.contains("mark the function `#gql.subscription`"))
}

///|
test "a schema that does not parse is refused where it is declared" {
  let why = refused(with_sdl("type Query {"))
  assert_true(why.contains("schema.mbt:1:"))
}

///|
test "`#gql.sdl` reads a `#|` string only" {
  let why = refused("#gql.sdl\nlet s : String = make()\n")
  assert_true(why.contains("reads a `#|` string"))
  let why = refused("#gql.sdl\nlet s : String = \"type Query\"\n")
  assert_true(why.contains("reads a `#|` string"))
  let why = refused("#gql.sdl\nlet s : String =\n  $|type \\{name}\n")
  assert_true(why.contains("reads a `#|` string"))
}

///|
test "`file` goes on a declare fn, and a declare fn needs it" {
  let why = refused("#gql.sdl(file=\"a.graphql\")\nlet s : String = \"\"\n")
  assert_true(why.contains("`file` goes on a `declare fn`"))
  let why = refused("#gql.sdl\ndeclare fn s() -> String\n")
  assert_true(why.contains("names its `file`"))
  let why = refused(
    "#gql.sdl(file=\"a.graphql\")\nfn s() -> String {\n  \"\"\n}\n",
  )
  assert_true(why.contains("goes on a `declare fn`"))
  let why = refused(
    "#gql.sdl(file=\"no-such-file.graphql\")\ndeclare fn s() -> String\n",
  )
  assert_true(why.contains("cannot read `no-such-file.graphql`"))
}

///|
test "a schema file is found beside the source" {
  inspect(beside("a/b/shop.mbt", "x.graphql"), content="a/b/x.graphql")
  inspect(beside("a\\b\\shop.mbt", "x.graphql"), content="a\\b\\x.graphql")
  inspect(beside("shop.mbt", "x.graphql"), content="x.graphql")
}

///|
test "a schema file reads the same under either line ending" {
  inspect(line_feeds("type A\r\n{\r\n}\n"), content="type A\n{\n}\n")
}

///|
test "camelCase names become snake_case" {
  inspect(snake("addBook"), content="add_book")
  inspect(snake("id"), content="id")
  inspect(snake("type"), content="type_")
}
