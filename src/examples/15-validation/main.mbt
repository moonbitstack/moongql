///|
/// Static validation with `parse` + `validate`. A document is checked against the
/// schema before any resolver runs: a valid query yields an empty error list, while
/// an unknown field, an undefined variable and an unknown fragment each surface a
/// `GqlError`. `execute` runs the same pass and returns an errors-only response when
/// a query does not validate.
///
///     moon run src/examples/15-validation
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field_args("user", [("id", NonNull(Scalar("ID")))], Named("User"))
  q.field("hello", NonNull(Scalar("String")))
  let u = s.object("User")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", NonNull(Scalar("String")))
  let report = fn(label : String, query : String) -> Unit {
    let doc = @moongql.parse(query) catch {
      @lang.GqlSyntaxError(msg, _, _) => {
        println(label + ": syntax error: " + msg)
        return
      }
    }
    let errs = @moongql.validate(s, doc)
    if errs.is_empty() {
      println(label + ": valid")
    } else {
      for e in errs {
        println(label + ": " + e.message)
      }
    }
  }
  report("valid", "{ hello user(id: \"1\") { name } }")
  report("unknown-field", "{ nope }")
  report("undefined-variable", "{ user(id: $missing) { name } }")
  report("unknown-fragment", "{ user(id: \"1\") { ...Missing } }")
  // `execute` folds validation in: an invalid query never reaches a resolver.
  println(
    @moongql.execute(s, @moongql.Resolvers::new(), "{ nope }").stringify(),
  )
}
