///|
test "field description surfaces in introspection __Field.description" {
  let schema = @schema.Schema::new(query="Query")
  let query = schema.object("Query")
  query.field("hero", Scalar("String"), description="the main hero")
  query.field("plain", Scalar("String"))
  let q =
    #|{ __type(name: "Query") { fields { name description } } }
  let res = execute(schema, Resolvers::new(), q)
  guard res is Object(m) else { fail("response should be an object") }
  guard m.get("data") is Some(Object(data)) else { fail("data") }
  guard data.get("__type") is Some(Object(t)) else { fail("__type") }
  guard t.get("fields") is Some(Array(fields)) else { fail("fields") }
  let mut hero_desc : Json? = None
  let mut plain_desc : Json? = None
  for fj in fields {
    match fj {
      Object(fm) =>
        if fm.get("name") == Some(Json("hero")) {
          hero_desc = fm.get("description")
        } else if fm.get("name") == Some(Json("plain")) {
          plain_desc = fm.get("description")
        }
      _ => ()
    }
  }
  assert_eq(hero_desc, Some(Json("the main hero")))
  // A field with no description reports `null`, per the introspection schema.
  assert_eq(plain_desc, Some(Json::null()))
}

///|
test "type description surfaces in introspection __Type.description" {
  let schema = @schema.Schema::new(query="Query")
  let query = schema.object("Query", description="the root query type")
  query.field("hero", Scalar("String"))
  let q =
    #|{ __type(name: "Query") { name description } }
  let res = execute(schema, Resolvers::new(), q)
  guard res is Object(m) else { fail("response should be an object") }
  guard m.get("data") is Some(Object(data)) else { fail("data") }
  guard data.get("__type") is Some(Object(t)) else { fail("__type") }
  assert_eq(t.get("description"), Some(Json("the root query type")))
}

///|
test "enum type and value descriptions surface in introspection" {
  let schema = @schema.Schema::new(query="Query")
  schema.enum_("Color", ["RED", "GREEN"], description="a color choice", descriptions=[
    ("RED", "the color red"),
  ])
  schema.object("Query").field("color", Scalar("Color"))
  let q =
    #|{ __type(name: "Color") { name description enumValues { name description } } }
  let res = execute(schema, Resolvers::new(), q)
  guard res is Object(m) else { fail("response should be an object") }
  guard m.get("data") is Some(Object(data)) else { fail("data") }
  guard data.get("__type") is Some(Object(t)) else { fail("__type") }
  assert_eq(t.get("description"), Some(Json("a color choice")))
  guard t.get("enumValues") is Some(Array(vals)) else { fail("enumValues") }
  let mut red_desc : Json? = None
  let mut green_desc : Json? = None
  for vj in vals {
    match vj {
      Object(vm) =>
        if vm.get("name") == Some(Json("RED")) {
          red_desc = vm.get("description")
        } else if vm.get("name") == Some(Json("GREEN")) {
          green_desc = vm.get("description")
        }
      _ => ()
    }
  }
  assert_eq(red_desc, Some(Json("the color red")))
  assert_eq(green_desc, Some(Json::null()))
}
