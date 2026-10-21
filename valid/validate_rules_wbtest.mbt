///|
/// A small schema for exercising the document-level validation rules.
fn rules_schema() -> @schema.Schema {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field_args(
    "user",
    [("id", @schema.NonNull(@schema.Scalar("ID")))],
    Named("User"),
  )
  q.field("hello", NonNull(@schema.Scalar("String")))
  let u = s.object("User")
  u.field("id", NonNull(@schema.Scalar("ID")))
  u.field("name", NonNull(@schema.Scalar("String")))
  s
}

///|
/// The validation errors for `query` against `s`, joined one per line (so a test
/// can assert a message is present, or that the string is empty for a valid query).
fn verr_text(s : @schema.Schema, query : String) -> String {
  let doc = @lang.parse(query) catch { GqlSyntaxError(m, _, _) => return m }
  let sb = StringBuilder()
  for e in validate(s, doc) {
    sb.write_string(e.message)
    sb.write_char('\n')
  }
  sb.to_string()
}

///|
/// §5.2.1.1: two operations may not share a name.
test "operation name uniqueness" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s,
      (
        #|query A { hello }
        #|query A { hello }
      ),
    ).contains("There can be only one operation named 'A'"),
    true,
  )
}

///|
/// §5.2.2.1: an anonymous operation must stand alone.
test "lone anonymous operation" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s,
      (
        #|{ hello }
        #|query B { hello }
      ),
    ).contains("anonymous operation must be the only defined operation"),
    true,
  )
}

///|
/// §5.4.2: a field's arguments must have unique names.
test "argument uniqueness" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s,
      (
        #|{ user(id: "1", id: "2") { name } }
      ),
    ).contains("Duplicate argument 'id' on 'user'"),
    true,
  )
}

///|
/// §5.5.1.1: two fragments may not share a name.
test "fragment name uniqueness" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s,
      (
        #|{ user(id: "1") { ...F } }
        #|fragment F on User { name }
        #|fragment F on User { id }
      ),
    ).contains("There can be only one fragment named 'F'"),
    true,
  )
}

///|
/// §5.5.1.4: a defined fragment must be used.
test "no unused fragments" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s,
      (
        #|{ hello }
        #|fragment Unused on User { name }
      ),
    ).contains("Fragment 'Unused' is never used"),
    true,
  )
}

///|
/// §5.5.2.2: fragment spreads must not form a cycle.
test "no fragment spread cycles" {
  let s = rules_schema()
  let errs = verr_text(
    s,
    (
      #|{ user(id: "1") { ...A } }
      #|fragment A on User { name ...B }
      #|fragment B on User { id ...A }
    ),
  )
  assert_eq(errs.contains("Fragment 'A' spreads itself (cycle)"), true)
  assert_eq(errs.contains("Fragment 'B' spreads itself (cycle)"), true)
}

///|
/// §5.8.1: a variable may be defined only once in an operation.
test "variable uniqueness" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s,
      (
        #|query ($x: ID!, $x: ID!) { user(id: $x) { name } }
      ),
    ).contains("Duplicate variable '$x'"),
    true,
  )
}

///|
/// §5.8.4: every defined variable must be used.
test "no unused variables" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s,
      (
        #|query ($x: ID!) { hello }
      ),
    ).contains("Variable '$x' is never used"),
    true,
  )
}

///|
/// §5.8.3: a referenced variable must be defined.
test "undefined variable use" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s,
      (
        #|query { user(id: $y) { name } }
      ),
    ).contains("Variable '$y' is not defined"),
    true,
  )
}

///|
/// A query using variables, a fragment and a directive, all correctly, raises no
/// validation errors — the rules do not fire on valid documents.
test "a valid document passes every rule" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s,
      (
        #|query GetUser($id: ID!, $show: Boolean!) {
        #|  user(id: $id) { ...UserFields }
        #|}
        #|fragment UserFields on User { id name @include(if: $show) }
      ),
    ),
    "",
  )
}

///|
/// §5.8.2 Variables Are Input Types: a scalar variable type is valid, but an output
/// object type is not, and an unknown type is reported as unknown.
test "variables are input types" {
  let s = rules_schema()
  // A scalar variable used against a matching argument is valid.
  assert_eq(verr_text(s, "query ($id: ID!) { user(id: $id) { name } }"), "")
  // The output object type `User` cannot be a variable type.
  assert_eq(
    verr_text(s, "query ($u: User) { user(id: \"1\") { name } }").contains(
      "cannot be non-input type 'User'",
    ),
    true,
  )
  // A type that does not exist is reported as unknown, not as a non-input type.
  assert_eq(
    verr_text(s, "query ($x: Nope) { hello }").contains(
      "has unknown type 'Nope'",
    ),
    true,
  )
}

///|
/// §5.6.3: an input object literal may not repeat a field name.
test "input object field uniqueness" {
  let s = rules_schema()
  let f = s.input("Filter")
  f.field("name", Scalar("String"))
  let q = s.type_by_name("Query").unwrap()
  q.field_args("search", [("filter", @schema.Named("Filter"))], Named("User"))
  assert_eq(
    verr_text(s, "{ search(filter: { name: \"a\", name: \"b\" }) { id } }").contains(
      "only one input field named 'Filter.name'",
    ),
    true,
  )
  assert_eq(verr_text(s, "{ search(filter: { name: \"a\" }) { id } }"), "")
}

///|
/// §5.5.1.3: a fragment's type condition must be composite — an input object is a
/// type, but nothing selects fields from it.
test "a fragment cannot condition on an input object" {
  let s = rules_schema()
  let f = s.input("Filter")
  f.field("name", Scalar("String"))
  assert_eq(
    verr_text(s, "{ user(id: \"1\") { ...F } } fragment F on Filter { name }").length() >
    0,
    true,
  )
  // The same fragment on an object type is fine.
  assert_eq(
    verr_text(s, "{ user(id: \"1\") { ...F } } fragment F on User { name }"),
    "",
  )
}

///|
/// §5.3.2: two fields under one response key must be the same field. `{ a: name
/// a: email }` used to execute as `a: <name>` with `email`'s selections folded in,
/// because the executor concatenates same-key sub-selections without comparing
/// them. Two different keys are the way to ask for both.
test "fields sharing a response key must be the same field" {
  let s = rules_schema()
  s
  .type_by_name("User")
  .unwrap()
  .field("email", NonNull(@schema.Scalar("String")))
  assert_eq(
    verr_text(s, "{ user(id: \"1\") { a: name a: email } }").contains(
      "Fields 'a' conflict because 'name' and 'email' are different fields",
    ),
    true,
  )
  assert_eq(verr_text(s, "{ user(id: \"1\") { a: name b: email } }"), "")
}

///|
/// §5.3.2: the same field under one key must also be asked the same question —
/// two `user` selections with different `id` arguments cannot answer as one.
test "fields sharing a response key must have the same arguments" {
  let s = rules_schema()
  assert_eq(
    verr_text(s, "{ x: user(id: \"1\") { name } x: user(id: \"2\") { name } }").contains(
      "Fields 'x' conflict because they have differing arguments",
    ),
    true,
  )
  assert_eq(
    verr_text(s, "{ x: user(id: \"1\") { name } x: user(id: \"1\") { name } }"),
    "",
  )
}

///|
/// §5.3.2: the check reaches into sub-selections, where the conflicting keys sit
/// one level below the ones that merge.
test "sub-selections of merged fields must merge too" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s, "{ x: user(id: \"1\") { y: name } x: user(id: \"1\") { y: id } }",
    ).contains(
      "Fields 'x' conflict because subfields 'y' conflict because 'name' and 'id' are different fields",
    ),
    true,
  )
  assert_eq(
    verr_text(
      s, "{ x: user(id: \"1\") { y: name } x: user(id: \"1\") { z: id } }",
    ),
    "",
  )
}

///|
/// §5.8.5: a variable may only be used where its declared type fits. A nullable
/// `String` cannot stand at an `ID!` argument; declaring the variable `ID!` can.
test "a variable must fit the position it is used in" {
  let s = rules_schema()
  assert_eq(
    verr_text(s, "query ($s: String) { user(id: $s) { name } }").contains(
      "Variable '$s' of type 'String' used in position expecting type 'ID!'.",
    ),
    true,
  )
  assert_eq(verr_text(s, "query ($s: ID!) { user(id: $s) { name } }"), "")
}

///|
/// §5.8.5: a nullable variable still reaches a non-null position when its own
/// default supplies the value the position insists on.
test "a variable default satisfies a non-null position" {
  let s = rules_schema()
  assert_eq(
    verr_text(s, "query ($s: ID = \"1\") { user(id: $s) { name } }"),
    "",
  )
  assert_eq(
    verr_text(s, "query ($s: ID) { user(id: $s) { name } }").contains(
      "Variable '$s' of type 'ID' used in position expecting type 'ID!'.",
    ),
    true,
  )
}

///|
/// §5.8.5 reaches the positions inside a spread fragment, which the fragment's own
/// check cannot see — it runs before any operation has offered it variables.
test "a variable must fit its position inside a spread fragment" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s, "query Q($s: String) { ...F } fragment F on Query { user(id: $s) { name } }",
    ).contains(
      "Variable '$s' of type 'String' used in position expecting type 'ID!'.",
    ),
    true,
  )
  assert_eq(
    verr_text(
      s, "query Q($s: ID!) { ...F } fragment F on Query { user(id: $s) { name } }",
    ),
    "",
  )
}

///|
/// §5.7.4: a directive's arguments are checked against its definition, so a
/// misspelt `@skip(iff:)` is caught rather than silently ignored at execution.
test "a directive argument must be declared" {
  let s = rules_schema()
  assert_eq(
    verr_text(s, "{ hello @skip(iff: true) }").contains(
      "Unknown argument 'iff' on directive '@skip'",
    ),
    true,
  )
  assert_eq(verr_text(s, "{ hello @skip(if: true) }"), "")
}

///|
/// §5.7.4: `@skip` declares `if: Boolean!`, so a bare `@skip` is incomplete. It
/// used to reach the executor, which read the missing argument as false.
test "a directive must supply its required arguments" {
  let s = rules_schema()
  assert_eq(
    verr_text(s, "{ hello @skip }").contains(
      "Directive '@skip' is missing required argument 'if'",
    ),
    true,
  )
  assert_eq(verr_text(s, "{ hello @include(if: false) }"), "")
}

///|
/// §5.8.3: a variable used inside a spread fragment must be defined by the
/// operation that spreads it. Checking only the operation's own selections missed
/// the common case, and the undefined variable then executed as null.
test "a variable used inside a fragment must be defined by the operation" {
  let s = rules_schema()
  let bad = verr_text(
    s,
    "query Q($a: ID!) { user(id: $a) { ...F } } fragment F on User { name }" +
    " query R($b: ID!) { user(id: $b) { ...G } } fragment G on User { name }",
  )
  assert_eq(bad, "")
  let unbound = verr_text(
    s, "query Q($a: ID!) { ...F } fragment F on Query { user(id: $missing) { id } }",
  )
  assert_eq(unbound.contains("'$missing' is not defined"), true)
}
