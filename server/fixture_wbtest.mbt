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
fn sub_schema() -> @schema.Schema {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("ok", NonNull(@schema.Scalar("String")))
  s.set_subscription("Subscription")
  let sub = s.object("Subscription")
  sub.field_args(
    "messageAdded",
    [("channel", @schema.NonNull(@schema.Scalar("String")))],
    NonNull(@schema.Named("Message")),
  )
  sub.field("ticks", NonNull(@schema.Scalar("Int")))
  let msg = s.object("Message")
  msg.field("id", NonNull(@schema.Scalar("ID")))
  msg.field("body", NonNull(@schema.Scalar("String")))
  msg.field("channel", NonNull(@schema.Scalar("String")))
  s
}

///|
/// The `messageAdded` source emits three messages tagged with the requested
/// channel; each becomes the resolved value of the root field for one payload.
fn sub_subscribers() -> @exec.Subscribers {
  let subs = @exec.Subscribers::new()
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
