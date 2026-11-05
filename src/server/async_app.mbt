// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The application a server mounts: one request in, one response out, with the
/// async engine behind it so resolvers that wait work, and with incremental
/// delivery when the client asks for it.
///
/// `graphql_handler` stays the synchronous request-to-response function — it is
/// what moonasgi's `TestClient` drives and what a program embedding moongql
/// calls directly. This application reads the request's events itself, so it can
/// start the response before the last payload is computed.

///|
/// The media type of an incremental response: one multipart document, the boundary
/// the parts are separated by, and the version of the format, so a client knows
/// how to read the parts.
pub fn incremental_content_type(boundary : String) -> String {
  "multipart/mixed; boundary=\"" + boundary + "\"; deferSpec=20220824"
}

///|
/// Whether a client's `Accept` asks for the incremental response. A client that
/// does not is answered with one plain JSON body, which is what every
/// pre-incremental client expects.
fn wants_incremental(accept : String?) -> Bool {
  match accept {
    None => false
    Some(h) => h.contains("multipart/mixed") || h.contains("deferSpec")
  }
}

///|
/// One payload as a multipart part: a boundary line, the part's headers, and the
/// payload itself. Parts end with the closing boundary rather than each carrying
/// it, so `close_multipart` writes the last one.
pub fn multipart_part(boundary : String, payload : Json) -> String {
  let body = payload.stringify()
  "\r\n--" +
  boundary +
  "\r\nContent-Type: application/json; charset=utf-8\r\n\r\n" +
  body +
  "\r\n"
}

///|
/// The closing boundary of a multipart document.
pub fn multipart_close(boundary : String) -> String {
  "\r\n--" + boundary + "--\r\n"
}

///|
/// How an incremental response is written: the boundary its parts use. A client
/// that sends `Accept: multipart/mixed; boundary=...` picks its own; otherwise the
/// server's is used, which is what the specification allows.
fn boundary_of(accept : String?) -> String {
  let header = match accept {
    None => return "-"
    Some(h) => h
  }
  let at = match header.find("boundary=") {
    None => return "-"
    Some(i) => i
  }
  let rest = header[at + 9:].to_owned()
  let stop = match rest.find(";") {
    Some(i) => i
    None => rest.length()
  }
  let raw = rest[:stop].trim().to_owned()
  // A boundary may be quoted; the quotes are not part of it.
  let candidate = if raw.length() >= 2 &&
    raw[0] == '"' &&
    raw[raw.length() - 1] == '"' {
    raw[1:raw.length() - 1].to_owned()
  } else {
    raw
  }
  if candidate == "" {
    "-"
  } else {
    candidate
  }
}

///|
/// Lift the GraphQL handler onto the load-bearing `AsgiApp` a server binds to.
///
/// A `POST` on `path` runs the request with the asynchronous engine: one JSON
/// response, or — when the client's `Accept` asks for `multipart/mixed` — the
/// initial payload followed by one part per deferred fragment or streamed list
/// item. A `GET` serves the IDE, or runs a query operation with `?query=`.
///
/// Mount it in mooncat (or any ASGI server) where the schema should be reachable;
/// `graphql_handler` is the same endpoint as a plain request-to-response function.
pub fn graphql_app(
  schema : @schema.Schema,
  resolvers : @exec.Resolvers,
  path~ : String = "/graphql",
  ide~ : Ide = site,
  limits~ : @exec.Limits = @exec.limits,
) -> @moonasgi.AsgiApp {
  async fn(scope, receive, send) {
    let http = match scope {
      @spec.Http(h) => h
      _ => {
        let body = @utf8.encode("Not Found")
        send(
          @spec.Event::HttpResponseStart(
            status=404,
            headers=[("content-type", "text/plain; charset=utf-8")],
            trailers=false,
          ),
        )
        send(@spec.Event::HttpResponseBody(body~, more_body=false))
        return
      }
    }
    if http.path != path {
      return reply(send, 404, "Not Found")
    }
    let accept = header_of(http.headers, "accept")
    let wire = match wire_of(accept) {
      Some(w) => w
      None =>
        return reply(
          send, 406, "Not Acceptable: this endpoint serves application/graphql-response+json or application/json",
        )
    }
    match http.http_method {
      "GET" | "HEAD" => {
        let params = query_params(http.query_string)
        match params.get("query") {
          Some(q) => run_get(schema, resolvers, wire, params, q, send, limits)
          None =>
            if ide.is_off() {
              reply(send, 405, "Method Not Allowed")
            } else {
              let page = @utf8.encode(ide.html(endpoint=path))
              send(
                @spec.Event::HttpResponseStart(
                  status=200,
                  headers=[("content-type", "text/html; charset=utf-8")],
                  trailers=false,
                ),
              )
              send(@spec.Event::HttpResponseBody(body=page, more_body=false))
            }
        }
      }
      "POST" =>
        read_body(receive, send, schema, resolvers, wire, accept, limits)
      _ => reply(send, 405, "Method Not Allowed")
    }
  }
}

///|
/// Read the request body from the remaining events, then answer it.
async fn read_body(
  receive : @moonasgi.Receive,
  send : @moonasgi.Send,
  schema : @schema.Schema,
  resolvers : @exec.Resolvers,
  wire : Wire,
  accept : String?,
  limits : @exec.Limits,
) -> Unit {
  let buf : Array[Byte] = []
  let mut more = true
  while more {
    let event = receive()
    match event {
      @spec.Event::HttpRequest(body~, more_body~) => {
        for i in 0..<body.length() {
          buf.push(body[i])
        }
        more = more_body
      }
      @spec.Event::HttpDisconnect => return
      _ => more = false
    }
  }
  let text = @utf8.decode_lossy(Bytes::from_array(buf[:]))
  let body = @json.parse(text) catch {
    _ => return reply(send, 400, "Request body is not valid JSON")
  }
  match body {
    Array(items) =>
      if items.is_empty() {
        reply(send, 400, "GraphQL batch must not be empty")
      } else {
        let results : Array[Json] = []
        for item in items {
          results.push(run_one(schema, resolvers, item, limits))
        }
        send_json(send, wire, Json(results))
      }
    _ =>
      if wants_incremental(accept) {
        incremental(send, body, schema, resolvers, accept, limits)
      } else {
        send_json(send, wire, run_one(schema, resolvers, body, limits))
      }
  }
}

///|
/// Run one request object and answer its response, or a request-level failure.
async fn run_one(
  schema : @schema.Schema,
  resolvers : @exec.Resolvers,
  body : Json,
  limits : @exec.Limits,
) -> Json {
  let (query, variables, operation_name) = parse_request(body)
  match query {
    None =>
      @exec.build_response(None, [@lang.GqlError::msg(no_query_message())])
    Some(q) =>
      @exec.execute_async(
        schema,
        resolvers,
        q,
        variables~,
        operation_name?,
        limits~,
      )
  }
}

///|
/// The message every request without a query gets.
fn no_query_message() -> String {
  "No GraphQL query found in request body"
}

///|
/// Serve a `GET` carrying `?query=`: query operations only, per the
/// specification's rule that a `GET` is safe and idempotent.
async fn run_get(
  schema : @schema.Schema,
  resolvers : @exec.Resolvers,
  wire : Wire,
  params : Map[String, String],
  query : String,
  send : @moonasgi.Send,
  limits : @exec.Limits,
) -> Unit {
  let operation_name : String? = params.get("operationName")
  let variables : Map[String, Json] = match params.get("variables") {
    None => Map([])
    Some(text) =>
      match
        (@json.parse(text) catch {
          _ =>
            return reply(
              send, 400, "The 'variables' parameter is not valid JSON",
            )
        }) {
        Object(m) => m
        _ => Map([])
      }
  }
  if operation_type_of(schema, query, operation_name) is Ok(op) &&
    !(op is @lang.Query) {
    return reply(
      send, 405, "GET supports query operations only; use POST for a mutation or subscription",
    )
  }
  let result = @exec.execute_async(
    schema,
    resolvers,
    query,
    variables~,
    operation_name?,
    limits~,
  )
  send_json(send, wire, result)
}

///|
/// Run a request and write its payloads as a multipart document, one part each,
/// so a client sees the initial result before the deferred ones are ready.
async fn incremental(
  send : @moonasgi.Send,
  body : Json,
  schema : @schema.Schema,
  resolvers : @exec.Resolvers,
  accept : String?,
  limits : @exec.Limits,
) -> Unit {
  let (query, variables, operation_name) = parse_request(body)
  let boundary = boundary_of(accept)
  send(
    @spec.Event::HttpResponseStart(
      status=200,
      headers=[("content-type", incremental_content_type(boundary))],
      trailers=false,
    ),
  )
  let payloads = match query {
    None =>
      [@exec.build_response(None, [@lang.GqlError::msg(no_query_message())])]
    Some(q) =>
      @exec.execute_incremental(
        schema,
        resolvers,
        q,
        variables~,
        operation_name?,
        limits~,
      )
  }
  for payload in payloads {
    let chunk = @utf8.encode(multipart_part(boundary, payload))
    send(@spec.Event::HttpResponseBody(body=chunk, more_body=true))
  }
  let last = @utf8.encode(multipart_close(boundary))
  send(@spec.Event::HttpResponseBody(body=last, more_body=false))
}

///|
/// Write a whole JSON response in one body.
async fn send_json(send : @moonasgi.Send, wire : Wire, body : Json) -> Unit {
  let encoded = @utf8.encode(body.stringify())
  send(
    @spec.Event::HttpResponseStart(
      status=wire_status(wire, body),
      headers=[("content-type", wire_content_type(wire))],
      trailers=false,
    ),
  )
  send(@spec.Event::HttpResponseBody(body=encoded, more_body=false))
}

///|
/// Write a plain-text response.
async fn reply(send : @moonasgi.Send, status : Int32, message : String) -> Unit {
  let encoded = @utf8.encode(message)
  send(
    @spec.Event::HttpResponseStart(
      status~,
      headers=[("content-type", "text/plain; charset=utf-8")],
      trailers=false,
    ),
  )
  send(@spec.Event::HttpResponseBody(body=encoded, more_body=false))
}

///|
/// Read a header by name, ignoring case, out of an ASGI header list.
fn header_of(headers : Array[(String, String)], name : String) -> String? {
  for pair in headers {
    if ci_eq(pair.0, name) {
      return Some(pair.1)
    }
  }
  None
}
