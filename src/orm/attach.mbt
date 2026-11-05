// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Fetch and attach a field's rows for a whole list at once.
///
/// N+1 is a shape, not a mistake: `{ posts { author { name } } }` runs `author`
/// once per post. A single `Post.author` resolver cannot see the other posts — it
/// is handed one parent and has to answer — so the only place that knows the list
/// is the field that produced it. Here that is `Query.posts`, and it attaches the
/// authors in one statement:
///
/// ```moonbit nocheck
/// r.field("Query", "posts", fn(info) {
///   let rows = db.select(info, "posts", ["id", "title", "author_id"], keep=["author_id"])
///   Json(db.attach(rows, "author", "authors", ["id", "name"], parent_key="author_id"))
/// })
/// ```
///
/// `Post.author` then needs no resolver at all: the default resolver reads the
/// attached object off the parent, so the field costs nothing and the list costs
/// one statement however long it is. The same call answers a single parent — one
/// `IN` with one value.
///
/// Keys are deduplicated before the statement, so ten posts by one author fetch
/// that author once.
pub fn[D : @moondb.Driver] Database::attach(
  self : Database[D],
  parents : Array[Json],
  field : String,
  table : String,
  columns : Array[String],
  parent_key~ : String,
  child_key~ : String = "id",
) -> Array[Json] raise @exec.FieldError {
  let keys : Array[String] = []
  for parent in parents {
    match key_in(parent, parent_key) {
      Some(key) => if !keys.contains(key) { keys.push(key) }
      None => ()
    }
  }
  let found = self.rows_by_key(table, columns, child_key, keys)
  let out : Array[Json] = []
  for parent in parents {
    let child = match key_in(parent, parent_key) {
      Some(key) => found.get(key).unwrap_or(Json::null())
      None => Json::null()
    }
    out.push(with_field(parent, field, child))
  }
  out
}

///|
/// The text a parent object holds under `name`, if it holds one. A key is an id,
/// so it travels as a string, an integer, or a number; anything else is not a key.
fn key_in(parent : Json, name : String) -> String? {
  match parent {
    Object(fields) =>
      match fields.get(name) {
        Some(String(s)) => Some(s)
        Some(Number(n, ..)) => Some(n.to_string())
        _ => None
      }
    _ => None
  }
}

///|
/// `parent` with `field` set to `value`. The parent is copied rather than
/// changed: a row is shared with whoever else holds it, and a response should not
/// be able to alter a value another field already answered with.
fn with_field(parent : Json, field : String, value : Json) -> Json {
  match parent {
    Object(fields) => {
      let copy : Map[String, Json] = Map([])
      fields.each(fn(name, held) { copy[name] = held })
      copy[field] = value
      Json::object(copy)
    }
    other => other
  }
}
