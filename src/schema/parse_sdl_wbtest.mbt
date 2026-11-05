///|
/// A schema that carries every element `to_sdl` prints: three root operation
/// types, a schema directive, a directive definition, descriptions on a type, a
/// field, an input field, an enum and an enum value, a deprecated field and a
/// deprecated enum value, argument defaults, `implements`, an applied directive,
/// a union, and a scalar with `@specifiedBy`.
fn sdl_schema() -> Schema {
  let s = Schema::new()
  s.set_mutation("Mutation")
  s.set_subscription("Subscription")
  s.apply_schema_directive(
    AppliedDirective::new("link", args=[
      ("url", Json("https://specs.example.dev/graphql/v1.0")),
    ]),
  )
  s.directive(
    "tag",
    locations=["OBJECT", "FIELD_DEFINITION"],
    args=[("name", NonNull(Scalar("String")))],
    is_repeatable=true,
  )
  s.directive("upper", locations=["FIELD"])
  let node = s.interface("Node", description="Anything with an id.")
  node.field("id", NonNull(Scalar("ID")), description="The unique id.")
  let q = s.object("Query", description="The root query.")
  q.implements("Node")
  q.field("id", NonNull(Scalar("ID")))
  q.field_args(
    "search",
    [("term", NonNull(Scalar("String"))), ("first", Scalar("Int"))],
    NonNull(ListOf(NonNull(Named("SearchResult")))),
    defaults=[("first", Json::number(10.0))],
    description="Search everything.",
  )
  q.field(
    "old",
    Scalar("String"),
    deprecation_reason="use search",
    description="Gone soon.",
  )
  s.apply_field_directive(
    "Query",
    "old",
    AppliedDirective::new("tag", args=[("name", Json("legacy"))]),
  )
  s.apply_type_directive(
    "Query",
    AppliedDirective::new("tag", args=[("name", Json("root"))]),
  )
  let m = s.object("Mutation")
  m.field_args(
    "add",
    [("input", NonNull(Named("NewUser"))), ("notify", Scalar("Boolean"))],
    Named("User"),
    defaults=[("notify", Json(true))],
  )
  s.object("Subscription").field("events", NonNull(Named("User")))
  let inp = s.input("NewUser", description="A user to add.")
  inp.field("name", NonNull(Scalar("String")), description="Their name.")
  inp.field("role", Named("Role"), description="Their role.")
  let u = s.object("User")
  u.implements("Node")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", NonNull(Scalar("String")))
  s.object("Post").field("title", NonNull(Scalar("String")))
  s.enum_(
    "Role",
    ["ADMIN", "GUEST", "ANON"],
    deprecated=[("ANON", "use GUEST")],
    description="What a user may do.",
    descriptions=[("ADMIN", "Everything.")],
  )
  s.union("SearchResult", ["User", "Post"], description="One hit.")
  s.scalar(
    "DateTime",
    spec_url="https://scalars.example.dev/date-time",
    description="An ISO-8601 instant.",
  )
  s
}

///|
/// The declared composite type `name`, or a failed test when it is not there.
fn tdef(s : Schema, name : String) -> ObjectType {
  match s.type_by_name(name) {
    Some(t) => t
    None => abort("no type named " + name)
  }
}

///|
/// The declared field `name` on `t`, or a failed test when it is not there.
fn fdef(t : ObjectType, name : String) -> Field {
  match t.field_by_name(name) {
    Some(f) => f
    None => abort("no field named " + name)
  }
}

///|
/// The declared enum `name`, or a failed test when it is not there.
fn edef(s : Schema, name : String) -> EnumType {
  match s.enum_by_name(name) {
    Some(e) => e
    None => abort("no enum named " + name)
  }
}

///|
/// The declared union `name`, or a failed test when it is not there.
fn udef(s : Schema, name : String) -> UnionType {
  match s.union_by_name(name) {
    Some(u) => u
    None => abort("no union named " + name)
  }
}

///|
/// The declared scalar `name`, or a failed test when it is not there.
fn sdef(s : Schema, name : String) -> ScalarType {
  match s.scalar_by_name(name) {
    Some(x) => x
    None => abort("no scalar named " + name)
  }
}

///|
/// The declared directive definition `name`, or a failed test when it is not
/// there.
fn ddef(s : Schema, name : String) -> DirectiveDef {
  match s.directive_def_by_name(name) {
    Some(d) => d
    None => abort("no directive named " + name)
  }
}

///|
/// The `Refused` `text` raises, as `line:column message`; the empty
/// string when it reads without error.
fn sdl_error(text : String) -> String {
  let schema = Schema::of_sdl(text) catch {
    e => {
      let r = @lang.refusal(e)
      return "\{r.locations[0].line}:\{r.locations[0].col} " + r.message
    }
  }
  let _ = schema
  ""
}

///|
/// The round trip: reading back what the printer wrote describes the schema it
/// was printed from, and printing that again is the same text.
test "to_sdl then of_sdl is the same schema again" {
  let s = sdl_schema()
  assert_eq(Schema::of_sdl(s.to_sdl()).to_sdl(), s.to_sdl())
}

///|
/// A round trip over a schema with nothing but a query root, which is the shape
/// most of the examples build.
test "to_sdl then of_sdl round-trips a minimal schema" {
  let s = Schema::new()
  s.object("Query").field("hello", NonNull(Scalar("String")))
  assert_eq(Schema::of_sdl(s.to_sdl()).to_sdl(), s.to_sdl())
}

///|
/// Three root operation types, so that a schema whose SDL names a mutation and
/// a subscription root comes back running the same roots.
test "of_sdl reads the root operation types back" {
  let s = Schema::new(query="Root")
  s.set_mutation("M")
  s.set_subscription("S")
  s.object("Root").field("a", Scalar("String"))
  let re = Schema::of_sdl(s.to_sdl())
  assert_eq(re.query, "Root")
  assert_eq(re.mutation, Some("M"))
  assert_eq(re.subscription, Some("S"))
}

///|
/// Descriptions, which are what a client browsing the schema reads.
test "of_sdl reads descriptions back" {
  let s = Schema::new()
  s
  .object("Query", description="The root query.")
  .field_args("hero", [], Scalar("String"), description="The main hero.")
  s
  .input("In", description="An input.")
  .field("a", Scalar("Int"), description="A field.")
  let re = Schema::of_sdl(s.to_sdl())
  assert_eq(tdef(re, "Query").description, Some("The root query."))
  assert_eq(tdef(re, "In").description, Some("An input."))
  assert_eq(fdef(tdef(re, "Query"), "hero").description, Some("The main hero."))
  assert_eq(fdef(tdef(re, "In"), "a").description, Some("A field."))
  assert_eq(s.to_sdl().contains("\"The root query.\"\ntype Query {"), true)
}

///|
/// `@deprecated(reason:)` on a field and on an enum value.
test "of_sdl reads @deprecated on fields and enum values back" {
  let s = Schema::new()
  s.object("Query").field("old", Scalar("String"), deprecation_reason="use new")
  s.enum_("Color", ["RED", "OLD"], deprecated=[("OLD", "use RED")])
  let re = Schema::of_sdl(s.to_sdl())
  assert_eq(fdef(tdef(re, "Query"), "old").deprecation_reason, Some("use new"))
  assert_eq(edef(re, "Color").deprecations.get("OLD"), Some("use RED"))
  assert_eq(
    s.to_sdl().contains("old: String @deprecated(reason: \"use new\")"),
    true,
  )
  assert_eq(s.to_sdl().contains("OLD @deprecated(reason: \"use RED\")"), true)
}

///|
/// Argument default values, so a client reading the SDL knows what it may omit.
test "of_sdl reads argument default values back" {
  let s = Schema::new()
  s
  .object("Query")
  .field_args(
    "greet",
    [("name", Scalar("String")), ("times", Scalar("Int"))],
    Scalar("String"),
    defaults=[("name", Json("world")), ("times", Json::number(3.0))],
  )
  let re = Schema::of_sdl(s.to_sdl())
  assert_eq(
    fdef(tdef(re, "Query"), "greet").arg_defaults.get("name"),
    Some(Json("world")),
  )
  assert_eq(
    s.to_sdl().contains("greet(name: String = \"world\", times: Int = 3)"),
    true,
  )
  assert_eq(re.to_sdl(), s.to_sdl())
}

///|
/// Directive definitions and the three places a directive may be applied.
test "of_sdl reads directive definitions and applied directives back" {
  let s = Schema::new()
  s.directive(
    "tag",
    locations=["OBJECT", "FIELD_DEFINITION"],
    args=[("name", NonNull(Scalar("String")))],
    is_repeatable=true,
  )
  s.object("Query").field("hello", Scalar("String"))
  s.apply_type_directive(
    "Query",
    AppliedDirective::new("tag", args=[("name", Json("root"))]),
  )
  s.apply_field_directive(
    "Query",
    "hello",
    AppliedDirective::new("tag", args=[("name", Json("greet"))]),
  )
  s.apply_schema_directive(AppliedDirective::new("compose"))
  let re = Schema::of_sdl(s.to_sdl())
  assert_eq(ddef(re, "tag").is_repeatable, true)
  assert_eq(ddef(re, "tag").locations, ["OBJECT", "FIELD_DEFINITION"])
  assert_eq(ddef(re, "tag").args.length(), 1)
  assert_eq(re.type_has_directive("Query", "tag"), true)
  assert_eq(re.field_has_directive("Query", "hello", "tag"), true)
  assert_eq(re.schema_directives.length(), 1)
  assert_eq(s.to_sdl().contains("schema @compose {\n"), true)
  assert_eq(
    s
    .to_sdl()
    .contains(
      "directive @tag(name: String!) repeatable on OBJECT | FIELD_DEFINITION",
    ),
    true,
  )
  assert_eq(re.to_sdl(), s.to_sdl())
}

///|
/// Unions, scalars and `@specifiedBy`.
test "of_sdl reads unions, scalars and @specifiedBy back" {
  let s = Schema::new()
  s.object("Query").field("any", Named("Hit"))
  s.object("User").field("id", Scalar("ID"))
  s.object("Post").field("id", Scalar("ID"))
  s.union("Hit", ["User", "Post"], description="One hit.")
  s.scalar(
    "DateTime",
    spec_url="https://scalars.example.dev/date-time",
    description="An instant.",
  )
  let re = Schema::of_sdl(s.to_sdl())
  assert_eq(udef(re, "Hit").members, ["User", "Post"])
  assert_eq(udef(re, "Hit").description, Some("One hit."))
  assert_eq(
    sdef(re, "DateTime").spec_url,
    Some("https://scalars.example.dev/date-time"),
  )
  assert_eq(s.to_sdl().contains("union Hit = User | Post"), true)
  assert_eq(
    s
    .to_sdl()
    .contains(
      "scalar DateTime @specifiedBy(url: \"https://scalars.example.dev/date-time\")",
    ),
    true,
  )
  assert_eq(re.to_sdl(), s.to_sdl())
}

///|
/// `implements`, and the field order a type's SDL carries.
test "of_sdl reads implements and field order back" {
  let s = Schema::new()
  let node = s.interface("Node")
  node.field("id", NonNull(Scalar("ID")))
  let u = s.object("User")
  u.implements("Node")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", NonNull(Scalar("String")))
  let re = Schema::of_sdl(s.to_sdl())
  assert_eq(tdef(re, "User").interfaces, ["Node"])
  assert_eq(tdef(re, "User").fields.length(), 2)
  assert_eq(
    s
    .to_sdl()
    .contains("type User implements Node {\n  id: ID!\n  name: String!\n}"),
    true,
  )
}

///|
/// An `extend` block merges into the type already declared, which is how a
/// federated subgraph's SDL reads back.
test "of_sdl merges an extend block into the declared type" {
  let text =
    #|schema { query: Query }
    #|
    #|type Query { a: String }
    #|
    #|extend type Query { b: String }
  let s = Schema::of_sdl(text)
  assert_eq(tdef(s, "Query").fields.length(), 2)
  assert_eq(fdef(tdef(s, "Query"), "b").name, "b")
}

///|
/// A document that is not a type-system definition is a `Refused` naming
/// the token that stopped it, not a half-built schema.
test "of_sdl raises on a definition it does not know" {
  assert_eq(
    sdl_error("type Query { a: String }\nquery { a }").contains("query"),
    true,
  )
}

///|
/// A root operation type the schema does not have: the printer never writes one,
/// and a reader that accepted it would build a schema whose root is a guess.
test "of_sdl refuses a root operation type it does not know" {
  assert_eq(
    sdl_error("schema { querie: Query }").contains(
      "expected query, mutation or subscription",
    ),
    true,
  )
}

///|
/// The line and column of a definition that stops halfway.
test "of_sdl reports where a definition stopped" {
  let text =
    #|type Query { a: String }
    #|!
  assert_eq(sdl_error(text), "2:1 expected a type system definition")
}

///|
test "add_sdl adds beside what the schema already has" {
  let schema = Schema::new()
  schema.object("Query").field("built", Scalar("Int"))
  schema.add_sdl("type Extra { a: Int }")
  assert_true(schema.type_by_name("Extra") is Some(_))
  assert_true(schema.type_by_name("Query") is Some(_))
}

///|
test "with no schema block the roots go by their default names" {
  let schema = Schema::of_sdl(
    (
      #|type Query { a: Int }
      #|type Mutation { b: Int }
      #|type Subscription { c: Int }
    ),
  )
  assert_eq(schema.mutation, Some("Mutation"))
  assert_eq(schema.subscription, Some("Subscription"))
}

///|
test "a schema block outranks the default names" {
  let schema = Schema::of_sdl(
    (
      #|schema { query: Q mutation: Write }
      #|type Q { a: Int }
      #|type Write { b: Int }
      #|type Mutation { c: Int }
    ),
  )
  assert_eq(schema.mutation, Some("Write"))
}

///|
test "a schema with neither has no mutation root" {
  assert_eq(Schema::of_sdl("type Query { a: Int }").mutation, None)
}

///|
/// A schema carrying every part of the type system the printer has to render.
fn complete_schema() -> Schema {
  let s = Schema::new()
  s.enum_(
    "Role",
    ["ADMIN", "GUEST", "OLD"],
    description="Who may see this.",
    deprecated=[("OLD", "use GUEST")],
    descriptions=[("ADMIN", "Can do anything.")],
  )
  s.scalar(
    "DateTime",
    spec_url="https://example.invalid/dt",
    description="An instant.",
  )
  let q = s.object("Query", description="The root.")
  q.field("now", NonNull(Named("DateTime")), description="The current instant.")
  q.field_args(
    "search",
    [("term", NonNull(Scalar("String"))), ("first", Scalar("Int"))],
    NonNull(ListOf(NonNull(Scalar("String")))),
    defaults=[("first", Json(10)), ("term", Json("all"))],
    description="Finds text.",
    deprecation_reason="use find",
  )
  let m = s.object("Mutation")
  m.field("noop", Scalar("Boolean"))
  s.set_mutation("Mutation")
  let sub = s.object("Subscription")
  sub.field("ticks", Scalar("Int"))
  s.set_subscription("Subscription")
  s.directive(
    "tag",
    locations=["OBJECT", "FIELD_DEFINITION"],
    args=[("name", NonNull(Scalar("String"))), ("weight", Scalar("Int"))],
    defaults=[("weight", Json(1))],
    is_repeatable=true,
    description="A label.",
  )
  s.apply_type_directive(
    "Query",
    AppliedDirective::new("tag", args=[("name", Json("root"))]),
  )
  s.apply_field_directive(
    "Query",
    "now",
    AppliedDirective::new("tag", args=[
      ("name", Json("clock")),
      ("weight", Json(3)),
    ]),
  )
  s
}

///|
/// Every part of the type system the printer carries, byte for byte: descriptions,
/// `@deprecated(reason:)`, argument defaults, a described repeatable directive
/// with a defaulted argument, applied directives, and the schema block naming all
/// three roots.
test "SDL renders every part of the type system" {
  let expected = (
      #|schema {
      #|  query: Query
      #|  mutation: Mutation
      #|  subscription: Subscription
      #|}
      #|
      #|"A label."
      #|directive @tag(name: String!, weight: Int = 1) repeatable on OBJECT | FIELD_DEFINITION
      #|
      #|"The root."
      #|type Query @tag(name: "root") {
      #|  "The current instant."
      #|  now: DateTime! @tag(name: "clock", weight: 3)
      #|  "Finds text."
      #|  search(term: String! = "all", first: Int = 10): [String!]! @deprecated(reason: "use find")
      #|}
      #|
      #|type Mutation {
      #|  noop: Boolean
      #|}
      #|
      #|type Subscription {
      #|  ticks: Int
      #|}
      #|
      #|"Who may see this."
      #|enum Role {
      #|  "Can do anything."
      #|  ADMIN
      #|  GUEST
      #|  OLD @deprecated(reason: "use GUEST")
      #|}
      #|
      #|"An instant."
      #|scalar DateTime @specifiedBy(url: "https://example.invalid/dt")
    ) +
    "\n\n"
  assert_eq(complete_schema().to_sdl(), expected)
}

///|
/// …and reading that text back describes the same schema, so the printed form is
/// not lossy for anything SDL can say.
test "SDL reads back what it printed" {
  let once = complete_schema().to_sdl()
  let again = Schema::of_sdl(once) catch { e => abort(e.to_string()) }
  assert_eq(again.to_sdl(), once)
  assert_eq(again.check().length(), 0)
}

///|
/// An input object's fields may name a default of their own, and a name-standing
/// default is an enum value rather than a string: the two are told apart by the
/// field's type, which is why the printer reads defaults against the schema.
test "an input field's default survives the round trip" {
  let text =
    #|enum Role {
    #|  ADMIN
    #|  GUEST
    #|}
    #|
    #|input Inner {
    #|  n: Int
    #|}
    #|
    #|input Filter {
    #|  role: Role = GUEST
    #|  limit: Int = 10
    #|  tags: [String!] = ["a", "b"]
    #|  nested: Inner = { n: 1 }
    #|  title: String = "all"
    #|}
    #|
    #|type Query {
    #|  books(filter: Filter = { role: ADMIN, limit: 5 }): [String!]!
    #|}
  let s = Schema::of_sdl(text) catch { e => abort(e.to_string()) }
  let printed = s.to_sdl()
  assert_eq(
    printed.contains(
      (
        #|input Filter {
        #|  role: Role = GUEST
        #|  limit: Int = 10
        #|  tags: [String!] = ["a", "b"]
        #|  nested: Inner = {n: 1}
        #|  title: String = "all"
        #|}
      ),
    ),
    true,
  )
  assert_eq(
    printed.contains(
      "books(filter: Filter = {role: ADMIN, limit: 5}): [String!]!",
    ),
    true,
  )
  // Reading the print back describes the same schema, byte for byte.
  let again = Schema::of_sdl(printed) catch { e => abort(e.to_string()) }
  assert_eq(again.to_sdl(), printed)
  assert_eq(again.check().length(), 0)
}
