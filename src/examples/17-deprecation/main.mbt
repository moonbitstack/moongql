///|
/// The `@deprecated` directive through introspection. A field carries a
/// `deprecation_reason`, an enum value is deprecated through `enum_`'s `deprecated`
/// pairs. Both are hidden from `fields` / `enumValues` by default and reappear under
/// `includeDeprecated: true`, each reporting `isDeprecated` and `deprecationReason`
/// — the exact contract a schema-explorer relies on.
///
///     moon run src/examples/17-deprecation
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field("alive", NonNull(Scalar("String")))
  q.field("old", Scalar("String"), deprecation_reason="use alive")
  q.field("color", Named("Color"))
  s.enum_("Color", ["RED", "GREEN", "OLD"], deprecated=[("OLD", "use RED")])
  let r = @moongql.Resolvers::new()
  println(
    @moongql.execute(s, r, "{ __type(name: \"Query\") { fields { name } } }").stringify(),
  )
  let with_dep =
    #|{ __type(name: "Query") {
    #|  fields(includeDeprecated: true) { name isDeprecated deprecationReason }
    #|} }
  println(@moongql.execute(s, r, with_dep).stringify())
  let enums_default =
    #|{ __type(name: "Color") { enumValues { name } } }
  println(@moongql.execute(s, r, enums_default).stringify())
  let enum_dep =
    #|{ __type(name: "Color") {
    #|  enumValues(includeDeprecated: true) { name isDeprecated deprecationReason }
    #|} }
  println(@moongql.execute(s, r, enum_dep).stringify())
}
