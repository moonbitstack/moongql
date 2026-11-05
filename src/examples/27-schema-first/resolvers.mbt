///|
/// Only the resolvers are written by hand: leaving one out is a compile warning that names it.
let authors : Array[Author] = [
  { id: "a1", name: "Ursula", },
  { id: "a2", name: "Stanislaw", },
]

///|
let books : Array[Book] = [
  { id: "b1", title: "The Dispossessed", status: PUBLISHED, author_id: "a1", },
  { id: "b2", title: "Solaris", status: PUBLISHED, author_id: "a2", },
  { id: "b3", title: "Notes", status: DRAFT, author_id: "a2", },
]

///|
fn Query::book(id : String) -> Book? raise {
  books.iter().find_first(b => b.id == id)
}

///|
fn Query::search(text : String) -> Array[Hit] raise {
  let hits : Array[Hit] = []
  for a in authors {
    if a.name.contains(text) {
      hits.push(Author(a))
    }
  }
  for b in books {
    if b.title.contains(text) {
      hits.push(Book(b))
    }
  }
  hits
}

///|
fn Mutation::add_book(input : NewBook) -> Book raise {
  guard authors.iter().any(a => a.id == input.author_id) else {
    raise @exec.FieldError("no author \{input.author_id}")
  }
  let book = {
    id: "b\{books.length() + 1}",
    title: input.title,
    status: DRAFT,
    author_id: input.author_id,
  }
  books.push(book)
  book
}

///|
fn Author::books(self : Author, first? : Int32) -> Array[Book] raise {
  let own = books.filter(b => b.author_id == self.id)
  match first {
    Some(n) if n < own.length() => own[:n].to_owned()
    _ => own
  }
}

///|
fn Book::author(self : Book) -> Author raise {
  guard authors.iter().find_first(a => a.id == self.author_id) is Some(a) else {
    raise @exec.FieldError("no author \{self.author_id}")
  }
  a
}

///|
/// A subscription is a function whose array is the stream of events, so `bookAdded` delivers the
/// books it finds — one event each — and the executor maps every event to a response.
fn Subscription::book_added(author_id? : String) -> Array[Book] raise {
  match author_id {
    Some(id) => books.filter(b => b.author_id == id)
    None => books.copy()
  }
}
