// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A database with a blog in it: two authors, three posts, one post by the second.
fn seeded() -> @orm.Database[@moonsqlite.SqliteDriver] raise @exec.FieldError {
  let db = open(":memory:")
  script(
    db,
    "CREATE TABLE authors (id TEXT PRIMARY KEY, name TEXT NOT NULL);\n" +
    "CREATE TABLE posts (id TEXT PRIMARY KEY, title TEXT NOT NULL, views INTEGER NOT NULL, author_id TEXT NOT NULL REFERENCES authors(id));",
  )
  script(
    db,
    "INSERT INTO authors (id, name) VALUES ('a1', 'Alice'), ('a2', 'Bob');\n" +
    "INSERT INTO posts (id, title, views, author_id) VALUES ('p1', 'One', 12, 'a1'), ('p2', 'Two', 0, 'a1'), ('p3', 'Three', 7, 'a2');",
  )
  db
}

///|
fn blog_schema() -> @schema.Schema {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field(
    "posts",
    @schema.NonNull(@schema.ListOf(@schema.NonNull(@schema.Named("Post")))),
  )
  q.field("broken", @schema.Named("Post"))
  let p = s.object("Post")
  p.field("id", @schema.NonNull(@schema.Scalar("ID")))
  p.field("title", @schema.NonNull(@schema.Scalar("String")))
  p.field("views", @schema.NonNull(@schema.Scalar("Int")))
  p.field("author_id", @schema.NonNull(@schema.Scalar("ID")))
  p.field("author", @schema.Named("Author"))
  let a = s.object("Author")
  a.field("id", @schema.NonNull(@schema.Scalar("ID")))
  a.field("name", @schema.NonNull(@schema.Scalar("String")))
  s
}

///|
/// The list read with the columns the document asks for, and the authors attached
/// when — and only when — the document asks for them.
fn blog_resolvers(
  db : @orm.Database[@moonsqlite.SqliteDriver],
) -> @exec.Resolvers {
  let r = @exec.Resolvers::new()
  r.field("Query", "posts", fn(info) -> Json raise @exec.FieldError {
    let rows = db.select(
      info,
      "posts",
      ["id", "title", "views", "author_id"],
      keep=["author_id"],
      order_by="id",
    )
    let with_authors = if info.reads("author") {
      db.attach(
        rows,
        "author",
        "authors",
        ["id", "name"],
        parent_key="author_id",
      )
    } else {
      rows
    }
    Json(with_authors)
  })
  r.field("Query", "broken", fn(info) -> Json raise @exec.FieldError {
    Json(db.select(info, "no_such_table", ["id"]))
  })
  r
}

///|
async test "sqlite: a list and its authors cost two statements" {
  let db = seeded()
  let response = @exec.execute_async(
    blog_schema(),
    blog_resolvers(db),
    "{ posts { title views author { name } } }",
  )
  assert_eq(db.statements(), 2)
  assert_eq(
    response.stringify(),
    "{\"data\":{\"posts\":[{\"title\":\"One\",\"views\":12,\"author\":{\"name\":\"Alice\"}},{\"title\":\"Two\",\"views\":0,\"author\":{\"name\":\"Alice\"}},{\"title\":\"Three\",\"views\":7,\"author\":{\"name\":\"Bob\"}}]}}",
  )
}

///|
async test "sqlite: a document that does not ask for the author costs one statement" {
  let db = seeded()
  let response = @exec.execute_async(
    blog_schema(),
    blog_resolvers(db),
    "{ posts { title } }",
  )
  // `info.reads("author")` is false, so the join never runs: the same resolver is
  // one statement for one document and two for another.
  assert_eq(db.statements(), 1)
  assert_eq(
    response.stringify(),
    "{\"data\":{\"posts\":[{\"title\":\"One\"},{\"title\":\"Two\"},{\"title\":\"Three\"}]}}",
  )
}

///|
async test "sqlite: a statement the database refuses is a field error" {
  let db = seeded()
  let response = @exec.execute_async(
    blog_schema(),
    blog_resolvers(db),
    "{ broken { id } }",
  )
  let text = response.stringify()
  assert_eq(text.contains("no such table: no_such_table"), true)
  assert_eq(text.contains("\"path\":[\"broken\"]"), true)
}

///|
test "sqlite: a row's types survive the trip to JSON" {
  let db = seeded()
  let info : @exec.ResolveInfo = {
    parent: Json::null(),
    args: Map([]),
    ctx: Json::null(),
    field_name: "posts",
    selection: ["id", "views"],
  }
  let rows = db.select(info, "posts", ["id", "title", "views"], order_by="id")
  // An integer is a JSON number, not a string, and the columns the document did
  // not ask for are not fetched.
  assert_eq(rows[0].stringify(), "{\"id\":\"p1\",\"views\":12}")
  assert_eq(rows[2].stringify(), "{\"id\":\"p3\",\"views\":7}")
}

///|
test "sqlite: the connection goes back after a failed statement" {
  let db = seeded()
  try {
    let _ = db.select(
      {
        parent: Json::null(),
        args: Map([]),
        ctx: Json::null(),
        field_name: "broken",
        selection: ["id"],
      },
      "no_such_table",
      ["id"],
    )
  } catch {
    _ => ()
  }
  // Nothing leaked: the pool still has its one connection, idle.
  assert_eq(db.connections(), (1, 0))
}
