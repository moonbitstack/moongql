///|
/// The established subscription, or a failure loud enough to find the test by.
fn expect_live(r : Result[Live, Array[@lang.GqlError]]) -> Live {
  match r {
    Ok(live) => live
    Err(errs) => abort("subscribe failed: " + errs[0].message)
  }
}

///|
/// A schema with a live subscription root: `Subscription { event: Event }`.
fn live_schema() -> @schema.Schema {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("ping", NonNull(@schema.Scalar("String")))
  let sub = s.object("Subscription")
  sub.field("tick", NonNull(@schema.Named("Tick")))
  let t = s.object("Tick")
  t.field("n", NonNull(@schema.Scalar("Int")))
  t.field("note", @schema.Scalar("String"))
  s.set_subscription("Subscription")
  s
}

///|
async test "live: a channel-backed source delivers each event as a payload" {
  let s = live_schema()
  let subscribers = Subscribers::new()
  let held : Array[Sender] = []
  subscribers.stream("Subscription", "tick", fn(_info) {
    let (stream, sender) = Stream::channel()
    held.push(sender)
    stream
  })
  let live = expect_live(
    subscribe_live(
      s,
      Resolvers::new(),
      subscribers,
      "subscription { tick { n } }",
    ),
  )
  let sender = held[0]
  let one : Map[String, Json] = Map([])
  one["n"] = Json(1)
  let two : Map[String, Json] = Map([])
  two["n"] = Json(2)
  sender.send(Json(one)) catch {
    _ => ()
  }
  sender.send(Json(two)) catch {
    _ => ()
  }
  sender.close()
  let first = live.next() catch { _ => None }
  inspect(
    first.unwrap_or(Json::null()).stringify(),
    content="{\"data\":{\"tick\":{\"n\":1}}}",
  )
  let second = live.next() catch { _ => None }
  inspect(
    second.unwrap_or(Json::null()).stringify(),
    content="{\"data\":{\"tick\":{\"n\":2}}}",
  )
  let done = live.next() catch { _ => None }
  assert_eq(done is None, true)
  live.close()
}

///|
async test "live: a request that cannot start is refused before any stream opens" {
  let s = live_schema()
  let subscribers = Subscribers::new()
  subscribers.stream("Subscription", "tick", fn(_info) {
    Stream::of(pull=fn() { None })
  })
  let refused = subscribe_live(s, Resolvers::new(), subscribers, "{ ping }")
  match refused {
    Ok(_) => abort("a query is not a subscription")
    Err(errs) =>
      assert_eq(errs[0].message.contains("subscription operation"), true)
  }
}

///|
async test "live: a materialised source is turned into a stream in order" {
  let s = live_schema()
  let subscribers = Subscribers::new()
  subscribers.field("Subscription", "tick", fn(_info) {
    let one : Map[String, Json] = Map([])
    one["n"] = Json(1)
    let two : Map[String, Json] = Map([])
    two["n"] = Json(2)
    [Json(one), Json(two)]
  })
  let live = expect_live(
    subscribe_live(
      s,
      Resolvers::new(),
      subscribers,
      "subscription { tick { n } }",
    ),
  )
  let a = live.next() catch { _ => None }
  let b = live.next() catch { _ => None }
  let c = live.next() catch { _ => None }
  assert_eq(
    a.unwrap_or(Json::null()).stringify(),
    "{\"data\":{\"tick\":{\"n\":1}}}",
  )
  assert_eq(
    b.unwrap_or(Json::null()).stringify(),
    "{\"data\":{\"tick\":{\"n\":2}}}",
  )
  assert_eq(c is None, true)
}

///|
async test "live: the field's sub-selection resolves against each event" {
  let s = live_schema()
  let subscribers = Subscribers::new()
  subscribers.stream("Subscription", "tick", fn(_info) {
    let (stream, sender) = Stream::channel()
    let ev : Map[String, Json] = Map([])
    ev["n"] = Json(7)
    ev["note"] = Json("seven")
    sender.send(Json(ev)) catch {
      _ => ()
    }
    sender.close()
    stream
  })
  let live = expect_live(
    subscribe_live(
      s,
      Resolvers::new(),
      subscribers,
      "subscription { tick { note } }",
    ),
  )
  let p = live.next() catch { _ => None }
  inspect(
    p.unwrap_or(Json::null()).stringify(),
    content="{\"data\":{\"tick\":{\"note\":\"seven\"}}}",
  )
}
