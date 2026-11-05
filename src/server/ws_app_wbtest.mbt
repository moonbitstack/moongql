///|
/// The WebSocket application driven the way a server drives it: a scope and a
/// stream of events in, the events it answers out. The frames are the ones a
/// client reads off the wire, so the protocol is checked where it is written.
///
/// This is the only way to hold `graphql_ws_app` still: it runs until the socket
/// closes, so a test hands it events and reads what it says in between.
struct Socket {
  inbox : @aqueue.Queue[@spec.Event]
  outbox : @aqueue.Queue[@spec.Event]
}

///|
/// Open a connection's protocol state and the two queues a scripted socket needs.
async fn socket() -> Socket {
  let inbox : @aqueue.Queue[@spec.Event] = @aqueue.Queue::Queue(
    kind=@aqueue.Unbounded,
  )
  let outbox : @aqueue.Queue[@spec.Event] = @aqueue.Queue::Queue(
    kind=@aqueue.Unbounded,
  )
  inbox.put(@spec.Event::WebSocketConnect)
  ({ inbox, outbox, } : Socket)
}

///|
/// The next event the application writes, or a stop if it says nothing for long
/// enough that the expectation is clearly not coming.
async fn next_event(s : Socket) -> @spec.Event {
  match @async.with_timeout_opt(2000, async fn() { s.outbox.get() }) {
    Some(e) => e
    None => abort("the application wrote nothing")
  }
}

///|
/// The text of the next frame, insisting it is one.
async fn next_text(s : Socket) -> String {
  match next_event(s) {
    @spec.Event::WebSocketSendText(t) => t
    @spec.Event::WebSocketAccept(..) =>
      abort("expected a text frame, got accept")
    @spec.Event::WebSocketClose(code~, ..) =>
      abort("expected a text frame, got close " + code.to_string())
    _ => abort("expected a text frame")
  }
}

///|
/// The audit schema, with one subscription that ends by itself.
fn ws_schema() -> @schema.Schema {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("hello", NonNull(@schema.Scalar("String")))
  let sub = s.object("Subscription")
  sub.field("tick", NonNull(@schema.Named("Tick")))
  let t = s.object("Tick")
  t.field("n", NonNull(@schema.Scalar("Int")))
  s.set_subscription("Subscription")
  s
}

///|
/// The subscribers behind `ws_schema`: two events, then the source ends.
fn ws_subscribers() -> @exec.Subscribers {
  let subs = @exec.Subscribers::new()
  subs.stream("Subscription", "tick", fn(_info) {
    let (stream, sender) = @exec.Stream::channel()
    for i in 1..<=2 {
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
/// Drive `graphql_ws_app` over a scripted socket: the handshake, a subscription,
/// its events, and the client's `complete`.
async test "ws app: the handshake, a subscription and its events" {
  let s = ws_schema()
  let r = @exec.Resolvers::new()
  r.field("Query", "hello", fn(_info) { Json("hello") })
  let app = graphql_ws_app(s, r, ws_subscribers())
  let sock = socket()
  @async.with_task_group(async fn(group) {
    let _ = group.spawn(async fn() {
      let receive : @moonasgi.Receive = () => sock.inbox.get()
      let send : @moonasgi.Send = e => sock.outbox.put(e) catch { _ => () }
      app(
        @spec.Scope::WebSocket(
          @spec.WebSocketScope::new(path="/graphql", subprotocols=[
            "graphql-transport-ws",
          ]),
        ),
        receive,
        send,
      )
    })
    match next_event(sock) {
      @spec.Event::WebSocketAccept(subprotocol~, ..) =>
        assert_eq(subprotocol, Some("graphql-transport-ws"))
      _ => abort("the connection was not accepted")
    }
    sock.inbox.put(
      @spec.Event::WebSocketReceive(
        text=Some("{\"type\":\"connection_init\"}"),
        bytes=None,
      ),
    )
    inspect(next_text(sock), content="{\"type\":\"connection_ack\"}")
    sock.inbox.put(
      @spec.Event::WebSocketReceive(
        text=Some(
          "{\"id\":\"1\",\"type\":\"subscribe\",\"payload\":{\"query\":\"subscription { tick { n } }\"}}",
        ),
        bytes=None,
      ),
    )
    inspect(
      next_text(sock),
      content="{\"id\":\"1\",\"type\":\"next\",\"payload\":{\"data\":{\"tick\":{\"n\":1}}}}",
    )
    inspect(
      next_text(sock),
      content="{\"id\":\"1\",\"type\":\"next\",\"payload\":{\"data\":{\"tick\":{\"n\":2}}}}",
    )
    inspect(next_text(sock), content="{\"id\":\"1\",\"type\":\"complete\"}")
    // The id is free again: a second subscription on the same connection is
    // accepted rather than closed with 4409.
    sock.inbox.put(
      @spec.Event::WebSocketReceive(
        text=Some(
          "{\"id\":\"1\",\"type\":\"subscribe\",\"payload\":{\"query\":\"subscription { tick { n } }\"}}",
        ),
        bytes=None,
      ),
    )
    inspect(
      next_text(sock),
      content="{\"id\":\"1\",\"type\":\"next\",\"payload\":{\"data\":{\"tick\":{\"n\":1}}}}",
    )
    sock.inbox.put(
      @spec.Event::WebSocketDisconnect(code=1000, reason=Some("bye")),
    )
  })
}

///|
/// A subscribe before `connection_init` is a 4401 close, which is what the
/// protocol says an unauthorized subscriber gets.
async test "ws app: a subscribe before the handshake closes with 4401" {
  let s = ws_schema()
  let app = graphql_ws_app(s, @exec.Resolvers::new(), ws_subscribers())
  let sock = socket()
  @async.with_task_group(async fn(group) {
    let _ = group.spawn(async fn() {
      let receive : @moonasgi.Receive = () => sock.inbox.get()
      let send : @moonasgi.Send = e => sock.outbox.put(e) catch { _ => () }
      app(
        @spec.Scope::WebSocket(
          @spec.WebSocketScope::new(path="/graphql", subprotocols=[
            "graphql-transport-ws",
          ]),
        ),
        receive,
        send,
      )
    })
    let _ = next_event(sock)
    sock.inbox.put(
      @spec.Event::WebSocketReceive(
        text=Some(
          "{\"id\":\"1\",\"type\":\"subscribe\",\"payload\":{\"query\":\"subscription { tick { n } }\"}}",
        ),
        bytes=None,
      ),
    )
    match next_event(sock) {
      @spec.Event::WebSocketClose(code~, ..) => assert_eq(code, 4401)
      _ => abort("expected a 4401 close")
    }
    sock.inbox.put(
      @spec.Event::WebSocketDisconnect(code=1000, reason=Some("bye")),
    )
  })
}
