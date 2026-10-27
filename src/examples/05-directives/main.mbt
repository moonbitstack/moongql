///|
/// The built-in `@skip` / `@include` directives. Guarding a field on a boolean
/// variable makes one query text return different shapes: `@include(if: false)`
/// drops the guarded field, `@skip(if: true)` drops it too.
///
///     moon run src/examples/05-directives
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field("id", NonNull(Scalar("ID")))
  q.field("name", NonNull(Scalar("String")))
  q.field("age", Scalar("Int"))
  let r = @moongql.Resolvers::new()
  r.field("Query", "id", fn(_info) { Json("1") })
  r.field("Query", "name", fn(_info) { Json("lfanke") })
  r.field("Query", "age", fn(_info) { Json(233) })
  let query =
    #|query ($withAge: Boolean!, $hideName: Boolean!) {
    #|  id
    #|  name @skip(if: $hideName)
    #|  age @include(if: $withAge)
    #|}
  let shown : Map[String, Json] = { "withAge": true, "hideName": false }
  println(@moongql.execute(s, r, query, variables=shown).stringify())
  let hidden : Map[String, Json] = { "withAge": false, "hideName": true }
  println(@moongql.execute(s, r, query, variables=hidden).stringify())
}
