///|
/// Build a JSON object from ordered `(key, value)` entries, preserving order.
fn jobj(entries : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for e in entries {
    m[e.0] = e.1
  }
  Json(m)
}
