///|
/// Define a one-type schema, register a field resolver, run a query string and
/// print the `{ data }` JSON — the smallest end-to-end moongql pipeline.
///
///     moon run src/examples/00-hello
#coverage.skip
fn main {
  let schema = @moongql.Schema::new()
  let query = schema.object("Query")
  query.field("greeting", NonNull(Scalar("String")))
  query.field("luckyNumber", NonNull(Scalar("Int")))
  let resolvers = @moongql.Resolvers::new()
  resolvers.field("Query", "greeting", fn(_info) { Json("qwq from moongql") })
  resolvers.field("Query", "luckyNumber", fn(_info) { Json(233) })
  let res = @moongql.execute(schema, resolvers, "{ greeting luckyNumber }")
  println(res.stringify())
}
