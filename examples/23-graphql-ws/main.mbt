///|
/// A `connection_init` frame carrying the connection's parameters.
fn init_frame(params : Json) -> @moonasgi.WsMessage {
  let m : Json = { "type": "connection_init", "payload": params }
  @ws.Text(m.stringify())
}

///|
/// A `subscribe` frame `{ id, type, payload: { query } }` as a text message.
fn subscribe_frame(id : String, query : String) -> @moonasgi.WsMessage {
  let payload : Json = { "query": Json(query) }
  let m : Json = { "id": Json(id), "type": "subscribe", "payload": payload }
  @ws.Text(m.stringify())
}

///|
/// The text bodies of the `SendText` frames a handler emits, in order.
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
/// The close code in a reply, or -1 when it did not close.
fn close_code(sends : Array[@moonasgi.WsSend]) -> Int32 {
  for s in sends {
    if s is @ws.Close(code~, ..) {
      return code
    }
  }
  -1
}

///|
/// Subscriptions over the `graphql-transport-ws` protocol. `GqlWs` is one
/// connection's protocol state and `recv` maps a client frame to the frames sent
/// back — the synchronous seam under the async socket. A `connection_init` is
/// answered with `connection_ack` and its payload reaches every resolver's context
/// under `connectionParams`; a `subscribe` streams one `next` per source event and
/// closes with `complete`, which frees its id for the next operation.
///
/// The protocol's two timers are state here, not threads: `tick` takes a
/// millisecond clock reading from the server and hands back the 4408 close for a
/// `connection_init` that never arrived, or a keep-alive `ping`. `graphql_ws_handler`
/// wraps a connection whose timers nothing drives.
///
///     moon run examples/23-graphql-ws
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field("ok", @moongql.NonNull(@moongql.Scalar("String")))
  s.set_subscription("Subscription")
  let sub = s.object("Subscription")
  sub.field("ticks", @moongql.NonNull(@moongql.Scalar("Int")))
  let subs = @moongql.Subscribers::new()
  subs.field("Subscription", "ticks", _info => [Json(1), Json(2)])
  let r = @moongql.Resolvers::new()
  r.field("Query", "ok", info => {
    match info.ctx {
      Object(m) =>
        match m.get("connectionParams") {
          Some(p) => p
          None => Json("no params")
        }
      _ => Json("no context")
    }
  })
  let ws = @moongql.GqlWs::new(s, r, subs)
  let params : Json = { "token": "heke1228" }
  for t in sent_texts(ws.recv(init_frame(params))) {
    println("ack: " + t)
  }
  for t in sent_texts(ws.recv(subscribe_frame("1", "subscription { ticks }"))) {
    println("frame: " + t)
  }
  // The id was released with the `complete` above, so the client may reuse it.
  println(
    "id reusable: \{close_code(ws.recv(subscribe_frame("1", "subscription { ticks }"))) == -1}",
  )
  for t in sent_texts(ws.recv(subscribe_frame("2", "{ ok }"))) {
    println("params: " + t)
  }
  ws.tick(0L) |> ignore
  for t in sent_texts(ws.tick(12000L)) {
    println("keep-alive: " + t)
  }
  let silent = @moongql.GqlWs::new(s, r, subs, init_timeout=3000)
  silent.tick(0L) |> ignore
  println("no init after 3s: \{close_code(silent.tick(3000L))}")
}
