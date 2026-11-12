// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The conformance driver: a schema served by `graphql_app` and `graphql_ws_app`,
/// reached through one JSON line pair per step.
///
/// A specification audit, a reference executor and a protocol client all want to
/// talk to a server, and all of them are written in JavaScript. This program is
/// the server side of that conversation, with the ASGI seam as its edge: it reads
/// the scope and the events a server would hand an application, and prints the
/// events the application hands back. Nothing is re-implemented — the bytes that
/// come out are the ones `graphql_app` produced.
///
///     {"op":"http","method":"POST","path":"/graphql","headers":[["accept","application/json"]],"body":"{\"query\":\"{ hello }\"}"}
///     {"op":"http_start","status":200,"headers":[[...]]}
///     {"op":"http_body","body":"{\"data\":{\"hello\":\"hello\"}}","more":false}
///     {"op":"end"}

///|
/// A person, the object most of the schema is about.
fn user(id : String, name : String, age : Int32, role : String) -> Json {
  friend_of(id, name, age, role, [])
}

///|
/// The same person with the friends the fixture gives them. The reference schema
/// the audits compare against says Alice has one friend and the other two have
/// none, so this one says it too: a streamed `friends` is only worth replaying if
/// both sides stream the same list.
fn friend_of(
  id : String,
  name : String,
  age : Int32,
  role : String,
  friends : Array[Json],
) -> Json {
  let m : Map[String, Json] = Map([])
  m["__typename"] = Json("User")
  m["id"] = Json(id)
  m["name"] = Json(name)
  m["age"] = Json(age)
  m["role"] = Json(role)
  m["friends"] = Json(friends)
  Json(m)
}

///|
/// The three people the schema knows, in id order: Alice, who knows Bob; Bob; and
/// Cara, who knows nobody.
fn people() -> Array[Json] {
  let bob = user("2", "Bob", 25, "GUEST")
  [
    friend_of("1", "Alice", 30, "ADMIN", [bob]),
    bob,
    user("3", "Cara", 41, "ADMIN"),
  ]
}

///|
/// The book the union's other arm returns.
fn dune() -> Json {
  let m : Map[String, Json] = Map([])
  m["__typename"] = Json("Book")
  m["title"] = Json("Dune")
  m["isbn"] = Json("9780441013593")
  Json(m)
}

///|
/// The schema the conformance scripts exercise: objects, an interface, a union, an
/// enum, arguments with defaults, a nullable field that fails, a mutation and a
/// subscription.
fn shop() -> @schema.Schema {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("hello", NonNull(Scalar("String")))
  q.field_args("user", [("id", NonNull(Scalar("ID")))], @schema.Named("User"))
  q.field_args(
    "users",
    [("first", Scalar("Int"))],
    NonNull(ListOf(NonNull(Named("User")))),
    defaults=[("first", Json(3))],
  )
  q.field_args("node", [("id", NonNull(Scalar("ID")))], Named("Node"))
  q.field_args(
    "search",
    [("text", NonNull(Scalar("String")))],
    NonNull(ListOf(NonNull(Named("SearchResult")))),
  )
  q.field("fail", Scalar("String"))
  let node = s.interface("Node")
  node.field("id", NonNull(Scalar("ID")))
  let u = s.object("User")
  u.implements("Node")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", NonNull(Scalar("String")))
  u.field("age", Scalar("Int"))
  u.field("role", NonNull(Named("Role")))
  u.field("friends", NonNull(ListOf(NonNull(Named("User")))))
  let b = s.object("Book")
  b.field("title", NonNull(Scalar("String")))
  b.field("isbn", NonNull(Scalar("String")))
  s.enum_("Role", ["ADMIN", "GUEST"])
  s.union("SearchResult", ["User", "Book"])
  let m = s.object("Mutation")
  m.field_args(
    "addUser",
    [("name", NonNull(Scalar("String")))],
    NonNull(Named("User")),
  )
  m.field("boom", Scalar("String"))
  s.set_mutation("Mutation")
  let sub = s.object("Subscription")
  sub.field_args("tick", [("times", Scalar("Int"))], NonNull(Named("Tick")), defaults=[
    ("times", Json(3)),
  ])
  let t = s.object("Tick")
  t.field("n", NonNull(Scalar("Int")))
  s.set_subscription("Subscription")
  s
}

///|
/// The resolvers that stand behind `shop()`. The data is fixed, so a reference
/// implementation can be asked the same questions and answer the same way.
fn resolvers() -> @exec.Resolvers {
  let r = @exec.Resolvers::new()
  r.field("Query", "hello", fn(_info) { Json("hello") })
  r.field("Query", "user", fn(info) -> Json raise @exec.FieldError {
    let id : String = info.read("id")
    for p in people() {
      if p is Object(m) && m.get("id") == Some(Json(id)) {
        return Json(m)
      }
    }
    Json::null()
  })
  r.field("Query", "users", fn(info) -> Json raise @exec.FieldError {
    let first : Int32? = info.read("first")
    let n = first.unwrap_or(3)
    let out : Array[Json] = []
    for i, p in people() {
      if i < n {
        out.push(p)
      }
    }
    Json(out)
  })
  r.field("Query", "node", fn(info) -> Json raise @exec.FieldError {
    let id : String = info.read("id")
    for p in people() {
      if p is Object(m) && m.get("id") == Some(Json(id)) {
        return Json(m)
      }
    }
    Json::null()
  })
  r.field("Query", "search", fn(_info) { Json([people()[0], dune()]) })
  r.field("Query", "fail", fn(_info) { Json::null() })
  r.field("Mutation", "addUser", fn(info) -> Json raise @exec.FieldError {
    let name : String = info.read("name")
    Json(user("99", name, 0, "GUEST"))
  })
  r.field_async("Mutation", "boom", async fn(_info) {
    @async.pause()
    raise @exec.FieldError("boom")
  })
  r
}

///|
/// The subscription behind `Subscription.tick`: `times` events, numbered from one.
fn subscribers() -> @exec.Subscribers {
  let subs = @exec.Subscribers::new()
  subs.stream("Subscription", "tick", fn(
    info,
  ) -> @exec.Stream raise @exec.FieldError {
    let times : Int32? = info.read("times")
    let n = times.unwrap_or(3)
    let (stream, sender) = @exec.Stream::channel()
    for i in 1..<=n {
      let m : Map[String, Json] = Map([])
      m["n"] = Json(i)
      sender.send(Json(m)) catch {
        _ => ()
      }
    }
    sender.close()
    stream
  })
  subs
}

///|
/// A header list as the JSON array of pairs a reader can print.
fn header_pairs(headers : Array[(String, String)]) -> Json {
  let out : Array[Json] = []
  for h in headers {
    out.push(Json([Json(h.0), Json(h.1)]))
  }
  Json(out)
}

///|
/// An object literal from ordered entries.
fn obj(entries : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for e in entries {
    m[e.0] = e.1
  }
  Json(m)
}

///|
/// One event the application produced, as the line the driver prints.
fn event_line(event : @spec.Event) -> Json? {
  match event {
    @spec.Event::HttpResponseStart(status~, headers~, ..) =>
      Some(
        obj([
          ("op", Json("http_start")),
          ("status", Json(status)),
          ("headers", header_pairs(headers)),
        ]),
      )
    @spec.Event::HttpResponseBody(body~, more_body~) =>
      Some(
        obj([
          ("op", Json("http_body")),
          ("body", Json(@utf8.decode_lossy(body[:]))),
          ("more", Json(more_body)),
        ]),
      )
    @spec.Event::WebSocketAccept(subprotocol~, headers~) =>
      Some(
        obj([
          ("op", Json("ws_accept")),
          ("subprotocol", Json(subprotocol.unwrap_or(""))),
          ("headers", header_pairs(headers)),
        ]),
      )
    @spec.Event::WebSocketSendText(text) =>
      Some(obj([("op", Json("ws_text")), ("text", Json(text))]))
    @spec.Event::WebSocketClose(code~, reason~) =>
      Some(
        obj([
          ("op", Json("ws_close")),
          ("code", Json(code)),
          ("reason", Json(reason)),
        ]),
      )
    _ => None
  }
}

///|
/// Write one line to the conformance script, holding the write lock so that a
/// subscription task and the read loop cannot interleave a half-written line.
async fn emit(out : @stdio.Output, lock : @async.Mutex, line : Json) -> Unit {
  lock.acquire()
  defer lock.release()
  out.write(@moonjson.dumps(line) + "\n")
}

///|
/// The fields every HTTP step carries, defaulted the way a real request would be.
fn http_step(m : Map[String, Json]) -> HttpStep {
  let verb = match m.get("method") {
    Some(String(s)) => s
    _ => "POST"
  }
  let path = match m.get("path") {
    Some(String(s)) => s
    _ => "/graphql"
  }
  let query = match m.get("query") {
    Some(String(s)) => s
    _ => ""
  }
  let headers : Array[(String, String)] = match m.get("headers") {
    Some(Array(items)) => {
      let out : Array[(String, String)] = []
      for item in items {
        match item {
          Array(pair) =>
            if pair.length() == 2 {
              match (pair[0], pair[1]) {
                (String(k), String(v)) => out.push((k, v))
                _ => ()
              }
            }
          _ => ()
        }
      }
      out
    }
    _ => []
  }
  let body = match m.get("body") {
    Some(String(s)) => s
    _ => ""
  }
  { verb, path, query, headers, body, }
}

///|
/// One HTTP step's request line and body.
priv struct HttpStep {
  verb : String
  path : String
  query : String
  headers : Array[(String, String)]
  body : String
}

///|
/// Answer one HTTP step: run the application with the scope and the one request
/// event a server would send, and print the events it produced.
async fn do_http(
  app : @moonasgi.AsgiApp,
  out : @stdio.Output,
  lock : @async.Mutex,
  step : Map[String, Json],
) -> Unit {
  let req = http_step(step)
  let scope = @spec.Scope::Http(
    @spec.HttpScope::new(
      http_method=req.verb,
      path=req.path,
      query_string=@utf8.encode(req.query),
      headers=req.headers,
    ),
  )
  let lines : Array[Json] = []
  let receive : @moonasgi.Receive = () => {
    @spec.Event::HttpRequest(body=@utf8.encode(req.body), more_body=false)
  }
  let send : @moonasgi.Send = e => {
    match event_line(e) {
      Some(line) => lines.push(line)
      None => ()
    }
  }
  app(scope, receive, send)
  for line in lines {
    emit(out, lock, line)
  }
  emit(out, lock, obj([("op", Json("end"))]))
}

///|
/// An open WebSocket: the queue its inbound events are read from, and the task
/// running the application, which is cancelled when the script closes it.
priv struct Session {
  inbox : @aqueue.Queue[@spec.Event]
  task : @async.Task[Unit]
}

///|
/// Drive the conformance script: one line in, the events it caused out.
async fn main {
  let input = @stdio.stdin
  let out = @stdio.stdout
  let lock = @async.Mutex::Mutex()
  let schema = shop()
  let res = resolvers()
  let subs = subscribers()
  let http_app = @server.graphql_app(schema, res)
  let ws_app = @server.graphql_ws_app(schema, res, subs)
  @async.with_task_group(async fn(group) {
    let mut session : Session? = None
    let mut running = true
    while running {
      let line = input.read_until("\n") catch { _ => None }
      let text = match line {
        None => break
        Some(t) => t
      }
      if text.trim() == "" {
        continue
      }
      let parsed = @moonjson.loads(text, @moonjson.strict) catch {
        _ => continue
      }
      let m = match parsed {
        Object(m) => m
        _ => continue
      }
      let op = match m.get("op") {
        Some(String(s)) => s
        _ => ""
      }
      match op {
        "http" => do_http(http_app, out, lock, m)
        "ws_open" => {
          let inbox : @aqueue.Queue[@spec.Event] = @aqueue.Queue::Queue(
            kind=@aqueue.Unbounded,
          )
          inbox.put(@spec.Event::WebSocketConnect)
          let path = match m.get("path") {
            Some(String(s)) => s
            _ => "/graphql"
          }
          let subprotocols : Array[String] = match m.get("subprotocols") {
            Some(Array(items)) => {
              let list : Array[String] = []
              for item in items {
                match item {
                  String(s) => list.push(s)
                  _ => ()
                }
              }
              list
            }
            _ => []
          }
          let scope = @spec.Scope::WebSocket(
            @spec.WebSocketScope::new(path~, subprotocols~),
          )
          let receive : @moonasgi.Receive = () => inbox.get()
          let send : @moonasgi.Send = e => {
            match event_line(e) {
              Some(l) => emit_line(out, lock, l)
              None => ()
            }
          }
          let task = group.spawn(async fn() { ws_app(scope, receive, send) })
          session = Some({ inbox, task, })
          emit(out, lock, obj([("op", Json("end"))]))
        }
        "ws_send" => {
          let text = match m.get("text") {
            Some(String(s)) => s
            _ => ""
          }
          match session {
            Some(s) =>
              s.inbox.put(
                @spec.Event::WebSocketReceive(text=Some(text), bytes=None),
              )
            None => ()
          }
          emit(out, lock, obj([("op", Json("end"))]))
        }
        "ws_close" => {
          match session {
            Some(s) => {
              s.task.cancel()
              s.inbox.put(
                @spec.Event::WebSocketDisconnect(code=1000, reason=Some("bye")),
              )
              session = None
            }
            None => ()
          }
          emit(out, lock, obj([("op", Json("end"))]))
        }
        "quit" => running = false
        _ => emit(out, lock, obj([("op", Json("unknown"))]))
      }
    }
    // A connection the script left open ends with the script.
    match session {
      Some(s) => s.task.cancel()
      None => ()
    }
  })
}

///|
/// `emit` for a call site that cannot await: the send callback of an application
/// is asynchronous, so this is the asynchronous one under a shorter name.
async fn emit_line(
  out : @stdio.Output,
  lock : @async.Mutex,
  line : Json,
) -> Unit {
  emit(out, lock, line)
}
