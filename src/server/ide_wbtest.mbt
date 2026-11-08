///|
/// Every CDN reference in a page is pinned to an exact version: an unpinned one
/// would silently change the page a year from now.
fn pinned(page : String) -> Bool {
  !(page.contains("@latest") || page.contains("@next") || page.contains("@^"))
}

///|
/// The default IDE is the library's own page: one string, no CDN, the endpoint
/// baked in, and the same field linking the documentation has.
test "the MoonQL page is the default, with nothing fetched from a CDN" {
  assert_eq(site.kind == Site, true)
  assert_eq(site.is_off(), false)
  assert_eq(site.title(), "MoonQL")
  let page = site.html(endpoint="/api/graphql")
  assert_eq(page.contains("<title>MoonQL</title>"), true)
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
  assert_eq(site.title(), "MoonQL")
  assert_eq(graphiql.title(), "GraphiQL")
  assert_eq(apollo_sandbox.title(), "Apollo Sandbox")
  assert_eq(altair.title(), "Altair")
  assert_eq(reference.title(), "Schema reference")
}

///|
/// The endpoint serves whichever IDE it is given, as HTML.
test "the endpoint serves the configured IDE" {
  let (s, r) = server_schema()
  for ide in [site, graphiql, apollo_sandbox, altair, reference] {
    let client = @moonasgi.TestClient::new(graphql_handler(s, r, ide~))
    let resp = client.get("/graphql")
    assert_eq(resp.status, 200)
    assert_eq(resp.header("content-type"), Some("text/html; charset=utf-8"))
    // the reference page is the one that reads the schema the handler holds
    assert_eq(resp.text(), ide.html(endpoint="/graphql", schema=s))
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

///|
/// A schema with one of everything, so the reference page has something to
/// document: a described object, a field with arguments and a default, a
/// deprecated field, a second object it links to, an enum, a union, an input and
/// a custom scalar.
fn reference_schema() -> @schema.Schema {
  let s = @schema.Schema::new()
  let q = s.object("Query", description="What a caller can ask for.")
  q.field("hello", NonNull(Scalar("String")), description="A greeting.")
  q.field_args(
    "user",
    [("id", NonNull(Scalar("ID")))],
    Named("User"),
    description="One person, by id.",
  )
  q.field_args(
    "users",
    [("first", Scalar("Int"))],
    NonNull(ListOf(NonNull(Named("User")))),
    defaults=[("first", Json(3))],
  )
  q.field(
    "old",
    Scalar("String"),
    deprecation_reason="use hello <instead>",
    description="Retired.",
  )
  let u = s.object("User")
  u.field("id", NonNull(Scalar("ID")))
  u.field("role", NonNull(Named("Role")))
  u.field("tags", ListOf(Scalar("String")))
  s.enum_("Role", ["ADMIN", "GUEST"], description="What a person may do.")
  s.union("Found", ["User"])
  s.scalar("Timestamp", description="Milliseconds since the epoch.")
  let input = s.input("Filter")
  input.field("name", Scalar("String"))
  s.set_mutation("Mutation")
  s.object("Mutation").field("ping", Scalar("String"))
  s
}

///|
/// The reference page is rendered from the schema: one section per type, the
/// fields of each with their arguments and defaults, deprecations marked, and the
/// types a field returns linked to their own section.
test "the reference page is built from the schema it is given" {
  assert_eq(reference.title(), "Schema reference")
  assert_eq(reference.is_off(), false)
  let page = reference.html(endpoint="/api/graphql", schema=reference_schema())
  assert_eq(page.contains("<title>Schema reference</title>"), true)
  assert_eq(page.contains("/api/graphql"), true)
  // every type has a section with an anchor
  for
    name in [
      "Query", "User", "Mutation", "Role", "Found", "Timestamp", "Filter",
    ] {
    assert_eq(page.contains("id=\"" + name + "\""), true)
  }
  // the root types come first in the rail, then the rest
  assert_eq(page.contains(">Root</h3>"), true)
  assert_eq(page.contains("href=\"#User\">User</a>"), true)
  // fields carry their arguments, defaults, descriptions and deprecations
  assert_eq(page.contains("<span class=\"aname\">id</span>"), true)
  assert_eq(page.contains("= </span><span class=\"def\">3</span>"), true)
  assert_eq(page.contains("What a caller can ask for."), true)
  assert_eq(page.contains("Deprecated: use hello &lt;instead&gt;"), true)
  // a field links to the type it returns
  assert_eq(page.contains("href=\"#User\">User</a>"), true)
  assert_eq(page.contains("href=\"#Role\">Role</a>"), true)
}

///|
/// Nothing a schema carries can end an element early: a description is text, not
/// markup.
test "the reference page escapes what a description carries" {
  let s = @schema.Schema::new()
  s
  .object("Query", description="<script>alert(1)</script> & \"quoted\"")
  .field("a", Scalar("String"))
  let page = reference.html(schema=s)
  assert_eq(page.contains("<script>alert(1)</script>"), false)
  assert_eq(page.contains("&lt;script&gt;alert(1)&lt;/script&gt;"), true)
  assert_eq(page.contains("&amp; &quot;quoted&quot;"), true)
}

///|
/// Served without a schema, the page says so instead of drawing an empty
/// document.
test "the reference page without a schema says it has none" {
  let page = reference.html(endpoint="/graphql")
  assert_eq(page.contains("No schema to show"), true)
  assert_eq(page.contains("<title>Schema reference</title>"), true)
}

///|
/// The page uses the site's own scrollbars rather than the browser's, and keeps
/// the standard properties off the page element so the custom ones survive in
/// Chrome.
test "the reference page styles both scrollbars and never overrides the custom one" {
  let page = reference.html(schema=reference_schema())
  assert_eq(page.contains("::-webkit-scrollbar"), true)
  assert_eq(page.contains("@supports not selector(::-webkit-scrollbar)"), true)
  assert_eq(page.contains("html.at-top::-webkit-scrollbar-thumb"), true)
  assert_eq(page.contains("nav.rail:hover::-webkit-scrollbar-thumb"), true)
  // the standard properties appear only after the fallback block opens: put
  // outside it, they would replace the custom bars in Chrome
  let fallback = page.find("@supports not selector(::-webkit-scrollbar)")
  let width = page.find("scrollbar-width")
  assert_eq(fallback is Some(_), true)
  match (fallback, width) {
    (Some(f), Some(w)) => assert_eq(w > f, true)
    _ => assert_eq(false, true)
  }
}
