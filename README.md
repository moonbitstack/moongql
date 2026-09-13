<div align="center">

# moongql

**A code-first GraphQL library for MoonBit — `← strawberry-graphql`.**

[![Check and Test](https://github.com/moonbitstack/moongql/actions/workflows/ci.yml/badge.svg)](https://github.com/moonbitstack/moongql/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![mooncakes](https://img.shields.io/badge/mooncakes-Lfan--ke%2Fmoongql-brightgreen)](https://mooncakes.io/docs/Lfan-ke/moongql)

</div>

`moongql` defines a GraphQL schema **in code** — object types and fields — the way `strawberry-graphql` does for Python, and emits the schema SDL. `v0` ships the code-first schema and SDL printer; it's pure logic with no runtime dependencies, so it runs on every backend.

## Quickstart

```moonbit
let s = @moongql.Schema::new()

let q = s.object("Query")
q.field("hello", @moongql.NonNull(@moongql.Scalar("String")))
q.field("user", @moongql.Named("User"))

let u = s.object("User")
u.field("id", @moongql.NonNull(@moongql.Scalar("ID")))
u.field("name", @moongql.NonNull(@moongql.Scalar("String")))
u.field("tags", @moongql.ListOf(@moongql.NonNull(@moongql.Scalar("String"))))

let sdl = s.to_sdl()
```

produces:

```graphql
schema {
  query: Query
}

type Query {
  hello: String!
  user: User
}

type User {
  id: ID!
  name: String!
  tags: [String!]
}
```

Verified across all backends (`wasm`, `wasm-gc`, `js`, `native`) in CI, 0 warnings under `--deny-warn`.

## Roadmap (transliterating strawberry)

The code-first schema and SDL are here, with **field arguments** (`field_args`), **input object types** (`Schema::input`), **enum types** (`Schema::enum_`), and **interfaces** (`Schema::interface` + object `implements`). The **query parser** now lands too — a hand-written lexer and a recursive-descent parser that turn a query string into a `Document` AST:

```moonbit
let doc = @moongql.parse(
  "query ($id: ID!) { user(id: $id) { name ...fields @skip(if: false) } }",
)
// doc.definitions[0] is an OperationDefinition; doc.to_query() prints it back.
```

It covers operations (`query`/`mutation`/`subscription` and the `{ ... }` shorthand), selection sets, fields with aliases/arguments/directives, variable definitions with default values, named and inline fragments, `@skip`/`@include` directives, and every input value (variables, ints, floats, strings, block strings, booleans, null, enums, lists, objects) — enough to parse the full GraphQL introspection query.

## Executing a query

`moongql` now **runs** queries. `execute` parses, validates against the schema, then walks the document with a **resolver map** — `(ResolveInfo) -> Json` functions keyed by `"Type.field"` — returning the `{ data, errors }` response as JSON. It supports variables (with defaults), aliases, named and inline fragments, `@skip`/`@include`, nested selection, list and object results, non-null error propagation, and introspection (`__schema` / `__type` / `__typename`), including the introspection types themselves and argument defaults.

```moonbit
let s = @moongql.Schema::new()
let q = s.object("Query")
q.field_args("user", [("id", @moongql.NonNull(@moongql.Scalar("ID")))],
  @moongql.Named("User"))
let u = s.object("User")
u.field("id", @moongql.NonNull(@moongql.Scalar("ID")))
u.field("name", @moongql.NonNull(@moongql.Scalar("String")))

let r = @moongql.Resolvers::new()
r.field("Query", "user", fn(info) {
  match info.arg("id") {
    String("1") => { "id": "1", "name": "Alice" }
    _ => Json::null()
  }
})
// User.id / User.name fall back to the default resolver (read off the parent).

let vars : Map[String, Json] = { "uid": "1" }
let res = @moongql.execute(s, r,
  "query ($uid: ID!) { hero: user(id: $uid) { id name } }", variables=vars)
// res.stringify() == {"data":{"hero":{"id":"1","name":"Alice"}}}
```

Every error that can be traced to a point in the document carries its `locations` — the line and column of the field, argument, directive or variable it is about, not just a message:

```moonbit
let res = @moongql.execute(s, r, "query Hero {\n  user(id: \"1\") {\n    nope\n  }\n}")
// {"errors":[{"message":"Cannot query field 'nope' on type 'User'",
//             "locations":[{"line":3,"column":5}]}]}
```

A server's own `extensions` entry (spec §7.1) rides on the response — a trace id, a timing, whatever the deployment wants to say alongside the result — and is left out when empty:

```moonbit
let res = @moongql.execute(s, r, "{ user(id: \"1\") { name } }",
  extensions={ "traceId": "qwq-233" })
// {"data":{...},"extensions":{"traceId":"qwq-233"}}
```

### Design: faithful equivalences to strawberry

MoonBit has no runtime reflection, so where strawberry discovers resolvers and schema from Python classes, `moongql` uses **explicit** values: resolvers are functions registered by `"Type.field"` (like Rust/Go GraphQL servers), and a field's declared return type drives leaf-vs-composite completion exactly as `graphql-core`'s `complete_value` does. Fields with no registered resolver read their value off the parent JSON object — the equivalent of `graphql-core`'s `default_field_resolver`.

Union types, custom scalars, subscriptions, a DataLoader, a GraphiQL HTTP endpoint, and Apollo Federation all land too (below).

```moonbit
let s = @moongql.Schema::new()

let node = s.interface("Node")
node.field("id", @moongql.NonNull(@moongql.Scalar("ID")))

let q = s.object("Query")
q.field_args(
  "user",
  [("id", @moongql.NonNull(@moongql.Scalar("ID")))],
  @moongql.Named("User"),
)

let u = s.object("User")
u.implements("Node")
u.field("id", @moongql.NonNull(@moongql.Scalar("ID")))

let inp = s.input("UserFilter")
inp.field("name", @moongql.Scalar("String"))

s.enum_("Role", ["ADMIN", "USER"])
```

emits `user(id: ID!): User`, `type User implements Node { .. }`, `input UserFilter { .. }`, and `enum Role { ADMIN USER }`.

## Unions and custom scalars

Declare a union with `Schema::union` and select into it through inline fragments; each value is discriminated by its `__typename`:

```moonbit
s.union("SearchResult", ["Book", "Author"])
// { search { __typename ... on Book { title } ... on Author { name } } }
```

A custom scalar carries its own `serialize` (output) and `parse_value` (input) hooks, the same two coercions strawberry's `Scalar` defines. Input arguments and variables run through `parse_value` before a resolver sees them; resolver results run through `serialize`:

```moonbit
s.scalar("DateTime",
  serialize=fn(j) { j },      // value -> output JSON
  parse_value=fn(j) { j })    // input JSON -> value
```

Both show up in SDL (`union SearchResult = Book | Author`, `scalar DateTime`) and in introspection (`kind: UNION` with `possibleTypes`, `kind: SCALAR`).

## Subscriptions

A subscription has one root field backed by a source stream. `execute_subscription` returns the ordered payloads a client would receive, one `{ data, errors }` per event. The stream is a pull source — a resolver returning `Array[Json]` — so the whole pipeline runs on every backend; the async native variant over a WebSocket wraps the same per-event core.

```moonbit
let subs = @moongql.Subscribers::new()
subs.field("Subscription", "messageAdded", fn(info) {
  // one Json payload per event, in delivery order
  [msg1, msg2, msg3]
})

let payloads = @moongql.execute_subscription(schema, resolvers, subs,
  "subscription { messageAdded(channel: \"general\") { id body } }")
// payloads[0].stringify() == {"data":{"messageAdded":{"id":"1","body":"hello"}}}
```

The single-root-field rule (spec §5.2.3.1) is enforced, and an introspection field can't be a subscription root.

## DataLoader

`DataLoader` is the batch-and-cache tool for the N+1 problem. Keys requested during a resolution pass are queued and deduped; one `dispatch` runs the batch function once over the distinct keys:

```moonbit
let loader : @moongql.DataLoader[Int, String] = @moongql.DataLoader::new(
  fn(ids) { load_authors(ids) },  // called once per pass
  fn(id) { id.to_string() },      // cache-key function
)
loader.load(1); loader.load(2); loader.load(1)  // three requests, two keys
loader.dispatch()                               // one batch call for {1, 2}
loader.get(1)                                   // Some("author#1")
```

`prime`, `clear`, `clear_all`, `load_many` and `load_now` round out the API. Where Facebook's DataLoader coalesces within an event-loop tick, this drains the queue explicitly so it stays testable without a runtime.

## HTTP endpoint

`graphql_handler` wires a schema and its resolvers onto the [moonasgi](https://mooncakes.io/docs/Lfan-ke/moonasgi) seam, so moongql serves over `mooncat` (or any server that binds the ASGI callable), following the [GraphQL-over-HTTP](https://graphql.github.io/graphql-over-http/draft/) specification:

```moonbit
let handler = @moongql.graphql_handler(schema, resolvers)      // path defaults to /graphql
let app = @moongql.graphql_app(schema, resolvers)              // the same, lifted onto an AsgiApp
```

A `POST` reads an `application/json` body — `{ query, variables, operationName }`, or an array of those for a batch, answered by an array of results. A POST with no `Content-Type` is a 415: the server will not guess what the bytes are. A `GET` carrying `?query=` runs it (a query only — a mutation over `GET` is a 405, since a `GET` must stay safe), taking `variables` as a JSON-encoded parameter; a `GET` without one serves the GraphiQL IDE.

`Accept` picks the response media type. Ask for `application/graphql-response+json` and the status carries meaning — 400 for a request error, where the document never ran, and 200 for an operation that ran whatever its field errors say. Ask for `application/json`, or send no `Accept` at all, and every GraphQL response is a 200 with the errors in the body, which is what pre-specification clients expect. A client that accepts neither gets a 406.

`graphql_app` is what a server mounts. The request/response logic is shared with `graphql_handler`, which moonasgi's `TestClient` drives without a socket — so the endpoint is tested on every backend:

```moonbit
let client = @moonasgi.TestClient::new(@moongql.graphql_handler(schema, resolvers))
let body = @utf8.encode(
  "{\"query\":\"{ user(id: \\\"1\\\") { name } }\"}",
)
let resp = client.post("/graphql", body~, headers=[
  ("content-type", "application/json"),
  ("accept", "application/graphql-response+json"),
])
// resp.status == 200, resp.text() == {"data":{"user":{"name":"Alice"}}}
```

## graphql-transport-ws

`GqlWs` is one WebSocket connection's protocol state, and `recv` maps a client frame to the frames sent back: `connection_init` → `connection_ack`, `subscribe` → a run of `next` then `complete`, `ping` → `pong`. The `connection_init` payload becomes the connection's parameters and reaches every resolver's context under `connectionParams`, so a client hands over a token once instead of on every operation. An operation id is unique among *running* operations — reusing one that has completed is fine, reusing one still running closes with 4409.

The protocol's two timers are state, not threads. This package has no runtime and no clock, so a server drives them by calling `tick` with a millisecond reading of a monotonic clock and sending whatever comes back: the 4408 close when `connection_init` never arrived, or a keep-alive `ping`.

```moonbit
let ws = @moongql.GqlWs::new(schema, resolvers, subs, init_timeout=3000, ping_interval=12000)
let handler = ws.handler()            // a moonasgi WebSocketHandler
ws.tick(now_ms)                       // the server's clock, as often as it likes
```

`graphql_ws_handler` builds a handler whose connection state nothing can reach, for a server with no clock to spare.

## Apollo Federation

A subgraph exposes `_service { sdl }` (its SDL, annotated with the federation directives), the `_entities(representations:)` resolver that turns a `{ __typename, <key> }` reference back into a full object, and `@key` / `@extends` / `@external` markers. Register the entity types and their reference resolvers, then `apply` installs the machinery — the `_Service` type, the `_Any` scalar, the `_Entity` union, and the two root fields — so the ordinary executor answers a federated query:

```moonbit
let fed = @moongql.Federation::new()
fed.entity(name="User", key="id", resolve=(rep, _ctx) => {
  let id = match rep {
    Object(m) => match m.get("id") { Some(String(s)) => s; _ => "" }
    _ => ""
  }
  { "id": id, "name": "User#" + id }.to_json()  // materialise from the key
})
fed.apply(schema, resolvers)

// { _service { sdl } } -> the subgraph SDL with `type User @key(fields: "id")`
// _entities(representations: [{ __typename: "User", id: "7" }]) -> the User object
```

An extended type declares `extends=true` and lists its `external` fields, which render as `extend type ... @key(...)` with `@external` on the borrowed fields — the shape a gateway composes.

### Federation v2

Pass `v2=true` for a Federation v2 subgraph. Its SDL opens with `extend schema @link(...)` onto the federation spec, and the v2 field directives — `@shareable`, `@inaccessible`, `@override(from:)`, `@requires(fields:)`, `@provides(fields:)` — are declared on fields and rendered into the subgraph SDL:

```moonbit
let fed = @moongql.Federation::new(v2=true)
fed.entity(name="Product", key="upc", extends=true, external=["weight"],
  resolve=(rep, _ctx) => {
    // @requires(fields: "weight"): the gateway ships the external weight in the
    // representation, so the resolver can read it to compute the estimate.
    let weight = read_int(rep, "weight")
    { "upc": read_str(rep, "upc"), "shippingEstimate": weight * 2 }.to_json()
  })
fed.shareable("Product", "name")
fed.override_("Product", "price", from="legacy")
fed.requires("Product", "shippingEstimate", fields="weight")
fed.inaccessible("User", "ssn")   // present in the subgraph, hidden from the composed schema
fed.apply(schema, resolvers)
```

`@inaccessible` is the one v2 directive with a runtime effect beyond SDL: the field stays resolvable inside the subgraph but is **hidden from introspection**, so a gateway composing the public schema never sees it.

## Custom directives

Beyond `@skip` / `@include`, a schema can register its own directives. A directive definition carries its valid locations, arguments, repeatability, and an optional `on_field` hook that transforms a resolved field value during execution:

```moonbit
s.directive("prefix",
  locations=["FIELD"],
  args=[("text", @moongql.NonNull(@moongql.Scalar("String")))],
  on_field=Some((value, args) => match (value, args.get("text")) {
    (String(x), Some(String(p))) => (p + x).to_json()
    _ => value
  }))
// { greeting @prefix(text: "Hello, ") } -> "Hello, world"
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

## License

Apache-2.0.
