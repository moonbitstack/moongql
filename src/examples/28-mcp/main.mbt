///|
/// A schema handed to an MCP client as tools.
///
/// The library side is one call: `Mcp::of` takes the schema and the resolvers,
/// `Mcp::server` wraps them in an MCP server whose tools are the schema's root
/// fields. This program drives that server over its message seam — the same
/// messages a Streamable HTTP or stdio transport carries — so the output is the
/// JSON-RPC a client would see.
///
/// Run it with `moon run src/examples/28-mcp`.

///|
/// The schema: a shop with one query and one mutation.
fn shop() -> (@schema.Schema, @exec.Resolvers) {
  let s = @schema.Schema::new()
  let q = s.object("Query")
  q.field_args(
    "book",
    [("id", NonNull(Scalar("ID")))],
    Named("Book"),
    description="One book, by id.",
  )
  q.field(
    "books",
    NonNull(ListOf(NonNull(Named("Book")))),
    description="Everything in stock.",
  )
  let b = s.object("Book")
  b.field("id", NonNull(Scalar("ID")))
  b.field("title", NonNull(Scalar("String")))
  b.field("inStock", NonNull(Scalar("Boolean")))
  let m = s.object("Mutation")
  m.field_args(
    "restock",
    [("id", NonNull(Scalar("ID")))],
    Named("Book"),
    description="Put a book back on the shelf.",
  )
  s.set_mutation("Mutation")
  let r = @exec.Resolvers::new()
  r.field("Query", "book", fn(info) -> Json raise @exec.FieldError {
    let id : String = info.read("id")
    Json(book(id))
  })
  r.field("Query", "books", fn(_info) { Json([book("1"), book("2")]) })
  r.field("Mutation", "restock", fn(info) -> Json raise @exec.FieldError {
    let id : String = info.read("id")
    Json(book(id))
  })
  (s, r)
}

///|
/// One book.
fn book(id : String) -> Json {
  let m : Map[String, Json] = Map([])
  m["id"] = Json(id)
  m["title"] = Json("Book " + id)
  m["inStock"] = Json(true)
  Json(m)
}

///|
/// Print one JSON-RPC exchange: the message, and the reply it drew.
async fn exchange(
  server : @moonmcp.Server,
  label : String,
  message : Json,
) -> Unit {
  println(label)
  println("  → " + message.stringify())
  match server.handle(message) {
    Some(reply) => println("  ← " + reply.stringify())
    None => println("  ← (no reply)")
  }
}

///|
/// Ask one JSON-RPC message, numbered so the replies are distinguishable.
fn message(id : Int32, op : String, params : Json) -> Json {
  {
    "jsonrpc": Json("2.0"),
    "id": Json(id),
    "method": Json(op),
    "params": params,
  }
}

///|
/// Run the example.
async fn main {
  let (s, r) = shop()
  // Read-only by default: the mutation is not offered, and `graphql_query`
  // refuses to write. `mutations: true` in the exposure opens both.
  let server = @moonmcp.Server::new(
    "shop",
    version="1.0.0",
    instructions=s.to_sdl(),
  )
  @mcp.Mcp::of(schema=s, resolvers=r).attach(server)
  exchange(
    server,
    "the client asks what the server offers",
    message(1, "tools/list", {}),
  )
  exchange(
    server,
    "and calls one tool",
    message(2, "tools/call", {
      "name": Json("book"),
      "arguments": Json({ "id": Json("1") }),
    }),
  )
  exchange(
    server,
    "a mutation is not a tool here",
    message(3, "tools/call", {
      "name": Json("graphql_query"),
      "arguments": Json({
        "query": Json("mutation { restock(id: \"1\") { title } }"),
      }),
    }),
  )
}
