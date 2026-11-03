// The type system's own rules, one test per way a schema can be wrong.

///|
/// A schema that holds together: an object implementing an interface, an input
/// object, a union, an enum, a custom scalar, a directive, and non-null and list
/// markers around all of it.
fn sound_schema() -> Schema {
  let s = Schema::new()
  s.scalar("DateTime", spec_url="https://example.invalid/datetime")
  s.enum_("Role", ["ADMIN", "GUEST"])
  let node = s.interface("Node")
  node.field("id", NonNull(Scalar("ID")))
  let user = s.object("User")
  user.field("id", NonNull(Scalar("ID")))
  user.field("role", NonNull(Named("Role")))
  user.field("joined", Named("DateTime"))
  user.implements("Node")
  let post = s.object("Post")
  post.field("id", NonNull(Scalar("ID")))
  post.field("author", NonNull(Named("User")))
  post.implements("Node")
  s.union("Content", ["Post"])
  let new_user = s.input("NewUser")
  new_user.field("name", NonNull(Scalar("String")))
  new_user.field("tags", ListOf(NonNull(Scalar("String"))))
  let q = s.object("Query")
  q.field("node", Named("Node"))
  q.field_args(
    "search",
    [("term", NonNull(Scalar("String"))), ("first", Scalar("Int"))],
    NonNull(ListOf(NonNull(Named("Content")))),
    defaults=[("first", Json(10))],
  )
  let m = s.object("Mutation")
  m.field_args("addUser", [("input", NonNull(Named("NewUser")))], Named("User"))
  s.set_mutation("Mutation")
  s.directive("trace", locations=["FIELD_DEFINITION"], args=[
    ("level", Scalar("Int")),
  ])
  s
}

///|
/// The messages `check` answers, one per line, so a test can compare all of them.
fn check_text(s : Schema) -> String {
  s.check().map(e => e.message).join("\n")
}

///|
test "a sound schema has nothing to report" {
  assert_eq(check_text(sound_schema()), "")
}

///|
test "one type name, once" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Scalar("String"))
  let again = s.object("Query")
  again.field("b", Scalar("String"))
  assert_eq(
    check_text(s),
    (
      #|There can be only one type named 'Query'.
    ),
  )
}

///|
test "a name beginning with two underscores is introspection's" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Scalar("String"))
  s.scalar("__Mine")
  assert_eq(
    check_text(s),
    "Name '__Mine' must not begin with '__', which is reserved by GraphQL introspection.",
  )
}

///|
test "a field is defined once on a type" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Scalar("String"))
  q.field("a", Scalar("Int"))
  assert_eq(check_text(s), "Field 'Query.a' can only be defined once.")
}

///|
test "an output field takes an output type, and an input field an input type" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Named("Filter"))
  let f = s.input("Filter")
  f.field("ok", NonNull(Scalar("Boolean")))
  let g = s.object("Gadget")
  g.field("x", Scalar("String"))
  f.field("bad", Named("Gadget"))
  assert_eq(
    check_text(s),
    (
      #|The type of Query.a must be Output Type but got: Filter.
      #|The type of Filter.bad must be Input Type but got: Gadget.
    ),
  )
}

///|
test "an input field cannot take arguments" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Scalar("String"))
  let f = s.input("Filter")
  f.field_args("x", [("n", Scalar("Int"))], Scalar("Int"))
  assert_eq(check_text(s), "Input field 'Filter.x' cannot have arguments.")
}

///|
test "an argument is named once, and takes an input type" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field_args(
    "a",
    [("n", Scalar("Int")), ("n", Scalar("String")), ("u", Named("User"))],
    Scalar("String"),
  )
  s.object("User").field("id", Scalar("ID"))
  assert_eq(
    check_text(s),
    (
      #|Argument 'Query.a(n:)' can only be defined once.
      #|The type of Query.a(u:) must be Input Type but got: User.
    ),
  )
}

///|
test "an interface's fields are on the object that implements it" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Scalar("String"))
  let node = s.interface("Node")
  node.field("id", NonNull(Scalar("ID")))
  node.field("title", Scalar("String"))
  let post = s.object("Post")
  post.field("id", Scalar("String"))
  post.implements("Node")
  assert_eq(
    check_text(s),
    (
      #|Interface field Node.id expects type ID! but Post.id is type String.
      #|Interface field Node.title expected but Post does not provide it.
    ),
  )
}

///|
test "an interface's arguments match exactly" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Scalar("String"))
  let node = s.interface("Node")
  node.field_args("item", [("id", NonNull(Scalar("ID")))], Scalar("String"))
  let post = s.object("Post")
  post.field_args("item", [("id", Scalar("ID"))], Scalar("String"))
  post.implements("Node")
  assert_eq(
    check_text(s),
    "Interface field argument Node.item(id:) expects type ID! but Post.item(id:) is type ID.",
  )
}

///|
test "an implementing field may not add a required argument" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Scalar("String"))
  let node = s.interface("Node")
  node.field("item", Scalar("String"))
  let post = s.object("Post")
  post.field_args("item", [("id", NonNull(Scalar("ID")))], Scalar("String"))
  post.implements("Node")
  assert_eq(
    check_text(s),
    "Object field Post.item includes required argument id that is missing from the Interface field Node.item.",
  )
}

///|
test "only an interface can be implemented" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Scalar("String"))
  s.object("Other").field("x", Scalar("String"))
  let post = s.object("Post")
  post.field("id", Scalar("ID"))
  post.implements("Other")
  post.implements("Missing")
  assert_eq(
    check_text(s),
    (
      #|Type Post must only implement Interface types, it cannot implement Other.
      #|Type Post must only implement Interface types, it cannot implement Missing.
    ),
  )
}

///|
test "an interface's own interfaces are declared by what implements it" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Scalar("String"))
  let node = s.interface("Node")
  node.field("id", NonNull(Scalar("ID")))
  let named = s.interface("Named")
  named.field("id", NonNull(Scalar("ID")))
  named.implements("Node")
  let post = s.object("Post")
  post.field("id", NonNull(Scalar("ID")))
  post.implements("Named")
  assert_eq(
    check_text(s),
    "Type Post must implement Node because it is implemented by Named.",
  )
}

///|
test "an interface cannot implement itself" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Scalar("String"))
  let node = s.interface("Node")
  node.field("id", NonNull(Scalar("ID")))
  node.implements("Node")
  assert_eq(
    check_text(s),
    "Type Node cannot implement itself because it would create a circular reference.",
  )
}

///|
test "a field may be narrowed but not widened to a sub-type" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Scalar("String"))
  let node = s.interface("Node")
  node.field("id", Scalar("ID"))
  node.field("items", ListOf(Scalar("String")))
  let post = s.object("Post")
  // A non-null ID where the interface allows null: narrower, allowed.
  post.field("id", NonNull(Scalar("ID")))
  // A single String where the interface promises a list: wider, refused.
  post.field("items", Scalar("String"))
  post.implements("Node")
  assert_eq(
    check_text(s),
    "Interface field Node.items expects type [String] but Post.items is type String.",
  )
}

///|
test "an object is a sub-type of the interface it implements" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Scalar("String"))
  let node = s.interface("Node")
  node.field("id", NonNull(Scalar("ID")))
  let container = s.interface("Container")
  container.field("item", Named("Node"))
  let box = s.object("Box")
  box.field("id", NonNull(Scalar("ID")))
  box.field("item", NonNull(Named("Post")))
  box.implements("Node")
  box.implements("Container")
  let post = s.object("Post")
  post.field("id", NonNull(Scalar("ID")))
  post.implements("Node")
  assert_eq(check_text(s), "")
}

///|
test "an input object cannot reach itself through non-null fields" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Scalar("String"))
  let chain = s.input("Chain")
  chain.field("next", NonNull(Named("Chain")))
  let outer = s.input("Outer")
  outer.field("inner", NonNull(Named("Chain")))
  assert_eq(
    check_text(s),
    (
      #|Cannot reference Input Object 'Chain' within itself through a series of non-null fields: 'next'.
      #|Cannot reference Input Object 'Chain' within itself through a series of non-null fields: 'inner.next'.
    ),
  )
}

///|
test "a nullable input object may close a cycle" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Scalar("String"))
  let chain = s.input("Chain")
  chain.field("next", Named("Chain"))
  assert_eq(check_text(s), "")
}

///|
test "a union's members are object types, each once" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Scalar("String"))
  let item = s.input("Item")
  item.field("x", Scalar("Int"))
  s.union("Thing", ["Query", "Item", "Query", "Ghost"])
  assert_eq(
    check_text(s),
    (
      #|Union type Thing can only include Object types, it cannot include Item.
      #|Union type Thing can only include type Query once.
      #|Union type Thing can only include Object types, it cannot include Ghost.
    ),
  )
}

///|
test "an enum's values are named once, and are not true, false or null" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Scalar("String"))
  s.enum_("Flag", ["ON", "ON", "true", "null"])
  assert_eq(
    check_text(s),
    (
      #|Enum type Flag can only include value 'ON' once.
      #|Enum type Flag cannot include value: true.
      #|Enum type Flag cannot include value: null.
    ),
  )
}

///|
test "a directive is defined once, in real locations, with input arguments" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Scalar("String"))
  s.directive("trace", locations=["FIELD_DEFINITION"])
  s.directive("trace", locations=["NOWHERE"], args=[("who", Named("Query"))])
  s.directive("empty", locations=[])
  assert_eq(
    check_text(s),
    (
      #|Directive @trace can only be defined once.
      #|Directive @trace may not be used on NOWHERE.
      #|The type of @trace(who:) must be Input Type but got: Query.
      #|Directive @empty must include 1 or more locations.
    ),
  )
}

///|
test "the root operation types are named, exist, and are objects" {
  let missing = Schema::new()
  assert_eq(check_text(missing), "Query root type must be provided.")

  let input_root = Schema::new()
  let f = input_root.input("Query")
  f.field("a", Scalar("String"))
  assert_eq(
    check_text(input_root),
    "Query root type must be Object type, it cannot be Query.",
  )

  let bad_mutation = Schema::new()
  let q = bad_mutation.object("Query")
  q.field("a", Scalar("String"))
  bad_mutation.set_mutation("Nope")
  assert_eq(
    check_text(bad_mutation),
    "Root type 'Nope' is not defined in the schema.",
  )

  let interface_root = Schema::new()
  let q = interface_root.object("Query")
  q.field("a", Scalar("String"))
  let node = interface_root.interface("Node")
  node.field("id", Scalar("ID"))
  interface_root.set_subscription("Node")
  assert_eq(
    check_text(interface_root),
    "Root type 'Node' must be Object type, it cannot be interface 'Node'.",
  )
}

///|
test "a field type the schema does not declare is reported" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Named("Ghost"))
  q.field_args("b", [("n", Named("Phantom"))], NonNull(ListOf(Named("Ghost"))))
  assert_eq(
    check_text(s),
    (
      #|The type of Query.a must be Output Type but got: Ghost.
      #|The type of Query.b must be Output Type but got: [Ghost]!.
      #|The type of Query.b(n:) must be Input Type but got: Phantom.
    ),
  )
}

///|
test "a shape with nothing in it is reported" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("a", Scalar("String"))
  ignore(s.object("Empty"))
  ignore(s.interface("Bare"))
  ignore(s.input("Nothing"))
  s.enum_("Never", [])
  s.union("Void", [])
  assert_eq(
    check_text(s),
    (
      #|Type Empty must define one or more fields.
      #|Interface type Bare must define one or more fields.
      #|Input Object type Nothing must define one or more fields.
      #|Enum type Never must define one or more values.
      #|Union type Void must include one or more types.
    ),
  )
}

///|
test "a schema read back from SDL passes the same checks" {
  let s = Schema::of_sdl(
    (
      #|schema { query: Query mutation: Mutation }
      #|
      #|interface Node { id: ID! }
      #|
      #|type User implements Node { id: ID! name: String! role: Role! }
      #|
      #|type Post implements Node { id: ID! author: User! }
      #|
      #|enum Role { ADMIN GUEST }
      #|
      #|union Content = Post
      #|
      #|input NewUser { name: String! }
      #|
      #|type Query { node(id: ID!): Node content: [Content!]! }
      #|
      #|type Mutation { addUser(input: NewUser!): User }
    ),
  ) catch {
    e => abort(e.to_string())
  }
  assert_eq(check_text(s), "")
}
