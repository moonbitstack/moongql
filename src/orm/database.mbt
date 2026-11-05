// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A database behind a connection pool: what a resolver asks for a row, rather
/// than the connection it would otherwise open itself.
///
/// A pool is the first half of the cost of a query — opening a connection is a
/// handshake — and a checked-out connection is the unit of isolation: each query
/// takes one, uses it, and gives it back, so two fields resolving at the same
/// time never share a session, and neither sees the other's uncommitted work.
///
/// The second half is the statement itself: [`Database::select`] builds the
/// column list out of the document's own selection, because a resolver is the
/// only place that knows what the client asked for, and [`Database::batch`]
/// answers a whole list's worth of lookups in one statement instead of one per
/// item.
pub struct Database[D] {
  pool : @pool.Pool[D]
  dialect : @query.Dialect
  // Statements this database issued. A test asserts on it — "this document costs
  // two statements" — and a service exports it as a metric. An `Int32` rather
  // than an `Int` so the interface is the same width on every backend.
  mut issued : Int32
}

///|
/// Open a pooled database. `open` is called only when the pool has no idle
/// connection and is still below `max_size`, so it may open a file, perform a
/// handshake, or return a mock in a test.
///
/// `max_size` is the ceiling on connections open at once, which is also the
/// ceiling on queries in flight: a resolver waits on the pool rather than on the
/// database. `pre_ping` probes an idle connection before handing it out, so a
/// connection the server dropped is replaced instead of failing a field.
pub fn[D] Database::new(
  open : () -> D raise @moondb.DbError,
  max_size~ : Int32 = 8,
  pre_ping~ : Bool = true,
  dialect~ : @query.Dialect = @query.Sqlite,
) -> Database[D] raise @moondb.DbError {
  let pool : @pool.Pool[D] = @pool.Pool::new(open, max_size~, pre_ping~)
  { pool, dialect, issued: 0, }
}

///|
/// The statements this database has issued, over its whole life.
pub fn[D] Database::statements(self : Database[D]) -> Int32 {
  self.issued
}

///|
/// Forget the statements so far, so a caller can measure one request.
pub fn[D] Database::reset_statements(self : Database[D]) -> Unit {
  self.issued = 0
}

///|
/// How many connections are open, and how many of them are checked out right now.
/// A field that forgot to give its connection back shows up in `in_use`.
pub fn[D] Database::connections(self : Database[D]) -> (Int32, Int32) {
  (self.pool.open_count(), self.pool.in_use_count())
}

///|
/// Run one unit of work on a connection of its own, and give the connection back
/// whichever way it ends: a resolver that raises still returns what it borrowed.
///
/// The unit of work is a `Session`, so it can read rows, write them, and hold a
/// transaction across several statements — the connection is the boundary, not
/// the statement. A database failure becomes a `FieldError`, which is the error a
/// field reports at its own path.
pub fn[D : @moondb.Driver, R] Database::session(
  self : Database[D],
  f : (@moonorm.Session) -> R raise,
) -> R raise @exec.FieldError {
  let conn = self.pool.acquire() catch {
    e => raise @exec.FieldError(e.to_string())
  }
  let sess = @moonorm.Session::new(conn, dialect=self.dialect)
  let outcome : Result[R, Error] = Ok(f(sess)) catch { e => Err(e) }
  self.pool.release(conn)
  match outcome {
    Ok(value) => value
    Err(e) => raise @exec.FieldError(e.to_string())
  }
}

///|
/// Run `f` with one connection checked out, for what only the driver can do —
/// creating a schema whole, a prepared statement, a statement a `Session` does not
/// model. The connection goes back whichever way `f` ends.
pub fn[D : @moondb.Driver, R] Database::with_connection(
  self : Database[D],
  f : (D) -> R raise,
) -> R raise @exec.FieldError {
  let conn = self.pool.acquire() catch {
    e => raise @exec.FieldError(e.to_string())
  }
  let outcome : Result[R, Error] = Ok(f(conn)) catch { e => Err(e) }
  self.pool.release(conn)
  match outcome {
    Ok(value) => value
    Err(e) => raise @exec.FieldError(e.to_string())
  }
}

///|
/// Run `sql` on a connection of its own and answer its rows.
pub fn[D : @moondb.Driver] Database::rows(
  self : Database[D],
  sql : String,
  params~ : Array[@moondb.Value] = [],
) -> Array[@moondb.Row] raise @exec.FieldError {
  self.session(sess => {
    self.issued = self.issued + 1
    sess.query(sql, params)
  })
}

///|
/// Run `sql` on a connection of its own and answer what it changed.
pub fn[D : @moondb.Driver] Database::execute(
  self : Database[D],
  sql : String,
  params~ : Array[@moondb.Value] = [],
) -> @moondb.ExecResult raise @exec.FieldError {
  self.session(sess => {
    self.issued = self.issued + 1
    sess.execute(sql, params)
  })
}
