///|
/// Encode a GraphQL-over-HTTP POST body as `{ query, variables }` JSON.
fn request_body(query : String, variables : Json) -> Bytes {
  let obj : Json = { "query": Json(query), "variables": variables }
  @utf8.encode(obj.stringify())
}

///|
/// The `content-type` a GraphQL POST must carry, plus the media type this client
/// wants back.
fn headers(accept : String) -> Array[(String, String)] {
  [("content-type", "application/json"), ("accept", accept)]
}

///|
/// The response's `content-type`, for printing.
fn ctype(resp : @moonasgi.TestResponse) -> String {
  match resp.header("content-type") {
    Some(h) => h
    None => "?"
  }
}

///|
/// The GraphQL-over-HTTP transport. `graphql_handler` turns a schema into a
/// moonasgi request handler; moonasgi's `TestClient` drives it over the synchronous
/// seam (no socket).
///
/// A POST carries an `application/json` body — one request, or an array of them
/// for a batch. `Accept` picks the response media type: ask for
/// `application/graphql-response+json` and the status separates a request error
/// (400, the document never ran) from a field error (200); ask for
/// `application/json` and everything is a 200. A GET carries the same fields in
/// its query string, and without a `query` serves the GraphiQL IDE, which
/// `graphiql_html` also renders standalone for any endpoint path.
///
///     moon run examples/22-http-server
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field_args(
    "user",
    [("id", @moongql.NonNull(@moongql.Scalar("ID")))],
    @moongql.Named("User"),
  )
  let u = s.object("User")
  u.field("id", @moongql.NonNull(@moongql.Scalar("ID")))
  u.field("name", @moongql.NonNull(@moongql.Scalar("String")))
  let r = @moongql.Resolvers::new()
  r.field("Query", "user", info => {
    match info.arg("id") {
      String("1") => { "id": "1", "name": "lfanke" }
      _ => Json::null()
    }
  })
  let client = @moonasgi.TestClient::new(@moongql.graphql_handler(s, r))
  let body = request_body("{ user(id: \"1\") { id name } }", Json::null())
  let resp = client.post("/graphql", body~, headers=headers("application/json"))
  println("POST status: \{resp.status}")
  println("content-type: " + ctype(resp))
  println("body: " + resp.text())
  let vars : Json = { "uid": "1" }
  let body2 = request_body(
    "query ($uid: ID!) { user(id: $uid) { name } }", vars,
  )
  println(
    "vars body: " +
    client
    .post("/graphql", body=body2, headers=headers("application/json"))
    .text(),
  )
  // Without a content type the server will not guess what the bytes are.
  println("no content-type: \{client.post("/graphql", body~).status}")
  let spec = client.post(
    "/graphql",
    body~,
    headers=headers("application/graphql-response+json"),
  )
  println("spec media type: " + ctype(spec) + " status: \{spec.status}")
  let bad = client.post(
    "/graphql",
    body=request_body("{ user(id: \"1\") { nope } }", Json::null()),
    headers=headers("application/graphql-response+json"),
  )
  println("request error status: \{bad.status}")
  let batch : Json = [
    { "query": "{ user(id: \"1\") { name } }" },
    { "query": "{ hero: user(id: \"1\") { id } }" },
  ]
  println(
    "batch: " +
    client
    .post(
      "/graphql",
      body=@utf8.encode(batch.stringify()),
      headers=headers("application/json"),
    )
    .text(),
  )
  let got = client.get(
    "/graphql?query=%7B%20user(id%3A%20%221%22)%20%7B%20name%20%7D%20%7D",
  )
  println("GET query: " + got.text())
  let page = client.get("/graphql")
  println("GET status: \{page.status}")
  println("serves GraphiQL: \{page.text().contains("<title>GraphiQL</title>")}")
  let standalone = @moongql.graphiql_html(endpoint="/api/graphql")
  println(
    "fetcher target present: \{standalone.contains("url: '/api/graphql'")}",
  )
}
