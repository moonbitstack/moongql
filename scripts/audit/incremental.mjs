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
  {
    name: 'two deferrals at the root, each opening a stream',
    query:
      '{ user(id: "1") { id ... @defer { friends @stream(initialCount: 0) { id } } } users @stream(initialCount: 1) { id ... @defer { name } } }',
  },
  {
    name: 'two streams on sibling fields',
    query: '{ users @stream(initialCount: 1) { id } more: users(first: 2) @stream(initialCount: 0) { id } }',
  },
  {
    name: 'a deferral after a stream at the root',
    query:
      '{ users @stream(initialCount: 2) { name } user(id: "2") { id ... @defer(label: "second") { role } } }',
  },
  {
    name: 'two deferrals on one object, one of them labelled',
    query:
      '{ user(id: "1") { id ... @defer { name } ... @defer(label: "solo") { age } } }',
  },
  {
    name: 'a deferral inside a deferral inside a deferral',
    query:
      '{ user(id: "1") { id ... @defer { name ... @defer { age ... @defer { role } } } } }',
  },
  {
    name: 'a deferral on an interface member',
    query: '{ node(id: "1") { id ... on User @defer { name } } }',
  },
  {
    name: 'a deferral on a union member',
    query:
      '{ search(text: "d") { __typename ... on User @defer { name } ... on Book { title } } }',
  },
  {
    name: 'aliased deferred fields',
    query:
      '{ first: user(id: "1") { id ... @defer(label: "a") { name } } second: user(id: "2") { id ... @defer(label: "b") { name } } }',
  },
  {
    name: 'a deferral wrapping a conditional field',
    query:
      '{ user(id: "1") { id ... @defer { name @include(if: true) age @skip(if: true) } } }',
  },
  {
    name: 'a stream inside a streamed item',
    query: '{ users @stream(initialCount: 1) { id friends @stream(initialCount: 0) { name } } }',
  },
  {
    name: 'a deferral inside a streamed item inside a deferral',
    query:
      '{ user(id: "1") { id ... @defer { friends @stream(initialCount: 0) { id ... @defer { name } } } } }',
  },
  {
    name: 'a failing deferred non-null field',
    query: '{ fail user(id: "1") { id ... @defer { name } } }',
  },
  {
    name: 'the same fragment deferred from two fields',
    query:
      'query { a: user(id: "1") { ...F @defer } b: user(id: "2") { ...F @defer(label: "b") } } fragment F on User { name role }',
  },
  {
    name: 'a stream asked for exactly the whole list',
    query: '{ users @stream(initialCount: 3) { id } }',
  },
  {
    name: 'a stream on a field that answers null',
    query: '{ user(id: "404") { friends @stream(initialCount: 0) { id } } }',
  },
  {
    name: 'a labelled deferral wrapping a labelled stream',
    query:
      '{ user(id: "1") { id ... @defer(label: "outer") { friends @stream(initialCount: 0, label: "inner") { name } } } }',
  },
  {
    name: 'two deferrals and a stream on one object',
    query:
      '{ user(id: "1") { id ... @defer { name } ... @defer { age } friends @stream(initialCount: 0) { id } } }',
  },
  {
    name: 'a streamed list whose items defer and error',
    query:
      '{ users @stream(initialCount: 1) { id ... @defer { name } } }',
  },
  {
    name: 'a deferral behind a variable that is off',
    query:
      'query ($on: Boolean!) { user(id: "1") { id ... @defer(if: $on) { name } } }',
    variables: { on: false },
  },
  {
    name: 'a stream behind a variable that is on',
    query:
      'query ($on: Boolean!) { users @stream(if: $on, initialCount: 1) { id } }',
    variables: { on: true },
  },
];
