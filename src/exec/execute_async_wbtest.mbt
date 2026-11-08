///|
/// How many resolvers were inside their body at once, and the most that ever
/// were. A concurrency test reads `peak`: the serial engine never gets past 1.
priv struct Probe {
  mut active : Int32
  mut peak : Int32
}

///|
/// A resolver body that takes a moment and records how crowded it was, through
/// the captured `Probe` so the test can see it after the response is built.
fn probe_fn(probe : Probe, value : Json) -> async (ResolveInfo) -> Json {
  async fn(_info) {
    probe.active = probe.active + 1
    if probe.active > probe.peak {
      probe.peak = probe.active
    }
    @async.sleep(5)
    probe.active = probe.active - 1
    value
  }
}

///|
async test "async: a query answers exactly what the synchronous engine answers" {
  let sync = execute(
    demo_schema(),
    demo_resolvers(),
    "{ user(id: \"1\") { id name } }",
  )
  let asy = execute_async(
    demo_schema(),
    demo_resolvers(),
    "{ user(id: \"1\") { id name } }",
  )
  assert_eq(asy.stringify(), sync.stringify())
}

///|
async test "async: a field registered as async is used, and a synchronous one still runs" {
  let r = Resolvers::new()
  r.field_async("Query", "a", fn(_info) { Json("async") })
  r.field("Query", "b", fn(_info) { Json("sync") })
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("a", NonNull(Scalar("String")))
  q.field("b", NonNull(Scalar("String")))
  let out = execute_async(s, r, "{ a b }")
  inspect(
    out.stringify(),
    content="{\"data\":{\"a\":\"async\",\"b\":\"sync\"}}",
  )
}

///|
async test "async: the async registration wins over the synchronous one" {
  let r = Resolvers::new()
  r.field("Query", "a", fn(_info) { Json("sync") })
  r.field_async("Query", "a", fn(_info) { Json("async") })
  let s = @schema.Schema::new()
  s.object("Query").field("a", NonNull(Scalar("String")))
  let out = execute_async(s, r, "{ a }")
  inspect(out.stringify(), content="{\"data\":{\"a\":\"async\"}}")
}

///|
async test "async: sibling fields are resolved concurrently" {
  let probe = { active: 0, peak: 0, }
  let s = @schema.Schema::new()
  let q = s.object("Query")
  let r = Resolvers::new()
  for name in ["a", "b", "c", "d"] {
    q.field(name, NonNull(Scalar("Int")))
    r.field_async("Query", name, probe_fn(probe, Json(1)))
  }
  let out = execute_async(s, r, "{ a b c d }")
  inspect(
    out.stringify(),
    content="{\"data\":{\"a\":1,\"b\":1,\"c\":1,\"d\":1}}",
  )
  assert_eq(probe.peak > 1, true)
}

///|
async test "async: the elements of a list are resolved concurrently" {
  let probe = { active: 0, peak: 0, }
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("items", NonNull(ListOf(NonNull(Named("Item")))))
  let item = s.object("Item")
  item.field("n", NonNull(Scalar("Int")))
  let r = Resolvers::new()
  r.field("Query", "items", fn(_info) {
    let items : Array[Json] = [Json(1), Json(2), Json(3)]
    Json(items)
  })
  r.field_async("Item", "n", async fn(info) {
    probe.active = probe.active + 1
    if probe.active > probe.peak {
      probe.peak = probe.active
    }
    @async.sleep(5)
    probe.active = probe.active - 1
    info.parent
  })
  let out = execute_async(s, r, "{ items { n } }")
  // Each element is completed on its own (§6.4.3), so the elements overlap — the
  // order of the answer is the order of the list either way.
  inspect(
    out.stringify(),
    content="{\"data\":{\"items\":[{\"n\":1},{\"n\":2},{\"n\":3}]}}",
  )
  assert_eq(probe.peak > 1, true)
}

///|
async test "async: mutation root fields run one after another" {
  let probe = { active: 0, peak: 0, }
  let s = @schema.Schema::new(query="Query")
  let q0 = s.object("Query")
  q0.field("noop", NonNull(Scalar("Int")))
  let m = s.object("Mutation")
  let r = Resolvers::new()
  for name in ["a", "b", "c"] {
    m.field(name, NonNull(Scalar("Int")))
    r.field_async("Mutation", name, probe_fn(probe, Json(1)))
  }
  s.set_mutation("Mutation")
  let out = execute_async(s, r, "mutation { a b c }")
  inspect(out.stringify(), content="{\"data\":{\"a\":1,\"b\":1,\"c\":1}}")
  assert_eq(probe.peak, 1)
}

///|
async test "async: a non-null field that resolves null nulls its parent" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("user", Named("User"))
  let u = s.object("User")
  u.field("name", NonNull(Scalar("String")))
  u.field("tag", Scalar("String"))
  let r = Resolvers::new()
  r.field("Query", "user", fn(_info) {
    let m : Map[String, Json] = Map([])
    m["name"] = Json::null()
    m["tag"] = Json("kept in errors only")
    Json(m)
  })
  let out = execute_async(s, r, "{ user { tag name } }")
  inspect(
    out.stringify(),
    content="{\"data\":{\"user\":null},\"errors\":[{\"message\":\"Cannot return null for non-nullable field\",\"locations\":[{\"line\":1,\"column\":14}],\"path\":[\"user\",\"name\"]}]}",
  )
}

///|
async test "async: a resolver's refusal is a field error at its path" {
  let s = @schema.Schema::new()
  s.object("Query").field("boom", Scalar("String"))
  let r = Resolvers::new()
  r.field_async("Query", "boom", async fn(_info) {
    @async.pause()
    raise FieldError("went wrong")
  })
  let out = execute_async(s, r, "{ boom }")
  inspect(
    out.stringify(),
    content="{\"data\":{\"boom\":null},\"errors\":[{\"message\":\"went wrong\",\"locations\":[{\"line\":1,\"column\":3}],\"path\":[\"boom\"]}]}",
  )
}

///|
test "selection: a resolver reads the keys the document asks for" {
  let seen : Array[String] = []
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("user", Named("User"))
  let u = s.object("User")
  u.field("id", Scalar("ID"))
  u.field("name", Scalar("String"))
  let r = Resolvers::new()
  r.field("Query", "user", fn(info) {
    seen.push(info.selection.join(","))
    let m : Map[String, Json] = Map([])
    m["id"] = Json("1")
    m["name"] = Json("Alice")
    Json(m)
  })
  let _ = execute(s, r, "{ user { id name } }")
  assert_eq(seen[0], "id,name")
}

///|
test "selection: reads answers for one key and not another" {
  let seen : Array[String] = []
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("user", Named("User"))
  let u = s.object("User")
  u.field("id", Scalar("ID"))
  u.field("name", Scalar("String"))
  let r = Resolvers::new()
  r.field("Query", "user", fn(info) {
    seen.push(if info.reads("name") { "yes" } else { "no" })
    let m : Map[String, Json] = Map([])
    m["id"] = Json("1")
    Json(m)
  })
  let _ = execute(s, r, "{ user { id } }")
  assert_eq(seen[0], "no")
}

///|
test "permission: a refused field is an error and its resolver never runs" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("secret", Scalar("String"))
  q.field("open", NonNull(Scalar("String")))
  let mut ran = false
  let r = Resolvers::new()
  r.field("Query", "secret", fn(_info) {
    ran = true
    Json("s3cret")
  })
  r.field("Query", "open", fn(_info) { Json("fine") })
  r.permission("Query", "secret", fn(_info) { false })
  let out = execute(s, r, "{ secret open }")
  inspect(
    out.stringify(),
    content="{\"data\":{\"secret\":null,\"open\":\"fine\"},\"errors\":[{\"message\":\"not permitted\",\"locations\":[{\"line\":1,\"column\":3}],\"path\":[\"secret\"]}]}",
  )
  assert_eq(ran, false)
}

///|
priv struct Upcase {
  seen : Array[String]
}

///|
impl Extension for Upcase with fn on_field(self, info) {
  self.seen.push(info.field_name)
}

///|
impl Extension for Upcase with fn on_result(_, info, value) {
  if info.field_name == "a" && value is String(s) {
    Json(s + "!")
  } else {
    value
  }
}

///|
test "hook: an extension sees every field and may replace a value" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("a", NonNull(Scalar("String")))
  q.field("b", NonNull(Scalar("String")))
  let r = Resolvers::new()
  r.field("Query", "a", fn(_info) { Json("low") })
  r.field("Query", "b", fn(_info) { Json("low") })
  let ext : Upcase = { seen: [], }
  r.hook(ext)
  let out = execute(s, r, "{ a b }")
  inspect(out.stringify(), content="{\"data\":{\"a\":\"low!\",\"b\":\"low\"}}")
  assert_eq(ext.seen.join(","), "a,b")
}

///|
async test "incremental: a deferred fragment arrives in a second payload" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("user", Named("User"))
  let u = s.object("User")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", NonNull(Scalar("String")))
  let r = Resolvers::new()
  r.field("Query", "user", fn(_info) {
    let m : Map[String, Json] = Map([])
    m["id"] = Json("1")
    m["name"] = Json("Alice")
    Json(m)
  })
  let out = execute_incremental(
    s, r, "{ user { id ... @defer(label: \"late\") { name } } }",
  )
  assert_eq(out.length(), 2)
  inspect(
    out[0].stringify(),
    content="{\"data\":{\"user\":{\"id\":\"1\"}},\"pending\":[{\"id\":\"0\",\"path\":[\"user\"],\"label\":\"late\"}],\"hasNext\":true}",
  )
  inspect(
    out[1].stringify(),
    content="{\"incremental\":[{\"id\":\"0\",\"data\":{\"name\":\"Alice\"}}],\"completed\":[{\"id\":\"0\"}],\"hasNext\":false}",
  )
}

///|
async test "incremental: a streamed list sends its first items at once and the rest later" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("nums", NonNull(@schema.ListOf(@schema.NonNull(Scalar("Int")))))
  let r = Resolvers::new()
  r.field("Query", "nums", fn(_info) { Json([1, 2, 3]) })
  let out = execute_incremental(s, r, "{ nums @stream(initialCount: 1) }")
  assert_eq(out.length(), 2)
  inspect(
    out[0].stringify(),
    content="{\"data\":{\"nums\":[1]},\"pending\":[{\"id\":\"0\",\"path\":[\"nums\"]}],\"hasNext\":true}",
  )
  inspect(
    out[1].stringify(),
    content="{\"incremental\":[{\"id\":\"0\",\"items\":[2,3]}],\"completed\":[{\"id\":\"0\"}],\"hasNext\":false}",
  )
}

///|
async test "incremental: a document that defers nothing is one payload" {
  let out = execute_incremental(
    demo_schema(),
    demo_resolvers(),
    "{ user(id: \"1\") { id } }",
  )
  assert_eq(out.length(), 1)
  inspect(out[0].stringify(), content="{\"data\":{\"user\":{\"id\":\"1\"}}}")
}

///|
async test "incremental: switching deferral off in the limits runs the fragment in place" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("user", Named("User"))
  let u = s.object("User")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", NonNull(Scalar("String")))
  let r = Resolvers::new()
  r.field("Query", "user", fn(_info) {
    let m : Map[String, Json] = Map([])
    m["id"] = Json("1")
    m["name"] = Json("Alice")
    Json(m)
  })
  let out = execute_incremental(s, r, "{ user { id ... @defer { name } } }", limits={
    max_concurrency: 8,
    max_defer: 0,
    max_stream: 0,
  })
  assert_eq(out.length(), 1)
  inspect(
    out[0].stringify(),
    content="{\"data\":{\"user\":{\"id\":\"1\",\"name\":\"Alice\"}}}",
  )
}

///|
async test "async: a deferred fragment is executed by the asynchronous engine too" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("user", Named("User"))
  let u = s.object("User")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", NonNull(Scalar("String")))
  let r = Resolvers::new()
  r.field_async("Query", "user", fn(_info) {
    let m : Map[String, Json] = Map([])
    m["id"] = Json("1")
    m["name"] = Json("Alice")
    Json(m)
  })
  let out = execute_incremental(s, r, "{ user { id ... @defer { name } } }")
  assert_eq(out.length(), 2)
  inspect(
    out[1].stringify(),
    content="{\"incremental\":[{\"id\":\"0\",\"data\":{\"name\":\"Alice\"}}],\"completed\":[{\"id\":\"0\"}],\"hasNext\":false}",
  )
}

///|
async test "incremental: two deferrals on one object share a payload" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("user", Named("User"))
  let u = s.object("User")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", NonNull(Scalar("String")))
  let r = Resolvers::new()
  r.field("Query", "user", fn(_info) {
    let m : Map[String, Json] = Map([])
    m["id"] = Json("1")
    m["name"] = Json("Alice")
    Json(m)
  })
  let out = execute_incremental(
    s, r, "{ user { ... @defer { id } ... @defer(label: \"L\") { name } } }",
  )
  assert_eq(out.length(), 2)
  inspect(
    out[0].stringify(),
    content="{\"data\":{\"user\":{}},\"pending\":[{\"id\":\"0\",\"path\":[\"user\"]},{\"id\":\"1\",\"path\":[\"user\"],\"label\":\"L\"}],\"hasNext\":true}",
  )
  inspect(
    out[1].stringify(),
    content="{\"incremental\":[{\"id\":\"0\",\"data\":{\"id\":\"1\"}},{\"id\":\"1\",\"data\":{\"name\":\"Alice\"}}],\"completed\":[{\"id\":\"0\"},{\"id\":\"1\"}],\"hasNext\":false}",
  )
}

///|
async test "incremental: a deferral inside a deferral arrives with its parent" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("user", Named("User"))
  let u = s.object("User")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", NonNull(Scalar("String")))
  let r = Resolvers::new()
  r.field("Query", "user", fn(_info) {
    let m : Map[String, Json] = Map([])
    m["id"] = Json("1")
    m["name"] = Json("Alice")
    Json(m)
  })
  let out = execute_incremental(
    s, r, "{ user { ... @defer { name ... @defer { id } } } }",
  )
  assert_eq(out.length(), 2)
  inspect(
    out[1].stringify(),
    content="{\"incremental\":[{\"id\":\"0\",\"data\":{\"name\":\"Alice\"}},{\"id\":\"1\",\"data\":{\"id\":\"1\"}}],\"pending\":[{\"id\":\"1\",\"path\":[\"user\"]}],\"completed\":[{\"id\":\"0\"},{\"id\":\"1\"}],\"hasNext\":false}",
  )
}

///|
async test "incremental: an error inside a deferral rides with its entry" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("user", Named("User"))
  let u = s.object("User")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", Scalar("String"))
  let r = Resolvers::new()
  r.field("Query", "user", fn(_info) {
    let m : Map[String, Json] = Map([])
    m["id"] = Json("1")
    Json(m)
  })
  r.field("User", "name", fn(_info) raise FieldError {
    raise FieldError("no name")
  })
  let out = execute_incremental(s, r, "{ user { id ... @defer { name } } }")
  assert_eq(out.length(), 2)
  let patch = out[1].stringify()
  assert_eq(
    patch.contains("{\"id\":\"0\",\"data\":{\"name\":null},\"errors\":["),
    true,
  )
  assert_eq(patch.contains("\"path\":[\"user\",\"name\"]"), true)
  assert_eq(
    patch.contains("\"completed\":[{\"id\":\"0\"}],\"hasNext\":false"),
    true,
  )
}

///|
async test "incremental: a stream of an empty list opens and closes a pending" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("nums", NonNull(@schema.ListOf(@schema.NonNull(Scalar("Int")))))
  let r = Resolvers::new()
  let empty : Array[Json] = []
  r.field("Query", "nums", fn(_info) { Json(empty) })
  let out = execute_incremental(s, r, "{ nums @stream }")
  assert_eq(out.length(), 2)
  inspect(
    out[0].stringify(),
    content="{\"data\":{\"nums\":[]},\"pending\":[{\"id\":\"0\",\"path\":[\"nums\"]}],\"hasNext\":true}",
  )
  inspect(
    out[1].stringify(),
    content="{\"completed\":[{\"id\":\"0\"}],\"hasNext\":false}",
  )
}

///|
async test "incremental: an initial count past the end collapses the stream" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("nums", NonNull(@schema.ListOf(@schema.NonNull(Scalar("Int")))))
  let r = Resolvers::new()
  r.field("Query", "nums", fn(_info) { Json([1, 2, 3]) })
  let out = execute_incremental(s, r, "{ nums @stream(initialCount: 9) }")
  assert_eq(out.length(), 1)
  inspect(out[0].stringify(), content="{\"data\":{\"nums\":[1,2,3]}}")
}
