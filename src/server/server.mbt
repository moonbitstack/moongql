///|
/// The HTTP surface: an in-browser IDE page plus the GraphQL endpoint, wired as a
/// `moonasgi` handler so moongql plugs straight into `mooncat` (or any server that
/// binds the ASGI seam). It follows the GraphQL-over-HTTP specification: a `POST`
/// carries an `application/json` request body, a `GET` carries the same fields in
/// its query string (query operations only) or serves the IDE, and the response
/// media type is negotiated from `Accept`. Everything rides the synchronous
/// `run_http_app` core moonasgi exposes, so the whole thing is testable on every
/// backend through `TestClient` without an async runtime.

///|
/// The GraphiQL IDE page, wired to fetch against `endpoint`. This is what
/// `graphiql` (the default `Ide`) serves; the page itself is built in `ide.mbt`.
pub fn graphiql_html(endpoint~ : String = "/graphql") -> String {
  graphiql.html(endpoint~)
}

///|
/// An `application/json` error reply carrying a single `errors` entry, for the
/// transport-level failures (wrong path, wrong method, an unacceptable or missing
/// media type, an unreadable body) that stop a request before the executor runs.
fn error_response(status : Int32, message : String) -> @moonasgi.Response {
  let errs : Array[Json] = [jobj([("message", Json(message))])]
  @moonasgi.Response::json(status~, jobj([("errors", Json(errs))]))
}

///|
/// The media type a GraphQL response is written as. `GraphqlJson` is the
/// GraphQL-over-HTTP media type, under which the status code carries meaning: a
/// request error answers 400, an operation that ran answers 200 whatever its field
/// errors say. `AppJson` is the legacy `application/json` older clients speak,
/// where every GraphQL response is a 200.
priv enum Wire {
  AppJson
  GraphqlJson
}

///|
/// An ASCII upper-case code point folded to lower case.
fn fold_case(c : Int32) -> Int32 {
  if c >= 65 && c <= 90 {
    c + 32
  } else {
    c
  }
}

///|
/// ASCII-case-insensitive equality, for the header names and media types HTTP
/// does not fix a case for.
fn ci_eq(a : String, b : String) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    if fold_case(a[i].to_int()) != fold_case(b[i].to_int()) {
      return false
    }
  }
  true
}

///|
/// Split `s` on every occurrence of `sep`, keeping empty pieces.
fn split_on(s : String, sep : Char) -> Array[String] {
  let out : Array[String] = []
  let cur = StringBuilder()
  for c in s {
    if c == sep {
      out.push(cur.to_string())
      cur.reset()
    } else {
      cur.write_char(c)
    }
  }
  out.push(cur.to_string())
  out
}

///|
/// Strip leading and trailing spaces and tabs.
fn trim_ws(s : String) -> String {
  let mut a = 0
  let mut b = s.length()
  while a < b && (s[a].to_int() == 32 || s[a].to_int() == 9) {
    a = a + 1
  }
  while b > a && (s[b - 1].to_int() == 32 || s[b - 1].to_int() == 9) {
    b = b - 1
  }
  s[a:b].to_owned()
}

///|
/// A media type with its parameters dropped: `application/json; charset=utf-8`
/// is `application/json`.
fn media_type(s : String) -> String {
  trim_ws(split_on(s, ';')[0])
}

///|
/// Read a request header by name, ignoring case.
fn req_header(req : @moonasgi.Request, name : String) -> String? {
  for pair in req.headers {
    if ci_eq(pair.0, name) {
      return Some(pair.1)
    }
  }
  None
}

///|
/// Choose the response media type from an `Accept` header, or `None` when the
/// client accepts neither GraphQL media type and the request is a 406. A client
/// that sends no `Accept` gets `application/json`, which is what every
/// pre-specification client expects.
fn wire_of(accept : String?) -> Wire? {
  let header = match accept {
    None => return Some(AppJson)
    Some(h) => h
  }
  let mut json = false
  for entry in split_on(header, ',') {
    let m = media_type(entry)
    if ci_eq(m, "application/graphql-response+json") {
      return Some(GraphqlJson)
    }
    if ci_eq(m, "application/json") || m == "*/*" || m == "application/*" {
      json = true
    }
  }
  if json {
    Some(AppJson)
  } else {
    None
  }
}

///|
/// The `content-type` a response under `wire` carries.
fn wire_content_type(wire : Wire) -> String {
  match wire {
    AppJson => "application/json"
    GraphqlJson => "application/graphql-response+json; charset=utf-8"
  }
}

///|
/// The status a GraphQL response gets. Under `application/json` every response is
/// a 200 and the client reads `errors`; under the GraphQL media type a response
/// with no `data` entry is a request error — the operation never ran — which the
/// specification maps to 400. A batch is neither, and answers 200.
fn wire_status(wire : Wire, body : Json) -> Int32 {
  match wire {
    AppJson => 200
    GraphqlJson =>
      match body {
        Object(m) => if m.get("data") is Some(_) { 200 } else { 400 }
        _ => 200
      }
  }
}

///|
/// Serialise a GraphQL response body under the negotiated media type.
fn wire_response(wire : Wire, body : Json) -> @moonasgi.Response {
  @moonasgi.Response::new(
    wire_status(wire, body),
    [("content-type", wire_content_type(wire))],
    @utf8.encode(body.stringify()),
  )
}

///|
/// Percent-decode one query-string component, with `+` meaning a space as
/// `application/x-www-form-urlencoded` requires.
fn url_decode(s : String) -> String {
  let spaced = StringBuilder()
  for c in s {
    spaced.write_char(if c == '+' { ' ' } else { c })
  }
  @utf8.decode_lossy(@moonasgi.percent_decode(spaced.to_string())[:])
}

///|
/// Decode a URL query string into its parameters. A repeated name keeps the first
/// value, since every GraphQL request parameter is single-valued.
fn query_params(qs : Bytes) -> Map[String, String] {
  let out : Map[String, String] = Map([])
  for pair in split_on(@utf8.decode_lossy(qs[:]), '&') {
    if pair == "" {
      continue
    }
    let cut = split_on(pair, '=')
    let name = url_decode(cut[0])
    let value = if cut.length() > 1 {
      url_decode(cut[1:].join("="))
    } else {
      ""
    }
    if out.get(name) is None {
      out[name] = value
    }
  }
  out
}

///|
/// Pull `query`, `variables` and `operationName` out of a parsed request body.
/// A missing or non-string `query` yields `None`; `variables` defaults to empty
/// and `operationName` to `None`, matching the GraphQL-over-HTTP request shape.
fn parse_request(body : Json) -> (String?, Map[String, Json], String?) {
  match body {
    Object(m) => {
      let query = match m.get("query") {
        Some(String(q)) => Some(q)
        _ => None
      }
      let variables = match m.get("variables") {
        Some(Object(v)) => v
        _ => Map([])
      }
      let operation_name = match m.get("operationName") {
        Some(String(n)) => Some(n)
        _ => None
      }
      (query, variables, operation_name)
    }
    _ => (None, Map([]), None)
  }
}

///|
/// Run one GraphQL request out of a parsed body, or report the request-level
/// failure that stops it.
fn run_body(
  schema : @schema.Schema,
  resolvers : @exec.Resolvers,
  body : Json,
) -> Result[Json, String] {
  let (query, variables, operation_name) = parse_request(body)
  match query {
    None => Err("No GraphQL query found in request body")
    Some(q) =>
      Ok(@exec.execute(schema, resolvers, q, variables~, operation_name?))
  }
}

///|
/// Serve a `GET` carrying a `?query=`. The specification allows only query
/// operations here, a `GET` being safe and idempotent, so a mutation or
/// subscription is a 405; the parameters are the request body's fields spelled out
/// in the URL, with `variables` a JSON object encoded as a string.
fn get_request(
  schema : @schema.Schema,
  resolvers : @exec.Resolvers,
  wire : Wire,
  params : Map[String, String],
  query : String,
) -> @moonasgi.Response {
  let operation_name : String? = params.get("operationName")
  let variables : Map[String, Json] = match params.get("variables") {
    None => Map([])
    Some(text) =>
      match
        (@json.parse(text) catch {
          _ =>
            return error_response(
              400, "The 'variables' parameter is not valid JSON",
            )
        }) {
        Object(m) => m
        _ => Map([])
      }
  }
  // A parse or validation failure falls through to `execute`, which reports it
  // once in the response body rather than as a transport error.
  if operation_type_of(schema, query, operation_name) is Ok(op) &&
    !(op is Query) {
    return error_response(
      405, "GET supports query operations only; use POST for a mutation or subscription",
    )
  }
  wire_response(
    wire,
    @exec.execute(schema, resolvers, query, variables~, operation_name?),
  )
}

///|
/// Serve a `POST`: the media type must be `application/json`, and the body is
/// either one request object or an array of them, answered by an array of results
/// in the same order. Batching is outside the specification, which describes one
/// request per POST; it is served here because clients that coalesce queries send
/// it.
fn post_request(
  schema : @schema.Schema,
  resolvers : @exec.Resolvers,
  wire : Wire,
  req : @moonasgi.Request,
) -> @moonasgi.Response {
  match req_header(req, "content-type") {
    None =>
      return error_response(
        415, "POST requires a Content-Type of application/json",
      )
    Some(ct) =>
      if !ci_eq(media_type(ct), "application/json") {
        return error_response(
          415,
          "Unsupported Content-Type '" + media_type(ct) + "'",
        )
      }
  }
  let body = @json.parse(@utf8.decode_lossy(req.body[:])) catch {
    _ => return error_response(400, "Request body is not valid JSON")
  }
  match body {
    Array(items) => {
      if items.is_empty() {
        return error_response(400, "GraphQL batch must not be empty")
      }
      let results : Array[Json] = []
      for item in items {
        results.push(
          match run_body(schema, resolvers, item) {
            Ok(r) => r
            Err(m) => @exec.build_response(None, [@lang.GqlError::msg(m)])
          },
        )
      }
      wire_response(wire, Json(results))
    }
    _ =>
      match run_body(schema, resolvers, body) {
        Ok(r) => wire_response(wire, r)
        Err(m) => error_response(400, m)
      }
  }
}

///|
/// Build the moonasgi request handler for a schema and its resolvers, following
/// the GraphQL-over-HTTP specification.
///
/// A `POST` on `path` executes an `application/json` body — one request object, or
/// an array of them for a batch. A `GET` with a `?query=` executes a query
/// operation (only a query: a mutation there is a 405); a `GET` without one serves
/// the IDE `ide` names (GraphiQL by default, or `off` for a 405). The response
/// media type is negotiated from `Accept`: a client asking for
/// `application/graphql-response+json` gets it, and with it the status codes that
/// separate a request error (400) from a field error (200); anything else gets
/// `application/json` and a 200. Lift it onto an `AsgiApp` with `graphql_app`, or
/// drive it directly with moonasgi's `TestClient`.
pub fn graphql_handler(
  schema : @schema.Schema,
  resolvers : @exec.Resolvers,
  path~ : String = "/graphql",
  ide~ : Ide = graphiql,
) -> @moonasgi.Handler {
  fn(req : @moonasgi.Request) -> @moonasgi.Response {
    if req.path != path {
      return error_response(404, "Not Found")
    }
    let wire = match wire_of(req_header(req, "accept")) {
      Some(w) => w
      None =>
        return error_response(
          406, "Not Acceptable: this endpoint serves application/graphql-response+json or application/json",
        )
    }
    match req.http_method {
      "GET" | "HEAD" => {
        let params = query_params(req.query_string)
        match params.get("query") {
          Some(q) => get_request(schema, resolvers, wire, params, q)
          None =>
            if ide.is_off() {
              error_response(405, "Method Not Allowed")
            } else {
              @moonasgi.Response::new(
                200,
                [("content-type", "text/html; charset=utf-8")],
                @utf8.encode(ide.html(endpoint=path)),
              )
            }
        }
      }
      "POST" => post_request(schema, resolvers, wire, req)
      _ => error_response(405, "Method Not Allowed")
    }
  }
}

///|
/// Lift the GraphQL handler onto the load-bearing `AsgiApp` a server binds to.
/// This is what `mooncat` (or any moonasgi server) mounts to serve the schema
/// over real HTTP; the request→response logic is shared with `graphql_handler`,
/// which `TestClient` exercises without a socket.
pub fn graphql_app(
  schema : @schema.Schema,
  resolvers : @exec.Resolvers,
  path~ : String = "/graphql",
  ide~ : Ide = graphiql,
) -> @moonasgi.AsgiApp {
  @moonasgi.to_asgi(graphql_handler(schema, resolvers, path~, ide~))
}
