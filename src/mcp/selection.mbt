// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The selection a tool sends for a field: the field's own type decides it, so an
/// agent asks for `user` and receives the person's fields rather than a document
/// it had to write.
///
/// A leaf stops here. An object selects the fields that are themselves leaves, and
/// — while `Exposure.depth` lasts — the leaf fields of the objects it returns.
/// Fields that cannot be selected without arguments are left out: a tool call is
/// not the place to invent values for them. Deprecated fields are left out as
/// well, since the description of the tool is what an agent reads.

///|
/// The selection for one field's type, or the empty string when the type is a
/// leaf and needs none.
fn Mcp::selection(self : Mcp, t : @schema.GqlType, depth : Int32) -> String {
  let base = base_name(t)
  if self.is_leaf(base) {
    return ""
  }
  match self.schema.union_by_name(base) {
    Some(u) => self.union_selection(u, depth)
    None =>
      match self.schema.type_by_name(base) {
        Some(obj) => self.object_selection(obj, depth)
        None => ""
      }
  }
}

///|
/// The named type a reference points at.
fn base_name(t : @schema.GqlType) -> String {
  match t {
    NonNull(inner) => base_name(inner)
    ListOf(inner) => base_name(inner)
    Scalar(name) => name
    Named(name) => name
  }
}

///|
/// Whether a named type is a leaf: a built-in scalar, a custom scalar, or an enum.
fn Mcp::is_leaf(self : Mcp, name : String) -> Bool {
  @schema.is_builtin_scalar(name) ||
  self.schema.scalar_by_name(name) is Some(_) ||
  self.schema.enum_by_name(name) is Some(_)
}

///|
/// The fields an object or interface selects at this depth: its leaves, plus one
/// more level for the composites that are still within reach.
fn Mcp::object_selection(
  self : Mcp,
  obj : @schema.ObjectType,
  depth : Int32,
) -> String {
  let chosen : Array[String] = ["__typename"]
  let mut count = 0
  for f in obj.fields {
    if count >= self.exposure.width {
      break
    }
    if f.deprecation_reason is Some(_) {
      continue
    }
    if needs_arguments(f) {
      continue
    }
    let base = base_name(f.typ)
    if self.is_leaf(base) {
      chosen.push(f.name)
      count = count + 1
    } else if depth > 1 {
      let inner = self.selection(f.typ, depth - 1)
      if inner != "" {
        chosen.push(f.name + " " + inner)
        count = count + 1
      }
    }
  }
  "{ " + chosen.join(" ") + " }"
}

///|
/// A union selects its type name and, while depth lasts, the leaf fields of each
/// member through an inline fragment — the only way a union can be read at all.
fn Mcp::union_selection(
  self : Mcp,
  u : @schema.UnionType,
  depth : Int32,
) -> String {
  let chosen : Array[String] = ["__typename"]
  if depth > 1 {
    for m in u.members {
      match self.schema.type_by_name(m) {
        Some(obj) =>
          chosen.push(
            "... on " + m + " " + self.object_selection(obj, depth - 1),
          )
        None => ()
      }
    }
  }
  "{ " + chosen.join(" ") + " }"
}

///|
/// Whether a field cannot be selected without a value for one of its arguments.
fn needs_arguments(f : @schema.Field) -> Bool {
  for a in f.args {
    if a.1 is NonNull(_) && f.arg_defaults.get(a.0) is None {
      return true
    }
  }
  false
}

///|
/// A JSON object from ordered entries.
fn jobj(entries : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for e in entries {
    m[e.0] = e.1
  }
  Json(m)
}

///|
/// A JSON object with one more entry, or the value unchanged when it is not an
/// object.
fn with_entry(value : Json, key : String, entry : Json) -> Json {
  match value {
    Object(m) => {
      let copy : Map[String, Json] = Map([])
      for k, v in m {
        copy[k] = v
      }
      copy[key] = entry
      Json(copy)
    }
    _ => value
  }
}
