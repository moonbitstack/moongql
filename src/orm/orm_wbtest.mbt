// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A driver over two fixed tables that records the SQL it is given.
///
/// It answers the statement's own column list rather than a canned row, so a test
/// can see both halves of projection: the statement asks for fewer columns, and
/// the row carries fewer fields.
priv struct Fake {
  sql : Array[String]
  posts : Array[Map[String, @moondb.Value]]
  authors : Array[Map[String, @moondb.Value]]
  // When set, any statement against `authors` fails, which is how a test reaches
  // the path where the database refuses.
  mut broken : Bool
}

///|
fn Fake::new() -> Fake {
  let posts : Array[Map[String, @moondb.Value]] = [
    record([("id", "p1"), ("title", "One"), ("author_id", "a1")]),
    record([("id", "p2"), ("title", "Two"), ("author_id", "a1")]),
    record([("id", "p3"), ("title", "Three"), ("author_id", "a2")]),
  ]
  let authors : Array[Map[String, @moondb.Value]] = [
    record([("id", "a1"), ("name", "Alice"), ("email", "alice@example.com")]),
    record([("id", "a2"), ("name", "Bob"), ("email", "bob@example.com")]),
  ]
  { sql: [], posts, authors, broken: false, }
}

///|
fn record(pairs : Array[(String, String)]) -> Map[String, @moondb.Value] {
  let m : Map[String, @moondb.Value] = Map([])
  for pair in pairs {
    m[pair.0] = @moondb.Text(pair.1)
  }
  m
}

///|
/// The columns a `SELECT a, b FROM ...` statement asks for.
fn select_columns(sql : String) -> Array[String] {
  let rest = match sql.find("SELECT ") {
    Some(i) => sql[i + 7:].to_owned()
    None => return []
  }
  let stop = match rest.find(" FROM ") {
    Some(i) => i
    None => rest.length()
  }
  let out : Array[String] = []
  for part in rest[:stop].split(",") {
    out.push(part.trim().to_owned())
  }
  out
}

///|
fn Fake::answer(
  self : Fake,
  sql : String,
  params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  let cols = select_columns(sql)
  let table = if sql.contains("FROM posts") {
    self.posts
  } else if sql.contains("FROM authors") {
    if self.broken {
      raise @moondb.QueryError("no such table: authors")
    }
    self.authors
  } else {
    raise @moondb.QueryError("no such table in: " + sql)
  }
  // A `WHERE id IN (?, ?)` statement is filtered by its parameters; a statement
  // without one returns the table.
  let wanted : Array[String] = []
  for param in params {
    guard param is @moondb.Text(s) else { continue }
    wanted.push(s)
  }
  let out : Array[@moondb.Row] = []
  for row in table {
    if !wanted.is_empty() {
      let id = row.get("id").unwrap_or(@moondb.Null)
      guard id is @moondb.Text(s) && wanted.contains(s) else { continue }
    }
    let values : Array[@moondb.Value] = []
    for col in cols {
      values.push(row.get(col).unwrap_or(@moondb.Null))
    }
    out.push({ columns: cols, values, })
  }
  out
}

///|
impl @moondb.Driver for Fake with fn query(self, sql, params) {
  self.sql.push(sql)
  self.answer(sql, params)
}

///|
impl @moondb.Driver for Fake with fn execute(self, sql, params) {
  self.sql.push(sql)
  self.answer(sql, params) |> ignore
  { rows_affected: 1L, last_insert_id: 1L, }
}

///|
impl @moondb.Driver for Fake with fn begin(_self) {

}

///|
impl @moondb.Driver for Fake with fn commit(_self) {

}

///|
impl @moondb.Driver for Fake with fn rollback(_self) {

}

///|
impl @moondb.Driver for Fake with fn close(_self) {

}

///|
impl @moondb.Driver for Fake with fn ping(_self) {
  true
}

///|
/// A database over one fake connection, and the fake itself so a test can read the
/// statements back.
fn fake_db() -> (Database[Fake], Fake) raise @exec.FieldError {
  let fake = Fake::new()
  let db = Database::new(() => fake) catch {
    e => raise @exec.FieldError(e.to_string())
  }
  (db, fake)
}

///|
/// A field's info with the response keys the document selects beneath it.
fn info_of(selection : Array[String]) -> @exec.ResolveInfo {
  {
    parent: Json::null(),
    args: Map([]),
    ctx: Json::null(),
    field_name: "posts",
    selection,
  }
}

///|
test "orm: the statement asks for the columns the document asks for" {
  let (db, fake) = fake_db()
  let columns = ["id", "title", "author_id", "body"]
  let rows = db.select(info_of(["id", "title"]), "posts", columns)
  assert_eq(fake.sql[0], "SELECT id, title FROM posts")
  // The row carries exactly what was fetched.
  assert_eq(rows[0].stringify(), "{\"id\":\"p1\",\"title\":\"One\"}")
}

///|
test "orm: a document that selects only a child field keeps the whole row" {
  let (db, fake) = fake_db()
  let columns = ["id", "title", "author_id", "body"]
  let _ = db.select(info_of(["author"]), "posts", columns)
  assert_eq(fake.sql[0], "SELECT id, title, author_id, body FROM posts")
}

///|
test "orm: an alias is not recognised, so the whole row is fetched" {
  let (db, fake) = fake_db()
  let columns = ["id", "title", "author_id", "body"]
  let _ = db.select(info_of(["t"]), "posts", columns)
  assert_eq(fake.sql[0], "SELECT id, title, author_id, body FROM posts")
}

///|
test "orm: a predicate and a limit are part of the statement, values are not" {
  let (db, fake) = fake_db()
  let _ = db.select(
    info_of(["id", "title"]),
    "posts",
    ["id", "title"],
    predicate="author_id = ?",
    params=[@moondb.Text("a1")],
    order_by="title DESC",
    limit=Some(2),
  )
  assert_eq(
    fake.sql[0],
    "SELECT id, title FROM posts WHERE author_id = ? ORDER BY title DESC LIMIT 2",
  )
}

///|
test "orm: every statement checks a connection out and gives it back" {
  let (db, _fake) = fake_db()
  let _ = db.select(info_of(["id"]), "posts", ["id", "title"])
  let _ = db.select(info_of(["id"]), "posts", ["id", "title"])
  // One connection opened, and none left checked out: two statements reused it.
  assert_eq(db.connections(), (1, 0))
  assert_eq(db.statements(), 2)
}

///|
/// The schema both list tests run: `Query.posts` and `Post.author`.
fn blog_schema() -> @schema.Schema {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field(
    "posts",
    @schema.NonNull(@schema.ListOf(@schema.NonNull(@schema.Named("Post")))),
  )
  let p = s.object("Post")
  p.field("id", @schema.NonNull(@schema.Scalar("ID")))
  p.field("title", @schema.NonNull(@schema.Scalar("String")))
  p.field("author_id", @schema.NonNull(@schema.Scalar("ID")))
  p.field("author", @schema.Named("Author"))
  let a = s.object("Author")
  a.field("id", @schema.NonNull(@schema.Scalar("ID")))
  a.field("name", @schema.NonNull(@schema.Scalar("String")))
  s
}

///|
/// `Query.posts` read through the database, with the authors attached in one
/// statement — `Post.author` needs no resolver of its own.
fn blog_resolvers(db : Database[Fake]) -> @exec.Resolvers {
  let r = @exec.Resolvers::new()
  r.field("Query", "posts", fn(info) -> Json raise @exec.FieldError {
    let rows = db.select(info, "posts", ["id", "title", "author_id"], keep=[
      "author_id",
    ])
    Json(
      db.attach(
        rows,
        "author",
        "authors",
        ["id", "name", "email"],
        parent_key="author_id",
      ),
    )
  })
  r
}

///|
async test "orm: three posts and their authors cost two statements, not four" {
  let (db, fake) = fake_db()
  let response = @exec.execute_async(
    blog_schema(),
    blog_resolvers(db),
    "{ posts { title author { name } } }",
  )
  // One statement for the list, one for every author on it — three posts, two
  // authors, and the second key is deduplicated out.
  assert_eq(db.statements(), 2)
  assert_eq(fake.sql.length(), 2)
  assert_eq(
    fake.sql[1],
    "SELECT id, name, email FROM authors WHERE id IN (?, ?)",
  )
  assert_eq(
    response.stringify(),
    "{\"data\":{\"posts\":[{\"title\":\"One\",\"author\":{\"name\":\"Alice\"}},{\"title\":\"Two\",\"author\":{\"name\":\"Alice\"}},{\"title\":\"Three\",\"author\":{\"name\":\"Bob\"}}]}}",
  )
}

///|
async test "orm: a longer list does not cost a longer run of statements" {
  let (db, _fake) = fake_db()
  let response = @exec.execute_async(
    blog_schema(),
    blog_resolvers(db),
    "{ posts { author { name } } }",
  )
  assert_eq(db.statements(), 2)
  assert_eq(
    response.stringify(),
    "{\"data\":{\"posts\":[{\"author\":{\"name\":\"Alice\"}},{\"author\":{\"name\":\"Alice\"}},{\"author\":{\"name\":\"Bob\"}}]}}",
  )
}

///|
async test "orm: a sibling field on the list does not split the batch" {
  let (db, fake) = fake_db()
  let _ = @exec.execute_async(
    blog_schema(),
    blog_resolvers(db),
    "{ posts { id title author { name id } } }",
  )
  // The document asks for two fields per post and two per author; the authors are
  // still one statement. An attached row carries the columns the caller listed,
  // which is why the caller lists only what the child field needs.
  assert_eq(db.statements(), 2)
  assert_eq(
    fake.sql[1],
    "SELECT id, name, email FROM authors WHERE id IN (?, ?)",
  )
}

///|
async test "orm: a refused statement is a field error at the field's path" {
  let (db, fake) = fake_db()
  fake.broken = true
  let response = @exec.execute_async(
    blog_schema(),
    blog_resolvers(db),
    "{ posts { title author { name } } }",
  )
  let text = response.stringify()
  // The list's own statement succeeded; the attached one did not, so the field
  // that ran it is what failed, at its own path.
  assert_eq(text.contains("\"errors\":"), true)
  assert_eq(text.contains("\"path\":[\"posts\"]"), true)
  assert_eq(text.contains("no such table: authors"), true)
}

///|
test "orm: one parent is attached with one statement, and a missing child is null" {
  let (db, fake) = fake_db()
  let parent : Map[String, Json] = Map([])
  parent["id"] = Json("p1")
  parent["author_id"] = Json("a1")
  let missing : Map[String, Json] = Map([])
  missing["id"] = Json("p9")
  missing["author_id"] = Json("a9")
  let out = db.attach(
    [Json::object(parent), Json::object(missing)],
    "author",
    "authors",
    ["id", "name"],
    parent_key="author_id",
  )
  assert_eq(fake.sql.length(), 1)
  assert_eq(
    out[0].stringify(),
    "{\"id\":\"p1\",\"author_id\":\"a1\",\"author\":{\"id\":\"a1\",\"name\":\"Alice\"}}",
  )
  // No row for that key: the field is null rather than the list failing.
  assert_eq(
    out[1].stringify(),
    "{\"id\":\"p9\",\"author_id\":\"a9\",\"author\":null}",
  )
}

///|
test "orm: attaching to an empty list issues no statement" {
  let (db, fake) = fake_db()
  let out = db.attach(
    [],
    "author",
    "authors",
    ["id", "name"],
    parent_key="author_id",
  )
  assert_eq(out.length(), 0)
  assert_eq(fake.sql.length(), 0)
}
