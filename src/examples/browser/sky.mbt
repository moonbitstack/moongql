///|
/// The schema the showcase page runs: a small star catalogue, small enough that
/// the whole pipeline — parse, validate, execute — answers while the reader is
/// still looking at the editor, and deep enough to show a computed field.
///
/// This package exists for the documentation site only: it links the library
/// into JavaScript and exposes two names the page calls. It is not part of the
/// library's public surface.

///|
fn catalogue() -> Json {
  let sirius : Json = {
    "id": "sirius",
    "name": "Sirius",
    "magnitude": -1.46,
    "constellation": "Canis Major",
  }
  let vega : Json = {
    "id": "vega",
    "name": "Vega",
    "magnitude": 0.03,
    "constellation": "Lyra",
  }
  let polaris : Json = {
    "id": "polaris",
    "name": "Polaris",
    "magnitude": 1.98,
    "constellation": "Ursa Minor",
  }
  {
    "name": "The northern sky",
    "stars": [sirius, vega, polaris],
    "brightest": sirius,
  }
}

///|
/// The demo schema: a query root that hands out the catalogue, plus a field the
/// resolver computes from the parent instead of reading it off the object.
fn demo() -> (@moongql.Schema, @moongql.Resolvers) {
  let schema = @moongql.Schema::new()
  let query = schema.object("Query")
  query.field("sky", NonNull(Named("Sky")))
  // A named tuple gives the argument's type, which is what lets `NonNull` and
  // `Scalar` resolve without naming the package they live in.
  let by_id : (String, @moongql.GqlType) = ("id", NonNull(Scalar("ID")))
  query.field_args("star", [by_id], Named("Star"))

  let sky = schema.object("Sky")
  sky.field("name", NonNull(Scalar("String")))
  sky.field("stars", NonNull(ListOf(NonNull(Named("Star")))))
  sky.field("brightest", Named("Star"))

  let star = schema.object("Star")
  star.field("id", NonNull(Scalar("ID")))
  star.field("name", NonNull(Scalar("String")))
  star.field("magnitude", NonNull(Scalar("Float")))
  star.field("constellation", Scalar("String"))
  star.field("label", NonNull(Scalar("String")))

  let resolvers = @moongql.Resolvers::new()
  resolvers.field("Query", "sky", fn(_info) { catalogue() })
  resolvers.field("Query", "star", fn(info) {
    let wanted = match info.arg("id") {
      String(id) => id
      _ => ""
    }
    let stars = match catalogue() {
      Object(fields) =>
        match fields.get("stars") {
          Some(Array(items)) => items
          _ => []
        }
      _ => []
    }
    let mut found = Json::null()
    for item in stars {
      if found is Null {
        match item {
          Object(fields) =>
            match fields.get("id") {
              Some(String(id)) => if id == wanted { found = item }
              _ => ()
            }
          _ => ()
        }
      }
    }
    found
  })
  // A field with no stored value: the resolver composes it from the parent,
  // which is how a row becomes the shape the client asked for.
  resolvers.field("Star", "label", fn(info) {
    let name = match info.parent {
      Object(fields) =>
        match fields.get("name") {
          Some(String(name)) => name
          _ => ""
        }
      _ => ""
    }
    let constellation = match info.parent {
      Object(fields) =>
        match fields.get("constellation") {
          Some(String(c)) => c
          _ => ""
        }
      _ => ""
    }
    if constellation == "" {
      Json(name)
    } else {
      Json("\{name} of \{constellation}")
    }
  })
  (schema, resolvers)
}

///|
/// The demo schema as SDL, so the page can show the schema it is querying.
pub fn sdl() -> String {
  let (schema, _) = demo()
  schema.to_sdl()
}

///|
/// Run a document against the demo schema and return the response as JSON text.
/// A bad document comes back as `{"errors": [...]}` rather than an exception,
/// which is exactly what the page needs to display.
pub fn run(document : String) -> String {
  let (schema, resolvers) = demo()
  @moongql.execute(schema, resolvers, document).stringify()
}
