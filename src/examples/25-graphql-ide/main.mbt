///|
/// The IDE a `GET` on the GraphQL endpoint serves. `graphql_handler` takes an
/// `Ide`: the default is GraphiQL, Apollo Sandbox and Altair are the other two,
/// and `off` serves nothing (a `GET` without a `?query=` is a 405). Each page
/// loads its IDE from a CDN at a pinned version and points it at the endpoint.
///
///     moon run src/examples/25-graphql-ide
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query", description="The root query.")
  q.field_args("user", [("id", NonNull(Scalar("ID")))], Named("User"))
  q.field("events", NonNull(Named("User")))
  s.set_subscription("Query")
  let u = s.object("User")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", NonNull(Scalar("String")))
  let r = @moongql.Resolvers::new()
  r.field("Query", "user", fn(info) {
    match info.arg("id") {
      String(id) => { "id": id, "name": "lfanke" }
      _ => Json::null()
    }
  })
  for ide in [@moongql.graphiql, @moongql.apollo_sandbox, @moongql.altair] {
    let client = @moonasgi.TestClient::new(@moongql.graphql_handler(s, r, ide~))
    let page = client.get("/graphql")
    println(
      "\{ide.title()}: \{page.status} \{page.header("content-type").unwrap_or("?")}, \{page.text().length()} bytes",
    )
    println("  targets /graphql: \{page.text().contains("/graphql")}")
  }
  // The subscription socket: left unset each page derives one from the page's
  // own location; set, it is spelled out.
  let wired : @moongql.Ide = {
    ..@moongql.graphiql,
    subscription_endpoint: Some("ws://localhost:12000/graphql"),
  }
  println(
    "subscription endpoint named: \{wired.html(endpoint="/graphql").contains("ws://localhost:12000/graphql")}",
  )
  let off = @moonasgi.TestClient::new(
    @moongql.graphql_handler(s, r, ide=@moongql.off),
  )
  println("off: a GET without a query is \{off.get("/graphql").status}")
  println(
    "off still answers a query: \{off.get("/graphql?query=%7Buser(id%3A%221%22)%7Bname%7D%7D").text()}",
  )
}
