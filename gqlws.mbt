///|
/// The `graphql-transport-ws` subprotocol (the wire protocol GraphiQL and the
/// `graphql-ws` client library speak, and what strawberry serves) over the
/// moonasgi WebSocket seam. A `WebSocketHandler` whose `on_receive` folds each
/// inbound control message into the frames a server sends back:
///
/// - `connection_init` -> `connection_ack` (a second init closes with 4429); its
///   `payload` becomes the connection parameters every operation sees on its
///   context
/// - `ping` -> `pong` (echoing any payload)
/// - `subscribe` -> a run of `next` messages, one per event, then `complete`;
///   a request that fails to start (parse/validation/no-source) yields a single
///   `error` message instead, per the spec's distinction between a request error
///   and an execution result
/// - `complete` (client) -> the operation id is released for reuse
///
/// A `subscribe` before `connection_init` closes with 4401, and a `subscribe`
/// naming an id that is currently running closes with 4409; an id whose operation
/// has finished is free again, which is what the protocol means by unique "among
/// all *active* subscribers". A binary frame or an unparseable message closes with
/// 4400.
///
/// The source is the synchronous pull stream from `create_source_event_stream`,
/// so a subscription's events are delivered as an ordered `next` run followed by
/// `complete` — the protocol exactly as a client observes it, testable on every
/// backend through the moonasgi `TestClient` without an async runtime. A live
/// async source (an infinite stream that blocks between events) is the async
/// native variant that lifts this same message handling onto a real socket.

///|
/// One `graphql-transport-ws` connection: the schema it serves plus the protocol
/// state a connection carries — whether `connection_init` has arrived, the
/// parameters it brought, the operation ids currently running, and the two timers
/// the protocol defines.
///
/// This package has no async runtime and no clock of its own, so the timers are
/// state plus a transition and nothing more: a server drives them by calling
/// `tick` with a millisecond reading of a monotonic clock, as often as it likes
/// (once a second is plenty), and sending whatever frames come back. Nothing else
/// starts the connection-init countdown or emits a keep-alive `ping`.
pub struct GqlWs {
  schema : Schema
  resolvers : Resolvers
  subscribers : Subscribers
  root_value : Json
  context : Json
  init_timeout : Int64
  ping_interval : Int64
  mut initialized : Bool
  mut params : Json
  mut opened : Int64?
  mut pinged : Int64
  active : Map[String, Unit]
}

///|
/// Open a connection's protocol state for `schema` / `resolvers` / `subscribers`.
/// `root_value` and `context` are threaded to every operation the way `execute`
/// threads them.
///
/// `init_timeout` is how long a client may take to send `connection_init` before
/// `tick` closes the socket with 4408, and `ping_interval` how long the server
/// waits between keep-alive `ping` frames; both are milliseconds, and either is
/// switched off by passing zero.
pub fn GqlWs::new(
  schema : Schema,
  resolvers : Resolvers,
  subscribers : Subscribers,
  root_value? : Json = Json::null(),
  context? : Json = Json::null(),
  init_timeout? : Int64 = 3000,
  ping_interval? : Int64 = 12000,
) -> GqlWs {
  {
    schema,
    resolvers,
    subscribers,
    root_value,
    context,
    init_timeout,
    ping_interval,
    initialized: false,
    params: Json::null(),
    opened: None,
    pinged: 0,
    active: Map([]),
  }
}

///|
/// Handle one inbound message, returning the frames to send back.
pub fn GqlWs::recv(
  self : GqlWs,
  msg : @moonasgi.WsMessage,
) -> Array[@moonasgi.WsSend] {
  match msg {
    @ws.Text(t) => self.recv_text(t)
    @ws.Binary(_) =>
      [@ws.Close(code=4400, reason="binary frames are not allowed")]
  }
}

///|
/// Drive the connection's timers from a monotonic clock reading in milliseconds,
/// returning the frames the elapsed time calls for: the 4408 close when
/// `connection_init` did not arrive in time, or a keep-alive `ping`.
///
/// The first call starts the clock, so a server should tick as soon as it has
/// accepted the socket and keep ticking for as long as it holds it.
pub fn GqlWs::tick(self : GqlWs, now : Int64) -> Array[@moonasgi.WsSend] {
  let since = match self.opened {
    None => {
      self.opened = Some(now)
      self.pinged = now
      return []
    }
    Some(t0) => now - t0
  }
  if not(self.initialized) {
    if self.init_timeout > 0 && since >= self.init_timeout {
      return [@ws.Close(code=4408, reason="Connection initialisation timeout")]
    }
    return []
  }
  if self.ping_interval > 0 && now - self.pinged >= self.ping_interval {
    self.pinged = now
    return [@ws.SendText(gql_ws_message("ping", None, None))]
  }
  []
}

///|
/// Claim operation `id` for an operation that is starting, answering `false` when
/// the id is already running — the caller must then close the socket with 4409.
///
/// `recv` claims and releases an id itself, because a pull source is drained
/// before it returns. A server streaming a live source claims the id when it
/// starts the task and calls `release` when the task sends its last frame; that is
/// what keeps 4409 meaning "still running" rather than "used once".
pub fn GqlWs::claim(self : GqlWs, id : String) -> Bool {
  if self.active.get(id) is Some(_) {
    return false
  }
  self.active[id] = ()
  true
}

///|
/// Release operation `id`, freeing it for reuse. Called after the operation's
/// terminating `complete` or `error` has been sent.
pub fn GqlWs::release(self : GqlWs, id : String) -> Unit {
  self.active.remove(id)
}

///|
/// The connection as a moonasgi `WebSocketHandler`, negotiating the
/// `graphql-transport-ws` subprotocol when the client offers it.
pub fn GqlWs::handler(self : GqlWs) -> @moonasgi.WebSocketHandler {
  @moonasgi.WebSocketHandler::new(
    on_connect=fn(scope) {
      if scope.subprotocols.contains("graphql-transport-ws") {
        @ws.Accept(subprotocol=Some("graphql-transport-ws"), headers=[])
      } else {
        @ws.Accept(subprotocol=None, headers=[])
      }
    },
    on_receive=fn(msg) { self.recv(msg) },
  )
}

///|
/// Build a `graphql-transport-ws` WebSocket handler for `schema` / `resolvers` /
/// `subscribers`. `root_value` and `context` are threaded to every operation the
/// way `execute` threads them. Negotiates the `graphql-transport-ws` subprotocol
/// when the client offers it.
///
/// The handler owns its connection state, so nothing can drive the protocol's
/// timers: build a `GqlWs` and take its `handler` when the server can tick.
pub fn graphql_ws_handler(
  schema : Schema,
  resolvers : Resolvers,
  subscribers : Subscribers,
  root_value? : Json = Json::null(),
  context? : Json = Json::null(),
) -> @moonasgi.WebSocketHandler {
  GqlWs::new(schema, resolvers, subscribers, root_value~, context~).handler()
}

///|
/// A server-to-client message `{ id?, type, payload? }` as a JSON string.
fn gql_ws_message(type_ : String, id : String?, payload : Json?) -> String {
  let entries : Array[(String, Json)] = []
  match id {
    Some(i) => entries.push(("id", i.to_json()))
    None => ()
  }
  entries.push(("type", type_.to_json()))
  match payload {
    Some(p) => entries.push(("payload", p))
    None => ()
  }
  jobj(entries).stringify()
}

///|
/// Serialise a request error list as the `error` message's payload — a JSON array
/// of GraphQL error objects.
fn gql_ws_errors_json(errors : Array[GqlError]) -> Json {
  let arr : Array[Json] = []
  for e in errors {
    arr.push(e.to_json())
  }
  arr.to_json()
}

///|
/// The context an operation on this connection runs with: the configured context
/// value, carrying the `connection_init` payload under `connectionParams` so a
/// resolver can read the credentials the client connected with. A context that is
/// not an object has nothing to merge into and is passed through unchanged.
fn GqlWs::op_context(self : GqlWs) -> Json {
  if self.params is Null {
    return self.context
  }
  match self.context {
    Object(m) => {
      let merged : Map[String, Json] = Map([])
      for k, v in m {
        merged[k] = v
      }
      merged["connectionParams"] = self.params
      merged.to_json()
    }
    Null => jobj([("connectionParams", self.params)])
    other => other
  }
}

///|
/// Handle one text frame, returning the frames to send back. Parses the control
/// message and dispatches on its `type`.
fn GqlWs::recv_text(self : GqlWs, text : String) -> Array[@moonasgi.WsSend] {
  let json = @json.parse(text) catch {
    _ => return [@ws.Close(code=4400, reason="invalid JSON")]
  }
  let obj = match json {
    Object(m) => m
    _ => return [@ws.Close(code=4400, reason="message must be an object")]
  }
  let mtype = match obj.get("type") {
    Some(String(s)) => s
    _ => return [@ws.Close(code=4400, reason="message is missing 'type'")]
  }
  match mtype {
    "connection_init" =>
      if self.initialized {
        [@ws.Close(code=4429, reason="Too many initialisation requests")]
      } else {
        self.initialized = true
        self.params = match obj.get("payload") {
          Some(p) => p
          None => Json::null()
        }
        [@ws.SendText(gql_ws_message("connection_ack", None, None))]
      }
    "ping" => [@ws.SendText(gql_ws_message("pong", None, obj.get("payload")))]
    "pong" => []
    // The client wants to stop an operation. A pull source has already finished,
    // so there is nothing to cancel — but the id it was running under is now free.
    "complete" => {
      match obj.get("id") {
        Some(String(i)) => self.release(i)
        _ => ()
      }
      []
    }
    "subscribe" => self.subscribe(obj)
    _ => [@ws.Close(code=4400, reason="invalid message type: " + mtype)]
  }
}

///|
/// Handle a `subscribe` message: authorise, claim the id, run the operation, and
/// map the outcome to `next`* + `complete` (success) or a single `error`. Either
/// way the operation is over by the time the frames go out, so the id is released.
fn GqlWs::subscribe(
  self : GqlWs,
  obj : Map[String, Json],
) -> Array[@moonasgi.WsSend] {
  if not(self.initialized) {
    return [@ws.Close(code=4401, reason="Unauthorized")]
  }
  let id = match obj.get("id") {
    Some(String(i)) => i
    _ => return [@ws.Close(code=4400, reason="subscribe requires an 'id'")]
  }
  if not(self.claim(id)) {
    return [
      @ws.Close(code=4409, reason="Subscriber for " + id + " already exists"),
    ]
  }
  let sends = self.run(id, obj)
  self.release(id)
  sends
}

///|
/// Run the operation a claimed `subscribe` message describes.
fn GqlWs::run(
  self : GqlWs,
  id : String,
  obj : Map[String, Json],
) -> Array[@moonasgi.WsSend] {
  let payload = match obj.get("payload") {
    Some(Object(p)) => p
    _ =>
      return [@ws.SendText(err_message(id, "subscribe is missing 'payload'"))]
  }
  let query = match payload.get("query") {
    Some(String(q)) => q
    _ =>
      return [
        @ws.SendText(err_message(id, "subscribe payload is missing 'query'")),
      ]
  }
  let variables : Map[String, Json] = match payload.get("variables") {
    Some(Object(v)) => v
    _ => Map([])
  }
  let operation_name : String? = match payload.get("operationName") {
    Some(String(n)) => Some(n)
    _ => None
  }
  let context = self.op_context()
  match operation_type_of(self.schema, query, operation_name) {
    Err(errs) =>
      [
        @ws.SendText(
          gql_ws_message("error", Some(id), Some(gql_ws_errors_json(errs))),
        ),
      ]
    Ok(Subscription) =>
      match
        create_source_event_stream(
          self.schema,
          self.resolvers,
          self.subscribers,
          query,
          variables~,
          operation_name?,
          root_value=self.root_value,
          context~,
        ) {
        RequestError(errs) =>
          [
            @ws.SendText(
              gql_ws_message("error", Some(id), Some(gql_ws_errors_json(errs))),
            ),
          ]
        EventStream(payloads) => {
          let sends : Array[@moonasgi.WsSend] = []
          for p in payloads {
            sends.push(@ws.SendText(gql_ws_message("next", Some(id), Some(p))))
          }
          sends.push(@ws.SendText(gql_ws_message("complete", Some(id), None)))
          sends
        }
      }
    Ok(_) => {
      // A query or mutation over the subscribe transport: a single execution
      // result, then complete.
      let result = execute(
        self.schema,
        self.resolvers,
        query,
        variables~,
        operation_name?,
        root_value=self.root_value,
        context~,
      )
      [
        @ws.SendText(gql_ws_message("next", Some(id), Some(result))),
        @ws.SendText(gql_ws_message("complete", Some(id), None)),
      ]
    }
  }
}

///|
/// Build an `error` message carrying a single message string.
fn err_message(id : String, message : String) -> String {
  gql_ws_message(
    "error",
    Some(id),
    Some(gql_ws_errors_json([GqlError::msg(message)])),
  )
}

///|
/// Parse, validate, and select `query`'s operation, returning its type or the
/// request errors that stop it from starting. The peek that routes a `subscribe`
/// to the subscription stream or to `execute` (query/mutation), and turns a
/// parse/validation failure into an `error` message rather than a `next`.
fn operation_type_of(
  schema : Schema,
  query : String,
  operation_name : String?,
) -> Result[OperationType, Array[GqlError]] {
  let doc = parse(query) catch {
    GqlSyntaxError(m, line, col) =>
      return Err([GqlError::at(m, { line, col, })])
  }
  let verrors = validate(schema, doc)
  if verrors.length() > 0 {
    return Err(verrors)
  }
  match select_operation(schema, doc, operation_name) {
    Ok(p) => Ok(p.operation.operation)
    Err(e) => Err([e])
  }
}
