// The documents the differential runs: the parts of execution where two
// implementations can disagree — aliases, fragments, variables and their
// defaults, directives, non-null propagation, interfaces, unions, enums,
// arguments and their defaults, and introspection.
export const corpus = [
  { name: 'shorthand', query: '{ hello }' },
  { name: 'alias', query: '{ greeting: hello }' },
  { name: 'object', query: '{ user(id: "1") { id name age role } }' },
  { name: 'argument', query: '{ user(id: "2") { name } }' },
  { name: 'nullable missing', query: '{ user(id: "404") { name } }' },
  { name: 'list', query: '{ users { id } }' },
  { name: 'list default arg', query: '{ users(first: 2) { id } }' },
  { name: 'list arg beyond the end', query: '{ users(first: 10) { id } }' },
  {
    name: 'nested selection',
    query: '{ user(id: "1") { name friends { name friends { name } } } }',
  },
  {
    name: 'fragment',
    query: 'query { user(id: "1") { ...F } } fragment F on User { id name }',
  },
  {
    name: 'inline fragment on interface',
    query: '{ node(id: "1") { ... on User { name } ... on Book { title } } }',
  },
  {
    name: 'union with __typename',
    query:
      '{ search(text: "d") { __typename ... on User { name } ... on Book { title } } }',
  },
  {
    name: 'skip and include',
    query: '{ a: hello @skip(if: true) b: hello @include(if: true) }',
  },
  {
    name: 'variable',
    query: 'query ($id: ID!) { user(id: $id) { name } }',
    variables: { id: '3' },
  },
  {
    name: 'variable default',
    query: 'query ($first: Int = 1) { users(first: $first) { id } }',
  },
  {
    name: 'mutation',
    query: 'mutation { addUser(name: "Dee") { id name role } }',
  },
  { name: 'failing resolver', query: '{ fail }' },
  { name: 'failing non-null resolver', query: 'mutation { boom }' },
  {
    name: 'aliased mutation fields',
    query:
      'mutation { a: addUser(name: "A") { id } b: addUser(name: "B") { id } }',
  },
  { name: 'enum value', query: '{ users { role } }' },
  { name: 'introspection type', query: '{ __type(name: "User") { kind name } }' },
  {
    name: 'introspection enum values',
    query: '{ __type(name: "Role") { enumValues { name } } }',
  },
  { name: 'syntax error', query: '{ hello' },
  { name: 'validation error', query: '{ nope }' },
  {
    name: 'variable coercion error',
    query: 'query ($id: ID!) { user(id: $id) { name } }',
    variables: {},
  },
];
