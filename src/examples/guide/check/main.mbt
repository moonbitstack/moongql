// Runs every document the guide shows against all three ways of writing the same
// server, and prints each answer once — after checking that all three answered
// the same thing. `scripts/gen_guide.py` puts this output on the page.

///|
/// One server, in the shape all three packages expose.
type Server = (@moongql.Schema, @moongql.Resolvers, @moongql.Subscribers)

///|
/// The documents the guide walks through, in the order it walks them.
let documents : Array[String] = [
  (
    #|{ author(id: "1") { name books { title } } }
  ),
  (
    #|{ books { title } }
  ),
  (
    #|mutation { addBook(input: { title: "Dune", authorId: "2" }) { id title } }
  ),
  (
    #|mutation { addBook(input: { title: "", authorId: "2" }) { id } }
  ),
  (
    #|subscription { bookAdded { title } }
  ),
]

///|
/// A `[_Any!]!` variable holding one Book representation.
fn representations() -> Map[String, Json] {
  let reps : Array[Json] = [{ "__typename": Json("Book"), "id": Json("b2") }]
  Map([("reps", Json(reps))])
}

///|
/// The entity a representation stands for, one line per fact every subgraph must
/// agree on.
let entity_query =
  #|query ($reps: [_Any!]!) {
  #|  _entities(representations: $reps) { ... on Book { id title } }
  #|}

///|
/// Every answer the server gives, one string per document, plus the federated
/// entity last.
fn answers(
  build : () -> Server,
  federated : (@moongql.Schema, @moongql.Resolvers) -> Unit,
) -> Array[String] {
  let (schema, resolvers, subscribers) = build()
  let out : Array[String] = []
  for doc in documents {
    if doc.has_prefix("subscription") {
      let events = @moongql.execute_subscription(
        schema, resolvers, subscribers, doc,
      )
      out.push(events.map(e => e.stringify()).join(" "))
    } else {
      out.push(@moongql.execute(schema, resolvers, doc).stringify())
    }
  }
  // A second server, this time joined to a gateway, so the entities section is
  // compared as well.
  let (fed_schema, fed_resolvers, _) = build()
  federated(fed_schema, fed_resolvers)
  out.push(
    @moongql.execute(
      fed_schema,
      fed_resolvers,
      entity_query,
      variables=representations(),
    ).stringify(),
  )
  out
}

///|
fn main {
  let ways = [
    ("annotations", answers(@annotations.server, @annotations.federated)),
    ("functions", answers(@functions.server, @functions.federated)),
    ("classes", answers(@classes.server, @classes.federated)),
  ]
  let mut differs = false
  for i, doc in documents {
    let first = ways[0].1[i]
    for way in ways {
      if way.1[i] != first {
        differs = true
        println("\{doc} -> \{way.0} differs: \{way.1[i]}")
      }
    }
    println("\{doc} -> \{first}")
  }
  let entity = ways[0].1[documents.length()]
  for way in ways {
    if way.1[documents.length()] != entity {
      differs = true
      println("_entities -> \{way.0} differs: \{way.1[documents.length()]}")
    }
  }
  println("_entities -> \{entity}")
  if differs {
    println("DIFFERS")
  } else {
    println("the three ways agree")
  }
}
