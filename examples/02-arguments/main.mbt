///|
/// Field arguments and their defaults. `greet(name: String = "lfanke")` echoes its
/// argument through `ResolveInfo::arg`, so omitting it applies the default,
/// supplying it overrides, and an explicit `null` counts as a value — the default
/// applies only to an omitted argument, not a null one.
///
///     moon run examples/02-arguments
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field_args(
    "greet",
    [("name", @moongql.Scalar("String"))],
    @moongql.NonNull(@moongql.Scalar("String")),
    defaults=[("name", Json("lfanke"))],
  )
  let r = @moongql.Resolvers::new()
  r.field("Query", "greet", fn(info) {
    let who = match info.arg("name") {
      String(n) => n
      Null => "nobody"
      _ => "?"
    }
    Json("qwq, " + who)
  })
  println(@moongql.execute(s, r, "{ greet }").stringify())
  println(@moongql.execute(s, r, "{ greet(name: \"heke1228\") }").stringify())
  println(@moongql.execute(s, r, "{ greet(name: null) }").stringify())
}
