///|
/// A schema whose type system is SDL text, read at run time; every resolver is
/// registered under "Type.field", the name the document gives the field.
fn schema_of_sdl(text : String) -> @schema.Schema {
  @schema.Schema::of_sdl(text) catch {
    e => abort(e.to_string())
  }
}

///|
test "a schema read from SDL answers through resolvers registered by name" {
  let schema = schema_of_sdl(
    (
      #|type Query {
      #|  "One book, by id."
      #|  book(id: ID!): Book
      #|}
      #|
      #|type Book {
      #|  id: ID!
      #|  title: String!
      #|}
    ),
  )
  let resolvers = Resolvers::new()
  resolvers.field("Query", "book", info => {
    let id = info.arg("id")
    { "id": id, "title": Json("Lathe") }
  })
  assert_eq(
    execute(schema, resolvers, "{ book(id: \"b2\") { id title } }").stringify(),
    "{\"data\":{\"book\":{\"id\":\"b2\",\"title\":\"Lathe\"}}}",
  )
}

///|
test "a second document extends a schema already in use" {
  let schema = schema_of_sdl("type Query { hello: String! }")
  let resolvers = Resolvers::new()
  resolvers.field("Query", "hello", _info => Json("hi"))
  assert_eq(
    execute(schema, resolvers, "{ hello }").stringify(),
    "{\"data\":{\"hello\":\"hi\"}}",
  )
  schema.add_sdl(
    (
      #|extend type Query {
      #|  count: Int!
      #|}
      #|
      #|type Mutation {
      #|  touch: Int!
      #|}
    ),
  ) catch {
    e => abort(e.to_string())
  }
  resolvers.field("Query", "count", _info => Json(2))
  resolvers.field("Mutation", "touch", _info => Json(3))
  assert_eq(
    execute(schema, resolvers, "{ hello count }").stringify(),
    "{\"data\":{\"hello\":\"hi\",\"count\":2}}",
  )
  // The mutation root came from the second document and is wired by its name.
  assert_eq(
    execute(schema, resolvers, "mutation { touch }").stringify(),
    "{\"data\":{\"touch\":3}}",
  )
}

///|
test "an interface and a union written in SDL resolve by the value's __typename" {
  let schema = schema_of_sdl(
    (
      #|type Query {
      #|  search(text: String!): [Hit!]!
      #|}
      #|
      #|interface Node {
      #|  id: ID!
      #|}
      #|
      #|type Book implements Node {
      #|  id: ID!
      #|  title: String!
      #|}
      #|
      #|type Author implements Node {
      #|  id: ID!
      #|  name: String!
      #|}
      #|
      #|union Hit = Book | Author
    ),
  )
  let resolvers = Resolvers::new()
  resolvers.field("Query", "search", _info => {
    [
      { "__typename": Json("Book"), "id": Json("b1"), "title": Json("Lathe") },
      { "__typename": Json("Author"), "id": Json("a1"), "name": Json("Ursula") },
    ]
  })
  assert_eq(
    execute(
      schema, resolvers, "{ search(text: \"a\") { __typename ... on Book { title } ... on Author { name } } }",
    ).stringify(),
    "{\"data\":{\"search\":[{\"__typename\":\"Book\",\"title\":\"Lathe\"},{\"__typename\":\"Author\",\"name\":\"Ursula\"}]}}",
  )
  // `Node` is an interface in the same document, and says who implements it.
  assert_eq(
    execute(
      schema, resolvers, "{ __type(name: \"Node\") { kind possibleTypes { name } } }",
    ).stringify(),
    "{\"data\":{\"__type\":{\"kind\":\"INTERFACE\",\"possibleTypes\":[{\"name\":\"Book\"},{\"name\":\"Author\"}]}}}",
  )
}

///|
test "a subscription written in SDL streams through subscribers registered by name" {
  let schema = schema_of_sdl(
    (
      #|type Query {
      #|  ping: String
      #|}
      #|
      #|type Subscription {
      #|  tick: Int!
      #|}
    ),
  )
  let resolvers = Resolvers::new()
  resolvers.field("Query", "ping", _info => Json("pong"))
  let subscribers = Subscribers::new()
  subscribers.field("Subscription", "tick", _info => [Json(1), Json(2)])
  let events = execute_subscription(
    schema, resolvers, subscribers, "subscription { tick }",
  )
  assert_eq(
    events.map(e => e.stringify()).join(" "),
    "{\"data\":{\"tick\":1}} {\"data\":{\"tick\":2}}",
  )
}

///|
test "descriptions and deprecations written in SDL are what introspection reports" {
  let schema = schema_of_sdl(
    (
      #|type Query {
      #|  "One book, by id."
      #|  book(id: ID!): Book
      #|}
      #|
      #|"""A book on the shelf."""
      #|type Book {
      #|  id: ID!
      #|  "The blurb, once there is one."
      #|  blurb: String @deprecated(reason: "books are sold without one")
      #|}
    ),
  )
  let resolvers = Resolvers::new()
  resolvers.field("Query", "book", _info => { "id": Json("b1") })
  // Nothing is registered for `blurb`; a deprecated nullable field is still a
  // field, and answers null.
  assert_eq(
    execute(schema, resolvers, "{ book(id: \"b1\") { blurb } }").stringify(),
    "{\"data\":{\"book\":{\"blurb\":null}}}",
  )
  assert_eq(
    execute(
      schema, resolvers, "{ __type(name: \"Book\") { description fields(includeDeprecated: true) { name isDeprecated } } }",
    ).stringify(),
    "{\"data\":{\"__type\":{\"description\":\"A book on the shelf.\",\"fields\":[{\"name\":\"id\",\"isDeprecated\":false},{\"name\":\"blurb\",\"isDeprecated\":true}]}}}",
  )
}
