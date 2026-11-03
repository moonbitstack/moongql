///|
/// Print a type-system document's SDL, as this library reads it and writes it
/// back: `to_sdl` of `of_sdl` of the file. Reading and printing are inverses, so
/// the output is the document normalised — the same schema written the way this
/// printer writes it — and a second run changes nothing.
///
///     moon run src/cmd/sdl -- schema.graphql
fn main {
  let args = @env.args()
  guard args.length() >= 2 else {
    println("usage: moon run src/cmd/sdl -- <schema.graphql>")
    return
  }
  let path = args[1]
  let text = @fs.read_file_to_string(path) catch {
    _ => {
      println("\{path}: cannot be read")
      return
    }
  }
  let schema = @schema.Schema::of_sdl(text) catch {
    e => {
      println("\{path}: \{e}")
      return
    }
  }
  println(schema.to_sdl())
}
