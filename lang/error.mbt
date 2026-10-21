///|
/// A GraphQL error entry: a message, an optional response path (string field
/// keys and integer list indices), and optional source locations.
pub(all) struct GqlError {
  message : String
  path : Array[Json]
  locations : Array[Pos]
  extensions : Map[String, Json]
}

///|
/// Build an error carrying only a message, for the request-level failures that
/// cannot be pinned to a point in the document (an empty document, an unknown
/// operation name).
pub fn GqlError::msg(message : String) -> GqlError {
  { message, path: [], locations: [], extensions: Map([]), }
}

///|
/// Build an error carrying a message and the position of the node it is about.
/// §7.1.2 requires `locations` on every error that can name one.
pub fn GqlError::at(message : String, pos : Pos) -> GqlError {
  { message, path: [], locations: [pos], extensions: Map([]), }
}

///|
/// Serialise an error to the GraphQL JSON error shape, omitting an empty path
/// or locations list.
pub fn GqlError::to_json(self : GqlError) -> Json {
  let entries : Array[(String, Json)] = [("message", Json(self.message))]
  if self.locations.length() > 0 {
    let locs : Array[Json] = []
    for p in self.locations {
      locs.push(jobj([("line", Json(p.line)), ("column", Json(p.col))]))
    }
    entries.push(("locations", Json(locs)))
  }
  if self.path.length() > 0 {
    entries.push(("path", Json(self.path)))
  }
  // A resolver-supplied `extensions` map (← GraphQL spec §7.1.2), emitted only
  // when non-empty.
  if !self.extensions.is_empty() {
    entries.push(("extensions", Json(self.extensions)))
  }
  jobj(entries)
}
