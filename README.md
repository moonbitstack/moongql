<div align="center">

# moongql

**A code-first GraphQL library for MoonBit.**

[Homepage](https://moonbitstack.github.io/moongql/) · [Guide](https://moonbitstack.github.io/moongql/guide.html) · [API reference](https://moonbitstack.github.io/moongql/api.html) · [mooncakes](https://mooncakes.io/docs/moonbitstack/moongql)

</div>

`moongql` is a code-first GraphQL library for MoonBit — define a schema in code, then execute queries, validate them against the spec, and serve them over HTTP with a built-in browser IDE and a documentation page rendered from the schema. It prints **and parses** GraphQL SDL (print-then-parse yields the same schema), delivers deferred and streamed work in pieces, runs subscriptions and Apollo Federation subgraphs, batches with a `DataLoader`, turns your own types into a schema with `#gql` annotations, and offers that same schema to an agent as Model Context Protocol tools. It is pure MoonBit and runs on every backend (`wasm`, `wasm-gc`, `js`, `native`).

## Quickstart

Annotate your own types, and the schema and its resolvers are written for you:

<!-- nocheck -->
```moonbit
#gql.type
pub struct User {
  id : String
  name : String
  tags : Array[String]
}

#gql.query
pub fn hello() -> String {
  "hello"
}

#gql.query
pub fn user(id : String) -> User? {
  lookup(id)
}

let schema = @moongql.Schema::new()
let resolvers = @moongql.Resolvers::new()
register(schema, resolvers)
let sdl = schema.to_sdl()
```

produces:

```graphql
schema {
  query: Query
}

type Query {
  hello: String!
  user(id: String!): User
}

type User {
  id: String!
  name: String!
  tags: [String!]!
}
```

The whole schema above is written for you; the sections below show the same thing written the other two ways.

## Annotations

`#gql` annotations write the schema and the resolvers from your own types. The
generator emits `register(schema, resolvers)`:

<!-- nocheck -->
```moonbit
#gql.type(description="Someone who writes books")
pub struct Author {
  id : Int64
  name : String
  #gql.skip
  email : String
}

#gql.enum
pub enum Status { Draft; Published }

#gql.input
pub struct NewBook { title : String; author_id : Int64; status : Status? }

#gql.field(description="Their books, at most `first`")
fn Author::books(self : Author, first? : Int) -> Array[Book] { ... }

#gql.query
fn author(id : Int64) -> Author? { ... }

#gql.mutation
fn add_book(input : NewBook) -> Book raise { ... }
```

<!-- nocheck -->
```moonbit
test {
  let s = @moongql.Schema::new()
  let r = @moongql.Resolvers::new()
  register(s, r)
  let app = @moongql.graphql_app(s, r)
}
```

A struct's fields become the type's fields, named in camelCase; `#gql.field`
renames, describes, deprecates or gives a `kind`, and `#gql.skip` keeps a field
out of the schema. A method marked `#gql.field` is a field resolved from the value
it is asked on, and free functions marked `#gql.query` and `#gql.mutation` are
root fields. A parameter is a field argument; one of type `ResolveInfo` receives
the request instead. A resolver that raises gives a field error, and a
`ResolverError` keeps its message.

An enum whose constructors each wrap one `#gql.type` struct is a union of those
types under `#gql.union`, or an interface they implement under
`#gql.interface`, which names the fields it carries; every member has each of
them, with the same type and arguments. A value converts by its constructor,
and back by the `__typename` its object carries.

<!-- nocheck -->
```moonbit
#gql.interface(field="id", field="title")
pub enum Work { Printed(Book); Periodical(Magazine) }

#gql.union
pub enum Hit { Writer(Author); Title(Book) }

#gql.query
fn search(text : String) -> Array[Hit] { ... }
```

| MoonBit | GraphQL |
|:--:|:--:|
| `String` | `String!` |
| `Int` | `Int!` |
| `Double` | `Float!` |
| `Bool` | `Boolean!` |
| `Int64` | `Int64!`, a scalar written as a string |
| `T?` | `T` |
| `Array[T]` | `[T]!` |
| an annotated type | its name |

Values cross as `ToGql` and `FromGql`, which the generator writes for each
annotated type; a type of the program's own takes `#gql.field(kind="...")` and
implements both. [`24-annotations`](src/examples/24-annotations/) checks the
generated schema against the same schema written by hand.

Wire the generator into the build once. In `moon.mod`:

```
rule(name: "gql", command: "moonx moonbitstack/moongql/cmd/gql@0.10.11 -C \"$mod_dir\" \"$input\" -o \"$output\"")
```

and in the `moon.pkg` of the package holding the declarations:

```
dev_build(rule: "gql", input: "schema.mbt", output: "schema.g.mbt")
formatter(ignore: [ "schema.g.mbt" ])
```

### Subscriptions, permissions and federation

<!-- nocheck -->
```moonbit
#gql.type(key="id")
pub struct User {
  id : String
  #gql.field(shareable=true)
  name : String
}

#gql.reference
pub fn user_by_id(id : String) -> User? { lookup(id) }

pub fn signed_in(info : @moongql.ResolveInfo) -> Bool { info.ctx is String(_) }

#gql.query(permission="signed_in")
pub fn secret() -> String { "the answer" }

#gql.subscription
pub fn countdown(from : Int32) -> Array[Int32] { Array::makei(from, i => from - i) }
```

`#gql.subscription` returns its events as an `Array[T]`, and the generator adds
`register_subscriptions(schema, resolvers, subscribers)`. `permission` names a
function of `ResolveInfo`, repeated for several, and a resolver whose checks fail
answers `not permitted` as a field error.

`key` makes a type a federation entity, and `#gql.reference` is how a representation
becomes one: its parameters are the key's fields, and without one an entity is its
representation. `extended=true` is `extend type`. The field directives are written on
`#gql.field` as `shareable`, `inaccessible`, `external`, `override_from`, `requires` and
`provides`. The generator adds `register_federation(federation)`.

[`26-annotated-subgraph`](src/examples/26-annotated-subgraph/) runs all of it.

### Schema first

The schema can come first instead. Put it in a `#|` string marked `#gql.sdl`, or in a file named by `#gql.sdl(file="schema.graphql")` on a `declare fn name() -> String`:

<!-- nocheck -->
```moonbit
#gql.sdl
let shop : String =
  #|type Book { id: ID! title: String! author: Author! }
  #|type Author { id: ID! name: String! }
  #|type Query { book(id: ID!): Book }
```

The generator writes a struct for each object and input type, an enum for each enum, union and interface, and a `declare fn` for every resolver. A scalar or enum field is a struct field. A root field, a field with arguments and a field of an object type is a resolver, named `Type::field`, and the compiler names any you have not written:

<!-- nocheck -->
```moonbit
fn Query::book(id : String) -> Book? raise { ... }
fn Book::author(self : Book) -> Author raise { ... }
```

Declare a struct of the same name to keep what the schema does not show, such as the id behind `Book::author`. The generator binds to it, and a field it holds needs no resolver. Every resolver is declared `raise`, so a package whose resolvers cannot fail sets `warnings = "-unused_error_type"`.

A subscription root is generated the same way: a field of the `Subscription` type becomes a `declare fn` returning its events, one array, and `register_subscriptions` wires them to the executor.

<!-- nocheck -->
```moonbit
#|type Subscription {
#|  bookAdded: Book!
#|}

fn Subscription::book_added() -> Array[Book] raise { ... }
```

`#gql.sdl` and the other annotations can share a schema, each type in one or the other. [`27-schema-first`](src/examples/27-schema-first/) runs all of it.

## Without annotations

The generator is a convenience, not the only door: everything it writes is ordinary API. These are the same server written the other two ways — the [guide](https://moonbitstack.github.io/moongql/guide.html) shows every block in all three, side by side.

### Functions

Calls on the schema and the resolver map. A field's declared type says whether its value is a leaf, a list or an object, and a resolver only returns JSON:

```moonbit
pub fn demo() -> (@moongql.Schema, @moongql.Resolvers) {
  let schema = @moongql.Schema::new()
  let q = schema.object("Query")
  q.field("hello", NonNull(Scalar("String")))
  q.field_args("user", [("id", NonNull(Scalar("ID")))], Named("User"))
  let u = schema.object("User")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", NonNull(Scalar("String")))
  u.field("tags", ListOf(NonNull(Scalar("String"))))
  let resolvers = @moongql.Resolvers::new()
  resolvers.field("Query", "hello", fn(_info) { Json("hello") })
  resolvers.field("Query", "user", fn(info) -> Json raise @moongql.FieldError {
    let id : String = info.read("id")
    let person : Map[String, Json] = {
      "id": Json(id),
      "name": Json("Alice"),
      "tags": Json(["admin"]),
    }
    Json(person)
  })
  (schema, resolvers)
}

// Every block below builds on this pair.
let demo_pair : (@moongql.Schema, @moongql.Resolvers) = demo()
let schema : @moongql.Schema = demo_pair.0
let resolvers : @moongql.Resolvers = demo_pair.1

test {
  assert_eq(schema.to_sdl().contains("type User {"), true)
}
```

### Classes

A struct per type, its two conversions, and a method per field — what the generator writes for an annotated struct, written by hand instead. A type that joins the executor this way is yours: it can carry fields the schema does not show, and the conversions decide how it crosses the wire.

```moonbit
pub(all) struct Person {
  id : String
  name : String
}

pub impl @moongql.ToGql for Person with fn to_gql(self) {
  Json({ "id": Json(self.id), "name": Json(self.name) })
}

pub impl @moongql.FromGql for Person with fn from_gql(v) {
  { id: @moongql.read(v, "id"), name: @moongql.read(v, "name") }
}

// The compiler wants the promotion said out loud: the impls make these methods
// of the type.
pub extend Person with @moongql.ToGql::{to_gql}
pub extend Person with @moongql.FromGql::{from_gql}

let people : Array[Person] = [{ id: "1", name: "Alice" }]

pub(all) struct PersonQuery {}

fn PersonQuery::person(id : String) -> Person? {
  people.iter().find_first(p => p.id == id)
}

pub fn people_server() -> (@moongql.Schema, @moongql.Resolvers) {
  let s = @moongql.Schema::new()
  let person = s.object("Person")
  person.field("id", NonNull(Scalar("String")))
  person.field("name", NonNull(Scalar("String")))
  let query = s.object("Query")
  query.field_args("person", [("id", NonNull(Scalar("String")))], Named("Person"))
  let r = @moongql.Resolvers::new()
  r.field("Query", "person", fn(info) {
    @moongql.ToGql::to_gql(PersonQuery::person(info.read("id")))
  })
  (s, r)
}

let pair : (@moongql.Schema, @moongql.Resolvers) = people_server()

test {
  assert_eq(
    @moongql.execute(pair.0, pair.1, "{ person(id: \"1\") { name } }").stringify(),
    "{\"data\":{\"person\":{\"name\":\"Alice\"}}}",
  )
}
```

## SDL, both ways

`to_sdl` prints a schema; `Schema::of_sdl` parses one back. The two are a round
trip — print a schema, parse the result, print it again, and the second print is
byte-for-byte the same as the first (descriptions, `@deprecated(reason:)`,
argument and input-field defaults, custom and built-in directives, `implements`,
and the `schema { ... }` root block all survive the trip). A default value is
printed against the type it is a default for, so an enum value stays `GUEST`
where a string stays `"all"`:

```moonbit
test {
  let parsed = @moongql.Schema::of_sdl(
    #|type Query {
    #|  "The user with this id."
    #|  user(id: ID!): User
    #|}
    #|type User {
    #|  id: ID!
    #|  name: String!
    #|  "Use `fullName` instead."
    #|  legacyName: String! @deprecated(reason: "use name")
    #|}
    #|,
  )
  // Print, parse, print: the second print is the first one again.
  assert_eq(@moongql.Schema::of_sdl(parsed.to_sdl()).to_sdl(), parsed.to_sdl())
  assert_eq(parsed.to_sdl().contains("@deprecated(reason: \"use name\")"), true)
}
```

A definition that stops mid-way reports where it stopped (`2:1 expected a type
system definition`), so a bad document is reported, not silently dropped. The
same round trip is a command: `moon run src/cmd/sdl -- schema.graphql` prints a
document the way this printer writes it.

## Packages

Each stage of a request is its own subpackage, so a program links the stages it
uses and no others. The root re-exports all of them, so `@moongql.Schema` and
`@moongql.execute` work as they always did.

|  Package  | What it holds | Depends on |
|:--:|:--|:--|
| `moongql/lang` | the document syntax tree, `tokenize`, `parse`, `GqlError` | nothing |
| `moongql/schema` | types, directives, the built-in scalars and meta-fields, SDL, and `Schema::check` | `lang` |
| `moongql/valid` | `validate` | `lang`, `schema` |
| `moongql/exec` | `execute`, `execute_async`, subscriptions, introspection | `lang`, `schema`, `valid` |
| `moongql/federation` | Apollo Federation v1 and v2 | `schema`, `exec` |
| `moongql/server` | the HTTP endpoint and graphql-transport-ws | `exec` and below, moonasgi |
| `moongql/loader` | `DataLoader` | nothing |
| `moongql/client` | a GraphQL client over HTTP | `lang`, moonfetch |
| `moongql/orm` | a pooled database for resolvers: projection, attaching a list's children, a statement budget | `exec`, moonorm, moondb |
| `moongql/orm/sqlite` | the same on SQLite | `orm`, moonsqlite (native) |
| `moongql/mcp` | the schema offered to an agent as Model Context Protocol tools | `schema`, `exec`, moonmcp |
| `moongql/cmd/gql` | the generator behind the `#gql` annotations | moonast |
| `moongql/cmd/sdl` | `moongql-sdl` on the command line: a document's schema, normalised | `schema` |

Running a query in-process needs nothing from `server`, so a test or a command
line tool never links moonasgi.

**Constructors are written without the package.** `pub using` re-exports types
but not their constructors, so `@moongql.NonNull(...)` does not resolve.
Wherever the expected type is known — a field's type, a match on a value — the
bare name does, and reads better: `NonNull(Scalar("ID"))`. The one place it is
not known is an error, because `raise` and `catch` work on any error; there the
subpackage is named, `@lang.Refused(...)` or `@exec.FieldError(...)`.

## Parser and execution

The code-first schema and SDL are here, with **field arguments** (`field_args`), **input object types** (`Schema::input`), **enum types** (`Schema::enum_`), and **interfaces** (`Schema::interface` + object `implements`). The **query parser** now lands too — a hand-written lexer and a recursive-descent parser that turn a query string into a `Document` AST:

```moonbit
test {
  let doc = @moongql.parse(
    "query ($id: ID!) { user(id: $id) { name ...fields @skip(if: false) } }",
  )
  assert_eq(doc.definitions.length(), 1)
  // Printing a document gives the canonical form the printer writes, not the
  // source text: whitespace and comments are gone, the shape is the same.
  assert_eq(doc.to_query().contains("query($id: ID!)"), true)
}
```

It covers operations (`query`/`mutation`/`subscription` and the `{ ... }` shorthand), selection sets, fields with aliases/arguments/directives, variable definitions with default values, named and inline fragments, `@skip`/`@include` directives, and every input value (variables, ints, floats, strings, block strings, booleans, null, enums, lists, objects) — enough to parse the full GraphQL introspection query.

## Executing a query

`moongql` now **runs** queries. `execute` parses, validates against the schema, then walks the document with a **resolver map** — `(ResolveInfo) -> Json` functions keyed by `"Type.field"` — returning the `{ data, errors }` response as JSON. It supports variables (with defaults), aliases, named and inline fragments, `@skip`/`@include`, nested selection, list and object results, non-null error propagation, and introspection (`__schema` / `__type` / `__typename`), including the introspection types themselves and argument defaults.

```moonbit
// `schema` and `resolvers` are the pair from the section above; a resolver of
// `Query.user` answers the whole object, and the fields under it fall back to the
// default resolver, which reads them off the parent (spec §6.4.4).
let vars : Map[String, Json] = { "uid": Json("1") }
let res = @moongql.execute(
  schema,
  resolvers,
  "query ($uid: ID!) { hero: user(id: $uid) { id name } }",
  variables=vars,
)
assert_eq(res.stringify(), "{\"data\":{\"hero\":{\"id\":\"1\",\"name\":\"Alice\"}}}")
```

Every error that can be traced to a point in the document carries its `locations` — the line and column of the field, argument, directive or variable it is about, not just a message:

```moonbit
test {
  let invalid = @moongql.execute(
    schema,
    resolvers,
    "query Hero {\n  user(id: \"1\") {\n    nope\n  }\n}",
  )

  assert_eq(
    invalid.stringify(),
    "{\"errors\":[{\"message\":\"Cannot query field 'nope' on type 'User'\",\"locations\":[{\"line\":3,\"column\":5}]}]}",
  )
}
```

A server's own `extensions` entry (spec §7.1) rides on the response — a trace id, a timing, whatever the deployment wants to say alongside the result — and is left out when empty:

```moonbit
test {
  let traced = @moongql.execute(
    schema,
    resolvers,
    "{ user(id: \"1\") { name } }",
    extensions={ "traceId": Json("qwq-233") },
  )

  assert_eq(
    traced.stringify(),
    "{\"data\":{\"user\":{\"name\":\"Alice\"}},\"extensions\":{\"traceId\":\"qwq-233\"}}",
  )
}
```

### Design: explicit, because MoonBit has no runtime reflection

A schema is built from **explicit** values rather than discovered from the shape of a class: a type is an object you declare, and its resolvers are functions registered by `"Type.field"`. A field's declared return type drives leaf-vs-composite completion, so a field returning a list of objects is completed as one without being told twice. Fields with no registered resolver read their value off the parent JSON object.

Union types, custom scalars, subscriptions, a DataLoader, a built-in HTTP endpoint with a browser IDE, and Apollo Federation are all part of the library and documented above.

```moonbit
test {
  let shapes = @moongql.Schema::new()

  let node = shapes.interface("Node")
  node.field("id", NonNull(Scalar("ID")))

  let member = shapes.object("User")
  member.implements("Node")
  member.field("id", NonNull(Scalar("ID")))

  let query = shapes.object("Query")
  query.field_args("user", [("id", NonNull(Scalar("ID")))], Named("User"))

  let filter = shapes.input("UserFilter")
  filter.field("name", Scalar("String"))

  shapes.enum_("Role", ["ADMIN", "USER"])

  let printed = shapes.to_sdl()

  assert_eq(printed.contains("type User implements Node"), true)
  assert_eq(printed.contains("input UserFilter"), true)
}
```

emits `user(id: ID!): User`, `type User implements Node { .. }`, `input UserFilter { .. }`, and `enum Role { ADMIN USER }`.

## Unions and custom scalars

Declare a union with `Schema::union` and select into it through inline fragments; each value is discriminated by its `__typename`:

```moonbit
test {
  schema.union("SearchResult", ["User", "Query"])
  let with_union = schema.to_sdl()
  assert_eq(with_union.contains("union SearchResult = User | Query"), true)
}
```

A custom scalar carries its own `serialize` (output) and `parse_value` (input) hooks — the two coercions the specification gives every scalar. Input arguments and variables run through `parse_value` before a resolver sees them; resolver results run through `serialize`:

```moonbit
test {
  schema.scalar(
    "DateTime",
    serialize=fn(j) { j },      // value -> output JSON
    parse_value=fn(j) { j },    // input JSON -> value
    description="Milliseconds since the epoch.",
  )
  assert_eq(schema.to_sdl().contains("scalar DateTime"), true)
}
```

Both show up in SDL (`union SearchResult = Book | Author`, `scalar DateTime`) and in introspection (`kind: UNION` with `possibleTypes`, `kind: SCALAR`).

### Which type is it?

A value at an interface or union position is normally told apart by the `__typename` it carries. A value that does not carry one — a database row, a decoded message — is classified by a hook instead. `resolve_type` answers the object type's name for the whole abstract type, and `is_type_of` answers whether a value belongs to one object type; it is asked of each possible type in turn:

```moonbit
test {
  let animals = @moongql.Schema::new()
  let pet = animals.interface("Pet")
  pet.field("name", NonNull(Scalar("String")))
  let dog = animals.object("Dog")
  dog.implements("Pet")
  dog.field("name", NonNull(Scalar("String")))
  dog.field("barks", NonNull(Scalar("Boolean")))

  let pet_resolvers = @moongql.Resolvers::new()
  pet_resolvers.resolve_type("Pet", fn(value, _ctx) {
    match value {
      Object(m) => if m.get("barks") is Some(_) { Some("Dog") } else { None }
      _ => None
    }
  })

  // or, per object type:
  pet_resolvers.is_type_of("Dog", fn(value, _ctx) {
    value is Object(m) && m.get("barks") is Some(_)
  })
}
```

A hook is asked before `__typename`, so a resolver that classifies values itself does not depend on the tag; a name that is not a possible type of the abstract type is a field error, not a silent fallback.

## Subscriptions

A subscription has one root field backed by a source stream. `execute_subscription` returns the ordered payloads a client would receive, one `{ data, errors }` per event. The stream is a pull source — a resolver returning `Array[Json]` — so the whole pipeline runs on every backend; the async native variant over a WebSocket wraps the same per-event core.

```moonbit
test {
  let feed = @moongql.Schema::new()
  let message = feed.object("Message")
  message.field("id", NonNull(Scalar("ID")))
  message.field("body", NonNull(Scalar("String")))
  let root = feed.object("Subscription")
  root.field("messageAdded", NonNull(Named("Message")))
  feed.set_subscription("Subscription")

  let subs = @moongql.Subscribers::new()
  subs.field("Subscription", "messageAdded", fn(_info) {
    // one Json payload per event, in delivery order
    [
      Json({ "id": Json("1"), "body": Json("hello") }),
      Json({ "id": Json("2"), "body": Json("again") }),
    ]
  })

  let payloads = @moongql.execute_subscription(
    feed,
    @moongql.Resolvers::new(),
    subs,
    "subscription { messageAdded { id body } }",
  )

  assert_eq(payloads.length(), 2)
  assert_eq(
    payloads[0].stringify(),
    "{\"data\":{\"messageAdded\":{\"id\":\"1\",\"body\":\"hello\"}}}",
  )
}
```

The single-root-field rule (spec §5.2.3.1) is enforced, and an introspection field can't be a subscription root.

## DataLoader

`DataLoader` is the batch-and-cache tool for the N+1 problem. Keys requested during a resolution pass are queued and deduped; one `dispatch` runs the batch function once over the distinct keys:

```moonbit
test {
  let loader : @moongql.DataLoader[Int, String] = @moongql.DataLoader::new(
    fn(ids) { ids.map(fn(id) { "author#" + id.to_string() }) },
    fn(id) { id.to_string() },
  )
  loader.load(1)
  loader.load(2)
  loader.load(1)     // three requests, two keys
  loader.dispatch()  // one batch call for {1, 2}

  assert_eq(loader.get(1).unwrap_or(""), "author#1")
}
```

`prime`, `clear`, `clear_all`, `load_many` and `load_now` round out the API. Where Facebook's DataLoader coalesces within an event-loop tick, this drains the queue explicitly so it stays testable without a runtime.

## Database

`@moongql/orm` puts a pool of connections behind a resolver, so a field asks for
rows instead of opening a connection:

```moonbit native
test {
  let db = @orm.Database::new(() => @moonsqlite.SqliteDriver::open("blog.db"), max_size=8)
  let res = @moongql.Resolvers::new()
  res.field("Query", "posts", fn(info) {
    Json(db.select(info, "posts", ["id", "title", "views", "author_id"], keep=["author_id"]))
  })
}
```

`select` takes the field's `info`, so the statement asks for the columns the
document asked for — `{ posts { title } }` becomes `SELECT title FROM posts` — and
`keep` names the columns a child field will need even though the document does not
select them. A parameter is bound, never interpolated; a table, a predicate and an
ordering are part of the query's shape and are written by the developer.

The N+1 problem is a shape, not a mistake: `{ posts { author { name } } }` runs
`author` once per post, and a resolver that sees one post cannot batch with the
others. The field that produced the list is the one that knows it, so it attaches
the children in a single statement:

```moonbit native
test {
  let db = @orm.Database::new(
    () => @moonsqlite.SqliteDriver::open("blog.db"),
    max_size=8,
  )
  let res = @moongql.Resolvers::new()
  res.field("Query", "posts", fn(info) {
    let rows = db.select(info, "posts", ["id", "title", "author_id"], keep=["author_id"])
    Json(db.attach(rows, "author", "authors", ["id", "name"], parent_key="author_id"))
  })
}
```

`Post.author` then needs no resolver of its own — the default resolver reads the
attached object off the parent. Three posts by two authors cost two statements, and
ten posts by the same two authors still cost two; `db.statements()` is the counter a
test asserts that on.

Two boundary notes. Every statement takes a connection from the pool and gives it
back — on the error path too — and `db.connections()` reports what is open and what
is checked out, which is how a leaked connection is found. And a `Session` is
synchronous, so on SQLite a query occupies the one event loop while it runs: the
pool bounds how many connections exist, not how many queries overlap. Overlapping
needs a driver and a session that wait; the structure here does not change when
they arrive.

## HTTP endpoint

`graphql_handler` wires a schema and its resolvers onto the [moonasgi](https://mooncakes.io/docs/moonbitstack/moonasgi) seam, so moongql serves over `mooncat` (or any server that binds the ASGI callable), following the [GraphQL-over-HTTP](https://graphql.github.io/graphql-over-http/draft/) specification:

```moonbit
test {
  let handler = @moongql.graphql_handler(schema, resolvers)      // path defaults to /graphql
  let app = @moongql.graphql_app(schema, resolvers)              // the same, lifted onto an AsgiApp
}
```

A `POST` reads an `application/json` body — `{ query, variables, operationName }`, or an array of those for a batch, answered by an array of results. A POST with no `Content-Type` is a 415: the server will not guess what the bytes are. The body is read as [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259) and nothing else, so a comment, a trailing comma or an unquoted member name is a 400 rather than a document only this server would accept; nesting is bounded before the reader recurses, so a body of ten thousand open brackets is refused instead of taking the stack down with it. A response is one line of text with the escapes JSON names, and non-ASCII written as it stands. A `GET` carrying `?query=` runs it (a query only — a mutation over `GET` is a 405, since a `GET` must stay safe), taking `variables` as a JSON-encoded parameter; a `GET` without one serves the built-in IDE — the library's own **MoonQL page** by default, or **GraphiQL**, **Apollo Sandbox** and **Altair** through the `ide~` argument, or nothing at all with `off`:

```moonbit
test {
  let app = @moongql.graphql_app(schema, resolvers)                     // the MoonQL page
  let app = @moongql.graphql_app(schema, resolvers, ide=@moongql.graphiql)
  let app = @moongql.graphql_app(schema, resolvers, ide=@moongql.apollo_sandbox)
  let app = @moongql.graphql_app(schema, resolvers, ide=@moongql.reference)
  let app = @moongql.graphql_app(schema, resolvers, ide=@moongql.off)   // no IDE, GET without ?query= is 405
}
```

The MoonQL page is built by the library — one HTML string, nothing fetched from a CDN: a document on the left, the answer on the right, a schema drawer, a variables box, and the field linking the documentation uses (a field lit on one side lights the same field on the other, and names its path and declared type). It speaks HTTP; subscriptions are GraphiQL's and Altair's, whose CDN assets are pinned to an exact version, and which derive their socket from the page's own location unless one is configured. Any page is available on its own: `@moongql.site.html(endpoint="/graphql")`.

### The schema reference

`@moongql.reference` is not an editor: it is the schema written down, rendered from
the one the handler already holds. The root types come first, then every other type
grouped by kind, each field with its arguments, its default values, its description
and its deprecation, and every type name a link to its own section. The directives a
document may write come last — the four the specification fixes, `@defer` and
`@stream`, and whatever the schema registered — each with the locations it may be
written at and the defaults its arguments run with. A filter box narrows the rail
and the page together. Nothing is fetched and no operation runs, which is what makes
the page safe to serve wherever the schema itself may be shown.

```moonbit
test {
  let page = @moongql.reference.html(endpoint="/graphql", schema=schema)
  assert_eq(page.contains("<title>Schema reference</title>"), true)
  assert_eq(page.contains("id=\"User\""), true)
  assert_eq(page.contains("hello"), true)
}
```

`Accept` picks the response media type. Ask for `application/graphql-response+json` and the status carries meaning — 400 for a request error, where the document never ran, and 200 for an operation that ran whatever its field errors say. Ask for `application/json`, or send no `Accept` at all, and every GraphQL response is a 200 with the errors in the body, which is what pre-specification clients expect. A client that accepts neither gets a 406.

`graphql_app` is what a server mounts. The request/response logic is shared with `graphql_handler`, which moonasgi's `TestClient` drives without a socket — so the endpoint is tested on every backend:

```moonbit
test {
  let client = @moonasgi.TestClient::new(@moongql.graphql_handler(schema, resolvers))
  let body = @utf8.encode(
    "{\"query\":\"{ user(id: \\\"1\\\") { name } }\"}",
  )
  let resp = client.post("/graphql", body~, headers=[
    ("content-type", "application/json"),
    ("accept", "application/graphql-response+json"),
  ])
  // resp.status == 200, resp.text() == {"data":{"user":{"name":"Alice"}}}
}
```

## graphql-transport-ws

`GqlWs` is one WebSocket connection's protocol state, and `recv` maps a client frame to the frames sent back: `connection_init` → `connection_ack`, `subscribe` → a run of `next` then `complete`, `ping` → `pong`. The `connection_init` payload becomes the connection's parameters and reaches every resolver's context under `connectionParams`, so a client hands over a token once instead of on every operation. An operation id is unique among *running* operations — reusing one that has completed is fine, reusing one still running closes with 4409.

The protocol's two timers are state, not threads. This package has no runtime and no clock, so a server drives them by calling `tick` with a millisecond reading of a monotonic clock and sending whatever comes back: the 4408 close when `connection_init` never arrived, or a keep-alive `ping`.

```moonbit
test {
  let subs = @moongql.Subscribers::new()
  subs.field("Subscription", "messageAdded", fn(_info) { [] })
  let ws = @moongql.GqlWs::new(schema, resolvers, subs, init_timeout=3000, ping_interval=12000)
  let handler = ws.handler()             // a moonasgi WebSocketHandler
  let quiet = ws.tick(4_000)             // the server's clock, as often as it likes
  let frames = ws.tick(20_000)
  assert_eq(quiet.length(), 0)
  assert_eq(frames.length() > 0, true)   // 4408: no connection_init, so it closes
}
```

`graphql_ws_handler` builds a handler whose connection state nothing can reach, for a server with no clock to spare.

## Asynchronous resolvers

A resolver that waits — a database round trip, an upstream call — is registered
with `field_async`, and the request runs with `execute_async`. Fields at the same
level are independent (§6.2.2), so they are resolved concurrently; the root fields
of a mutation run one after another (§6.2.3). The response is the one `execute`
would have built: same keys, same error paths, same `extensions`.

```moonbit
async test "an asynchronous resolver answers the same response" {
  let async_resolvers = @moongql.Resolvers::new()
  async_resolvers.field("Query", "hello", fn(_info) { Json("hello") })
  async_resolvers.field_async("Query", "user", async fn(info) {
    let id : String = info.read("id")
    Json({ "id": Json(id), "name": Json("Alice"), "tags": Json([]) })
  })

  let response = @moongql.execute_async(
    schema,
    async_resolvers,
    "{ hello user(id: \"1\") { name } }",
  )
  assert_eq(
    response.stringify(),
    "{\"data\":{\"hello\":\"hello\",\"user\":{\"name\":\"Alice\"}}}",
  )
}
```

A field registered the synchronous way still runs, so a schema moves one field at
a time. How much runs at once is a `Limits` record: `max_concurrency` bounds the
tasks of one selection set.

Two things every resolver can be held to. `Resolvers::permission` answers whether
a field may be resolved at all; a refused field is a `not permitted` field error at
its own path, and its resolver never runs. `Resolvers::hook` adds an `Extension`,
which sees each field before it resolves and its value after it completes —
tracing, metrics and a per-field cache are written as extensions rather than as
branches in the engine:

```moonbit
resolvers.permission("Query", "user", fn(info : @moongql.ResolveInfo) {
  info.ctx is Object(m) && m.get("admin") == Some(Json(true))
})
```

`ResolveInfo.selection` names the response keys the document selects under the
field, which is what a resolver that builds a query from the request — a column
projection, a Relay `node` — reads instead of fetching everything:

```moonbit
test {
  let projected = @moongql.Resolvers::new()
  projected.field("Query", "user", fn(
    info : @moongql.ResolveInfo
  ) -> Json raise @moongql.FieldError {
    let id : String = info.read("id")
    // a projection built from what the document asks for
    let name = if info.reads("name") { "Alice" } else { "" }
    Json({ "id": Json(id), "name": Json(name) })
  })
  assert_eq(
    @moongql.execute(schema, projected, "{ user(id: \"1\") { name } }").stringify(),
    "{\"data\":{\"user\":{\"name\":\"Alice\"}}}",
  )
}
```

## Incremental delivery

`@defer` on a fragment and `@stream` on a list field postpone work until after the
first payload has been sent. The initial payload lists what was postponed under
`pending`, each entry an `id`, the `path` it belongs at and the `label` the
document asked for; each later payload carries the results under `incremental`,
keyed by the same `id`, and closes those ids under `completed`. A client joins the
two by id, which is what lets several deferrals and a streamed list arrive out of
order without being confused:

```moonbit
async test "a deferral answers twice" {
  let payloads = payloads_of_deferred_user()
  assert_eq(payloads.length(), 2)
  assert_eq(
    payloads[0].stringify(),
    "{\"data\":{\"user\":{\"id\":\"1\"}},\"pending\":[{\"id\":\"0\",\"path\":[\"user\"],\"label\":\"late\"}],\"hasNext\":true}",
  )
  assert_eq(
    payloads[1].stringify(),
    "{\"incremental\":[{\"id\":\"0\",\"data\":{\"name\":\"Alice\",\"tags\":[\"admin\"]}}],\"completed\":[{\"id\":\"0\"}],\"hasNext\":false}",
  )
}

async fn payloads_of_deferred_user() -> Array[Json] {
  let s = @moongql.Schema::new()
  let query = s.object("Query")
  query.field("user", Named("User"))
  let user = s.object("User")
  user.field("id", NonNull(Scalar("ID")))
  user.field("name", NonNull(Scalar("String")))
  user.field("tags", ListOf(NonNull(Scalar("String"))))
  let r = @moongql.Resolvers::new()
  r.field("Query", "user", fn(_info) {
    Json({ "id": Json("1"), "name": Json("Alice"), "tags": Json(["admin"]) })
  })
  @moongql.execute_incremental(
    s,
    r,
    "{ user { id ... @defer(label: \"late\") { name tags } } }",
  ) catch {
    _ => []
  }
}
```

A streamed list sends the items after `initialCount` in one entry, under `items`,
rather than one payload per row; the whole list is cut into successive entries only
when it is longer than `Limits.max_stream`.

Over HTTP the client asks for it with `Accept: multipart/mixed`, and `graphql_app`
writes one part per payload. A client that does not ask receives one JSON body, and
`@defer` / `@stream` collapse to their in-line meanings — the same response, with
no `pending` and no `hasNext`.

## Live subscriptions

A subscription whose events are not there yet is backed by a `Stream`: something
to pull from, and something to stop. `Stream::channel` pairs one with a `Sender`
that a producer writes events into; closing the sender ends the stream.

```moonbit
test {
  let subs = @moongql.Subscribers::new()
  let feed = @moongql.Stream::channel()
  subs.stream("Subscription", "messageAdded", fn(
    _info
  ) -> @moongql.Stream raise @moongql.FieldError {
    feed.0
  })

  // anywhere else, whenever something happens
  feed.1.send(Json({ "id": Json("1"), "body": Json("hello") })) catch {
    _ => ()
  }
}
```

`subscribe_live` establishes the subscription and hands back a `Live` whose `next`
answers one payload per event, so the transport decides how they travel:
`graphql_ws_app` is an ASGI application that keeps a task per running
subscription, writes each event as it arrives, and closes with `complete` when the
source ends or the client cancels.

## Client

`moonbitstack/moongql/client` sends operations over HTTP and reads answers with the
same parser the server uses:

```moonbit native
async test {
  let client = @client.Client::new(
    url="https://example.com/graphql",
    headers=[("authorization", "Bearer ...")],
  )
  let data = client.query("{ user(id: \"1\") { name } }")
  // `request` answers the response as it came, errors and all
  let whole = client.request("{ user(id: \"1\") { name } }")
  let answers = client.batch(["{ hello }", "{ hello }"])
  assert_eq(answers.length(), 2)
  assert_eq(data is Object(_), true)
  assert_eq(whole is Object(_), true)
}
```

`query` answers `data` and refuses with the server's errors when there is none;
`request` returns the response as it came, because a partial result is a result.
The document is parsed before it is sent, so a typo is reported without a round
trip.

## Agents: the schema as MCP tools

An agent that speaks the Model Context Protocol can read the same schema. `mcp`
offers every root field as a tool: the field's name is the tool's name, its
arguments become the tool's input schema — a `id: ID!` is `{"type":"string"}` and
required, an enum becomes a JSON Schema enum, an input object becomes an object —
and what it answers is the field's value, selected two levels deep by default:

```moonbit
test {
  let tools = @mcp.Mcp::of(schema=schema, resolvers=resolvers)
  let server = tools.server(name="shop")
  // mount it where an agent reaches it
  let asgi = server.to_asgi()
  let _ = asgi
}
```

`@mcp.exposure` is the preset: no mutations, two levels of selection, twelve fields
per level. A tool call is not a confirmation, so a mutation is not a tool until it
is asked for — `exposure={ ..exposure, mutations: true }` — and the `graphql_query`
tool, which runs a document the agent wrote, refuses a mutation document either
way. The schema itself travels as a resource (`graphql://schema`, in SDL) and as the
server's instructions, so an agent can write that document without another round
trip.

```moonbit
test {
  let open = @mcp.Mcp::of(
    schema=schema,
    resolvers=resolvers,
    exposure={ prefix: "shop_", mutations: false, depth: 3, width: 20 },
  )
  let named = open.server(name="shop", version="1.0.0")
  let _ = named
}
```

A field that cannot be selected without an argument is left out of the default
selection rather than sent with a value nobody chose, and a response carrying
`errors` comes back to the agent marked `isError` with the whole response as its
content, which is what it needs to correct itself.

## Apollo Federation

A subgraph exposes `_service { sdl }` (its SDL, annotated with the federation directives), the `_entities(representations:)` resolver that turns a `{ __typename, <key> }` reference back into a full object, and `@key` / `@extends` / `@external` markers. Register the entity types and their reference resolvers, then `apply` installs the machinery — the `_Service` type, the `_Any` scalar, the `_Entity` union, and the two root fields — so the ordinary executor answers a federated query:

```moonbit
test {
  let fed = @moongql.Federation::new()
  fed.entity(name="User", key="id", resolve=(rep, _ctx) => {
    let id = match rep {
      Object(m) =>
        match m.get("id") {
          Some(String(s)) => s
          _ => ""
        }
      _ => ""
    }
    // materialise from the key
    Json({ "id": Json(id), "name": Json("User#" + id), "tags": Json([]) })
  })
  fed.apply(schema, resolvers)

  // { _service { sdl } } -> the subgraph SDL with `type User @key(fields: "id")`
  // _entities(representations: [{ __typename: "User", id: "7" }]) -> the User object
  assert_eq(fed.sdl(schema).contains("@key(fields: \"id\")"), true)
}
```

An extended type declares `extends=true` and lists its `external` fields, which render as `extend type ... @key(...)` with `@external` on the borrowed fields — the shape a gateway composes.

### Federation v2

Pass `v2=true` for a Federation v2 subgraph. Its SDL opens with `extend schema @link(...)` onto the federation spec, and the v2 field directives — `@shareable`, `@inaccessible`, `@override(from:)`, `@requires(fields:)`, `@provides(fields:)` — are declared on fields and rendered into the subgraph SDL:

```moonbit
test {
  let fed = @moongql.Federation::new(v2=true)
  fed.entity(name="Product", key="upc", extends=true, external=["weight"],
    resolve=(rep, _ctx) => {
      // @requires(fields: "weight"): the gateway ships the external weight in the
      // representation, so the resolver can read it to compute the estimate.
      let weight = match rep {
        Object(m) =>
          match m.get("weight") {
            Some(Number(w, ..)) => w
            _ => 0.0
          }
        _ => 0.0
      }
      let upc = match rep {
        Object(m) =>
          match m.get("upc") {
            Some(String(u)) => u
            _ => ""
          }
        _ => ""
      }
      Json({ "upc": Json(upc), "shippingEstimate": Json(weight * 2.0) })
    })
  fed.shareable("Product", "name")
  fed.override_("Product", "price", from="legacy")
  fed.requires("Product", "shippingEstimate", fields="weight")
  fed.inaccessible("User", "ssn")   // present in the subgraph, hidden from the composed schema
  fed.apply(schema, resolvers)
}
```

`@tag(name:)` labels a type or a field for the router to filter or route by; it is repeatable, so a type may carry several:

```moonbit
test {
  let fed = @moongql.Federation::new(v2=true)
  fed.tag("Product", name="catalog")
  fed.tag_field("Product", "weight", name="measured")
}
```

`@inaccessible` is the one v2 directive with a runtime effect beyond SDL: the field stays resolvable inside the subgraph but is **hidden from introspection**, so a gateway composing the public schema never sees it.

`@requires` and `@provides` have a runtime side too. The gateway ships the `@requires` fields inside the representation, and `_entities` keeps whatever the representation carried on the value the entity resolver returns — so a field resolver can read an external field the entity resolver knows nothing about:

```moonbit
test {
  let product_resolvers = @moongql.Resolvers::new()
  product_resolvers.field("Product", "shipping", fn(
    info : @moongql.ResolveInfo
  ) -> Json raise @moongql.FieldError {
  // `weight` is @external: the gateway sent it with the representation.
  let weight = match info.parent {
    Object(m) =>
      match m.get("weight") {
        Some(Number(w, ..)) => w
        _ => 0.0
      }
    _ => 0.0
  }
    Json(weight * 2.0)
  })
}
```

`Federation::check` reads every `@key`, `@requires` and `@provides` field set against the schema and answers one line per path that does not exist, so a subgraph that would fail at composition fails in a test instead:

```moonbit
test {
  let fed = @moongql.Federation::new(v2=true)
  // an empty list means the gateway can compose this subgraph
  assert_eq(fed.check(schema).length(), 0)
}
```

## Custom directives

Beyond `@skip` / `@include`, a schema can register its own directives. A directive definition carries its valid locations, arguments, repeatability, and an optional `on_field` hook that transforms a resolved field value during execution:

```moonbit
test {
  let text : @moongql.GqlType = NonNull(Scalar("String"))
  schema.directive(
    "prefix",
    locations=["FIELD"],
    args=[("text", text)],
    on_field=(value : Json, args : Map[String, Json]) => match
      (value, args.get("text")) {
      (String(x), Some(String(p))) => Json(p + x)
      _ => value
    },
  )
  assert_eq(schema.to_sdl().contains("directive @prefix(text: String!) on FIELD"), true)
}
```

A definition carries a description and its arguments' default values, which `to_sdl` and introspection both report:

```moonbit
test {
  let text : @moongql.GqlType = NonNull(Scalar("String"))
  let times : @moongql.GqlType = Scalar("Int")
  schema.directive(
    "repeat",
    locations=["FIELD"],
    args=[("text", text), ("times", times)],
    defaults=[("times", Json(1))],
    description="Repeats the prefix.",
  )
  assert_eq(
    schema.to_sdl().contains("directive @repeat(text: String!, times: Int = 1) on FIELD"),
    true,
  )
}
```

Registered directives show up in `__schema { directives }` beside the built-ins, and the validator accepts them only where they are declared.

## Spec validation

The validator implements a broad slice of the GraphQL spec's §5 validation table. Beyond the per-selection rules (fields and arguments exist, leaf-vs-composite selections, fragment type conditions, and variables defined by the operation — checked through the fragments it spreads, not only its own selections), it enforces the document-level rules:

| Rule | Spec |
|---|---|
| Operation name uniqueness | §5.2.1.1 |
| Lone anonymous operation | §5.2.2.1 |
| Argument uniqueness | §5.4.2 |
| Fragment name uniqueness | §5.5.1.1 |
| Fragments must be used | §5.5.1.4 |
| Fragment spreads must not form cycles | §5.5.2.2 |
| Directives are defined | §5.7.1 |
| Directives are in valid locations | §5.7.2 |
| Directive repeatability | §5.7.3 |
| Variable uniqueness | §5.8.1 |
| All variables used | §5.8.4 |
| Executable definitions (§5.1.1: a document carrying the type system is refused by name) | §5.1.1 |

`Schema::check` asks the other half — chapter 3, of the schema itself rather than of a document: names are unique and none begins with `__`, fields and arguments are unique and on the right side of the schema (output on objects and interfaces, input on inputs), an input object does not reach itself through required fields, a union's members are object types named once, an enum's values are names once each, a directive definition is declared once with real locations and input arguments, and every interface an object claims is one it actually satisfies — same field names, sub-types where the interface widens, arguments that match exactly — with the interfaces of its interfaces declared too. It answers one message per problem, empty when the schema holds:

```moonbit
test {
  let checked = @moongql.Schema::new()
  checked.object("Query").field("hello", NonNull(Scalar("String")))
  // one message per problem, and none at all when the schema holds
  assert_eq(checked.check().length(), 0)
}
```

## Conformance

The HTTP surface is held to the specification's own audit, and execution is held
to the reference implementation. Both run in CI, against a driver that hands the
application the scopes and events a server would hand it, so the tools written for
other languages can drive it without a socket:

```
moon build --target native
cd scripts/audit && npm install
node run-audit.mjs          # the graphql-http specification audit
node run-differential.mjs   # the same corpus through graphql-js, compared
node run-incremental.mjs    # deferred and streamed payloads, replayed
node run-client.mjs         # this library's client against a graphql-js server
```

The audit is `graphql-http`'s own: **61 checks, 61 passing**, with no failures and
no notices — media types, status codes, the four parameters and their types,
`GET` running queries only, and the status codes that separate a request error
from a field error.

The differential runs 25 documents — aliases, fragments, variables and their
defaults, directives, non-null propagation, interfaces, unions, enums, argument
defaults, introspection, and the three failure classes — through `graphql` and
through this library, and compares `data` exactly and errors by the path and
location they point at. **25 of 25 agree.** Wording is not compared: the
specification fixes the shape of an error and where it is reported, not the
sentence.

`run-incremental.mjs` holds deferred and streamed work to the same standard, at the
level of the payload sequence rather than the response: 40 documents — a deferral, a
labelled one, two on one object, three levels of them, a named fragment spread
twice, a type condition that does and does not match, a null parent, one switched
off by a literal and one by a variable, aliased fields, conditional fields inside a
deferral, streams with each shape of `initialCount`, past the end, of an empty list
and of a missing one, two streams on sibling fields, a stream inside a streamed
item, a deferral inside a stream inside a deferral, a deferral wrapping a stream
and vice versa, and the two in one document — are replayed through
`graphql-js`'s `experimentalExecuteIncrementally` and through this library, and both
sequences are compared payload by payload, as text with object keys ordered.
**40 of 40 agree**: how many payloads there are, which ids they announce, when a
piece of work settles, and the order of `pending`, `incremental` and `completed`
within each.

`run-client.mjs` asks the same question from the other side. A `graphql-js` schema
behind `graphql-http`'s own handler serves a real socket, and this library's client
talks to it: seven requests — a plain field, arguments bound from variables, an
alias with a fragment, a field error under a non-null field, one operation named out
of two, a field the schema does not have, and a document that is not GraphQL at all
— and **7 of 7 agree**, with `data` compared exactly and errors by the path and
location they point at. The last one never reaches the server: the client checks a
document before spending a round trip on it.

## License

Apache-2.0.
