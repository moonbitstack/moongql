// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Which of `columns` the document asks for.
///
/// The selection a resolver receives names the response keys beneath its field, so
/// `{ posts { id title } }` asks for two columns out of however many the table has.
/// A selection that names none of them — `{ posts { author { name } } }`, where
/// every selected key belongs to a child — keeps the whole row, because the row
/// has to carry the keys the child needs.
///
/// The match is by response key, so an alias (`title` selected as `t`) is not
/// recognised and falls back to the whole row: fetching a column too many is
/// cheaper than fetching one too few. Columns named in `keep` are fetched
/// whatever the document says, because they are what a child field needs to find
/// its own row — a foreign key is rarely selected and always required.
fn projected(
  info : @exec.ResolveInfo,
  columns : Array[String],
  keep : Array[String],
) -> Array[String] {
  if info.selection.is_empty() {
    return columns.copy()
  }
  let picked = columns.filter(fn(column) {
    info.reads(column) || keep.contains(column)
  })
  if picked.is_empty() {
    columns.copy()
  } else {
    picked
  }
}

///|
/// `SELECT <columns> FROM <table> [WHERE ...] [ORDER BY ...] [LIMIT n]`.
///
/// The table, the columns, the predicate and the ordering are written by the
/// developer as part of the query shape — they are identifiers and SQL fragments,
/// not values — while every value travels as a bound parameter, so a request
/// cannot reach the statement text.
fn select_sql(
  table : String,
  columns : Array[String],
  predicate~ : String,
  order_by~ : String,
  limit? : Int32,
) -> String {
  let sb = StringBuilder()
  sb.write_string("SELECT ")
  sb.write_string(join(columns, ", "))
  sb.write_string(" FROM ")
  sb.write_string(table)
  if predicate != "" {
    sb.write_string(" WHERE ")
    sb.write_string(predicate)
  }
  if order_by != "" {
    sb.write_string(" ORDER BY ")
    sb.write_string(order_by)
  }
  if limit is Some(n) {
    sb.write_string(" LIMIT ")
    sb.write_string(n.to_string())
  }
  sb.to_string()
}

///|
/// `items` joined by `separator`, without a trailing one.
fn join(items : Array[String], separator : String) -> String {
  let sb = StringBuilder()
  for i, item in items {
    if i > 0 {
      sb.write_string(separator)
    }
    sb.write_string(item)
  }
  sb.to_string()
}

///|
/// A row as a JSON object named by its columns, which is the shape the default
/// field resolver reads a parent object from.
pub fn row_json(row : @moondb.Row) -> Json {
  let fields : Map[String, Json] = Map([])
  for i, name in row.columns {
    fields[name] = value_json(row.values[i])
  }
  Json::object(fields)
}

///|
/// One cell as JSON: a number stays a number, text stays text, and a value whose
/// JSON shape is decided elsewhere travels as its own rendering.
fn value_json(value : @moondb.Value) -> Json {
  match value {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Int(i) => Json::number(i.to_double())
    Int64(i) => Json::number(i.to_double())
    Double(d) => Json::number(d)
    Text(s) => Json::string(s)
    other => Json::string(other.to_string())
  }
}

///|
/// Read one table for the field whose selection `info` carries, answering rows as
/// JSON objects. Only the columns the document asks for are fetched.
///
/// ```moonbit nocheck
/// r.field_async("Query", "posts", fn(info) {
///   Json(db.select(info, "posts", ["id", "title", "author_id", "body"]))
/// })
/// ```
///
/// `WHERE` takes `?` for each of `params`, in order; `limit` is a number written
/// into the statement because a LIMIT is not a value a driver binds portably.
pub fn[D : @moondb.Driver] Database::select(
  self : Database[D],
  info : @exec.ResolveInfo,
  table : String,
  columns : Array[String],
  predicate~ : String = "",
  params~ : Array[@moondb.Value] = [],
  order_by~ : String = "",
  limit? : Int32,
  keep~ : Array[String] = [],
) -> Array[Json] raise @exec.FieldError {
  let cols = projected(info, columns, keep)
  let sql = select_sql(table, cols, predicate~, order_by~, limit?)
  let rows = self.rows(sql, params~)
  let out : Array[Json] = []
  for row in rows {
    out.push(row_json(row))
  }
  out
}

///|
/// One row as a JSON object, or `None` when the predicate matched nothing.
pub fn[D : @moondb.Driver] Database::select_one(
  self : Database[D],
  info : @exec.ResolveInfo,
  table : String,
  columns : Array[String],
  predicate~ : String,
  params~ : Array[@moondb.Value] = [],
  keep~ : Array[String] = [],
) -> Json? raise @exec.FieldError {
  let rows = self.select(
    info,
    table,
    columns,
    predicate~,
    params~,
    limit=1,
    keep~,
  )
  if rows.is_empty() {
    None
  } else {
    Some(rows[0])
  }
}

///|
/// The rows whose `key_column` is one of `keys`, in one statement, keyed by that
/// column — the load half of [`Batch`].
///
/// The key column is always fetched, even when the document does not ask for it,
/// because it is how a row finds the item it belongs to.
pub fn[D : @moondb.Driver] Database::rows_by_key(
  self : Database[D],
  table : String,
  columns : Array[String],
  key_column : String,
  keys : Array[String],
) -> Map[String, Json] raise @exec.FieldError {
  let out : Map[String, Json] = Map([])
  if keys.is_empty() {
    return out
  }
  let cols = columns.copy()
  if !cols.contains(key_column) {
    cols.insert(0, key_column)
  }
  let marks : Array[String] = []
  for _ in keys {
    marks.push("?")
  }
  let sql = "SELECT " +
    join(cols, ", ") +
    " FROM " +
    table +
    " WHERE " +
    key_column +
    " IN (" +
    join(marks, ", ") +
    ")"
  let params : Array[@moondb.Value] = []
  for key in keys {
    params.push(@moondb.Text(key))
  }
  for row in self.rows(sql, params~) {
    match row.by_name(key_column) {
      Some(value) =>
        match key_of(value) {
          Some(key) => out[key] = row_json(row)
          None => ()
        }
      None => ()
    }
  }
  out
}

///|
/// The text of a value used as a key. A key column is an id, so it is text,
/// an integer, or a uuid; anything else is not a key and the row is skipped
/// rather than filed under a made-up name.
fn key_of(value : @moondb.Value) -> String? {
  match value {
    Text(s) => Some(s)
    Int(i) => Some(i.to_string())
    Int64(i) => Some(i.to_string())
    Null => None
    _ => None
  }
}
