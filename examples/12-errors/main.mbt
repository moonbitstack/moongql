///|
/// Field errors and the `{ data, errors }` shape. A non-null field resolving to null
/// records an error and bubbles null up to the nearest nullable parent; a resolver
/// raising `ResolverError` becomes one error entry; and `ResolverErrorExt` attaches
/// an `extensions` object (an error code, a status) to that entry.
///
///     moon run examples/12-errors
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field("mustFail", NonNull(Scalar("String")))
  q.field("boom", Scalar("String"))
  q.field("kaboom", Scalar("String"))
  let r = @moongql.Resolvers::new()
  r.field("Query", "mustFail", fn(_info) { Json::null() })
  r.field("Query", "boom", _info => raise @exec.ResolverError("plain failure"))
  r.field("Query", "kaboom", _info => {
    raise @exec.ResolverErrorExt("with extensions", {
      "code": "qwq",
      "status": 233,
    })
  })
  println(@moongql.execute(s, r, "{ mustFail }").stringify())
  println(@moongql.execute(s, r, "{ boom }").stringify())
  println(@moongql.execute(s, r, "{ kaboom }").stringify())
}
