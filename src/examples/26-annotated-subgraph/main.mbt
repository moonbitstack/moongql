// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A subgraph written as annotations: `schema.g.mbt` comes from `cmd/gql`, and gives
/// `register`, `register_subscriptions` and `register_federation`.
///
///     moon run src/examples/26-annotated-subgraph
fn main {
  let schema = @moongql.Schema::new()
  let resolvers = @moongql.Resolvers::new()
  let subscribers = @moongql.Subscribers::new()
  register(schema, resolvers)
  register_subscriptions(schema, resolvers, subscribers)
  let federation = @moongql.Federation::new(v2=true)
  register_federation(federation)
  federation.apply(schema, resolvers)
  let ask = (query : String, context : Json) => {
    let answer = @moongql.execute(schema, resolvers, query, context~)
    println(@json.to_json(answer).stringify())
  }
  ask("{ hello }", Json::null())
  ask("{ secret }", Json::null())
  ask("{ secret }", Json::string("ada"))
  ask(
    "{ _entities(representations: [{ __typename: \"User\", id: \"1\" }]) { ... on User { name } } }",
    Json::null(),
  )
  println(federation.sdl(schema).contains("@shareable"))
}
