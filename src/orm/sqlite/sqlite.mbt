// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A pooled database on a SQLite file, or on `:memory:` for a test.
///
/// `max_size` is one by default, and that default is not timidity: every
/// connection to `:memory:` is a database of its own, so a pool larger than one
/// would give a resolver a table it cannot see. Raise it only for a file, and only
/// where several connections to the same file are what you want.
pub fn open(
  path : String,
  max_size~ : Int32 = 1,
) -> @orm.Database[@moonsqlite.SqliteDriver] raise @exec.FieldError {
  @orm.Database::new(() => @moonsqlite.SqliteDriver::open(path), max_size~) catch {
    e => raise @exec.FieldError(e.to_string())
  }
}

///|
/// Run a script — DDL, seed data — as one unit of work, so a schema is created
/// whole or not at all.
pub fn script(
  db : @orm.Database[@moonsqlite.SqliteDriver],
  sql : String,
) -> Unit raise @exec.FieldError {
  db.with_connection(conn => conn.exec_script(sql))
}
