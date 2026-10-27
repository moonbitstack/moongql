///|
/// The introspection meta-fields. `__typename` names the runtime type, `__type`
/// answers a type's kind and fields, and `__schema` reports the root operation
/// types. A field's wrapped type is walked through `ofType` (`User` → `[User!]` →
/// `NON_NULL`/`LIST`), exactly what a client tool sends to learn the schema.
///
///     moon run src/examples/11-introspection
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field_args("user", [("id", NonNull(Scalar("ID")))], Named("User"))
  q.field("users", NonNull(ListOf(NonNull(Named("User")))))
  let u = s.object("User")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", NonNull(Scalar("String")))
  let r = @moongql.Resolvers::new()
  println(@moongql.execute(s, r, "{ __typename }").stringify())
  println(
    @moongql.execute(
      s, r, "{ __type(name: \"User\") { name kind fields { name } } }",
    ).stringify(),
  )
  let deep =
    #|{
    #|  __schema { queryType { name } }
    #|  __type(name: "Query") {
    #|    fields { name type { kind ofType { kind name } } }
    #|  }
    #|}
  println(@moongql.execute(s, r, deep).stringify())
}
