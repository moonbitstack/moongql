///|
/// An interface-position schema: `Query.animal: Animal`, where `Dog` and `Cat`
/// both implement `Animal` and each adds a field of its own. A value can arrive
/// as a plain JSON object with no `__typename`, which is when a hook has to
/// answer for it.
fn animal_schema() -> @schema.Schema {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("animal", Named("Animal"))
  let animal = s.interface("Animal")
  animal.field("name", NonNull(@schema.Scalar("String")))
  let dog = s.object("Dog")
  dog.field("name", NonNull(@schema.Scalar("String")))
  dog.field("barks", @schema.Scalar("Boolean"))
  dog.implements("Animal")
  let cat = s.object("Cat")
  cat.field("name", NonNull(@schema.Scalar("String")))
  cat.field("lives", @schema.Scalar("Int"))
  cat.implements("Animal")
  s
}

///|
/// A plain object with no `__typename`, as a database row would arrive.
fn plain(entries : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for e in entries {
    m[e.0] = e.1
  }
  Json(m)
}

///|
/// `Query.animal` answering `value`, with `hook` (if given) as the `resolve_type`
/// of `Animal`.
fn animal_resolvers(
  value : Json,
  hook : ((Json, Json) -> String?)?,
) -> Resolvers {
  let r = Resolvers::new()
  r.field("Query", "animal", fn(_info) { value })
  match hook {
    Some(f) => r.resolve_type("Animal", f)
    None => ()
  }
  r
}

///|
/// A `resolve_type` hook decides the object type when the value has no
/// `__typename` of its own, so the object's own fields are selectable.
test "resolve_type names the object type of an untagged interface value" {
  let value = plain([("name", Json("Rex")), ("barks", Json(true))])
  let r = animal_resolvers(value, Some(fn(_v, _ctx) { Some("Dog") }))
  let res = execute(
    animal_schema(),
    r,
    (
      #|{ animal { __typename name ... on Dog { barks } ... on Cat { lives } } }
    ),
  )
  assert_eq(
    res.stringify(),
    "{\"data\":{\"animal\":{\"__typename\":\"Dog\",\"name\":\"Rex\",\"barks\":true}}}",
  )
}

///|
/// The hook may answer `None` for a value it does not know; the declared type
/// then answers, and the interface's own fields still resolve.
test "a hook that answers nothing leaves the interface's fields working" {
  let value = plain([("name", Json("Rex"))])
  let r = animal_resolvers(value, Some(fn(_v, _ctx) { None }))
  let res = execute(animal_schema(), r, "{ animal { __typename name } }")
  assert_eq(
    res.stringify(),
    "{\"data\":{\"animal\":{\"__typename\":\"Animal\",\"name\":\"Rex\"}}}",
  )
}

///|
/// `is_type_of` is asked of each possible type in turn, which is how a value that
/// carries no name at all is classified.
test "is_type_of classifies a value for an interface" {
  let value = plain([("name", Json("Tom")), ("lives", Json(9))])
  let r = animal_resolvers(value, None)
  r.is_type_of("Dog", fn(v, _ctx) {
    match v {
      Object(m) => m.get("barks") is Some(_)
      _ => false
    }
  })
  r.is_type_of("Cat", fn(v, _ctx) {
    match v {
      Object(m) => m.get("lives") is Some(_)
      _ => false
    }
  })
  let res = execute(
    animal_schema(),
    r,
    "{ animal { __typename ... on Cat { lives } } }",
  )
  assert_eq(
    res.stringify(),
    "{\"data\":{\"animal\":{\"__typename\":\"Cat\",\"lives\":9}}}",
  )
}

///|
/// The same hook answers at a union position.
test "resolve_type names the member of a union" {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field("search", @schema.ListOf(@schema.Named("Hit")))
  s.union("Hit", ["Book", "Author"])
  let book = s.object("Book")
  book.field("title", NonNull(@schema.Scalar("String")))
  let author = s.object("Author")
  author.field("name", NonNull(@schema.Scalar("String")))
  let r = Resolvers::new()
  r.field("Query", "search", fn(_info) {
    Json([plain([("title", Json("Solaris"))])])
  })
  r.resolve_type("Hit", fn(v, _ctx) {
    match v {
      Object(m) => if m.get("title") is Some(_) { Some("Book") } else { None }
      _ => None
    }
  })
  let res = execute(s, r, "{ search { __typename ... on Book { title } } }")
  assert_eq(
    res.stringify(),
    "{\"data\":{\"search\":[{\"__typename\":\"Book\",\"title\":\"Solaris\"}]}}",
  )
}

///|
/// A hook that names a type the interface does not stand for is a field error,
/// not a silent fallback: the value would otherwise be resolved against fields
/// it does not have.
test "a hook naming a non-implementation is a field error" {
  let value = plain([("name", Json("Rex"))])
  let r = animal_resolvers(value, Some(fn(_v, _ctx) { Some("Rock") }))
  // A type that exists but implements nothing.
  let s = animal_schema()
  let rock = s.object("Rock")
  rock.field("name", @schema.Scalar("String"))
  let res = execute(s, r, "{ animal { name } }")
  assert_eq(
    res
    .stringify()
    .contains("Runtime Object type 'Rock' is not a possible type for 'Animal'"),
    true,
  )
}

///|
/// An explicit hook is asked before the value's own `__typename`, so a resolver
/// that classifies values itself is not at the mercy of a stale tag.
test "the hook decides before __typename does" {
  let value = plain([("__typename", Json("Cat")), ("name", Json("Rex"))])
  let r = animal_resolvers(value, Some(fn(_v, _ctx) { Some("Dog") }))
  let res = execute(animal_schema(), r, "{ animal { __typename } }")
  assert_eq(res.stringify(), "{\"data\":{\"animal\":{\"__typename\":\"Dog\"}}}")
}
