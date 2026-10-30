///|
/// Every CDN reference in a page is pinned to an exact version: an unpinned one
/// would silently change the page a year from now.
fn pinned(page : String) -> Bool {
  !(page.contains("@latest") || page.contains("@next") || page.contains("@^"))
}

///|
/// The default IDE is the library's own page: one string, no CDN, the endpoint
/// baked in, and the same field linking the documentation has.
test "the gilded page is the default, with nothing fetched from a CDN" {
  assert_eq(gilded.kind == Gilded, true)
  assert_eq(gilded.is_off(), false)
  assert_eq(gilded.title(), "moongql")
  let page = gilded.html(endpoint="/api/graphql")
  assert_eq(page.contains("<title>moongql</title>"), true)
  assert_eq(page.contains("const ENDPOINT = '/api/graphql'"), true)
  assert_eq(page.contains("https://esm.sh"), false)
  assert_eq(page.contains("unpkg.com"), false)
  // the linking, the annotation and the schema drawer are all in the page
  assert_eq(page.contains("data-focus"), true)
  assert_eq(page.contains("data-ann"), true)
  assert_eq(page.contains("__schema"), true)
  assert_eq(page.contains("fetch(ENDPOINT"), true)
}

///|
/// GraphiQL is still served on request, and its page fetches against the
/// endpoint it is told about.
test "the GraphiQL page points its fetcher at the endpoint" {
  assert_eq(graphiql.kind == GraphiQL, true)
  assert_eq(graphiql.is_off(), false)
  let page = graphiql.html(endpoint="/api/graphql")
  assert_eq(page.contains("<title>GraphiQL</title>"), true)
  assert_eq(
    page.contains("createGraphiQLFetcher({ url: '/api/graphql' })"),
    true,
  )
  assert_eq(page.contains("https://esm.sh/graphiql@5.4.0"), true)
  assert_eq(pinned(page), true)
}

///|
/// Apollo Sandbox mounts into a container and is given an absolute endpoint URL,
/// which it needs because it runs in an iframe.
test "the Apollo Sandbox page embeds the sandbox at the endpoint" {
  let page = apollo_sandbox.html(endpoint="/graphql")
  assert_eq(page.contains("<title>Apollo Sandbox</title>"), true)
  assert_eq(page.contains("https://esm.sh/@apollo/sandbox@2.7.4"), true)
  assert_eq(page.contains("initialEndpoint: endpoint"), true)
  assert_eq(page.contains("new URL('/graphql', location.href)"), true)
  // Sandbox carries its own theme, so the page asks for the reader's
  assert_eq(page.contains("prefers-color-scheme: light"), true)
  assert_eq(pinned(page), true)
}

///|
/// Altair reads its endpoint and its subscription endpoint from the page's
/// globals before its own bundle loads.
test "the Altair page hands the endpoint to Altair's globals" {
  let page = altair.html(endpoint="/graphql")
  assert_eq(page.contains("<title>Altair</title>"), true)
  assert_eq(page.contains("window.__ALTAIR_ENDPOINT_URL__ = endpoint"), true)
  assert_eq(
    page.contains("https://unpkg.com/altair-static@8.5.11/build/dist/main.js"),
    true,
  )
  assert_eq(pinned(page), true)
}

///|
/// The subscription socket: derived from the page's own location by default, and
/// spelled out where one was configured.
test "the subscription endpoint is derived, or taken from the configuration" {
  let derived = graphiql.html(endpoint="/graphql")
  assert_eq(derived.contains("subscriptionUrl"), false)
  assert_eq(derived.contains("location.href"), false)
  let wired : Ide = {
    ..altair,
    subscription_endpoint: Some("ws://localhost:12000/graphql"),
  }
  assert_eq(
    wired.html(endpoint="/graphql").contains("ws://localhost:12000/graphql"),
    true,
  )
  assert_eq(
    graphiql.html(endpoint="/graphql").contains("subscriptionUrl"),
    false,
  )
}

///|
/// `off` has no page, and a `GET` without a `?query=` is a 405 rather than an
/// IDE — which is what a production deployment wants.
test "off serves no IDE" {
  assert_eq(off.is_off(), true)
  assert_eq(off.html(endpoint="/graphql"), "")
  assert_eq(off.title(), "")
}

///|
/// The titles, so a page can be told apart in a browser tab.
test "each IDE names itself" {
  assert_eq(gilded.title(), "moongql")
  assert_eq(graphiql.title(), "GraphiQL")
  assert_eq(apollo_sandbox.title(), "Apollo Sandbox")
  assert_eq(altair.title(), "Altair")
}

///|
/// The endpoint serves whichever IDE it is given, as HTML.
test "the endpoint serves the configured IDE" {
  let (s, r) = server_schema()
  for ide in [gilded, graphiql, apollo_sandbox, altair] {
    let client = @moonasgi.TestClient::new(graphql_handler(s, r, ide~))
    let resp = client.get("/graphql")
    assert_eq(resp.status, 200)
    assert_eq(resp.header("content-type"), Some("text/html; charset=utf-8"))
    assert_eq(resp.text(), ide.html(endpoint="/graphql"))
  }
}

///|
/// With `off`, the endpoint still answers queries — only the IDE is gone.
test "the endpoint with no IDE still answers a GET query" {
  let (s, r) = server_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r, ide=off))
  assert_eq(client.get("/graphql").status, 405)
  assert_eq(
    client
    .get("/graphql?query=%7B%20user(id%3A%20%221%22)%20%7B%20name%20%7D%20%7D")
    .text(),
    (
      #|{"data":{"user":{"name":"Alice"}}}
    ),
  )
}
