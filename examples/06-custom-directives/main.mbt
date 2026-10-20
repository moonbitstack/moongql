///|
/// A schema-defined executable directive. `@prefix(text:)` declares its location and
/// argument, plus an `on_field` hook that rewrites the resolved value. The hook reads
/// its argument (a different `text` yields a different result), and the directive
/// shows up in `__schema { directives }` beside the built-ins.
///
///     moon run examples/06-custom-directives
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field("greeting", @moongql.NonNull(@moongql.Scalar("String")))
  s.directive(
    "prefix",
    locations=["FIELD"],
    args=[("text", @moongql.NonNull(@moongql.Scalar("String")))],
    on_field=(value, args) => {
      match (value, args.get("text")) {
        (String(x), Some(String(p))) => Json(p + x)
        _ => value
      }
    },
  )
  let r = @moongql.Resolvers::new()
  r.field("Query", "greeting", fn(_info) { Json("world") })
  println(
    @moongql.execute(s, r, "{ greeting @prefix(text: \"qwq, \") }").stringify(),
  )
  println(@moongql.execute(s, r, "{ greeting }").stringify())
  println(
    @moongql.execute(s, r, "{ __schema { directives { name locations } } }").stringify(),
  )
}
