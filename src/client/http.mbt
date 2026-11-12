// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The half of the client that needs a socket: moonfetch's connections exist on
/// the native and wasm backends, so these functions do too, and the rest of the
/// package — the request body, the reading of an answer, the document check —
/// stays available everywhere.

///|
/// Run `query` and answer the server's response as it came.
///
/// The answer is returned whole, `errors` and all: a partial result is a result.
/// A transport failure, an unreadable answer, or a document that does not parse is
/// a `Refused`.
pub async fn Client::request(
  self : Client,
  query : String,
  variables~ : Map[String, Json] = Map([]),
  operation_name? : String,
) -> Json raise Refused {
  check(query)
  let body = request_body(query, variables~, operation_name?)
  let headers = self.headers.copy()
  headers.push(("content-type", "application/json"))
  headers.push(
    ("accept", "application/graphql-response+json, application/json"),
  )
  let answer : @moonfetch.Response = @moonfetch.post(
    self.url,
    body=@moonfetch.Body::Text(@moonjson.dumps(body)),
    headers~,
    timeout=self.timeout.unwrap_or(@moonfetch.timeout),
  ) catch {
    e => raise Transport(e.to_string())
  }
  let text = answer.text()
  @moonjson.loads(text, @moonjson.strict) catch {
    _ => raise Malformed(text)
  }
}

///|
/// Run `query` and answer its `data`, refusing when the server answers with
/// errors and nothing to show for them — the operation did not run, or ran and
/// failed everywhere.
pub async fn Client::query(
  self : Client,
  query : String,
  variables~ : Map[String, Json] = Map([]),
  operation_name? : String,
) -> Json raise Refused {
  let answer = self.request(query, variables~, operation_name?)
  match errors_of(answer) {
    Some(errs) =>
      if answer_has_data(answer) {
        match answer {
          Object(m) => m.get("data").unwrap_or(Json::null())
          _ => Json::null()
        }
      } else {
        raise Rejected(errs)
      }
    None =>
      match answer {
        Object(m) => m.get("data").unwrap_or(Json::null())
        _ => raise Malformed(@moonjson.dumps(answer))
      }
  }
}

///|
/// Whether the answer carries a `data` entry, which is what tells a request
/// error (§7.1.2, no execution) from a field error (execution, partial result).
fn answer_has_data(answer : Json) -> Bool {
  match answer {
    Object(m) => m.get("data") is Some(_)
    _ => false
  }
}

///|
/// Run several operations in one round trip, answering their responses in the
/// order they were given. A server that does not serve batches answers with one
/// response, which is reported as malformed.
pub async fn Client::batch(
  self : Client,
  queries : Array[String],
  variables~ : Array[Map[String, Json]] = [],
) -> Array[Json] raise Refused {
  let bodies : Array[Json] = []
  for i, q in queries {
    check(q)
    let vars = if i < variables.length() { variables[i] } else { Map([]) }
    bodies.push(request_body(q, variables=vars))
  }
  let headers = self.headers.copy()
  headers.push(("content-type", "application/json"))
  headers.push(
    ("accept", "application/graphql-response+json, application/json"),
  )
  let answer : @moonfetch.Response = @moonfetch.post(
    self.url,
    body=@moonfetch.Body::Text(@moonjson.dumps(Json(bodies))),
    headers~,
    timeout=self.timeout.unwrap_or(@moonfetch.timeout),
  ) catch {
    e => raise Transport(e.to_string())
  }
  let text = answer.text()
  let parsed = @moonjson.loads(text, @moonjson.strict) catch {
    _ => raise Malformed(text)
  }
  match parsed {
    Array(items) => items
    _ => raise Malformed(text)
  }
}
