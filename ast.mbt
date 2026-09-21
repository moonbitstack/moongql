///|
/// The GraphQL executable-document AST, transliterated from the node types
/// `graphql-core` (strawberry's parser) produces: a `Document` is a list of
/// executable `Definition`s (operations and named fragments). These nodes are
/// pure data — the parser fills them and `to_query` prints them back to a
/// canonical GraphQL string, so a parse→print round-trip is testable.

///|
/// The 1-based line and column of a node's first token. Every node an error can
/// point back at carries one, so a validation or field error can answer with the
/// `locations` entry the spec requires (§7.1.2).
pub(all) struct Pos {
  line : Int
  col : Int
} derive(Eq)

///|
/// A parsed GraphQL document: an ordered list of executable definitions.
pub(all) struct Document {
  definitions : Array[Definition]
}

///|
/// A top-level executable definition: an operation or a named fragment.
pub(all) enum Definition {
  OperationDef(OperationDefinition)
  FragmentDef(FragmentDefinition)
}

///|
/// Which kind of operation a definition describes.
pub(all) enum OperationType {
  Query
  Mutation
  Subscription
} derive(Eq)

///|
/// An operation: its type, an optional name, variable definitions, directives
/// and a selection set. The anonymous `{ ... }` query shorthand parses to an
/// `OperationDefinition` with `operation = Query` and `name = None`.
pub(all) struct OperationDefinition {
  operation : OperationType
  name : String?
  variable_definitions : Array[VariableDefinition]
  directives : Array[Directive]
  selection_set : Array[Selection]
  pos : Pos
}

///|
/// A variable declaration in an operation's `(...)` list: `$name: Type = default`
/// with optional default value and directives.
pub(all) struct VariableDefinition {
  variable : String
  typ : TypeRef
  default_value : Value?
  directives : Array[Directive]
  pos : Pos
}

///|
/// A type reference as it appears in the query grammar: a named type, a list
/// wrapper `[T]`, or a non-null wrapper `T!`. Distinct from the schema builder's
/// `GqlType` (which carries a `Scalar` sugar the parser never sees).
pub(all) enum TypeRef {
  NamedType(String)
  ListType(TypeRef)
  NonNullType(TypeRef)
} derive(Eq)

///|
/// A named fragment definition: `fragment Name on Type @dir { selection }`.
pub(all) struct FragmentDefinition {
  name : String
  type_condition : String
  directives : Array[Directive]
  selection_set : Array[Selection]
  pos : Pos
}

///|
/// One entry in a selection set: a field, a `...Name` fragment spread, or an
/// inline `... on Type { ... }` fragment.
pub(all) enum Selection {
  FieldSel(QueryField)
  FragmentSpreadSel(String, Array[Directive], Pos)
  InlineFragmentSel(String?, Array[Directive], Array[Selection], Pos)
}

///|
/// A queried field: an optional alias, the field name, arguments, directives and
/// an optional nested selection set. Prints as `alias: name(args) @dir { ... }`.
pub(all) struct QueryField {
  alias_ : String?
  name : String
  arguments : Array[Argument]
  directives : Array[Directive]
  selection_set : Array[Selection]
  pos : Pos
}

///|
/// A `name: value` argument on a field or directive.
pub(all) struct Argument {
  name : String
  value : Value
  pos : Pos
}

///|
/// A directive application: `@name(args)`.
pub(all) struct Directive {
  name : String
  arguments : Array[Argument]
  pos : Pos
}

///|
/// A GraphQL input value. Numeric and string literals keep their source text
/// (matching `graphql-core`, whose `IntValueNode.value` etc. are strings), so no
/// lossy numeric round-trip is baked into the AST. `StringValue`'s second field
/// is the block-string flag.
pub(all) enum Value {
  Variable(String)
  IntValue(String)
  FloatValue(String)
  StringValue(String, Bool)
  BooleanValue(Bool)
  NullValue
  EnumValue(String)
  ListValue(Array[Value])
  ObjectValue(Array[(String, Value)])
}

///|
/// A string of `2 * n` spaces, used as one indentation level by the printer.
fn indent_pad(n : Int) -> String {
  let sb = StringBuilder()
  for _ in 0..<(n * 2) {
    sb.write_char(' ')
  }
  sb.to_string()
}

///|
/// Escape a string's contents for printing inside GraphQL double quotes.
fn escape_string(s : String) -> String {
  let sb = StringBuilder()
  for c in s {
    match c {
      '"' => sb.write_string("\\\"")
      '\\' => sb.write_string("\\\\")
      '\n' => sb.write_string("\\n")
      '\r' => sb.write_string("\\r")
      '\t' => sb.write_string("\\t")
      _ => sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
/// Print a value back to GraphQL literal syntax.
pub fn Value::to_query(self : Value) -> String {
  match self {
    Variable(n) => "$" + n
    IntValue(s) => s
    FloatValue(s) => s
    StringValue(s, block) =>
      if block {
        "\"\"\"" + s + "\"\"\""
      } else {
        "\"" + escape_string(s) + "\""
      }
    BooleanValue(b) => if b { "true" } else { "false" }
    NullValue => "null"
    EnumValue(n) => n
    ListValue(items) => {
      let sb = StringBuilder()
      sb.write_char('[')
      for i, v in items {
        if i > 0 {
          sb.write_string(", ")
        }
        sb.write_string(v.to_query())
      }
      sb.write_char(']')
      sb.to_string()
    }
    ObjectValue(fields) => {
      let sb = StringBuilder()
      sb.write_char('{')
      for i, kv in fields {
        if i > 0 {
          sb.write_string(", ")
        }
        let (k, v) = kv
        sb.write_string(k)
        sb.write_string(": ")
        sb.write_string(v.to_query())
      }
      sb.write_char('}')
      sb.to_string()
    }
  }
}

///|
/// Print a type reference back to GraphQL notation (`[Int!]!`).
pub fn TypeRef::to_query(self : TypeRef) -> String {
  match self {
    NamedType(n) => n
    ListType(inner) => "[" + inner.to_query() + "]"
    NonNullType(inner) => inner.to_query() + "!"
  }
}

///|
/// Print a directive: `@name(a: 1, b: 2)`.
fn directive_sdl(d : Directive) -> String {
  let sb = StringBuilder()
  sb.write_char('@')
  sb.write_string(d.name)
  sb.write_string(arguments_sdl(d.arguments))
  sb.to_string()
}

///|
/// Print a directive list, each prefixed by a space, or the empty string.
fn directives_sdl(ds : Array[Directive]) -> String {
  let sb = StringBuilder()
  for d in ds {
    sb.write_char(' ')
    sb.write_string(directive_sdl(d))
  }
  sb.to_string()
}

///|
/// Print an argument list `(a: 1, b: 2)`, or the empty string when there are none.
fn arguments_sdl(args : Array[Argument]) -> String {
  if args.length() == 0 {
    return ""
  }
  let sb = StringBuilder()
  sb.write_char('(')
  for i, a in args {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(a.name)
    sb.write_string(": ")
    sb.write_string(a.value.to_query())
  }
  sb.write_char(')')
  sb.to_string()
}

///|
/// Print a selection set as an indented `{ ... }` block at the given depth.
fn selection_set_sdl(sels : Array[Selection], depth : Int) -> String {
  let sb = StringBuilder()
  sb.write_string("{\n")
  let pad = indent_pad(depth + 1)
  for s in sels {
    sb.write_string(pad)
    sb.write_string(selection_sdl(s, depth + 1))
    sb.write_char('\n')
  }
  sb.write_string(indent_pad(depth))
  sb.write_char('}')
  sb.to_string()
}

///|
/// Print one selection (field / fragment spread / inline fragment) at `depth`.
fn selection_sdl(sel : Selection, depth : Int) -> String {
  match sel {
    FieldSel(f) => {
      let sb = StringBuilder()
      match f.alias_ {
        Some(a) => {
          sb.write_string(a)
          sb.write_string(": ")
        }
        None => ()
      }
      sb.write_string(f.name)
      sb.write_string(arguments_sdl(f.arguments))
      sb.write_string(directives_sdl(f.directives))
      if f.selection_set.length() > 0 {
        sb.write_char(' ')
        sb.write_string(selection_set_sdl(f.selection_set, depth))
      }
      sb.to_string()
    }
    FragmentSpreadSel(name, ds, _) => "..." + name + directives_sdl(ds)
    InlineFragmentSel(cond, ds, sels, _) => {
      let sb = StringBuilder()
      sb.write_string("...")
      match cond {
        Some(c) => {
          sb.write_string(" on ")
          sb.write_string(c)
        }
        None => ()
      }
      sb.write_string(directives_sdl(ds))
      sb.write_char(' ')
      sb.write_string(selection_set_sdl(sels, depth))
      sb.to_string()
    }
  }
}

///|
/// The keyword for an operation type.
fn operation_keyword(op : OperationType) -> String {
  match op {
    Query => "query"
    Mutation => "mutation"
    Subscription => "subscription"
  }
}

///|
/// Print an operation definition, using the `{ ... }` shorthand only for an
/// anonymous query with no variables or directives (matching `graphql-core`).
fn operation_sdl(op : OperationDefinition) -> String {
  let shorthand = op.operation is Query &&
    op.name is None &&
    op.variable_definitions.length() == 0 &&
    op.directives.length() == 0
  if shorthand {
    return selection_set_sdl(op.selection_set, 0)
  }
  let sb = StringBuilder()
  sb.write_string(operation_keyword(op.operation))
  match op.name {
    Some(n) => {
      sb.write_char(' ')
      sb.write_string(n)
    }
    None => ()
  }
  if op.variable_definitions.length() > 0 {
    sb.write_char('(')
    for i, vd in op.variable_definitions {
      if i > 0 {
        sb.write_string(", ")
      }
      sb.write_char('$')
      sb.write_string(vd.variable)
      sb.write_string(": ")
      sb.write_string(vd.typ.to_query())
      match vd.default_value {
        Some(v) => {
          sb.write_string(" = ")
          sb.write_string(v.to_query())
        }
        None => ()
      }
      sb.write_string(directives_sdl(vd.directives))
    }
    sb.write_char(')')
  }
  sb.write_string(directives_sdl(op.directives))
  sb.write_char(' ')
  sb.write_string(selection_set_sdl(op.selection_set, 0))
  sb.to_string()
}

///|
/// Print a fragment definition: `fragment Name on Type @dir { ... }`.
fn fragment_sdl(fr : FragmentDefinition) -> String {
  let sb = StringBuilder()
  sb.write_string("fragment ")
  sb.write_string(fr.name)
  sb.write_string(" on ")
  sb.write_string(fr.type_condition)
  sb.write_string(directives_sdl(fr.directives))
  sb.write_char(' ')
  sb.write_string(selection_set_sdl(fr.selection_set, 0))
  sb.to_string()
}

///|
/// Print a whole document back to a canonical GraphQL string: each definition,
/// separated by a blank line. Parsing this output yields an equivalent AST.
pub fn Document::to_query(self : Document) -> String {
  let sb = StringBuilder()
  for i, def in self.definitions {
    if i > 0 {
      sb.write_string("\n\n")
    }
    match def {
      OperationDef(op) => sb.write_string(operation_sdl(op))
      FragmentDef(fr) => sb.write_string(fragment_sdl(fr))
    }
  }
  sb.to_string()
}

///|
pub extend OperationType with Eq::{not_equal, equal}

///|
pub extend Pos with Eq::{not_equal, equal}

///|
pub extend TypeRef with Eq::{not_equal, equal}
