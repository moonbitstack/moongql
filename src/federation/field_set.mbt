// The `fields:` argument of `@requires` and `@provides`: a selection set written
// as a string, read back so that a subgraph can be told its paths do not exist.

///|
/// What a field set that is not one raises inside this reader; `read_field_set`
/// turns it into `None`, since a bad set is reported by whoever asked.
priv suberror BadFieldSet

///|
/// One name in a federation field set, with the sub-selection written under it:
/// `"weight"` is one entry with no children, `"author { name }"` is `author` with
/// `name` inside.
priv struct FieldSetEntry {
  name : String
  children : Array[FieldSetEntry]
}

///|
/// Read a field set — names, each with an optional `{ ... }` sub-selection — or
/// `None` when the text is not one (an unclosed brace, a punctuation mark where a
/// name belongs, an empty set).
fn read_field_set(text : StringView) -> Array[FieldSetEntry]? {
  let chars = []
  for c in text {
    chars.push(c)
  }
  let (entries, at) = read_field_set_entries(chars, 0) catch {
    BadFieldSet => return None
  }
  if entries.is_empty() || at != chars.length() {
    return None
  }
  Some(entries)
}

///|
/// The entries at the current depth, and the index just past them. A `}` ends the
/// list; whitespace and commas separate names, and a `{` after a name opens its
/// sub-selection.
fn read_field_set_entries(
  chars : Array[Char],
  start : Int32,
) -> (Array[FieldSetEntry], Int32) raise BadFieldSet {
  let entries : Array[FieldSetEntry] = []
  let mut at = start
  while at < chars.length() {
    let c = chars[at]
    if c == '}' || c == '{' {
      break
    }
    if is_set_space(c) {
      at = at + 1
      continue
    }
    if !is_set_name_char(c) {
      raise BadFieldSet
    }
    let begin = at
    while at < chars.length() && is_set_name_char(chars[at]) {
      at = at + 1
    }
    let name = chars_to_string(chars, begin, at)
    // A `{` after the name opens its sub-selection; anything else ends the entry.
    let mut probe = at
    while probe < chars.length() && is_set_space(chars[probe]) {
      probe = probe + 1
    }
    let children = if probe < chars.length() && chars[probe] == '{' {
      let (inner, next) = read_field_set_entries(chars, probe + 1)
      // The `}` that closes this sub-selection is the one the inner list stopped at.
      if next >= chars.length() || chars[next] != '}' {
        raise BadFieldSet
      }
      at = next + 1
      inner
    } else {
      []
    }
    entries.push({ name, children, })
  }
  (entries, at)
}

///|
/// Whether `c` separates field-set names.
fn is_set_space(c : Char) -> Bool {
  c == ' ' || c == '\n' || c == '\r' || c == '\t' || c == ','
}

///|
/// Whether `c` may appear in a field-set name.
fn is_set_name_char(c : Char) -> Bool {
  c == '_' ||
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9')
}

///|
/// The characters `[start, end)` of `chars` as a string.
fn chars_to_string(chars : Array[Char], start : Int32, end : Int32) -> String {
  let out = StringBuilder()
  for i in start..<end {
    out.write_char(chars[i])
  }
  out.to_string()
}
