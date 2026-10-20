///|
/// The GraphQL-over-HTTP surface: media-type negotiation, the status codes that
/// come with `application/graphql-response+json`, `GET` with a `?query=`, and a
/// batched `POST`. `server_wbtest.mbt` holds the schema and the plain-POST tests.

///|
/// `server_schema` plus a mutation root, so a `GET` can be caught trying to run
/// one.
fn http_schema() -> (Schema, Resolvers) {
  let (s, r) = server_schema()
  s.set_mutation("Mutation")
  s.object("Mutation").field("touch", NonNull(Scalar("String")))
  r.field("Mutation", "touch", _info => Json("done"))
  (s, r)
}

///|
/// A `GET` carrying `?query=` executes it, rather than serving the IDE.
test "GET with a query parameter executes it" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.get(
    "/graphql?query=%7B%20user(id%3A%20%221%22)%20%7B%20name%20%7D%20%7D",
  )
  assert_eq(resp.status, 200)
  assert_eq(resp.header("content-type"), Some("application/json"))
  assert_eq(
    resp.text(),
    (
      #|{"data":{"user":{"name":"Alice"}}}
    ),
  )
}

///|
/// `GET` takes its variables as a JSON-encoded parameter, and `+` in the query
/// string still means a space.
test "GET binds variables from the query string" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.get(
    "/graphql?query=query+(%24uid%3A+ID!)+%7B+user(id%3A+%24uid)+%7B+name+%7D+%7D&variables=%7B%22uid%22%3A%221%22%7D",
  )
  assert_eq(
    resp.text(),
    (
      #|{"data":{"user":{"name":"Alice"}}}
    ),
  )
}

///|
/// Every GraphQL parameter is single-valued, so a repeated one keeps the first
/// rather than running whichever came last.
test "GET keeps the first value of a repeated parameter" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.get(
    "/graphql?query=%7B%20user(id%3A%20%221%22)%20%7B%20name%20%7D%20%7D&query=%7B%20user(id%3A%20%221%22)%20%7B%20id%20%7D%20%7D",
  )
  assert_eq(
    resp.text(),
    (
      #|{"data":{"user":{"name":"Alice"}}}
    ),
  )
}

///|
/// A `GET` must stay safe: a mutation over it is a 405, not an execution.
test "GET refuses a mutation" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.get("/graphql?query=mutation%20%7B%20touch%20%7D")
  assert_eq(resp.status, 405)
  assert_eq(resp.text().contains("query operations only"), true)
}

///|
/// A `GET` with no `query` parameter still serves the IDE.
test "GET without a query parameter serves GraphiQL" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.get("/graphql")
  assert_eq(resp.header("content-type"), Some("text/html; charset=utf-8"))
}

///|
/// A client asking for `application/graphql-response+json` gets it back, and with
/// it a 200 for an operation that ran.
test "Accept graphql-response+json is answered in that media type" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.post(
    "/graphql",
    body=request_body(
      (
        #|{ user(id: "1") { name } }
      ),
      Json::null(),
    ),
    headers=[
      ("content-type", "application/json"),
      ("accept", "application/graphql-response+json"),
    ],
  )
  assert_eq(resp.status, 200)
  assert_eq(
    resp.header("content-type"),
    Some("application/graphql-response+json; charset=utf-8"),
  )
  assert_eq(
    resp.text(),
    (
      #|{"data":{"user":{"name":"Alice"}}}
    ),
  )
}

///|
/// Under the GraphQL media type a request error — a document that never ran — is
/// a 400; the same request under `application/json` stays a 200, which is the
/// whole difference between the two media types.
test "a request error is 400 under graphql-response+json and 200 under json" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let body = request_body(
    (
      #|{ user(id: "1") { nope } }
    ),
    Json::null(),
  )
  let spec = client.post("/graphql", body~, headers=[
    ("content-type", "application/json"),
    ("accept", "application/graphql-response+json"),
  ])
  assert_eq(spec.status, 400)
  assert_eq(spec.text().contains("Cannot query field 'nope'"), true)
  let legacy = client.post("/graphql", body~, headers=[
    ("content-type", "application/json"),
    ("accept", "application/json"),
  ])
  assert_eq(legacy.status, 200)
  assert_eq(legacy.text().contains("Cannot query field 'nope'"), true)
}

///|
/// A field error is not a request error: the operation ran, so the status stays
/// 200 even under the GraphQL media type.
test "a field error keeps its 200 under graphql-response+json" {
  let (s, r) = http_schema()
  r.field("Query", "user", _info => raise ResolverError("no such user"))
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.post(
    "/graphql",
    body=request_body(
      (
        #|{ user(id: "1") { name } }
      ),
      Json::null(),
    ),
    headers=[
      ("content-type", "application/json"),
      ("accept", "application/graphql-response+json"),
    ],
  )
  assert_eq(resp.status, 200)
  assert_eq(resp.text().contains("no such user"), true)
}

///|
/// An `Accept` listing several types picks the GraphQL one, and a lone `*/*` is
/// answered as `application/json`.
test "Accept negotiation prefers graphql-response+json" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let body = request_body(
    (
      #|{ user(id: "1") { name } }
    ),
    Json::null(),
  )
  let both = client.post("/graphql", body~, headers=[
    ("content-type", "application/json"),
    ("accept", "application/json;q=0.9, application/graphql-response+json"),
  ])
  assert_eq(
    both.header("content-type"),
    Some("application/graphql-response+json; charset=utf-8"),
  )
  let any = client.post("/graphql", body~, headers=[
    ("content-type", "application/json"),
    ("accept", "*/*"),
  ])
  assert_eq(any.header("content-type"), Some("application/json"))
}

///|
/// A client that accepts neither media type gets a 406.
test "an unacceptable Accept is a 406" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.get("/graphql", headers=[("accept", "text/html")])
  assert_eq(resp.status, 406)
}

///|
/// A POST with no `Content-Type` is refused: the server will not guess what the
/// bytes are.
test "a POST without a content type is a 415" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.post(
    "/graphql",
    body=request_body(
      (
        #|{ user(id: "1") { name } }
      ),
      Json::null(),
    ),
  )
  assert_eq(resp.status, 415)
  assert_eq(resp.text().contains("Content-Type"), true)
}

///|
/// A POST in a media type the endpoint does not read is a 415 too; a charset
/// parameter on `application/json` is fine.
test "content type is matched on the media type alone" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let body = request_body(
    (
      #|{ user(id: "1") { name } }
    ),
    Json::null(),
  )
  let wrong = client.post("/graphql", body~, headers=[
    ("content-type", "text/plain"),
  ])
  assert_eq(wrong.status, 415)
  let charset = client.post("/graphql", body~, headers=[
    ("Content-Type", "application/json; charset=utf-8"),
  ])
  assert_eq(charset.status, 200)
  assert_eq(
    charset.text(),
    (
      #|{"data":{"user":{"name":"Alice"}}}
    ),
  )
}

///|
/// A batched POST — an array of requests — answers with an array of results in
/// the same order.
test "a batch of two operations returns two results" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let one = jobj([
    (
      "query",
      Json(
        (
          #|{ user(id: "1") { name } }
        ),
      ),
    ),
  ])
  let two = jobj([
    (
      "query",
      Json(
        (
          #|{ hero: user(id: "1") { id } }
        ),
      ),
    ),
  ])
  let resp = client.post(
    "/graphql",
    body=@utf8.encode(Json([one, two]).stringify()),
    headers=json_headers(),
  )
  assert_eq(resp.status, 200)
  assert_eq(
    resp.text(),
    (
      #|[{"data":{"user":{"name":"Alice"}}},{"data":{"hero":{"id":"1"}}}]
    ),
  )
}

///|
/// A batch entry that carries no query gets its own error result; the entries
/// beside it still run.
test "a batch reports a bad entry without losing the others" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let batch : Array[Json] = [
    jobj([
      (
        "query",
        Json(
          (
            #|{ user(id: "1") { name } }
          ),
        ),
      ),
    ]),
    jobj([("nothing", Json("here"))]),
  ]
  let resp = client.post(
    "/graphql",
    body=@utf8.encode(Json(batch).stringify()),
    headers=json_headers(),
  )
  assert_eq(resp.status, 200)
  assert_eq(
    resp.text(),
    (
      #|[{"data":{"user":{"name":"Alice"}}},{"errors":[{"message":"No GraphQL query found in request body"}]}]
    ),
  )
}

///|
/// `variables` on a `GET` is a JSON object encoded as a string; text that is not
/// JSON is a bad request, not a query run without its variables.
test "GET rejects a variables parameter that is not JSON" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.get(
    "/graphql?query=%7B%20user(id%3A%20%221%22)%20%7B%20name%20%7D%20%7D&variables=not-json",
  )
  assert_eq(resp.status, 400)
  assert_eq(
    resp.text().contains("'variables' parameter is not valid JSON"),
    true,
  )
}

///|
/// An empty batch has nothing to run and is refused.
test "an empty batch is a 400" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.post(
    "/graphql",
    body=@utf8.encode("[]"),
    headers=json_headers(),
  )
  assert_eq(resp.status, 400)
}

///|
/// `operationName` picks the operation out of a multi-operation document on a
/// `GET`, exactly as it does in a POST body.
test "GET picks the operation named by operationName" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.get(
    "/graphql?query=query+A+%7B+user(id%3A+%221%22)+%7B+name+%7D+%7D+query+B+%7B+hero%3A+user(id%3A+%221%22)+%7B+id+%7D+%7D&operationName=B",
  )
  assert_eq(resp.status, 200)
  assert_eq(
    resp.text(),
    (
      #|{"data":{"hero":{"id":"1"}}}
    ),
  )
}

///|
/// A parameter value may carry a raw `=`, which belongs to the value and not to
/// the split between name and value.
test "GET keeps a raw '=' inside a parameter value" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.get(
    "/graphql?query=query+(%24uid%3A+ID!)+%7B+user(id%3A+%24uid)+%7B+name+%7D+%7D&variables=%7B%22uid%22%3A%221%22%2C%22note%22%3A%22a=b%22%7D",
  )
  assert_eq(resp.status, 200)
  assert_eq(
    resp.text(),
    (
      #|{"data":{"user":{"name":"Alice"}}}
    ),
  )
}

///|
/// A wildcard `Accept` is served rather than refused: both `*/*` and
/// `application/*` mean `application/json` here, and answer 200.
test "a wildcard Accept is served as application/json" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let body = request_body(
    (
      #|{ user(id: "1") { name } }
    ),
    Json::null(),
  )
  for accept in ["*/*", "application/*"] {
    let resp = client.post("/graphql", body~, headers=[
      ("content-type", "application/json"),
      ("accept", accept),
    ])
    assert_eq(resp.status, 200)
    assert_eq(resp.header("content-type"), Some("application/json"))
    assert_eq(
      resp.text(),
      (
        #|{"data":{"user":{"name":"Alice"}}}
      ),
    )
  }
}

///|
/// A body that parses but carries no `query` never reaches execution, so it is a
/// request error rather than a 200 with an empty result.
test "a POST body without a query is a 400" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.post(
    "/graphql",
    body=@utf8.encode(jobj([("variables", jobj([]))]).stringify()),
    headers=json_headers(),
  )
  assert_eq(resp.status, 400)
  assert_eq(resp.text().contains("No GraphQL query found"), true)
}
