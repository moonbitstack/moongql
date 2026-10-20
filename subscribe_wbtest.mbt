///|
/// Build a `Message` object value for the subscription source stream.
fn jmsg(id : String, body : String, channel : String) -> Json {
  let m : Map[String, Json] = Map([])
  m["id"] = Json(id)
  m["body"] = Json(body)
  m["channel"] = Json(channel)
  Json(m)
}

///|
/// `Subscription { messageAdded(channel: String!): Message!, ticks: Int! }` plus
/// a `Message` object and a minimal `Query`.
fn sub_schema() -> Schema {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("ok", NonNull(Scalar("String")))
  s.set_subscription("Subscription")
  let sub = s.object("Subscription")
  sub.field_args(
    "messageAdded",
    [("channel", NonNull(Scalar("String")))],
    NonNull(Named("Message")),
  )
  sub.field("ticks", NonNull(Scalar("Int")))
  let msg = s.object("Message")
  msg.field("id", NonNull(Scalar("ID")))
  msg.field("body", NonNull(Scalar("String")))
  msg.field("channel", NonNull(Scalar("String")))
  s
}

///|
/// The `messageAdded` source emits three messages tagged with the requested
/// channel; each becomes the resolved value of the root field for one payload.
fn sub_subscribers() -> Subscribers {
  let subs = Subscribers::new()
  subs.field("Subscription", "messageAdded", fn(info) {
    let ch = match info.arg("channel") {
      String(s) => s
      _ => ""
    }
    [jmsg("1", "hello", ch), jmsg("2", "world", ch), jmsg("3", "bye", ch)]
  })
  subs.field("Subscription", "ticks", fn(_info) { [Json(1), Json(2)] })
  subs
}

///|
/// A subscription delivers an ordered sequence of `{ data }` payloads, one per
/// source event, with the argument threaded into the source — the "can actually
/// run" milestone for streaming.
test "subscription yields an ordered stream of payloads" {
  let query =
    #|subscription Feed($c: String!) {
    #|  messageAdded(channel: $c) { id body channel }
    #|}
  let vars : Map[String, Json] = Map([])
  vars["c"] = Json("general")
  let payloads = execute_subscription(
    sub_schema(),
    Resolvers::new(),
    sub_subscribers(),
    query,
    variables=vars,
  )
  assert_eq(payloads.length(), 3)
  assert_eq(
    payloads[0].stringify(),
    (
      #|{"data":{"messageAdded":{"id":"1","body":"hello","channel":"general"}}}
    ),
  )
  assert_eq(
    payloads[1].stringify(),
    (
      #|{"data":{"messageAdded":{"id":"2","body":"world","channel":"general"}}}
    ),
  )
  assert_eq(
    payloads[2].stringify(),
    (
      #|{"data":{"messageAdded":{"id":"3","body":"bye","channel":"general"}}}
    ),
  )
}

///|
/// A subscription selecting more than one root field is rejected (spec §5.2.3.1).
test "subscription with multiple root fields is rejected" {
  let query =
    #|subscription { messageAdded(channel: "x") { id } ticks }
  let payloads = execute_subscription(
    sub_schema(),
    Resolvers::new(),
    sub_subscribers(),
    query,
  )
  assert_eq(payloads.length(), 1)
  assert_eq(
    payloads[0].stringify().contains("must select exactly one root field"),
    true,
  )
}

///|
/// An introspection field cannot be a subscription root.
test "subscription root cannot be an introspection field" {
  let payloads = execute_subscription(
    sub_schema(),
    Resolvers::new(),
    sub_subscribers(),
    (
      #|subscription { __typename }
    ),
  )
  assert_eq(payloads.length(), 1)
  assert_eq(payloads[0].stringify().contains("introspection field"), true)
}

///|
/// Handing a non-subscription operation to `execute_subscription` is an error.
test "execute_subscription rejects a query operation" {
  let payloads = execute_subscription(
    sub_schema(),
    Resolvers::new(),
    sub_subscribers(),
    (
      #|{ ok }
    ),
  )
  assert_eq(payloads.length(), 1)
  assert_eq(
    payloads[0].stringify().contains("requires a subscription operation"),
    true,
  )
}

///|
/// A subscription root field with no registered source is an error.
test "subscription with no registered source errors" {
  let subs = Subscribers::new()
  let payloads = execute_subscription(
    sub_schema(),
    Resolvers::new(),
    subs,
    (
      #|subscription { messageAdded(channel: "x") { id } }
    ),
  )
  assert_eq(payloads.length(), 1)
  assert_eq(
    payloads[0].stringify().contains("No subscription source registered"),
    true,
  )
}

///|
/// A source that raises `ResolverError` surfaces a single error payload.
test "subscription source error yields one error payload" {
  let subs = Subscribers::new()
  subs.field("Subscription", "messageAdded", _info => {
    raise ResolverError("stream unavailable")
  })
  let payloads = execute_subscription(
    sub_schema(),
    Resolvers::new(),
    subs,
    (
      #|subscription { messageAdded(channel: "x") { id } }
    ),
  )
  assert_eq(payloads.length(), 1)
  assert_eq(
    payloads[0].stringify(),
    (
      #|{"errors":[{"message":"stream unavailable","locations":[{"line":1,"column":16}]}]}
    ),
  )
}

///|
/// A scalar subscription field streams leaf payloads directly.
test "scalar subscription streams leaf payloads" {
  let payloads = execute_subscription(
    sub_schema(),
    Resolvers::new(),
    sub_subscribers(),
    (
      #|subscription { ticks }
    ),
  )
  assert_eq(payloads.length(), 2)
  assert_eq(
    payloads[0].stringify(),
    (
      #|{"data":{"ticks":1}}
    ),
  )
  assert_eq(
    payloads[1].stringify(),
    (
      #|{"data":{"ticks":2}}
    ),
  )
}
