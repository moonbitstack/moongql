// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The client half of the conformance pipe: one request per line in, the answer
// this library's client read per line out, so a script in another language can
// hold the client to a server this repository did not write. `tools/conformance`
// is the other direction — it holds the server to clients it did not write.
//
// A line is `<name> TAB <variables> TAB <operation> TAB <document>`; `variables`
// is a JSON object or empty, and `operation` names one of several operations or
// is empty.

///|
/// A JSON object from ordered entries.
fn obj(entries : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for e in entries {
    m[e.0] = e.1
  }
  Json(m)
}

///|
/// One line of the answer: what the client read, or why it read nothing.
async fn report(out : @stdio.Output, fields : Array[(String, Json)]) -> Unit {
  out.write(@moonjson.dumps(obj(fields)) + "\n")
}

///|
/// The variables a line carries. An empty field is no variables rather than an
/// error, which is what a request without any looks like.
fn variables_of(text : StringView) -> Map[String, Json]? {
  if text == "" {
    return Some(Map([]))
  }
  let parsed = @moonjson.loads(text, @moonjson.strict) catch {
    _ => return None
  }
  match parsed {
    Object(m) => Some(m)
    _ => None
  }
}

///|
/// Run one line and write its answer.
async fn answer(
  client : @gqlclient.Client,
  out : @stdio.Output,
  text : StringView,
) -> Unit {
  let fields = text.split("\t").collect()
  guard fields.length() == 4 else {
    report(out, [("ok", Json(false)), ("why", Json("a line is four fields"))])
    return
  }
  let name = fields[0].to_owned()
  let variables = match variables_of(fields[1]) {
    Some(m) => m
    None => {
      report(out, [
        ("name", Json(name)),
        ("ok", Json(false)),
        ("why", Json("variables are not JSON")),
      ])
      return
    }
  }
  let operation : String? = if fields[2] == "" {
    None
  } else {
    Some(fields[2].to_owned())
  }
  let answer = client.request(
    fields[3].to_owned(),
    variables~,
    operation_name?=operation,
  ) catch {
    e => {
      report(out, [
        ("name", Json(name)),
        ("ok", Json(false)),
        ("why", Json(e.to_string())),
      ])
      return
    }
  }
  report(out, [("name", Json(name)), ("ok", Json(true)), ("answer", answer)])
}

///|
async fn main {
  let input = @stdio.stdin
  let out = @stdio.stdout
  let args = @env.args()
  guard args.length() >= 2 else {
    out.write("usage: moongql-client <url>")
    return
  }
  let client = @gqlclient.Client::new(url=args[1])
  let mut running = true
  while running {
    let line = input.read_until("\n") catch { _ => None }
    match line {
      None => running = false
      Some(t) => {
        let text = t.trim()
        if text != "" {
          answer(client, out, text)
        }
      }
    }
  }
}
