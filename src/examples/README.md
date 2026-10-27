# Examples

A tour of the public `@moongql` API. Each folder is a runnable `main` package that
builds a schema in code and exercises one feature end to end, printing the real
result so running it proves the feature works.

```bash
moon run examples/00-hello
```

| # | Example | What it teaches | Key API |
| --- | --- | --- | --- |
| 00 | [`hello`](00-hello/) | Define a one-type schema, register a resolver, execute a query and print the JSON result | `Schema::new`, `Schema::object`, `ObjectType::field`, `Resolvers`, `execute` |
| 01 | [`sdl`](01-sdl/) | Declare every kind of type — object, input, interface, enum, union, scalar — and print the schema as SDL | `Schema::input/interface/enum_/union/scalar`, `ObjectType::implements`, `to_sdl` |
| 02 | [`arguments`](02-arguments/) | Field arguments with defaults; omitted vs supplied vs explicit-null | `ObjectType::field_args`, `defaults`, `ResolveInfo::arg` |
| 03 | [`variables`](03-variables/) | Operation variables bound into an argument, field aliases, variable defaults | `execute` `variables`, `$var`, `alias:` |
| 04 | [`fragments`](04-fragments/) | Named fragment spreads and inline fragments merged into one selection | `...Frag`, `... on Type` |
| 05 | [`directives`](05-directives/) | The built-in `@skip` / `@include`, one query text, two shapes | `@skip(if:)`, `@include(if:)` |
| 06 | [`custom-directives`](06-custom-directives/) | A schema-defined executable directive with an `on_field` hook | `Schema::directive`, `on_field` |
| 07 | [`interfaces`](07-interfaces/) | Interface types and `implements`, concrete type via `__typename` | `Schema::interface`, `ObjectType::implements` |
| 08 | [`unions`](08-unions/) | Union members selected through inline fragments, `possibleTypes` | `Schema::union`, `__type` |
| 09 | [`enums`](09-enums/) | Enum types in SDL, as leaf values, and in introspection | `Schema::enum_`, `enumValues` |
| 10 | [`scalars`](10-scalars/) | Custom scalars with `serialize` / `parse_value` and a `@specifiedBy` URL | `Schema::scalar`, `spec_url`, `specifiedByURL` |
| 11 | [`introspection`](11-introspection/) | `__typename`, `__type`, `__schema` and walking a wrapped type via `ofType` | `__schema`, `__type`, `ofType` |
| 12 | [`errors`](12-errors/) | Non-null null-bubbling, `ResolverError`, and error `extensions` | `ResolverError`, `ResolverErrorExt` |
| 13 | [`mutations`](13-mutations/) | A mutation root type whose resolver reads an input object and mutates a store | `Schema::set_mutation`, `Schema::input` |
| 14 | [`context`](14-context/) | `context` / `root_value` threaded to resolvers, `operation_name` selection | `execute` `context`/`root_value`/`operation_name`, `ResolveInfo` |
| 15 | [`validation`](15-validation/) | Static validation before execution: unknown field, undefined variable, unknown fragment | `parse`, `validate`, `GqlError` |
| 16 | [`parsing`](16-parsing/) | The lexer, parser and AST round-trip underneath `execute` | `tokenize`, `parse`, `Document::to_query`, `TypeRef`/`Value::to_query`, `GqlSyntaxError` |
| 17 | [`deprecation`](17-deprecation/) | `@deprecated` fields and enum values via `includeDeprecated` introspection | `deprecation_reason`, `enum_` `deprecated`, `isDeprecated` |
| 18 | [`dataloader`](18-dataloader/) | Batched, deduplicated key loading that collapses N+1 fetches | `DataLoader::new/load/dispatch/get/prime/clear/load_now/load_many` |
| 19 | [`subscriptions`](19-subscriptions/) | A subscription stream at the in-process seam, and the typed source result | `Subscribers`, `execute_subscription`, `create_source_event_stream`, `SubscriptionResult` |
| 20 | [`federation`](20-federation/) | An Apollo Federation v2 subgraph: `@key` entities, `_service`, `_entities` | `Federation::new/entity/shareable/override_/requires/provides/inaccessible/apply/sdl` |
| 21 | [`schema-directives`](21-schema-directives/) | Applied type-system directives and by-name schema reflection | `apply_*_directive`, `AppliedDirective`, `type_has_directive`, `*_by_name`, `named_base` |
| 22 | [`http-server`](22-http-server/) | GraphQL over HTTP through the moonasgi handler and GraphiQL page | `graphql_handler`, `graphiql_html`, `@moonasgi.TestClient` |
| 23 | [`graphql-ws`](23-graphql-ws/) | Subscriptions over `graphql-transport-ws` at the synchronous frame seam | `graphql_ws_handler`, `on_receive` |

`00-hello` declares a `Query` type with two scalar fields, backs each with a
resolver keyed by `"Type.field"`, then runs `{ greeting luckyNumber }` through
`execute` and prints the `{ data }` response:

```
{"data":{"greeting":"qwq from moongql","luckyNumber":233}}
```
