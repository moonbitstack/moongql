// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A GraphQL client over HTTP.
///
/// The request body and the answer are the shapes the server reads and writes —
/// `{ query, variables, operationName }` in, `{ data, errors, extensions }` out —
/// and the document is read with the same parser the server uses, so a typo is
/// reported before anything is sent and the error reads the same way on both
/// sides.
///
/// One thing a client built on a buffering HTTP client cannot do is watch a
/// subscription: an event arrives after the response has been read, so it needs a
/// transport that reads as it goes. `Request` is public for that reason — a
/// transport of a different shape builds the same body and reads the same answer.

///|
/// Why a call did not produce a result: the document is not a GraphQL document,
/// the request did not complete, the answer is not a GraphQL response, or the
/// server ran the operation and refused it.
pub(all) suberror Refused {
  Invalid(String)
  Transport(String)
  Malformed(String)
  Rejected(Array[@lang.GqlError])
}

///|
/// A refusal in words: what failed, and what the server said about it.
pub fn Refused::to_string(self : Refused) -> String {
  match self {
    Invalid(m) => "invalid document: " + m
    Transport(m) => "transport: " + m
    Malformed(m) => "malformed answer: " + m
    Rejected(errs) =>
      "refused by the server: " + errs.map(e => e.message).join("; ")
  }
}

///|
/// A GraphQL endpoint and what every request to it carries.
pub struct Client {
  url : String
  headers : Array[(String, String)]
  timeout : Int32?
}

///|
/// A client for `url`, sending `headers` with every request — an
/// `authorization`, an `accept`, a trace id.
pub fn Client::new(
  url~ : String,
  headers~ : Array[(String, String)] = [],
  timeout? : Int32,
) -> Client {
  { url, headers, timeout, }
}

///|
/// The body of a request: the document, its variables and the operation to run
/// when the document holds several.
pub fn request_body(
  query : String,
  variables~ : Map[String, Json] = Map([]),
  operation_name? : String,
) -> Json {
  let entries : Array[(String, Json)] = [("query", Json(query))]
  if !variables.is_empty() {
    entries.push(("variables", Json(variables)))
  }
  match operation_name {
    Some(n) => entries.push(("operationName", Json(n)))
    None => ()
  }
  Json(
    entries.fold(init=Map([]), (m, kv) => {
      m[kv.0] = kv.1
      m
    }),
  )
}

///|
/// The errors an answer carries, or `None` when it carries none. An answer with
/// errors and data is a partial result, not a failure, so the two are read apart.
pub fn errors_of(answer : Json) -> Array[@lang.GqlError]? {
  match answer {
    Object(m) =>
      match m.get("errors") {
        Some(Array(items)) => {
          let out : Array[@lang.GqlError] = []
          for item in items {
            out.push(error_entry(item))
          }
          Some(out)
        }
        _ => None
      }
    _ => None
  }
}

///|
/// One entry of an answer's `errors` list, read back into the shape the server
/// reported it in: the message, the path, the locations and the extensions.
fn error_entry(item : Json) -> @lang.GqlError {
  let message = match item {
    Object(m) =>
      match m.get("message") {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
  let path : Array[Json] = match item {
    Object(m) =>
      match m.get("path") {
        Some(Array(p)) => p
        _ => []
      }
    _ => []
  }
  let locations : Array[@lang.Pos] = match item {
    Object(m) =>
      match m.get("locations") {
        Some(Array(locs)) => {
          let out : Array[@lang.Pos] = []
          for loc in locs {
            match loc {
              Object(lm) => {
                let line = match lm.get("line") {
                  Some(Number(n, ..)) => n.to_int()
                  _ => 0
                }
                let col = match lm.get("column") {
                  Some(Number(n, ..)) => n.to_int()
                  _ => 0
                }
                out.push({ line, col, })
              }
              _ => ()
            }
          }
          out
        }
        _ => []
      }
    _ => []
  }
  let extensions : Map[String, Json] = match item {
    Object(m) =>
      match m.get("extensions") {
        Some(Object(e)) => e
        _ => Map([])
      }
    _ => Map([])
  }
  { message, path, locations, extensions, }
}

///|
/// Check that `query` is a GraphQL document before spending a round trip on it.
/// Only the document's own syntax is checked — a client has no schema to check
/// fields against — and the refusal names the position.
pub fn check(query : String) -> Unit raise Refused {
  let _ = @lang.parse(query) catch {
    e => raise Invalid(@lang.refusal(e).message)
  }
}
