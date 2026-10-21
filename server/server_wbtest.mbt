///|
/// A `Query { user(id: ID!): User }`, `User { id, name }` schema with a resolver
/// that answers `user(id: "1")`, shared by the endpoint tests.
fn server_schema() -> (@schema.Schema, @exec.Resolvers) {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field_args(
    "user",
    [("id", @schema.NonNull(@schema.Scalar("ID")))],
    Named("User"),
  )
  let u = s.object("User")
  u.field("id", NonNull(@schema.Scalar("ID")))
  u.field("name", NonNull(@schema.Scalar("String")))
  let r = @exec.Resolvers::new()
  r.field("Query", "user", fn(info) {
    match info.arg("id") {
      String("1") => jobj([("id", Json("1")), ("name", Json("Alice"))])
      _ => Json::null()
    }
  })
  (s, r)
}

///|
/// Encode a GraphQL-over-HTTP request body without hand-escaping: build the
/// `{ query, variables }` object as JSON and serialise it.
fn request_body(query : String, variables : Json) -> Bytes {
  @utf8.encode(
    jobj([("query", Json(query)), ("variables", variables)]).stringify(),
  )
}

///|
/// The `content-type` every GraphQL POST must carry.
fn json_headers() -> Array[(String, String)] {
  [("content-type", "application/json")]
}

///|
/// The "can actually run" milestone: drive the moonasgi handler with a real
/// GraphQL POST through moonasgi's `TestClient` (the synchronous seam, no socket)
/// and assert the exact `{ data }` body a client would read.
test "graphql endpoint answers a real POST with the exact data" {
  let (s, r) = server_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let body = request_body(
    (
      #|{ hero: user(id: "1") { id name } }
    ),
    Json::null(),
  )
  let resp = client.post("/graphql", body~, headers=json_headers())
  assert_eq(resp.status, 200)
  assert_eq(resp.header("content-type"), Some("application/json"))
  assert_eq(
    resp.text(),
    (
      #|{"data":{"hero":{"id":"1","name":"Alice"}}}
    ),
  )
}

///|
/// A POST carrying operation variables runs with them bound.
test "graphql endpoint binds request variables" {
  let (s, r) = server_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let vars = jobj([("uid", Json("1"))])
  let body = request_body(
    (
      #|query ($uid: ID!) { user(id: $uid) { name } }
    ),
    vars,
  )
  let resp = client.post("/graphql", body~, headers=json_headers())
  assert_eq(
    resp.text(),
    (
      #|{"data":{"user":{"name":"Alice"}}}
    ),
  )
}

///|
/// A GET on the endpoint serves the GraphiQL IDE as HTML.
test "graphql endpoint serves GraphiQL on GET" {
  let (s, r) = server_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.get("/graphql")
  assert_eq(resp.status, 200)
  assert_eq(resp.header("content-type"), Some("text/html; charset=utf-8"))
  assert_eq(
    resp.text().contains("createGraphiQLFetcher({ url: '/graphql' })"),
    true,
  )
}

///|
/// The GraphiQL page points its fetcher at whatever endpoint path is configured.
test "graphiql html targets the configured endpoint" {
  let html = graphiql_html(endpoint="/api/graphql")
  assert_eq(html.contains("url: '/api/graphql'"), true)
  assert_eq(html.contains("<title>GraphiQL</title>"), true)
}

///|
/// A request to a path the endpoint does not own is a 404 JSON error.
test "graphql endpoint 404s an unknown path" {
  let (s, r) = server_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.get("/other")
  assert_eq(resp.status, 404)
  assert_eq(
    resp.text(),
    (
      #|{"errors":[{"message":"Not Found"}]}
    ),
  )
}

///|
/// A malformed JSON body is a 400 with a transport-level error, not a crash.
test "graphql endpoint rejects a non-JSON body" {
  let (s, r) = server_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.post(
    "/graphql",
    body=@utf8.encode("not json {"),
    headers=json_headers(),
  )
  assert_eq(resp.status, 400)
  assert_eq(
    resp.text(),
    (
      #|{"errors":[{"message":"Request body is not valid JSON"}]}
    ),
  )
}

///|
/// A DELETE (or any non-GET/POST method) on the endpoint is a 405.
test "graphql endpoint 405s an unsupported method" {
  let (s, r) = server_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.delete("/graphql")
  assert_eq(resp.status, 405)
}
