///|
/// Custom scalars. `Tag` carries a `parse_value` (input coercion) and a `serialize`
/// (output coercion): an argument runs through `parse_value` before the resolver
/// sees it, and the result runs through `serialize`, so a round-trip shows both
/// prefixes. `DateTime` carries a `spec_url`, surfaced as `specifiedByURL` in
/// introspection (`@specifiedBy`).
///
///     moon run src/examples/10-scalars
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field_args("echo", [("v", NonNull(Named("Tag")))], NonNull(Named("Tag")))
  q.field("now", Named("DateTime"))
  s.scalar(
    "Tag",
    serialize=fn(j) {
      match j {
        String(x) => Json("out:" + x)
        _ => j
      }
    },
    parse_value=fn(j) {
      match j {
        String(x) => Json("in:" + x)
        _ => j
      }
    },
  )
  s.scalar("DateTime", spec_url="https://scalars.graphql.org/datetime")
  let r = @moongql.Resolvers::new()
  r.field("Query", "echo", fn(info) { info.arg("v") })
  println(@moongql.execute(s, r, "{ echo(v: \"emm\") }").stringify())
  println(
    @moongql.execute(
      s, r, "{ __type(name: \"DateTime\") { name kind specifiedByURL } }",
    ).stringify(),
  )
}
