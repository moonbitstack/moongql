///|
/// Subscriptions at the in-process seam. A `Subscribers` map registers a source per
/// root field; `execute_subscription` runs a subscription operation and returns the
/// ordered `{ data }` payloads, one per source event, with the operation variable
/// threaded into the source. `create_source_event_stream` exposes the stage before
/// payload mapping as a typed `SubscriptionResult`: an `EventStream` on success, a
/// `RequestError` when the operation is rejected (a subscription must select exactly
/// one root field).
///
///     moon run examples/19-subscriptions
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
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
  let subs = @moongql.Subscribers::new()
  subs.field("Subscription", "messageAdded", info => {
    let ch = match info.arg("channel") {
      String(c) => c
      _ => ""
    }
    [
      { "id": "1", "body": "hello", "channel": Json(ch) },
      { "id": "2", "body": "world", "channel": Json(ch) },
      { "id": "3", "body": "bye", "channel": Json(ch) },
    ]
  })
  subs.field("Subscription", "ticks", _info => [Json(1), Json(2)])
  let r = @moongql.Resolvers::new()
  let feed =
    #|subscription Feed($c: String!) {
    #|  messageAdded(channel: $c) { id body channel }
    #|}
  let vars : Map[String, Json] = { "c": "general" }
  for p in @moongql.execute_subscription(s, r, subs, feed, variables=vars) {
    println(p.stringify())
  }
  for p in @moongql.execute_subscription(s, r, subs, "subscription { ticks }") {
    println(p.stringify())
  }
  match
    @moongql.create_source_event_stream(s, r, subs, "subscription { ticks }") {
    EventStream(events) => println("source events: \{events.length()}")
    RequestError(errs) => println("request error count: \{errs.length()}")
  }
  let multi = "subscription { messageAdded(channel: \"x\") { id } ticks }"
  match @moongql.create_source_event_stream(s, r, subs, multi) {
    EventStream(events) => println("source events: \{events.length()}")
    RequestError(errs) =>
      for e in errs {
        println("rejected: " + e.message)
      }
  }
}
