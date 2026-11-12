// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Serving `graphql-transport-ws` over a real socket: an ASGI application that
/// holds a WebSocket open, keeps a task per running subscription, and writes each
/// event as it arrives.
///
/// `graphql_ws_handler` deals in pull sources — everything it sends is already
/// known when it answers a message — which is what moonasgi's synchronous
/// WebSocket seam can express. A subscription to a live feed has to write between
/// messages, so it needs the asynchronous half of the seam: this application
/// receives and sends `spec.Event` values itself, and any ASGI server serves it
/// as it serves any other application.
///
/// The protocol state is the `GqlWs` the message-level handler already uses:
/// `claim` marks an id as running and `release` frees it, so 4409 keeps meaning
/// "a subscriber with this id is still running" rather than "this id was used
/// once". Writes go through one mutex, because two tasks writing the same socket
/// is the one thing this seam does not allow.

///|
/// The application that serves `graphql-transport-ws` on `path` for `schema`,
/// `resolvers` and `subscribers`.
///
/// A request that is not a WebSocket upgrade on `path` is answered with a 404, so
/// one application can be mounted beside a plain HTTP endpoint.
pub fn graphql_ws_app(
  schema : @schema.Schema,
  resolvers : @exec.Resolvers,
  subscribers : @exec.Subscribers,
  root_value~ : Json = Json::null(),
  context~ : Json = Json::null(),
  path~ : String = "/graphql",
  limits~ : @exec.Limits = @exec.limits,
) -> @moonasgi.AsgiApp {
  async fn(scope, receive, send) {
    match scope {
      @spec.WebSocket(ws) =>
        if ws.path != path {
          send(close_event(4404, "Not Found"))
        } else {
          serve_connection(
            ws, receive, send, schema, resolvers, subscribers, root_value, context,
            limits,
          )
        }
      _ => not_found(send)
    }
  }
}

///|
/// A 404 for a plain HTTP request to the socket's path.
async fn not_found(send : @moonasgi.Send) -> Unit {
  let body = @utf8.encode("Not Found")
  send(
    @spec.Event::HttpResponseStart(
      status=404,
      headers=[
        ("content-type", "text/plain; charset=utf-8"),
        ("content-length", body.length().to_string()),
      ],
      trailers=false,
    ),
  )
  send(@spec.Event::HttpResponseBody(body~, more_body=false))
}

///|
/// A protocol close frame as the event on the wire.
fn close_event(code : Int32, reason : String) -> @spec.Event {
  @spec.Event::WebSocketClose(code~, reason~)
}

///|
/// One connection: negotiate the subprotocol, then read messages until the client
/// goes away, keeping a task for every running subscription.
async fn serve_connection(
  ws : @spec.WebSocketScope,
  receive : @moonasgi.Receive,
  send : @moonasgi.Send,
  schema : @schema.Schema,
  resolvers : @exec.Resolvers,
  subscribers : @exec.Subscribers,
  root_value : Json,
  context : Json,
  limits : @exec.Limits,
) -> Unit {
  let _ = receive()
  let protocol = if ws.subprotocols.contains("graphql-transport-ws") {
    Some("graphql-transport-ws")
  } else {
    None
  }
  send(@spec.Event::WebSocketAccept(subprotocol=protocol, headers=[]))
  let gql = GqlWs::new(schema, resolvers, subscribers, root_value~, context~)
  let writer = @async.Mutex::Mutex()
  let running : Map[String, @async.Task[Unit]] = Map([])
  @async.with_task_group(async fn(group) {
    let mut open = true
    while open {
      let event = receive()
      match event {
        @spec.WebSocketReceive(text=Some(text), ..) =>
          handle_text(
            gql, group, running, writer, send, schema, resolvers, subscribers, text,
            root_value, limits,
          )
        @spec.WebSocketReceive(bytes=Some(_), ..) =>
          write_event(
            writer,
            send,
            close_event(4400, "binary frames are not allowed"),
          )
        @spec.WebSocketDisconnect(code=_, reason=_) => open = false
        _ => ()
      }
    }
    // The socket is gone: every subscription on it goes with it.
    for _, task in running {
      task.cancel()
    }
  })
}

///|
/// Write one event, holding the connection's write lock.
async fn write_event(
  writer : @async.Mutex,
  send : @moonasgi.Send,
  event : @spec.Event,
) -> Unit {
  writer.acquire()
  defer writer.release()
  send(event)
}

///|
/// Write one already-encoded protocol message.
async fn write_text(
  writer : @async.Mutex,
  send : @moonasgi.Send,
  text : String,
) -> Unit {
  write_event(writer, send, @spec.Event::WebSocketSendText(text))
}

///|
/// Handle one inbound text frame. The handshake messages reuse the message-level
/// state machine, so the acknowledgement and the connection parameters are the
/// ones the synchronous handler produces; `subscribe` may open a live stream and
/// therefore a task.
async fn handle_text(
  gql : GqlWs,
  group : @async.TaskGroup[Unit],
  running : Map[String, @async.Task[Unit]],
  writer : @async.Mutex,
  send : @moonasgi.Send,
  schema : @schema.Schema,
  resolvers : @exec.Resolvers,
  subscribers : @exec.Subscribers,
  text : String,
  root_value : Json,
  limits : @exec.Limits,
) -> Unit {
  let json = @moonjson.loads(text, @moonjson.strict) catch { _ => return }
  let obj = match json {
    Object(m) => m
    _ => return
  }
  let mtype = match obj.get("type") {
    Some(String(s)) => s
    _ =>
      return write_event(
        writer,
        send,
        close_event(4400, "message is missing 'type'"),
      )
  }
  let id : String? = match obj.get("id") {
    Some(String(i)) => Some(i)
    _ => None
  }
  match mtype {
    "connection_init" => {
      let frames = gql.recv(@ws.Text(text))
      for frame in frames {
        write_send(writer, send, frame)
      }
    }
    "ping" | "pong" => {
      let frames = gql.recv(@ws.Text(text))
      for frame in frames {
        write_send(writer, send, frame)
      }
    }
    "complete" =>
      match id {
        Some(i) =>
          match running.get(i) {
            Some(task) => task.cancel()
            None => gql.release(i)
          }
        None => ()
      }
    "subscribe" =>
      match id {
        Some(i) =>
          subscribe(
            gql, group, running, writer, send, schema, resolvers, subscribers, i,
            obj, root_value, limits,
          )
        None =>
          write_event(
            writer,
            send,
            close_event(4400, "subscribe requires an 'id'"),
          )
      }
    _ =>
      write_event(
        writer,
        send,
        close_event(4400, "invalid message type: " + mtype),
      )
  }
}

///|
/// A `WsSend` frame the message-level handler produced, as the event the socket
/// carries.
async fn write_send(
  writer : @async.Mutex,
  send : @moonasgi.Send,
  frame : @moonasgi.WsSend,
) -> Unit {
  match frame {
    @ws.SendText(t) => write_text(writer, send, t)
    @ws.SendBinary(b) =>
      write_event(writer, send, @spec.Event::WebSocketSendBytes(b))
    @ws.Close(code~, reason~) =>
      write_event(writer, send, close_event(code, reason))
  }
}

///|
/// Start the operation a `subscribe` message describes: a query or mutation runs
/// at once and answers one payload; a subscription to a live source gets a task
/// that writes `next` frames until the source ends or the client cancels it.
async fn subscribe(
  gql : GqlWs,
  group : @async.TaskGroup[Unit],
  running : Map[String, @async.Task[Unit]],
  writer : @async.Mutex,
  send : @moonasgi.Send,
  schema : @schema.Schema,
  resolvers : @exec.Resolvers,
  subscribers : @exec.Subscribers,
  id : String,
  obj : Map[String, Json],
  root_value : Json,
  limits : @exec.Limits,
) -> Unit {
  if !gql.initialized {
    return write_event(writer, send, close_event(4401, "Unauthorized"))
  }
  if !gql.claim(id) {
    return write_event(
      writer,
      send,
      close_event(4409, "Subscriber for " + id + " already exists"),
    )
  }
  let payload = match obj.get("payload") {
    Some(Object(p)) => p
    _ => {
      gql.release(id)
      return write_text(
        writer,
        send,
        err_message(id, "subscribe is missing 'payload'"),
      )
    }
  }
  let query = match payload.get("query") {
    Some(String(q)) => q
    _ => {
      gql.release(id)
      return write_text(
        writer,
        send,
        err_message(id, "subscribe payload is missing 'query'"),
      )
    }
  }
  let variables : Map[String, Json] = match payload.get("variables") {
    Some(Object(v)) => v
    _ => Map([])
  }
  let operation_name : String? = match payload.get("operationName") {
    Some(String(n)) => Some(n)
    _ => None
  }
  let op_context = gql.op_context()
  let task = group.spawn(async fn() {
    defer gql.release(id)
    run_operation(
      writer, send, schema, resolvers, subscribers, id, query, variables, operation_name,
      root_value, op_context, limits,
    )
  })
  running[id] = task
}

///|
/// The body of one subscription task: a subscription opens a stream and writes a
/// `next` frame per payload; anything else runs once. A request that cannot start
/// answers one `error` frame, which is the protocol's distinction between a
/// request error and an execution result.
async fn run_operation(
  writer : @async.Mutex,
  send : @moonasgi.Send,
  schema : @schema.Schema,
  resolvers : @exec.Resolvers,
  subscribers : @exec.Subscribers,
  id : String,
  query : String,
  variables : Map[String, Json],
  operation_name : String?,
  root_value : Json,
  context : Json,
  limits : @exec.Limits,
) -> Unit {
  let kind = operation_type_of(schema, query, operation_name)
  match kind {
    Err(errs) =>
      write_text(
        writer,
        send,
        gql_ws_message("error", Some(id), Some(gql_ws_errors_json(errs))),
      )
    Ok(@lang.Subscription) =>
      match
        @exec.subscribe_live(
          schema,
          resolvers,
          subscribers,
          query,
          variables~,
          operation_name?,
          root_value~,
          context~,
          limits~,
        ) {
        Err(errs) =>
          write_text(
            writer,
            send,
            gql_ws_message("error", Some(id), Some(gql_ws_errors_json(errs))),
          )
        Ok(live) => {
          defer live.close()
          let mut more = true
          while more {
            let next = live.next() catch { _ => break }
            match next {
              Some(payload) =>
                write_text(
                  writer,
                  send,
                  gql_ws_message("next", Some(id), Some(payload)),
                )
              None => more = false
            }
          }
          write_text(writer, send, gql_ws_message("complete", Some(id), None))
        }
      }
    Ok(_) => {
      let result = @exec.execute_async(
        schema,
        resolvers,
        query,
        variables~,
        operation_name?,
        root_value~,
        context~,
      )
      write_text(writer, send, gql_ws_message("next", Some(id), Some(result)))
      write_text(writer, send, gql_ws_message("complete", Some(id), None))
    }
  }
}
