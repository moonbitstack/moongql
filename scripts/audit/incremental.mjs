// The documents the incremental differential runs: every shape of postponed work
// a client can ask for — a deferred fragment, a streamed list, the two nested in
// each other, labels, `if`, a null parent, an initial count past the end.
export const incrementalCorpus = [
  { name: 'defer a field', query: '{ user(id: "1") { id ... @defer { name } } }' },
  {
    name: 'defer with a label',
    query: '{ user(id: "1") { id ... @defer(label: "rest") { name age } } }',
  },
  {
    name: 'two deferrals on one object',
    query:
      '{ user(id: "1") { ... @defer { id } ... @defer(label: "L") { name } } }',
  },
  {
    name: 'a deferral inside a deferral',
    query: '{ user(id: "1") { id ... @defer { name ... @defer { age } } } }',
  },
  {
    name: 'defer a named fragment',
    query:
      'query { user(id: "1") { id ...F @defer } } fragment F on User { name friends { id } }',
  },
  {
    name: 'defer an inline fragment with a type condition',
    query: '{ user(id: "1") { id ... on User @defer(label: "u") { name } } }',
  },
  {
    name: 'defer a null parent',
    query: '{ user(id: "404") { id ... @defer { name } } }',
  },
  {
    name: 'defer switched off',
    query: '{ user(id: "1") { id ... @defer(if: false) { name } } }',
  },
  {
    name: 'defer behind a variable',
    query:
      'query ($on: Boolean!) { user(id: "1") { id ... @defer(if: $on) { name } } }',
    variables: { on: true },
  },
  { name: 'stream a list', query: '{ users @stream { id } }' },
  {
    name: 'stream with an initial count',
    query: '{ users @stream(initialCount: 2) { id name } }',
  },
  {
    name: 'stream with a label',
    query: '{ users @stream(initialCount: 1, label: "rest") { id } }',
  },
  {
    name: 'stream the whole list',
    query: '{ users @stream(initialCount: 3) { id } }',
  },
  {
    name: 'stream past the end',
    query: '{ users @stream(initialCount: 9) { id } }',
  },
  {
    name: 'stream a nested list',
    query: '{ user(id: "1") { friends @stream(initialCount: 0) { id } } }',
  },
  {
    name: 'stream switched off',
    query: '{ users @stream(if: false) { id } }',
  },
  {
    name: 'a deferral inside a streamed item',
    query: '{ users @stream(initialCount: 1) { id ... @defer { name } } }',
  },
  {
    name: 'a stream inside a deferral',
    query:
      '{ user(id: "1") { id ... @defer { friends @stream(initialCount: 0) { id } } } }',
  },
  {
    name: 'a stream of an empty list',
    query: '{ user(id: "2") { friends @stream(initialCount: 0) { id } } }',
  },
  {
    name: 'defer and stream in one document',
    query:
      '{ users @stream(initialCount: 1) { id } user(id: "1") { id ... @defer { name } } }',
  },
];
