// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A hook into field resolution, applied to every field: `on_field` before the
/// resolver runs (it may refuse, and the refusal is a field error at that
/// field's path), `on_result` after the value is completed (it may replace it).
///
/// Tracing, metrics, a per-field cache and Relay's global-id rewriting are all
/// extensions, so the engine stays free of whichever ones a program happens to
/// want.
pub(open) trait Extension {
  fn on_field(Self, ResolveInfo) -> Unit raise FieldError
  fn on_result(Self, ResolveInfo, Json) -> Json
}

///|
/// A limit on how much work one request may start. A deferral past `max_defer`
/// or a stream past `max_stream` is a field error rather than an unbounded run.
pub(all) struct Limits {
  max_concurrency : Int32
  max_defer : Int32
  max_stream : Int32
}

///|
/// The preset: siblings resolved concurrently but not without bound, and enough
/// room for the deferrals and streamed chunks a real document asks for.
pub let limits : Limits = {
  max_concurrency: 32,
  max_defer: 64,
  max_stream: 1024,
}
