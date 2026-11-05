///|
test "client: a request body carries the document, its variables and the operation" {
  let body = request_body(
    "{ hello }",
    variables=Map([("id", Json(7))]),
    operation_name="Q",
  )
  inspect(
    body.stringify(),
    content="{\"query\":\"{ hello }\",\"variables\":{\"id\":7},\"operationName\":\"Q\"}",
  )
}

///|
test "client: a body without variables or an operation name carries neither" {
  inspect(
    request_body("{ hello }").stringify(),
    content="{\"query\":\"{ hello }\"}",
  )
}

///|
test "client: the errors of an answer are read back whole" {
  let answer = @json.parse(
    "{\"data\":null,\"errors\":[{\"message\":\"boom\",\"path\":[\"a\",1],\"locations\":[{\"line\":3,\"column\":5}],\"extensions\":{\"code\":\"X\"}}]}",
  ) catch {
    _ => Json::null()
  }
  let errs = errors_of(answer).unwrap_or([])
  assert_eq(errs.length(), 1)
  assert_eq(errs[0].message, "boom")
  assert_eq(errs[0].path.length(), 2)
  assert_eq(errs[0].locations[0].line, 3)
  assert_eq(errs[0].locations[0].col, 5)
  assert_eq(errs[0].extensions.get("code") is Some(_), true)
}

///|
test "client: an answer without errors has none" {
  let answer = @json.parse("{\"data\":{\"a\":1}}") catch { _ => Json::null() }
  assert_eq(errors_of(answer) is None, true)
}

///|
test "client: a document that does not parse is refused before any request" {
  let refused = try {
    check("{ hello")
    ""
  } catch {
    e => e.to_string()
  }
  assert_eq(refused.contains("expected"), true)
}

///|
test "client: a document that parses is not refused" {
  let refused = try {
    check("{ hello }")
    ""
  } catch {
    e => e.to_string()
  }
  assert_eq(refused, "")
}
