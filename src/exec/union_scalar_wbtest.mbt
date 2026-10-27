///|
/// A `Book` object value tagged with its `__typename` for union discrimination.
fn jbook(title : String) -> Json {
  let m : Map[String, Json] = Map([])
  m["__typename"] = Json("Book")
  m["title"] = Json(title)
  Json(m)
}

///|
/// An `Author` object value tagged with its `__typename`.
fn jauthor(name : String) -> Json {
  let m : Map[String, Json] = Map([])
  m["__typename"] = Json("Author")
  m["name"] = Json(name)
  Json(m)
}

///|
/// `Query { search: [SearchResult!]! }` where `SearchResult` is a union of the
/// object types `Book` and `Author`.
fn union_schema() -> @schema.Schema {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field(
    "search",
    NonNull(@schema.ListOf(@schema.NonNull(@schema.Named("SearchResult")))),
  )
  s.union("SearchResult", ["Book", "Author"])
  let book = s.object("Book")
  book.field("title", NonNull(@schema.Scalar("String")))
  let author = s.object("Author")
  author.field("name", NonNull(@schema.Scalar("String")))
  s
}

///|
/// `Query.search` returns one of each member; member fields default-resolve off
/// the tagged parent value.
fn union_resolvers(results : Array[Json]) -> Resolvers {
  let r = Resolvers::new()
  r.field("Query", "search", fn(_info) { Json(results) })
  r
}

///|
/// A union field resolves each element to its member type via `__typename` and
/// selects the matching inline fragment's fields.
test "union resolves members by __typename" {
  let query =
    #|{
    #|  search {
    #|    __typename
    #|    ... on Book { title }
    #|    ... on Author { name }
    #|  }
    #|}
  let res = execute(
    union_schema(),
    union_resolvers([jbook("MoonBit in Action"), jauthor("Ada")]),
    query,
  )
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"search":[{"__typename":"Book","title":"MoonBit in Action"},{"__typename":"Author","name":"Ada"}]}}
    ),
  )
}

///|
/// A union value missing a `__typename` cannot be discriminated and is a field
/// error, nulling the list element's enclosing non-null slot.
test "union value without __typename is a field error" {
  let bad : Map[String, Json] = Map([])
  bad["title"] = Json("Untagged")
  let res = execute(
    union_schema(),
    union_resolvers([Json(bad)]),
    (
      #|{ search { __typename ... on Book { title } } }
    ),
  )
  let has_typename_error = res.stringify().contains("value has no __typename")
  assert_eq(has_typename_error, true)
}

///|
/// A `__typename` naming a type outside the union is rejected.
test "union value tagged with a non-member type is an error" {
  let movie : Map[String, Json] = Map([])
  movie["__typename"] = Json("Movie")
  let res = execute(
    union_schema(),
    union_resolvers([Json(movie)]),
    (
      #|{ search { __typename } }
    ),
  )
  assert_eq(
    res.stringify().contains("is not a member of union 'SearchResult'"),
    true,
  )
}

///|
/// Selecting an object field directly on a union (not through a fragment) is a
/// validation error.
test "union rejects a direct field selection" {
  let res = execute(
    union_schema(),
    union_resolvers([]),
    (
      #|{ search { title } }
    ),
  )
  assert_eq(
    res.stringify(),
    (
      #|{"errors":[{"message":"Cannot query field 'title' directly on union type 'SearchResult'; select it inside an inline fragment on a member type","locations":[{"line":1,"column":12}]}]}
    ),
  )
}

///|
/// A union prints to SDL as `union Name = A | B`.
test "union renders to SDL" {
  assert_eq(
    union_schema().to_sdl().contains("union SearchResult = Book | Author"),
    true,
  )
}

///|
/// Introspection reports a union's `kind` and `possibleTypes`.
test "union introspection lists possibleTypes" {
  let query =
    #|{ __type(name: "SearchResult") { kind name possibleTypes { name } } }
  let res = execute(union_schema(), union_resolvers([]), query)
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"__type":{"kind":"UNION","name":"SearchResult","possibleTypes":[{"name":"Book"},{"name":"Author"}]}}}
    ),
  )
}

///|
/// `Query { echo(v: Tag!): Tag! }` with a custom scalar `Tag` whose `parse_value`
/// prefixes `in:` on input and whose `serialize` prefixes `out:` on output, so a
/// round-trip shows both hooks ran.
fn scalar_schema() -> @schema.Schema {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field_args(
    "echo",
    [("v", @schema.NonNull(@schema.Named("Tag")))],
    NonNull(@schema.Named("Tag")),
  )
  s.scalar(
    "Tag",
    serialize=fn(j) {
      match j {
        String(x) => Json("out:" + x)
        _ => j
      }
    },
    parse_value=fn(j) {
      match j {
        String(x) => Json("in:" + x)
        _ => j
      }
    },
  )
  s
}

///|
/// `Query.echo` returns the argument it received; the argument is already parsed
/// by the scalar's `parse_value`.
fn scalar_resolvers() -> Resolvers {
  let r = Resolvers::new()
  r.field("Query", "echo", fn(info) { info.arg("v") })
  r
}

///|
/// A custom scalar parses its input argument and serialises the output: a literal
/// argument goes through `parse_value` then `serialize`.
test "custom scalar parse and serialize hooks run" {
  let res = execute(
    scalar_schema(),
    scalar_resolvers(),
    (
      #|{ echo(v: "hello") }
    ),
  )
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"echo":"out:in:hello"}}
    ),
  )
}

///|
/// The scalar's `parse_value` also runs on a value supplied through a variable.
test "custom scalar parses a variable-supplied argument" {
  let vars : Map[String, Json] = Map([])
  vars["v"] = Json("world")
  let res = execute(
    scalar_schema(),
    scalar_resolvers(),
    (
      #|query ($v: Tag!) { echo(v: $v) }
    ),
    variables=vars,
  )
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"echo":"out:in:world"}}
    ),
  )
}

///|
/// A custom scalar renders as `scalar Name` and introspects with `kind = SCALAR`.
test "custom scalar SDL and introspection" {
  assert_eq(scalar_schema().to_sdl().contains("scalar Tag"), true)
  let res = execute(
    scalar_schema(),
    scalar_resolvers(),
    (
      #|{ __type(name: "Tag") { kind name } }
    ),
  )
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"__type":{"kind":"SCALAR","name":"Tag"}}}
    ),
  )
}
