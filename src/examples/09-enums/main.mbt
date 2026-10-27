///|
/// Enum types. `enum Role { ADMIN USER GUEST }` renders in SDL, a resolver returns
/// one of its members as a leaf value, and `__type` introspects the value set.
///
///     moon run src/examples/09-enums
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field("role", Named("Role"))
  s.enum_("Role", ["ADMIN", "USER", "GUEST"])
  let r = @moongql.Resolvers::new()
  r.field("Query", "role", fn(_info) { Json("ADMIN") })
  println(@moongql.execute(s, r, "{ role }").stringify())
  println(
    @moongql.execute(
      s, r, "{ __type(name: \"Role\") { kind enumValues { name } } }",
    ).stringify(),
  )
  println(s.to_sdl().contains("enum Role {"))
}
