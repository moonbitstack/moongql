///|
/// The rest of `execute`'s inputs. `context` is threaded to every resolver as
/// `info.ctx`; `root_value` seeds the root object a resolver reads as `info.parent`;
/// `operation_name` picks one operation when the document defines several. `whoami`
/// reads the caller off the context, `origin` echoes a field of the root value, and
/// `field` reports its own `info.field_name`.
///
///     moon run examples/14-context
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field("whoami", @moongql.NonNull(@moongql.Scalar("String")))
  q.field("field", @moongql.NonNull(@moongql.Scalar("String")))
  q.field("origin", @moongql.Scalar("String"))
  let r = @moongql.Resolvers::new()
  r.field("Query", "whoami", info => {
    match info.ctx {
      Object(m) =>
        match m.get("user") {
          Some(u) => u
          _ => "anon".to_json()
        }
      _ => "anon".to_json()
    }
  })
  r.field("Query", "field", info => info.field_name.to_json())
  r.field("Query", "origin", info => {
    match info.parent {
      Object(m) =>
        match m.get("tag") {
          Some(t) => t
          _ => Json::null()
        }
      _ => Json::null()
    }
  })
  let ctx : Json = { "user": "heke1228" }
  let root : Json = { "tag": "qwq" }
  println(
    @moongql.execute(
      s,
      r,
      "{ whoami field origin }",
      context=ctx,
      root_value=root,
    ).stringify(),
  )
  let doc =
    #|query A { whoami }
    #|query B { field }
  println(
    @moongql.execute(s, r, doc, context=ctx, operation_name="A").stringify(),
  )
  println(
    @moongql.execute(s, r, doc, context=ctx, operation_name="B").stringify(),
  )
}
