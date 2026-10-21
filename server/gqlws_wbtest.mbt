///|
/// A client control frame `{ type }` as a text message.
fn ctrl_frame(type_ : String) -> @moonasgi.WsMessage {
  @ws.Text(jobj([("type", Json(type_))]).stringify())
}

///|
/// A `connection_init` frame carrying connection parameters.
fn init_frame(payload : Json) -> @moonasgi.WsMessage {
  @ws.Text(
    jobj([("type", Json("connection_init")), ("payload", payload)]).stringify(),
  )
}

///|
/// A client `complete` frame `{ id, type }` as a text message.
fn complete_frame(id : String) -> @moonasgi.WsMessage {
  @ws.Text(jobj([("id", Json(id)), ("type", Json("complete"))]).stringify())
}

///|
/// A `subscribe` frame `{ id, type, payload: { query } }` as a text message.
fn subscribe_frame(id : String, query : String) -> @moonasgi.WsMessage {
  let payload = jobj([("query", Json(query))])
  @ws.Text(
    jobj([("id", Json(id)), ("type", Json("subscribe")), ("payload", payload)]).stringify(),
  )
}

///|
/// The text bodies of the `SendText` frames in a handler's reply, in order.
fn sent_texts(sends : Array[@moonasgi.WsSend]) -> Array[String] {
  let out : Array[String] = []
  for s in sends {
    match s {
      @ws.SendText(t) => out.push(t)
      _ => ()
    }
  }
  out
}

///|
/// The close code in a handler's reply, or -1 if it did not close.
fn close_code(sends : Array[@moonasgi.WsSend]) -> Int32 {
  for s in sends {
    if s is @ws.Close(code~, ..) {
      return code
    }
  }
  -1
}

///|
test "graphql-transport-ws acks init, then streams next* and complete" {
  let h = graphql_ws_handler(
    sub_schema(),
    @exec.Resolvers::new(),
    sub_subscribers(),
  )
  let ack = sent_texts((h.on_receive)(ctrl_frame("connection_init")))
  assert_eq(ack.length(), 1)
  assert_eq(ack[0], "{\"type\":\"connection_ack\"}")
  let out = sent_texts(
    (h.on_receive)(subscribe_frame("1", "subscription { ticks }")),
  )
  assert_eq(out.length(), 3)
  assert_eq(
    out[0],
    "{\"id\":\"1\",\"type\":\"next\",\"payload\":{\"data\":{\"ticks\":1}}}",
  )
  assert_eq(
    out[1],
    "{\"id\":\"1\",\"type\":\"next\",\"payload\":{\"data\":{\"ticks\":2}}}",
  )
  assert_eq(out[2], "{\"id\":\"1\",\"type\":\"complete\"}")
}

///|
test "graphql-transport-ws refuses a subscribe before connection_init (4401)" {
  let h = graphql_ws_handler(
    sub_schema(),
    @exec.Resolvers::new(),
    sub_subscribers(),
  )
  assert_eq(
    close_code((h.on_receive)(subscribe_frame("1", "subscription { ticks }"))),
    4401,
  )
}

///|
test "graphql-transport-ws refuses a second connection_init (4429)" {
  let h = graphql_ws_handler(
    sub_schema(),
    @exec.Resolvers::new(),
    sub_subscribers(),
  )
  (h.on_receive)(ctrl_frame("connection_init")) |> ignore
  assert_eq(close_code((h.on_receive)(ctrl_frame("connection_init"))), 4429)
}

///|
/// An id belongs to a running operation, not to the connection: once the
/// operation has completed the client may open a new one under the same id.
test "graphql-transport-ws accepts an operation id reused after complete" {
  let ws = GqlWs::new(sub_schema(), @exec.Resolvers::new(), sub_subscribers())
  ws.recv(ctrl_frame("connection_init")) |> ignore
  let first = sent_texts(
    ws.recv(subscribe_frame("1", "subscription { ticks }")),
  )
  assert_eq(first[first.length() - 1], "{\"id\":\"1\",\"type\":\"complete\"}")
  let again = ws.recv(subscribe_frame("1", "subscription { ticks }"))
  assert_eq(close_code(again), -1)
  assert_eq(sent_texts(again).length(), 3)
}

///|
/// An id claimed by an operation that is still running is refused with 4409. The
/// claim is what a server streaming a live source holds while its task runs.
test "graphql-transport-ws refuses an operation id reused while running (4409)" {
  let ws = GqlWs::new(sub_schema(), @exec.Resolvers::new(), sub_subscribers())
  ws.recv(ctrl_frame("connection_init")) |> ignore
  assert_eq(ws.claim("1"), true)
  assert_eq(
    close_code(ws.recv(subscribe_frame("1", "subscription { ticks }"))),
    4409,
  )
  ws.release("1")
  assert_eq(
    close_code(ws.recv(subscribe_frame("1", "subscription { ticks }"))),
    -1,
  )
}

///|
/// A client's `complete` ends the operation, so its id is free again.
test "graphql-transport-ws frees an operation id on a client complete" {
  let ws = GqlWs::new(sub_schema(), @exec.Resolvers::new(), sub_subscribers())
  ws.recv(ctrl_frame("connection_init")) |> ignore
  assert_eq(ws.claim("1"), true)
  assert_eq(ws.recv(complete_frame("1")).length(), 0)
  assert_eq(
    close_code(ws.recv(subscribe_frame("1", "subscription { ticks }"))),
    -1,
  )
}

///|
/// A client that connects and never sends `connection_init` is closed with 4408
/// once the timeout passes. The clock is the server's: nothing happens until it
/// ticks.
test "graphql-transport-ws times out a missing connection_init (4408)" {
  let ws = GqlWs::new(
    sub_schema(),
    @exec.Resolvers::new(),
    sub_subscribers(),
    init_timeout=3000,
  )
  assert_eq(close_code(ws.tick(1000L)), -1)
  assert_eq(close_code(ws.tick(3999L)), -1)
  assert_eq(close_code(ws.tick(4000L)), 4408)
}

///|
/// The countdown stops once `connection_init` arrives.
test "graphql-transport-ws does not time out an initialised connection" {
  let ws = GqlWs::new(
    sub_schema(),
    @exec.Resolvers::new(),
    sub_subscribers(),
    init_timeout=3000,
  )
  ws.tick(0L) |> ignore
  ws.recv(ctrl_frame("connection_init")) |> ignore
  assert_eq(close_code(ws.tick(9000L)), -1)
}

///|
/// The server sends its own keep-alive `ping` once an interval has gone by.
test "graphql-transport-ws pings on the configured interval" {
  let ws = GqlWs::new(
    sub_schema(),
    @exec.Resolvers::new(),
    sub_subscribers(),
    ping_interval=12000,
  )
  ws.tick(0L) |> ignore
  ws.recv(ctrl_frame("connection_init")) |> ignore
  assert_eq(sent_texts(ws.tick(11999L)).length(), 0)
  let first = sent_texts(ws.tick(12000L))
  assert_eq(first.length(), 1)
  assert_eq(first[0], "{\"type\":\"ping\"}")
  assert_eq(sent_texts(ws.tick(12001L)).length(), 0)
  let second = sent_texts(ws.tick(24000L))
  assert_eq(second.length(), 1)
  assert_eq(second[0], "{\"type\":\"ping\"}")
}

///|
/// The `connection_init` payload is the connection's parameters, and reaches
/// every operation's context under `connectionParams` — which is how a client
/// hands the server a token once instead of on every operation.
test "graphql-transport-ws passes connection_init params to the context" {
  let r = @exec.Resolvers::new()
  r.field("Query", "ok", info => {
    match info.ctx {
      Object(m) =>
        match m.get("connectionParams") {
          Some(Object(p)) =>
            match p.get("token") {
              Some(t) => t
              None => Json("no token")
            }
          _ => Json("no params")
        }
      _ => Json("no context")
    }
  })
  let ws = GqlWs::new(sub_schema(), r, sub_subscribers())
  ws.recv(init_frame(jobj([("token", Json("heke1228"))]))) |> ignore
  assert_eq(
    sent_texts(ws.recv(subscribe_frame("q1", "{ ok }")))[0],
    "{\"id\":\"q1\",\"type\":\"next\",\"payload\":{\"data\":{\"ok\":\"heke1228\"}}}",
  )
}

///|
/// The parameters are merged into a configured context rather than replacing it,
/// so what the server set up and what the client sent are both there.
test "graphql-transport-ws merges init params into a context object" {
  let r = @exec.Resolvers::new()
  r.field("Query", "ok", info => info.ctx)
  let ws = GqlWs::new(
    sub_schema(),
    r,
    sub_subscribers(),
    context=jobj([("tenant", Json("qwq"))]),
  )
  ws.recv(init_frame(jobj([("token", Json("heke1228"))]))) |> ignore
  assert_eq(
    sent_texts(ws.recv(subscribe_frame("q1", "{ ok }")))[0],
    "{\"id\":\"q1\",\"type\":\"next\",\"payload\":{\"data\":{\"ok\":{\"tenant\":\"qwq\",\"connectionParams\":{\"token\":\"heke1228\"}}}}}",
  )
}

///|
/// A context that is not an object has nothing to merge into, so the parameters
/// leave it alone.
test "graphql-transport-ws leaves a non-object context alone" {
  let r = @exec.Resolvers::new()
  r.field("Query", "ok", info => info.ctx)
  let ws = GqlWs::new(sub_schema(), r, sub_subscribers(), context=Json("plain"))
  ws.recv(init_frame(jobj([("token", Json("heke1228"))]))) |> ignore
  assert_eq(
    sent_texts(ws.recv(subscribe_frame("q1", "{ ok }")))[0],
    "{\"id\":\"q1\",\"type\":\"next\",\"payload\":{\"data\":{\"ok\":\"plain\"}}}",
  )
}

///|
/// With no `connection_init` payload the configured context is passed through
/// untouched.
test "graphql-transport-ws leaves the context alone without init params" {
  let r = @exec.Resolvers::new()
  r.field("Query", "ok", info => info.ctx)
  let ws = GqlWs::new(sub_schema(), r, sub_subscribers(), context=Json("plain"))
  ws.recv(ctrl_frame("connection_init")) |> ignore
  assert_eq(
    sent_texts(ws.recv(subscribe_frame("q1", "{ ok }")))[0],
    "{\"id\":\"q1\",\"type\":\"next\",\"payload\":{\"data\":{\"ok\":\"plain\"}}}",
  )
}

///|
test "graphql-transport-ws answers ping with pong, echoing the payload" {
  let h = graphql_ws_handler(
    sub_schema(),
    @exec.Resolvers::new(),
    sub_subscribers(),
  )
  assert_eq(
    sent_texts((h.on_receive)(ctrl_frame("ping")))[0],
    "{\"type\":\"pong\"}",
  )
  let ping = @ws.Text(
    jobj([("type", Json("ping")), ("payload", jobj([("n", Json(1))]))]).stringify(),
  )
  assert_eq(
    sent_texts((h.on_receive)(ping))[0],
    "{\"type\":\"pong\",\"payload\":{\"n\":1}}",
  )
}

///|
test "graphql-transport-ws closes on a binary frame (4400)" {
  let h = graphql_ws_handler(
    sub_schema(),
    @exec.Resolvers::new(),
    sub_subscribers(),
  )
  assert_eq(close_code((h.on_receive)(@ws.Binary(b"\x00"))), 4400)
}

///|
test "graphql-transport-ws sends an error message for a request that cannot start" {
  let h = graphql_ws_handler(
    sub_schema(),
    @exec.Resolvers::new(),
    sub_subscribers(),
  )
  (h.on_receive)(ctrl_frame("connection_init")) |> ignore
  // A parse failure is a request error -> a single `error` message, not a `next`.
  let out = sent_texts((h.on_receive)(subscribe_frame("9", "{")))
  assert_eq(out.length(), 1)
  assert_eq(out[0].contains("\"type\":\"error\""), true)
  assert_eq(out[0].contains("\"id\":\"9\""), true)
}

///|
test "graphql-transport-ws runs a query over the subscribe transport (single next + complete)" {
  let r = @exec.Resolvers::new()
  r.field("Query", "ok", _info => Json("yes"))
  let h = graphql_ws_handler(sub_schema(), r, sub_subscribers())
  (h.on_receive)(ctrl_frame("connection_init")) |> ignore
  let out = sent_texts((h.on_receive)(subscribe_frame("q1", "{ ok }")))
  assert_eq(out.length(), 2)
  assert_eq(
    out[0],
    "{\"id\":\"q1\",\"type\":\"next\",\"payload\":{\"data\":{\"ok\":\"yes\"}}}",
  )
  assert_eq(out[1], "{\"id\":\"q1\",\"type\":\"complete\"}")
}

///|
test "graphql-transport-ws negotiates the subprotocol on connect" {
  let h = graphql_ws_handler(
    sub_schema(),
    @exec.Resolvers::new(),
    sub_subscribers(),
  )
  let offered = @moonasgi.WebSocketScope::new(path="/graphql", subprotocols=[
    "graphql-transport-ws",
  ])
  let chosen = match (h.on_connect)(offered) {
    @ws.Accept(subprotocol~, ..) => subprotocol
    _ => None
  }
  assert_eq(chosen, Some("graphql-transport-ws"))
  let bare = @moonasgi.WebSocketScope::new(path="/graphql")
  let none_chosen = match (h.on_connect)(bare) {
    @ws.Accept(subprotocol~, ..) => subprotocol
    _ => Some("unexpected")
  }
  assert_eq(none_chosen, None)
}

///|
/// The keep-alive clock is armed by the first tick, whatever the monotonic clock
/// reads there. A server whose clock does not start at zero — every real one —
/// must not be pinged on the first tick after it initialises.
test "graphql-transport-ws arms the ping clock from the first tick" {
  let ws = GqlWs::new(
    sub_schema(),
    @exec.Resolvers::new(),
    sub_subscribers(),
    ping_interval=12000,
  )
  ws.tick(1000000L) |> ignore
  ws.recv(ctrl_frame("connection_init")) |> ignore
  assert_eq(sent_texts(ws.tick(1005000L)).length(), 0)
  assert_eq(sent_texts(ws.tick(1012000L)).length(), 1)
}
