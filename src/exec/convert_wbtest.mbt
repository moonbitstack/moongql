///|
fn[T : FromGql] decode(v : Json) -> Result[T, String] {
  try T::from_gql(v) catch {
    ResolverError(m) | ResolverErrorExt(m, _) => Err(m)
  } noraise {
    x => Ok(x)
  }
}

///|
test "built-in values round-trip" {
  assert_eq(ToGql::to_gql("x"), Json::string("x"))
  assert_eq(ToGql::to_gql(true), Json::boolean(true))
  assert_eq(ToGql::to_gql((3 : Int32)), Json::number(3.0))
  assert_eq(ToGql::to_gql(1.5), Json::number(1.5))
  assert_eq(ToGql::to_gql(9000000000L), Json::string("9000000000"))
  assert_eq(decode(Json::string("x")), Ok("x"))
  assert_eq(decode(Json::boolean(false)), Ok(false))
  assert_eq(decode(Json::number(3.0)), Ok((3 : Int32)))
  assert_eq(decode(Json::number(2.0)), Ok(2.0))
  assert_eq(decode(Json::string("9000000000")), Ok(9000000000L))
  assert_eq(decode(Json::number(12.0)), Ok(12L))
  let j : Json = { "a": [1, 2] }
  assert_eq(ToGql::to_gql(j), j)
  assert_eq(decode(j), Ok(j))
}

///|
test "Int refuses a fraction and anything past 32 bits" {
  let r : Result[Int32, String] = decode(Json::number(1.5))
  assert_eq(r, Err("expected Int, got 1.5"))
  let r : Result[Int32, String] = decode(Json::number(2147483648.0))
  assert_eq(r, Err("expected Int, got 2147483648"))
  let r : Result[Int32, String] = decode(Json::number(-2147483648.0))
  assert_eq(r, Ok(-2147483648))
  let r : Result[Int64, String] = decode(Json::string("12x"))
  assert_eq(r, Err("expected Int64, got \"12x\""))
  let r : Result[Bool, String] = decode(Json::string("true"))
  assert_eq(r, Err("expected Boolean, got \"true\""))
  let r : Result[Double, String] = decode(Json::null())
  assert_eq(r, Err("expected Float, got null"))
}

///|
test "options and lists" {
  let none : Int32? = None
  assert_eq(ToGql::to_gql(none), Json::null())
  assert_eq(ToGql::to_gql([Some("a"), None]), ["a", Json::null()])
  assert_eq(decode(Json::null()), Ok((None : Int32?)))
  assert_eq(decode([1, 2]), Ok([1, 2]))
  let r : Result[Array[Int32], String] = decode(Json::string("x"))
  assert_eq(r, Err("expected a list, got \"x\""))
}

///|
test "ResolveInfo::read names the argument it refused" {
  let info : ResolveInfo = {
    parent: Json::null(),
    args: { "id": Json::string("7"), "first": Json::number(1.5) },
    ctx: Json::null(),
    field_name: "user",
  }
  let id : Int64 = info.read("id")
  let missing : Int32? = info.read("absent")
  assert_eq((id, missing), (7L, None))
  let refused = try {
    let n : Int32 = info.read("first")
    "\{n}"
  } catch {
    ResolverError(m) | ResolverErrorExt(m, _) => m
  }
  assert_eq(refused, "argument `first`: expected Int, got 1.5")
}

///|
test "read takes a member of an object and names it when refused" {
  let v : Json = { "name": "a", "age": "x" }
  let name : String = read(v, "name")
  let missing : Int32? = read(v, "absent")
  assert_eq((name, missing), ("a", None))
  let refused = (f : () -> Unit raise ResolverError) => {
    try f() catch {
      ResolverError(m) | ResolverErrorExt(m, _) => m
    } noraise {
      _ => ""
    }
  }
  assert_eq(
    refused(() => ignore((read(v, "age") : Int32))),
    "field `age`: expected Int, got \"x\"",
  )
  assert_eq(
    refused(() => ignore((read(Json::number(1.0), "age") : Int32))),
    "expected an object, got 1",
  )
  match ResolverError::expected("Role", Json::string("x")) {
    ResolverError(m) => assert_eq(m, "expected Role, got \"x\"")
    _ => fail("wrong kind")
  }
}

///|
test "field_error passes a ResolverError through and wraps the rest" {
  let ext : Map[String, Json] = { "code": "X" }
  match field_error(ResolverErrorExt("m", ext)) {
    ResolverErrorExt(m, e) => assert_eq((m, e), ("m", ext))
    _ => fail("lost the extensions")
  }
  match field_error(ResolverError("plain")) {
    ResolverError(m) => assert_eq(m, "plain")
    _ => fail("changed kind")
  }
  match field_error(Failure("bad")) {
    ResolverError(m) => assert_eq(m, "Failure(bad)")
    _ => fail("not wrapped")
  }
}
