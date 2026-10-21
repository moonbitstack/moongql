///|
/// The standard GraphQL introspection query graphql-core / strawberry send to
/// discover a schema. Parsing it exercises operation names, deeply nested
/// selection sets, aliases-free fields, arguments, directives, and both named
/// and inline fragments in one document.
let introspection_query : String =
  #|query IntrospectionQuery {
  #|  __schema {
  #|    queryType { name }
  #|    mutationType { name }
  #|    subscriptionType { name }
  #|    types {
  #|      ...FullType
  #|    }
  #|    directives {
  #|      name
  #|      description
  #|      locations
  #|      args {
  #|        ...InputValue
  #|      }
  #|    }
  #|  }
  #|}
  #|
  #|fragment FullType on __Type {
  #|  kind
  #|  name
  #|  description
  #|  fields(includeDeprecated: true) {
  #|    name
  #|    description
  #|    args {
  #|      ...InputValue
  #|    }
  #|    type {
  #|      ...TypeRef
  #|    }
  #|    isDeprecated
  #|    deprecationReason
  #|  }
  #|  inputFields {
  #|    ...InputValue
  #|  }
  #|  interfaces {
  #|    ...TypeRef
  #|  }
  #|  enumValues(includeDeprecated: true) {
  #|    name
  #|    description
  #|    isDeprecated
  #|    deprecationReason
  #|  }
  #|  possibleTypes {
  #|    ...TypeRef
  #|  }
  #|}
  #|
  #|fragment InputValue on __InputValue {
  #|  name
  #|  description
  #|  type { ...TypeRef }
  #|  defaultValue
  #|}
  #|
  #|fragment TypeRef on __Type {
  #|  kind
  #|  name
  #|  ofType {
  #|    kind
  #|    name
  #|  }
  #|}

///|
test "tokenize punctuators, names, numbers and strings" {
  let toks = tokenize("query a(b: 1, c: 2.5e-3) @dir { \"hi\" }")
  // query a ( b : 1 , c : 2.5e-3 ) @ dir { "hi" } EOF  (commas are ignored)
  let kinds = toks.map(t => t.kind)
  assert_eq(kinds[0] == Name, true)
  assert_eq(toks[0].value, "query")
  assert_eq(kinds[2] == ParenL, true)
  assert_eq(kinds[5] == IntVal, true)
  assert_eq(toks[5].value, "1")
  // find the float token
  let mut float_seen = false
  for t in toks {
    if t.kind == FloatVal {
      assert_eq(t.value, "2.5e-3")
      float_seen = true
    }
  }
  assert_eq(float_seen, true)
  assert_eq(toks[toks.length() - 1].kind == Eof, true)
}

///|
test "shorthand anonymous query round-trips" {
  let doc = parse("{ hero { name } }")
  assert_eq(doc.definitions.length(), 1)
  match doc.definitions[0] {
    OperationDef(op) => {
      assert_eq(op.operation == Query, true)
      assert_eq(op.name is None, true)
      assert_eq(op.selection_set.length(), 1)
    }
    _ => fail("expected an operation")
  }
  assert_eq(doc.to_query(), "{\n  hero {\n    name\n  }\n}")
}

///|
test "field alias, arguments and nested selection" {
  let doc = parse("query { human: user(id: 4, active: true) { name age } }")
  match doc.definitions[0] {
    OperationDef(op) =>
      match op.selection_set[0] {
        FieldSel(f) => {
          assert_eq(f.alias_ is Some("human"), true)
          assert_eq(f.name, "user")
          assert_eq(f.arguments.length(), 2)
          assert_eq(f.arguments[0].name, "id")
          assert_eq(f.arguments[0].value.to_query(), "4")
          assert_eq(f.arguments[1].value.to_query(), "true")
          assert_eq(f.selection_set.length(), 2)
        }
        _ => fail("expected a field")
      }
    _ => fail("expected an operation")
  }
}

///|
test "variable definitions with types and default values" {
  let doc = parse(
    "query Q($id: ID!, $tags: [String!] = [\"a\", \"b\"], $n: Int = 3) { f }",
  )
  match doc.definitions[0] {
    OperationDef(op) => {
      assert_eq(op.name is Some("Q"), true)
      assert_eq(op.variable_definitions.length(), 3)
      let v0 = op.variable_definitions[0]
      assert_eq(v0.variable, "id")
      assert_eq(v0.typ.to_query(), "ID!")
      assert_eq(v0.default_value is None, true)
      let v1 = op.variable_definitions[1]
      assert_eq(v1.typ.to_query(), "[String!]")
      match v1.default_value {
        Some(dv) => assert_eq(dv.to_query(), "[\"a\", \"b\"]")
        None => fail("expected a default value")
      }
      let v2 = op.variable_definitions[2]
      assert_eq(v2.default_value.unwrap().to_query(), "3")
    }
    _ => fail("expected an operation")
  }
}

///|
test "variable used as an argument value" {
  let doc = parse("query ($id: ID!) { user(id: $id) { name } }")
  match doc.definitions[0] {
    OperationDef(op) =>
      match op.selection_set[0] {
        FieldSel(f) => assert_eq(f.arguments[0].value.to_query(), "$id")
        _ => fail("expected a field")
      }
    _ => fail("expected an operation")
  }
}

///|
test "mutation with object-value argument" {
  let doc = parse(
    "mutation { createUser(input: {name: \"Ada\", age: 36, roles: [ADMIN]}) { id } }",
  )
  match doc.definitions[0] {
    OperationDef(op) => {
      assert_eq(op.operation == Mutation, true)
      match op.selection_set[0] {
        FieldSel(f) => {
          assert_eq(f.name, "createUser")
          assert_eq(
            f.arguments[0].value.to_query(),
            "{name: \"Ada\", age: 36, roles: [ADMIN]}",
          )
        }
        _ => fail("expected a field")
      }
    }
    _ => fail("expected an operation")
  }
}

///|
test "subscription operation type" {
  let doc = parse("subscription S { messageAdded { body } }")
  match doc.definitions[0] {
    OperationDef(op) => {
      assert_eq(op.operation == Subscription, true)
      assert_eq(op.name is Some("S"), true)
    }
    _ => fail("expected an operation")
  }
}

///|
test "named fragment definition and spread" {
  let doc = parse(
    (
      #|query { user { ...userFields } }
      #|fragment userFields on User { id name }
    ),
  )
  assert_eq(doc.definitions.length(), 2)
  match doc.definitions[0] {
    OperationDef(op) =>
      match op.selection_set[0] {
        FieldSel(f) =>
          match f.selection_set[0] {
            FragmentSpreadSel(name, _, _) => assert_eq(name, "userFields")
            _ => fail("expected a fragment spread")
          }
        _ => fail("expected a field")
      }
    _ => fail("expected an operation")
  }
  match doc.definitions[1] {
    FragmentDef(fr) => {
      assert_eq(fr.name, "userFields")
      assert_eq(fr.type_condition, "User")
      assert_eq(fr.selection_set.length(), 2)
    }
    _ => fail("expected a fragment definition")
  }
}

///|
test "inline fragment with type condition" {
  let doc = parse("{ hero { ... on Droid { primaryFunction } name } }")
  match doc.definitions[0] {
    OperationDef(op) =>
      match op.selection_set[0] {
        FieldSel(f) =>
          match f.selection_set[0] {
            InlineFragmentSel(cond, _, sels, _) => {
              assert_eq(cond is Some("Droid"), true)
              assert_eq(sels.length(), 1)
            }
            _ => fail("expected an inline fragment")
          }
        _ => fail("expected a field")
      }
    _ => fail("expected an operation")
  }
}

///|
test "directives @skip and @include with variable arguments" {
  let doc = parse(
    "query ($v: Boolean!) { a @skip(if: $v) b @include(if: true) }",
  )
  match doc.definitions[0] {
    OperationDef(op) => {
      match op.selection_set[0] {
        FieldSel(f) => {
          assert_eq(f.directives.length(), 1)
          assert_eq(f.directives[0].name, "skip")
          assert_eq(f.directives[0].arguments[0].name, "if")
          assert_eq(f.directives[0].arguments[0].value.to_query(), "$v")
        }
        _ => fail("expected a field")
      }
      match op.selection_set[1] {
        FieldSel(f) => assert_eq(f.directives[0].name, "include")
        _ => fail("expected a field")
      }
    }
    _ => fail("expected an operation")
  }
}

///|
test "string escapes are decoded" {
  let doc = parse("{ f(s: \"a\\nb\\tc\\u0041\") }")
  match doc.definitions[0] {
    OperationDef(op) =>
      match op.selection_set[0] {
        FieldSel(f) =>
          match f.arguments[0].value {
            StringValue(s, block) => {
              assert_eq(block, false)
              assert_eq(s, "a\nb\tcA")
            }
            _ => fail("expected a string value")
          }
        _ => fail("expected a field")
      }
    _ => fail("expected an operation")
  }
}

///|
test "block string is dedented per spec" {
  let doc = parse(
    (
      #|{ f(s: """
      #|    line one
      #|      line two
      #|    """) }
    ),
  )
  match doc.definitions[0] {
    OperationDef(op) =>
      match op.selection_set[0] {
        FieldSel(f) =>
          match f.arguments[0].value {
            StringValue(s, block) => {
              assert_eq(block, true)
              assert_eq(s, "line one\n  line two")
            }
            _ => fail("expected a string value")
          }
        _ => fail("expected a field")
      }
    _ => fail("expected an operation")
  }
}

///|
test "null and enum values" {
  let doc = parse("{ f(a: null, b: STATUS_OK, c: false) }")
  match doc.definitions[0] {
    OperationDef(op) =>
      match op.selection_set[0] {
        FieldSel(f) => {
          assert_eq(f.arguments[0].value is NullValue, true)
          match f.arguments[1].value {
            EnumValue(e) => assert_eq(e, "STATUS_OK")
            _ => fail("expected an enum value")
          }
          assert_eq(f.arguments[2].value.to_query(), "false")
        }
        _ => fail("expected a field")
      }
    _ => fail("expected an operation")
  }
}

///|
test "comments and commas are ignored" {
  let doc = parse(
    (
      #|# leading comment
      #|{
      #|  a,
      #|  b # trailing comment
      #|  c
      #|}
    ),
  )
  match doc.definitions[0] {
    OperationDef(op) => assert_eq(op.selection_set.length(), 3)
    _ => fail("expected an operation")
  }
}

///|
test "parses the full introspection query" {
  let doc = parse(introspection_query)
  // One operation + three fragments.
  assert_eq(doc.definitions.length(), 4)
  match doc.definitions[0] {
    OperationDef(op) => {
      assert_eq(op.operation == Query, true)
      assert_eq(op.name is Some("IntrospectionQuery"), true)
      // __schema is the single top-level field.
      match op.selection_set[0] {
        FieldSel(f) => assert_eq(f.name, "__schema")
        _ => fail("expected __schema field")
      }
    }
    _ => fail("expected an operation")
  }
  let frag_names = []
  for i = 1; i < doc.definitions.length(); i = i + 1 {
    match doc.definitions[i] {
      FragmentDef(fr) => frag_names.push(fr.name)
      _ => fail("expected a fragment")
    }
  }
  assert_eq(frag_names, ["FullType", "InputValue", "TypeRef"])
}

///|
test "re-parsing a printed document is stable" {
  let src = "query Q($id: ID!) { user(id: $id) { name friends { name } } }"
  let once = parse(src).to_query()
  let twice = parse(once).to_query()
  assert_eq(once, twice)
}

///|
test "syntax errors carry a position and message" {
  // Missing closing brace.
  let r = try {
    parse("{ a ") |> ignore
    None
  } catch {
    e => Some(e.to_string())
  }
  match r {
    Some(msg) => assert_eq(contains(msg, "Syntax error"), true)
    None => fail("expected a syntax error")
  }
  // Leading-zero integer is invalid.
  let bad_number = try {
    parse("{ f(n: 01) }") |> ignore
    false
  } catch {
    _ => true
  }
  assert_eq(bad_number, true)
  // A lone spread with nothing after it is invalid.
  let bad_spread = try {
    parse("{ ... }") |> ignore
    false
  } catch {
    _ => true
  }
  assert_eq(bad_spread, true)
}
