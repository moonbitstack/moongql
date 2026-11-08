---
name: moongql
description: "Build a GraphQL API in MoonBit — schema, resolvers, validation, execution, subscriptions, Apollo Federation, GraphQL over HTTP and graphql-transport-ws, plus an MCP tool surface over the same schema. Use it when a task needs a GraphQL server or client, a typed schema written in code or in SDL, or a schema exposed to an agent."
---

# moongql

A GraphQL server written in code, without runtime reflection: the schema is built
with calls, resolvers are registered by `"Type.field"`, and the executor walks the
document against both. Everything the specification fixes is here — validation,
non-null propagation, introspection, subscriptions, incremental delivery — plus
Apollo Federation and an HTTP transport.

```bash
moon add moonbitstack/moongql
```

The parts you import by what you need:

| Package | What it holds |
|:--|:--|
| `moonbitstack/moongql` | Everything, re-exported — start here |
| `moonbitstack/moongql/schema` | Types and SDL, when only the schema is needed |
| `moonbitstack/moongql/exec` | Execution alone, for a server whose transport is yours |
| `moonbitstack/moongql/server` | `graphql_app`, the IDEs, the WebSocket protocol |
| `moonbitstack/moongql/mcp` | The same schema as Model Context Protocol tools |

## A schema, a resolver, an answer

```moonbit
let schema = @moongql.Schema::new()
let query = schema.object("Query")
query.field("hello", NonNull(Scalar("String")))
query.field_args(
  "user",
  [("id", NonNull(Scalar("ID")))],
  Named("User"),
)
let user = schema.object("User")
user.field("id", NonNull(Scalar("ID")))
user.field("name", NonNull(Scalar("String")))
let resolvers = @moongql.Resolvers::new()
resolvers.field("Query", "hello", fn(_info) { Json("world") })
resolvers.field("Query", "user", fn(info) -> Json raise @moongql.FieldError {
  let id : String = info.read("id")
  Json({ "id": Json(id), "name": Json("Alice") })
})
let answer = @moongql.execute(schema, resolvers, "{ hello user(id: \"1\") { name } }")
assert_eq(
  answer.stringify(),
  "{\"data\":{\"hello\":\"world\",\"user\":{\"name\":\"Alice\"}}}",
)
```

A resolver that waits is registered with `field_async`; the rest of the call is
unchanged, and `execute_async` runs it.

## Serving it

`graphql_app` lifts the handler onto the ASGI seam, which is what `mooncat` binds:

```moonbit
let app = @moongql.graphql_app(schema, resolvers)
// @mooncat.serve(app, port=12000)
```

A `GET` without a `?query=` serves a page: the library's own IDE by default, or
`@moongql.graphiql`, `@moongql.apollo_sandbox`, `@moongql.altair`, the schema
reference at `@moongql.reference`, or `@moongql.off`. The reference is rendered
from the schema the handler already holds — a documentation page, not an editor:

```moonbit
let app = @moongql.graphql_app(schema, resolvers, ide=@moongql.reference)
```

## Incremental delivery

`@defer` on a fragment and `@stream` on a list field postpone work until the first
payload has gone out. Each payload carries the `pending` entries the request
opened, the `incremental` results that fulfil them, and the ids that are now
`completed`:

```moonbit
let payloads = @moongql.execute_incremental(
  schema,
  resolvers,
  "{ user(id: \"1\") { id ... @defer { name } } }",
)
assert_eq(payloads.length(), 2)
assert_eq(payloads[1].stringify().contains("\"completed\""), true)
```

Over HTTP a client asks for it with `Accept: multipart/mixed`, and `graphql_app`
writes one part per payload. A client that does not ask receives one JSON body, in
which `@defer` and `@stream` mean what they would have meant inline.

## The same schema as agent tools

`mcp` offers every root field as a Model Context Protocol tool: the field's name is
the tool's name, its arguments become the tool's input schema, and what it answers
is the field's value. Mutations are off unless they are asked for, and a
`graphql_query` tool runs a document the agent wrote:

```moonbit
let server = @mcp.Mcp::of(schema=schema, resolvers=resolvers).server(name="shop")
// mount it: server.to_asgi(), or server.run_stdio()
```

`@mcp.exposure` is the preset — no mutations, two levels of selection, twelve
fields wide. Pass your own `Exposure` to change any of it, including a `prefix` that
namespaces the tools when one program serves two schemas.

## Rules that catch people out

- A resolver is looked up by `"Type.field"`; a field with no entry falls back to
  reading that key off the parent value, which is what makes nested objects work.
- `Int` is GraphQL's 32-bit `Int`. `Int64` is a custom scalar that serialises as a
  string; register it with `Schema::scalar` under the name `Int64` if a document is
  to select it.
- A field declared `NonNull` that comes back null nulls its parent and records an
  error; the parent chain stops at the nearest nullable position.
- `execute_incremental` is asynchronous even when every resolver is synchronous:
  awaiting a piece of postponed work is what the payload sequence is.
- Validation runs inside `execute`. Run `@moongql.validate` yourself only when you
  want the errors before executing.
