// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The reference page's directive half: what a document may write, where it may
// write it, and what arguments it takes. Three sources meet on the page — the
// directives the specification fixes, the two this server executes, and the ones
// a schema registered — and all three have to be there, or the page describes a
// smaller schema than the endpoint serves.

///|
/// A schema with one directive of its own, beside a field to query.
fn directive_schema() -> @schema.Schema {
  let s = @schema.Schema::new()
  s.object("Query").field("hello", NonNull(@schema.Scalar("String")))
  s.directive(
    "lower",
    locations=["FIELD"],
    args=[("mode", Scalar("String"))],
    defaults=[("mode", Json("ascii"))],
    description="Lower-cases the field <for real>.",
  )
  s
}

///|
/// Every directive the endpoint accepts has a section of its own, anchored so a
/// link can reach it, with the locations it may be written at.
test "the reference page lists the directives, from all three sources" {
  let page = reference.html(schema=directive_schema())
  for
    name in [
      "include", "skip", "deprecated", "specifiedBy", "defer", "stream", "lower",
    ] {
    assert_eq(page.contains("id=\"directive-" + name + "\""), true)
    assert_eq(page.contains("href=\"#directive-" + name + "\""), true)
  }
  // the heading names it the way a document does
  assert_eq(page.contains("<span class=\"name\">@lower</span>"), true)
  assert_eq(page.contains("<span class=\"kind\">DIRECTIVE</span>"), true)
  // where it may be written, and what it takes
  assert_eq(page.contains("Locations: "), true)
  assert_eq(page.contains("<code>FIELD_DEFINITION</code>"), true)
  assert_eq(page.contains("<span class=\"aname\">mode</span>"), true)
  assert_eq(page.contains("&quot;ascii&quot;"), true)
  // a description is text, not markup
  assert_eq(page.contains("Lower-cases the field &lt;for real&gt;."), true)
  // the counts row numbers them
  assert_eq(page.contains("<div>Directives<b>7</b></div>"), true)
}

///|
/// A directive that can only appear on one kind of element says so, and one the
/// server executes carries the defaults it executes with: `@stream` streams
/// nothing until `initialCount` says so, and the page has to show the zero.
test "the directive section carries the locations and the defaults it runs with" {
  let page = reference.html(schema=directive_schema())
  assert_eq(page.contains("<code>FRAGMENT_SPREAD</code>"), true)
  assert_eq(page.contains("<span class=\"aname\">initialCount</span>"), true)
  assert_eq(page.contains("= </span><span class=\"def\">0</span>"), true)
  // `@deprecated` is a field-level fact, and its argument has the reason the
  // specification fixes
  assert_eq(page.contains("<span class=\"aname\">reason</span>"), true)
  assert_eq(page.contains("No longer supported"), true)
}
