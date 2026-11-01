///|
/// Code without spaces, line breaks or the trailing commas the printer adds when
/// it wraps a call, so a test can look for one call written on one line.
fn flat(code : String) -> String {
  let out = StringBuilder()
  for c in code {
    if c != ' ' && c != '\n' {
      out.write_char(c)
    }
  }
  out.to_string().replace_all(old=",)", new=")").replace_all(old=",]", new="]")
}

///|
fn generate(source : String) -> String raise {
  flat(@gen.render(Gql::{ }, [("schema.mbt", source)]))
}

///|
fn refused(source : String) -> String {
  try {
    ignore(generate(source))
    ""
  } catch {
    e => "\{e}"
  }
}

///|
test "a struct is an object type with camelCase fields and both conversions" {
  let code = generate(
    (
      #|#gql.type(description="A person")
      #|pub struct User {
      #|  id : Int64
      #|  display_name : String
      #|  #gql.field(name="handle", deprecation_reason="old", description="Login")
      #|  login : String?
      #|  tags : Array[String]
      #|  score : Double
      #|  admin : Bool
      #|  #gql.skip
      #|  password_hash : String
      #|}
    ),
  )
  assert_true(code.contains(flat("schema.scalar(\"Int64\")")))
  assert_true(
    code.contains(
      flat("let gql_user = schema.object(\"User\", description=\"A person\")"),
    ),
  )
  assert_true(
    code.contains(flat("gql_user.field(\"id\", NonNull(Scalar(\"Int64\")))")),
  )
  assert_true(
    code.contains(
      flat("gql_user.field(\"displayName\", NonNull(Scalar(\"String\")))"),
    ),
  )
  assert_true(
    code.contains(
      flat(
        "gql_user.field(\"handle\", Scalar(\"String\"), deprecation_reason=\"old\", description=\"Login\")",
      ),
    ),
  )
  assert_true(
    code.contains(flat("NonNull(ListOf(NonNull(Scalar(\"String\"))))")),
  )
  assert_true(code.contains(flat("NonNull(Scalar(\"Float\"))")))
  assert_true(code.contains(flat("NonNull(Scalar(\"Boolean\"))")))
  assert_true(!code.contains(flat("gql_user.field(\"passwordHash\"")))
  assert_true(code.contains(flat("pub impl @moongql.ToGql for User")))
  assert_true(code.contains(flat("\"__typename\": \"User\"")))
  assert_true(
    code.contains(
      flat("\"password_hash\": @moongql.ToGql::to_gql(self.password_hash)"),
    ),
  )
  assert_true(code.contains(flat("login: @moongql.read(v, \"handle\")")))
}

///|
test "enums and inputs" {
  let code = generate(
    (
      #|#gql.enum(name="Level", description="How sure")
      #|enum Certainty { Low; High }
      #|
      #|#gql.input
      #|struct Filter {
      #|  level : Certainty?
      #|  words : Array[String]
      #|}
    ),
  )
  assert_true(
    code.contains(
      flat(
        "schema.enum_(\"Level\", [\"Low\", \"High\"], description=\"How sure\")",
      ),
    ),
  )
  assert_true(code.contains(flat("Low => \"Low\"")))
  assert_true(code.contains(flat("String(\"High\") => High")))
  assert_true(
    code.contains(
      flat("raise @moongql.ResolverError::expected(\"Level\", other)"),
    ),
  )
  assert_true(code.contains(flat("let gql_filter = schema.input(\"Filter\")")))
  assert_true(
    code.contains(flat("gql_filter.field(\"level\", Named(\"Level\"))")),
  )
  assert_true(!code.contains(flat("\"__typename\": \"Filter\"")))
  assert_true(!code.contains(flat("pub impl")))
}

///|
test "root fields read each argument as its pass mode asks" {
  let code = generate(
    (
      #|#gql.query(description="One user")
      #|fn user(id : Int64, verbose~ : Bool, limit? : Int, depth~ : Int = 2, info : @moongql.ResolveInfo) -> String {
      #|  ignore((id, verbose, limit, depth, info))
      #|  ""
      #|}
      #|
      #|#gql.mutation(name="rename")
      #|fn rename_user(new_name : String) -> Bool raise {
      #|  new_name != ""
      #|}
    ),
  )
  assert_true(
    code.contains(
      flat(
        "gql_query.field_args(\"user\", [(\"id\", NonNull(Scalar(\"Int64\"))), (\"verbose\", NonNull(Scalar(\"Boolean\"))), (\"limit\", Scalar(\"Int\")), (\"depth\", Scalar(\"Int\"))], NonNull(Scalar(\"String\")), description=\"One user\")",
      ),
    ),
  )
  assert_true(
    code.contains(
      flat(
        "user(info.read(\"id\"), verbose=info.read(\"verbose\"), limit?=info.read(\"limit\"), depth?=info.read(\"depth\"), info)",
      ),
    ),
  )
  assert_true(code.contains(flat("schema.set_mutation(\"Mutation\")")))
  assert_true(code.contains(flat("gql_mutation.field_args(\"rename\"")))
  assert_true(code.contains(flat("rename_user(info.read(\"newName\"))")))
  assert_true(code.contains(flat("raise @moongql.field_error(e)")))
  assert_true(!code.contains("gql_query.name,\"rename\""))
}

///|
test "a method is a field of its type, resolved from the parent" {
  let code = generate(
    (
      #|#gql.type
      #|struct Book { title : String }
      #|
      #|#gql.field(name="shout")
      #|fn Book::loud(self : Book, times? : Int) -> String {
      #|  ignore(times)
      #|  self.title
      #|}
    ),
  )
  assert_true(
    code.contains(
      flat("gql_book.field_args(\"shout\", [(\"times\", Scalar(\"Int\"))]"),
    ),
  )
  assert_true(
    code.contains(
      flat("let self_ : Book = @moongql.FromGql::from_gql(info.parent)"),
    ),
  )
  assert_true(
    code.contains(flat("Book::loud(self_, times?=info.read(\"times\"))")),
  )
  assert_true(!code.contains("field_error"))
}

///|
test "kind names a scalar the program registers itself" {
  let code = generate(
    (
      #|#gql.type
      #|struct Event {
      #|  #gql.field(kind="DateTime")
      #|  at : Instant
      #|  #gql.field(kind="ID")
      #|  key : String
      #|}
    ),
  )
  assert_true(code.contains(flat("schema.scalar(\"DateTime\")")))
  assert_true(code.contains(flat("NonNull(Scalar(\"DateTime\"))")))
  assert_true(code.contains(flat("NonNull(Scalar(\"ID\"))")))
  assert_true(!code.contains(flat("schema.scalar(\"ID\")")))
}

///|
let pets : String =
  #|#gql.type
  #|struct Cat {
  #|  name : String
  #|  lives : Int
  #|}
  #|
  #|#gql.type
  #|struct Dog {
  #|  name : String
  #|}
  #|

///|
test "an enum over object types is a union or an interface" {
  let code = generate(
    pets +
    (
      #|#gql.union(description="Either")
      #|enum Pet { C(Cat); D(Dog) }
      #|
      #|#gql.interface(name="Named", field="name")
      #|pub enum Animal { Puss(Cat); Hound(Dog) }
      #|
      #|#gql.query
      #|fn pets() -> Array[Pet] { [] }
    ),
  )
  assert_true(
    code.contains(flat("\"pets\", _ => @moongql.ToGql::to_gql(pets())")),
  )
  assert_true(
    code.contains(
      flat("schema.union(\"Pet\", [\"Cat\", \"Dog\"], description=\"Either\")"),
    ),
  )
  assert_true(
    code.contains(flat("let gql_animal = schema.interface(\"Named\")")),
  )
  assert_true(
    code.contains(
      flat("gql_animal.field(\"name\", NonNull(Scalar(\"String\")))"),
    ),
  )
  assert_true(code.contains(flat("gql_cat.implements(\"Named\")")))
  assert_true(code.contains(flat("gql_dog.implements(\"Named\")")))
  assert_true(!code.contains(flat("implements(\"Pet\")")))
  assert_true(code.contains(flat("C(v) => @moongql.ToGql::to_gql(v)")))
  assert_true(
    code.contains(
      flat(
        "{ \"__typename\": String(\"Dog\"), .. } => Hound(@moongql.FromGql::from_gql(v))",
      ),
    ),
  )
  assert_true(
    code.contains(flat("pub impl @moongql.ToGql for Animal with fn to_gql")),
  )
  assert_true(
    code.contains(
      flat("raise @moongql.ResolverError::expected(\"Pet\", other)"),
    ),
  )
}

///|
test "an interface field keeps the arguments its members take" {
  let code = generate(
    (
      #|#gql.type
      #|struct A { x : Int }
      #|
      #|#gql.field
      #|fn A::at(self : A, n? : Int) -> Int { n.unwrap_or(self.x) }
      #|
      #|#gql.type
      #|struct B { y : Int }
      #|
      #|#gql.field
      #|fn B::at(self : B, n? : Int) -> Int { n.unwrap_or(self.y) }
      #|
      #|#gql.interface(field="at")
      #|enum Point { A(A); B(B) }
    ),
  )
  assert_true(
    code.contains(
      flat(
        "gql_point.field_args(\"at\", [(\"n\", Scalar(\"Int\"))], NonNull(Scalar(\"Int\")))",
      ),
    ),
  )
}

///|
test "unions and interfaces refuse what GraphQL does not allow" {
  assert_true(
    refused(
      pets +
      (
        #|#gql.union
        #|enum Pet { C(Cat); Stray }
      ),
    ).contains("`Pet::Stray` does not wrap one `#gql.type` struct"),
  )
  assert_true(
    refused(
      (
        #|#gql.union
        #|enum Num { I(Int) }
      ),
    ).contains("`Num::I` does not wrap one `#gql.type` struct"),
  )
  assert_true(
    refused(
      pets +
      (
        #|#gql.interface
        #|enum Animal { C(Cat); D(Dog) }
      ),
    ).contains("names at least one `field`"),
  )
  assert_true(
    refused(
      pets +
      (
        #|#gql.interface(field="lives")
        #|enum Animal { C(Cat); D(Dog) }
      ),
    ).contains("`Dog` has no field `lives`"),
  )
  assert_true(
    refused(
      (
        #|#gql.type
        #|struct A { id : Int }
        #|
        #|#gql.type
        #|struct B { id : String }
        #|
        #|#gql.interface(field="id")
        #|enum Node { A(A); B(B) }
      ),
    ).contains("field `id` is not the same in every member of `Node`"),
  )
  assert_true(
    refused(
      pets +
      (
        #|#gql.union
        #|enum Pet { C(Cat); D(Dog) }
        #|
        #|#gql.query
        #|fn adopt(pet : Pet) -> Int { 0 }
      ),
    ).contains("parameter `pet`: `Pet` is an output type"),
  )
  assert_true(
    refused(
      pets +
      (
        #|#gql.input
        #|struct Home {
        #|  cats : Array[Cat]
        #|}
      ),
    ).contains("field `cats`: `Cat` is an output type"),
  )
}

///|
test "names and nothing to generate" {
  assert_eq(camel("password_hash"), "passwordHash")
  assert_eq(camel("_private_key"), "_privateKey")
  assert_eq(camel("id"), "id")
  assert_true(!generate("struct Plain { x : Int }").contains("register"))
}

///|
test "mistakes are reported where they are written" {
  assert_true(
    refused(
      (
        #|#gql.type
        #|struct S {
        #|  when : Instant
        #|}
      ),
    ).contains("schema.mbt:1:1: field `when`: `Instant` has no GraphQL type"),
  )
  assert_true(
    refused(
      (
        #|#gql.type
        #|struct S {
        #|  #gql.field(type="ID")
        #|  a : String
        #|}
      ),
    ).contains("schema.mbt:3:3: `#gql.field(type=\"ID\")` does not parse"),
  )
  assert_true(
    refused(
      (
        #|#gql.enum
        #|enum E { A(Int); B }
      ),
    ).contains("`E::A` carries a payload"),
  )
  assert_true(
    refused(
      (
        #|#gql.query
        #|fn ping() -> Unit { () }
      ),
    ).contains("a GraphQL field returns a value"),
  )
  assert_true(
    refused(
      (
        #|#gql.query
        #|async fn ping() -> Int { 0 }
      ),
    ).contains("synchronous"),
  )
  assert_true(
    refused(
      (
        #|struct S { a : Int }
        #|
        #|#gql.field
        #|fn S::b(self : S) -> Int { self.a }
      ),
    ).contains("`S` has no `#gql.type`"),
  )
  assert_true(
    refused(
      (
        #|#gql.type
        #|struct S { a : Int }
        #|
        #|#gql.field
        #|fn S::b(other : Int) -> Int { other }
      ),
    ).contains("takes `self` first"),
  )
  assert_true(
    refused(
      (
        #|#gql.type
        #|struct S {
        #|  #gql.field(name="a")
        #|  b : Int
        #|  a : Int
        #|}
      ),
    ).contains("two fields called `a`"),
  )
  assert_true(
    refused(
      (
        #|#gql.query
        #|struct S { a : Int }
      ),
    ).contains("does not go on a struct"),
  )
  assert_true(
    refused(
      (
        #|struct S {
        #|  #gql.skip
        #|  a : Int
        #|}
      ),
    ).contains("`S` has no `#gql.type` or `#gql.input`"),
  )
  assert_true(
    refused(
      (
        #|#gql.type
        #|#gql.input
        #|struct S { a : Int }
      ),
    ).contains("one `#gql.*` per declaration"),
  )
}

///|
test "a subscription is a root field whose events are the array it returns" {
  let source =
    #|#gql.subscription
    #|pub fn countdown(from : Int32) -> Array[Int32] {
    #|  [from]
    #|}
  let code = generate(source)
  assert_true(code.contains("pubfnregister_subscriptions"))
  assert_true(code.contains("schema.set_subscription"))
  assert_true(code.contains("subscribers.field("))
  assert_true(code.contains("countdown(info.read"))
  assert_true(code.contains("info.parent"))
}

///|
test "a subscription has to return its events" {
  let source =
    #|#gql.subscription
    #|pub fn tick() -> Int32 {
    #|  1
    #|}
  assert_true(refused(source).contains("an `Array[T]`"))
}

///|
test "permission guards a resolver with the functions it names" {
  let source =
    #|#gql.query(permission="signed_in", permission="is_admin")
    #|pub fn secret() -> String {
    #|  "s"
    #|}
  let code = generate(source)
  assert_true(
    code.contains(
      flat(
        "if !(signed_in(info) && is_admin(info)) { raise @moongql.not_permitted() }",
      ),
    ),
  )
}

///|
test "permission has no resolver to guard on a plain field" {
  let source =
    #|#gql.type
    #|pub struct T {
    #|  #gql.field(permission="p")
    #|  x : Int32
    #|}
  assert_true(refused(source).contains("put `permission` on a method"))
}

///|
test "a key makes an entity, and its reference function resolves it" {
  let source =
    #|#gql.type(key="id")
    #|pub struct User {
    #|  id : String
    #|  #gql.field(shareable=true)
    #|  name : String
    #|  #gql.field(requires="name", override_from="accounts", provides="id")
    #|  label : String
    #|  #gql.field(inaccessible=true)
    #|  hidden : String
    #|  #gql.field(external=true)
    #|  email : String
    #|}
    #|
    #|#gql.reference
    #|pub fn user_by_id(id : String) -> User? raise {
    #|  None
    #|}
  let code = generate(source)
  assert_true(code.contains("pubfnregister_federation"))
  assert_true(code.contains(flat("name=\"User\", key=\"id\"")))
  assert_true(code.contains(flat("user_by_id(@moongql.read(rep, \"id\"))")))
  assert_true(code.contains(flat("external=[\"email\"]")))
  assert_true(code.contains(flat("federation.shareable(\"User\", \"name\")")))
  assert_true(
    code.contains(flat("federation.inaccessible(\"User\", \"hidden\")")),
  )
  assert_true(
    code.contains(
      flat("federation.override_(\"User\", \"label\", from=\"accounts\")"),
    ),
  )
  assert_true(
    code.contains(
      flat("federation.requires(\"User\", \"label\", fields=\"name\")"),
    ),
  )
  assert_true(
    code.contains(
      flat("federation.provides(\"User\", \"label\", fields=\"id\")"),
    ),
  )
}

///|
test "an entity without a reference function is its representation" {
  let source =
    #|#gql.type(key="id", extended=true)
    #|pub struct User {
    #|  id : String
    #|}
  let code = generate(source)
  assert_true(code.contains(flat("resolve=(rep, _) => rep")))
  assert_true(code.contains("extends=true"))
}

///|
test "a reference function returns an entity, once" {
  let not_entity =
    #|#gql.type
    #|pub struct T {
    #|  id : String
    #|}
    #|
    #|#gql.reference
    #|pub fn t(id : String) -> T {
    #|  { id, }
    #|}
  assert_true(refused(not_entity).contains("a type with a `key`"))
  let twice =
    #|#gql.type(key="id")
    #|pub struct T {
    #|  id : String
    #|}
    #|
    #|#gql.reference
    #|pub fn a(id : String) -> T {
    #|  { id, }
    #|}
    #|
    #|#gql.reference
    #|pub fn b(id : String) -> T {
    #|  { id, }
    #|}
  assert_true(refused(twice).contains("has a reference function already"))
}

///|
test "external needs a key" {
  let source =
    #|#gql.type
    #|pub struct T {
    #|  #gql.field(external=true)
    #|  x : Int32
    #|}
  assert_true(refused(source).contains("is for a type with a `key`"))
}
