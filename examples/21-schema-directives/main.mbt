///|
/// The schema-metadata surface: applied (type-system) directives and the by-name
/// accessors. `directive` defines a pure `@tag` directive; `apply_schema_directive`
/// / `apply_type_directive` / `apply_field_directive` record uses of it built with
/// `AppliedDirective::new`, then `type_has_directive` / `field_has_directive` and
/// the `*_applied_directives` lists read them back. The `*_by_name` lookups plus
/// `field_by_name` and `GqlType::named_base` let code reflect over a schema it built.
///
///     moon run examples/21-schema-directives
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field("me", @moongql.Named("User"))
  let u = s.object("User")
  u.field("id", @moongql.NonNull(@moongql.Scalar("ID")))
  u.field("email", @moongql.NonNull(@moongql.Scalar("String")))
  s.enum_("Role", ["ADMIN", "USER"])
  s.union("Actor", ["User"])
  s.scalar("DateTime")
  s.directive("tag", locations=["OBJECT", "FIELD_DEFINITION"], args=[
    ("name", @moongql.NonNull(@moongql.Scalar("String"))),
  ])
  s.apply_schema_directive(
    @moongql.AppliedDirective::new("link", args=[
      ("url", Json("https://example.com")),
    ]),
  )
  s.apply_type_directive(
    "User",
    @moongql.AppliedDirective::new("tag", args=[("name", Json("core"))]),
  )
  s.apply_field_directive(
    "User",
    "email",
    @moongql.AppliedDirective::new("tag", args=[("name", Json("pii"))]),
  )
  println("User has @tag: \{s.type_has_directive("User", "tag")}")
  println(
    "User.email has @tag: \{s.field_has_directive("User", "email", "tag")}",
  )
  println("User.id has @tag: \{s.field_has_directive("User", "id", "tag")}")
  for d in s.type_applied_directives("User") {
    println("type directive: @" + d.name)
  }
  for d in s.field_applied_directives("User", "email") {
    println("field directive: @" + d.name)
  }
  match s.directive_def_by_name("tag") {
    Some(def) => println("def @tag locations: " + def.locations.join(", "))
    None => ()
  }
  match s.type_by_name("User") {
    Some(t) => {
      println("type: " + t.name)
      match t.field_by_name("id") {
        Some(f) => println("field id base type: " + f.typ.named_base())
        None => ()
      }
    }
    None => ()
  }
  match s.enum_by_name("Role") {
    Some(e) => println("enum Role values: " + e.values.join(", "))
    None => ()
  }
  match s.union_by_name("Actor") {
    Some(un) => println("union Actor members: " + un.members.join(", "))
    None => ()
  }
  match s.scalar_by_name("DateTime") {
    Some(sc) => println("scalar: " + sc.name)
    None => ()
  }
}
