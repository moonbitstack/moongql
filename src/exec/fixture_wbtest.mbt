///|
/// The standard GraphQL introspection query graphql-core / strawberry send to
/// discover a schema. Parsing it exercises operation names, deeply nested
/// selection sets, aliases-free fields, arguments, directives, and both named
/// and inline fragments in one document.
let introspection_query : String =
  #|query IntrospectionQuery {
  #|  __schema {
  #|    queryType { name }
  #|    mutationType { name }
  #|    subscriptionType { name }
  #|    types {
  #|      ...FullType
  #|    }
  #|    directives {
  #|      name
  #|      description
  #|      locations
  #|      args {
  #|        ...InputValue
  #|      }
  #|    }
  #|  }
  #|}
  #|
  #|fragment FullType on __Type {
  #|  kind
  #|  name
  #|  description
  #|  fields(includeDeprecated: true) {
  #|    name
  #|    description
  #|    args {
  #|      ...InputValue
  #|    }
  #|    type {
  #|      ...TypeRef
  #|    }
  #|    isDeprecated
  #|    deprecationReason
  #|  }
  #|  inputFields {
  #|    ...InputValue
  #|  }
  #|  interfaces {
  #|    ...TypeRef
  #|  }
  #|  enumValues(includeDeprecated: true) {
  #|    name
  #|    description
  #|    isDeprecated
  #|    deprecationReason
  #|  }
  #|  possibleTypes {
  #|    ...TypeRef
  #|  }
  #|}
  #|
  #|fragment InputValue on __InputValue {
  #|  name
  #|  description
  #|  type { ...TypeRef }
  #|  defaultValue
  #|}
  #|
  #|fragment TypeRef on __Type {
  #|  kind
  #|  name
  #|  ofType {
  #|    kind
  #|    name
  #|  }
  #|}

///|
/// The validation errors for `query` against `s`, joined one per line (so a test
/// can assert a message is present, or that the string is empty for a valid query).
fn verr_text(s : @schema.Schema, query : String) -> String {
  let doc = @lang.parse(query) catch {
    @lang.GqlSyntaxError(m, _, _) => return m
  }
  let sb = StringBuilder()
  for e in @valid.validate(s, doc) {
    sb.write_string(e.message)
    sb.write_char('\n')
  }
  sb.to_string()
}
