///|
/// Drive the ASGI application the way a server does: a scope, the events the
/// request body arrives in, and a place to collect what it answers. This is the
/// transport's own interface, so a test here exercises the headers, the status and
/// the bytes a client actually reads.
fn demo() -> (@schema.Schema, @exec.Resolvers) {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("hello", NonNull(@schema.Scalar("String")))
  let r = @exec.Resolvers::new()
  r.field("Query", "hello", fn(_info) { Json("world") })
  (s, r)
}

///|
fn http_scope(
  verb : String,
  path : String,
  headers : Array[(String, String)],
) -> @spec.Scope {
  Http(@spec.HttpScope::new(http_method=verb, path~, headers~))
}

///|
async fn call_app(
  app : @moonasgi.AsgiApp,
  scope : @spec.Scope,
  body : Bytes?,
) -> Array[@spec.Event] {
  let out : Array[@spec.Event] = []
  let mut sent = false
  let receive : @moonasgi.Receive = () => {
    if sent {
      @spec.Event::HttpDisconnect
    } else {
      sent = true
      match body {
        Some(b) => @spec.Event::HttpRequest(body=b, more_body=false)
        None => @spec.Event::HttpDisconnect
      }
    }
  }
  let send : @moonasgi.Send = e => out.push(e)
  app(scope, receive, send)
  out
}

///|
fn body_of(events : Array[@spec.Event]) -> String {
  let sb = StringBuilder()
  for e in events {
    match e {
      @spec.Event::HttpResponseBody(body~, ..) =>
        sb.write_string(@utf8.decode_lossy(body[:]))
      _ => ()
    }
  }
  sb.to_string()
}

///|
fn status_of(events : Array[@spec.Event]) -> Int32 {
  for e in events {
    match e {
      @spec.Event::HttpResponseStart(status~, ..) => return status
      _ => ()
    }
  }
  0
}

///|
async test "app: a POST runs the async engine and answers one JSON body" {
  let (s, r) = demo()
  let app = graphql_app(s, r)
  let out = call_app(
    app,
    http_scope("POST", "/graphql", [("accept", "application/json")]),
    Some(@utf8.encode("{\"query\":\"{ hello }\"}")),
  )
  assert_eq(status_of(out), 200)
  assert_eq(body_of(out), "{\"data\":{\"hello\":\"world\"}}")
}

///|
async test "app: a client that asks for multipart gets the payloads as parts" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("hello", NonNull(@schema.Scalar("String")))
  q.field("user", @schema.Named("User"))
  let u = s.object("User")
  u.field("id", NonNull(@schema.Scalar("ID")))
  u.field("name", NonNull(@schema.Scalar("String")))
  let r = @exec.Resolvers::new()
  r.field("Query", "hello", fn(_info) { Json("world") })
  r.field("Query", "user", fn(_info) {
    let m : Map[String, Json] = Map([])
    m["id"] = Json("1")
    m["name"] = Json("Alice")
    Json(m)
  })
  let app = graphql_app(s, r)
  let out = call_app(
    app,
    http_scope("POST", "/graphql", [
      ("accept", "multipart/mixed; boundary=\"gql\"; deferSpec=20220824"),
    ]),
    Some(@utf8.encode("{\"query\":\"{ user { id ... @defer { name } } }\"}")),
  )
  assert_eq(status_of(out), 200)
  let body = body_of(out)
  assert_eq(body.contains("--gql"), true)
  assert_eq(
    body.contains("{\"data\":{\"user\":{\"id\":\"1\"}},\"hasNext\":true}"),
    true,
  )
  assert_eq(
    body.contains(
      "{\"incremental\":[{\"data\":{\"name\":\"Alice\"},\"path\":[\"user\"]}],\"hasNext\":false}",
    ),
    true,
  )
  assert_eq(body.contains("--gql--"), true)
}

///|
async test "app: a request to another path is a 404" {
  let (s, r) = demo()
  let app = graphql_app(s, r)
  let out = call_app(
    app,
    http_scope("POST", "/elsewhere", [("accept", "application/json")]),
    Some(@utf8.encode("{\"query\":\"{ hello }\"}")),
  )
  assert_eq(status_of(out), 404)
}
