// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The JSON text layer at the edge of the server: a body is read as RFC 8259 and
// nothing else, and what leaves in a response is text a strict reader takes back
// unchanged. Reading and writing are one decision — both go through the same
// library — so they are pinned in one file.

///|
/// A schema whose only field answers the string the escaping test needs: the
/// characters JSON has a name for, and one that is written as it stands.
fn json_echo_schema() -> (@schema.Schema, @exec.Resolvers) {
  let s = @schema.Schema::new()
  s.object("Query").field("text", NonNull(@schema.Scalar("String")))
  let r = @exec.Resolvers::new()
  r.field("Query", "text", _info => Json("a\"b\\c\nd\te é 中文"))
  (s, r)
}

///|
/// A body that only a relaxed dialect would accept never reaches execution. Left
/// to the reader that accepts comments and trailing commas, a client would learn
/// about its mistake from a resolver instead of from a 400.
test "a body that is not RFC 8259 is a 400" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let bodies = [
    "{query: \"{ user(id: \\\"1\\\") { name } }\"}", "{\"query\": \"{ user(id: \\\"1\\\") { name } }\",}",
    "{\"query\": \"{ user(id: \\\"1\\\") { name } }\"} // done", "{'query': '{ user(id: \"1\") { name } }'}",
    "{/* why */ \"query\": \"{ user(id: \\\"1\\\") { name } }\"}",
  ]
  for body in bodies {
    let resp = client.post(
      "/graphql",
      body=@utf8.encode(body),
      headers=json_headers(),
    )
    assert_eq(resp.status, 400)
    assert_eq(resp.text().contains("not valid JSON"), true)
  }
}

///|
/// Nesting is bounded before the reader recurses, so a body of ten thousand open
/// brackets is a 400 rather than the end of the process. The limit is the
/// reader's, and it is the reason the reader was worth having.
test "a body nested past the reader's limit is refused, not followed" {
  let (s, r) = http_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let body = StringBuilder()
  for _ in 0..<600 {
    body.write_char('[')
  }
  for _ in 0..<600 {
    body.write_char(']')
  }
  let resp = client.post(
    "/graphql",
    body=@utf8.encode(body.to_string()),
    headers=json_headers(),
  )
  assert_eq(resp.status, 400)
  assert_eq(resp.text().contains("not valid JSON"), true)
}

///|
/// A response is one line of text with the escapes JSON names, non-ASCII written
/// as it stands, and nothing a strict reader would have to guess at: reading the
/// body back and writing it again gives the same characters, so a client that
/// parses the answer reads exactly what the resolver produced.
test "a response reads back unchanged, escapes included" {
  let (s, r) = json_echo_schema()
  let client = @moonasgi.TestClient::new(graphql_handler(s, r))
  let resp = client.post(
    "/graphql",
    body=@utf8.encode("{\"query\":\"{ text }\"}"),
    headers=json_headers(),
  )
  assert_eq(resp.status, 200)
  let text = resp.text()
  // the newline the resolver wrote is an escape, not a line break
  assert_eq(text.contains("\n"), false)
  // and the characters a person reads are written as themselves
  assert_eq(text.contains("é 中文"), true)
  let back = @moonjson.loads(text, @moonjson.strict)
  assert_eq(@moonjson.dumps(back), text)
  let value = match back {
    Object(m) =>
      match m.get("data") {
        Some(Object(d)) => d.get("text")
        _ => None
      }
    _ => None
  }
  assert_eq(value, Some(Json("a\"b\\c\nd\te é 中文")))
}
