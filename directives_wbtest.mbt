///|
/// A schema with one custom executable directive, `@prefix(text:)`, whose
/// `on_field` hook prepends `text` to a resolved string field. `register` toggles
/// whether the directive is defined, so a test can compare a query with and
/// without the directive taking effect.
fn prefix_setup(register : Bool) -> (Schema, Resolvers) {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("greeting", NonNull(Scalar("String")))
  if register {
    s.directive(
      "prefix",
      locations=["FIELD"],
      args=[("text", NonNull(Scalar("String")))],
      on_field=(v, args) => {
        match (v, args.get("text")) {
          (String(x), Some(String(p))) => Json(p + x)
          _ => v
        }
      },
    )
  }
  let r = Resolvers::new()
  r.field("Query", "greeting", _info => Json("world"))
  (s, r)
}

///|
/// A custom directive with an `on_field` hook alters the resolved field value.
/// MUTATION-VERIFY (both directions): with the directive applied the value is
/// transformed; the same field without the directive keeps its raw value, and a
/// different directive argument produces a correspondingly different result.
test "a custom directive alters a resolved field" {
  let (s, r) = prefix_setup(true)
  assert_eq(
    execute(
      s,
      r,
      (
        #|{ greeting @prefix(text: "Hello, ") }
      ),
    ).stringify(),
    (
      #|{"data":{"greeting":"Hello, world"}}
    ),
  )
  // Different argument -> different output (the hook really reads its args).
  assert_eq(
    execute(
      s,
      r,
      (
        #|{ greeting @prefix(text: "Bye, ") }
      ),
    ).stringify(),
    (
      #|{"data":{"greeting":"Bye, world"}}
    ),
  )
  // No directive on the field -> the raw resolved value passes through.
  assert_eq(
    execute(
      s,
      r,
      (
        #|{ greeting }
      ),
    ).stringify(),
    (
      #|{"data":{"greeting":"world"}}
    ),
  )
}

///|
/// A registered custom directive shows up in `__schema { directives }` beside the
/// built-in `@skip` / `@include` / `@deprecated`, with its locations and args.
test "a custom directive appears in introspection" {
  let (s, r) = prefix_setup(true)
  let res = execute(
    s,
    r,
    (
      #|{ __schema { directives { name locations args { name } } } }
    ),
  ).stringify()
  assert_eq(res.contains("\"name\":\"skip\""), true)
  assert_eq(res.contains("\"name\":\"include\""), true)
  assert_eq(res.contains("\"name\":\"prefix\""), true)
  // its declared FIELD location and `text` argument are reported
  assert_eq(res.contains("\"locations\":[\"FIELD\"]"), true)
  assert_eq(res.contains("\"args\":[{\"name\":\"text\"}]"), true)
}

///|
/// The validator rejects a directive that is not defined (spec §5.7.1). An
/// unregistered `@prefix` is unknown.
test "an undefined directive is a validation error" {
  let (s, r) = prefix_setup(false)
  let res = execute(
    s,
    r,
    (
      #|{ greeting @prefix(text: "x") }
    ),
  ).stringify()
  assert_eq(res.contains("Unknown directive '@prefix'"), true)
}

///|
/// The validator rejects a directive used at a location it does not declare (spec
/// §5.7.2). `@prefix` allows only `FIELD`, so applying it to an inline fragment is
/// an error.
test "a directive at a disallowed location is a validation error" {
  let (s, r) = prefix_setup(true)
  let res = execute(
    s,
    r,
    (
      #|{ ... @prefix(text: "x") { greeting } }
    ),
  ).stringify()
  assert_eq(
    res.contains("Directive '@prefix' may not be used on INLINE_FRAGMENT"),
    true,
  )
}

///|
/// A non-repeatable directive may not appear twice at one location (spec §5.7.3),
/// while a directive declared repeatable may.
test "directive repeatability is enforced" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("greeting", NonNull(Scalar("String")))
  s.directive("once", locations=["FIELD"])
  s.directive("many", locations=["FIELD"], is_repeatable=true)
  let r = Resolvers::new()
  r.field("Query", "greeting", _info => Json("world"))
  let non_repeat = execute(
    s,
    r,
    (
      #|{ greeting @once @once }
    ),
  ).stringify()
  assert_eq(non_repeat.contains("can only be used once at this location"), true)
  let repeat = execute(
    s,
    r,
    (
      #|{ greeting @many @many }
    ),
  ).stringify()
  assert_eq(repeat.contains("can only be used once"), false)
}
