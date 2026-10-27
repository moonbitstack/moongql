///|
/// The lexer and parser surface underneath `execute`. `tokenize` turns query text
/// into a `Token` stream; `parse` builds a `Document`; `Document::to_query` prints
/// an AST back to normalized text. Walking the parsed tree reaches a `TypeRef` and
/// the argument `Value`s, each of which renders itself with `to_query`. A malformed
/// document raises `GqlSyntaxError` carrying its 1-based line and column.
///
///     moon run src/examples/16-parsing
#coverage.skip
fn main {
  let query = "query GetUser($id: ID! = \"7\") { user(id: $id) { name } }"
  let names : Array[String] = []
  for t in (@moongql.tokenize(query) catch { _ => [] }) {
    if t.kind == Name {
      names.push(t.value)
    }
  }
  println("name tokens: " + names.join(", "))
  let doc = @moongql.parse(query) catch { _ => return }
  println("round-trip: " + doc.to_query())
  match doc.definitions[0] {
    OperationDef(op) => {
      let vd = op.variable_definitions[0]
      println("var type: " + vd.typ.to_query())
      match vd.default_value {
        Some(v) => println("var default: " + v.to_query())
        None => ()
      }
      match op.selection_set[0] {
        FieldSel(f) => println("arg value: " + f.arguments[0].value.to_query())
        _ => ()
      }
    }
    _ => ()
  }
  let _ = @moongql.parse("{ oops") catch {
    @lang.GqlSyntaxError(msg, line, col) => {
      println("syntax error @ \{line}:\{col}: " + msg)
      return
    }
  }
}
