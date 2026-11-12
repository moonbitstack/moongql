// The other direction of the same question: `run-differential.mjs` asks whether
// this library's server answers like the reference implementation, and this one
// asks whether this library's client can talk to a server it did not write.
//
// A graphql-js schema and `graphql-http`'s own handler serve a real socket; the
// probe under `src/tools/client` is started against it and sends the documents
// over HTTP; what the client read is compared with what graphql-js answers for
// the same document. Both halves are held to the same standard: `data` exactly,
// errors by where they point, never by how they are worded.
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { buildSchema, graphql } from 'graphql';
import { createHandler } from 'graphql-http/lib/use/http';
import { resolveClientProbe } from './binary.mjs';

const sdl = `
  type Query {
    hello: String!
    user(id: ID!): User
    books: [Book!]!
    boom: String!
  }

  type User {
    id: ID!
    name: String!
    friends: [User!]!
  }

  type Book {
    title: String!
    pages: Int!
  }
`;

const rootValue = {
  hello: () => 'world',
  user: ({ id }) => ({
    id,
    name: 'Alice',
    friends: [{ id: '2', name: 'Bob', friends: [] }],
  }),
  books: () => [
    { title: 'One', pages: 10 },
    { title: 'Two', pages: 20 },
  ],
  boom: () => {
    throw new Error('the book is on fire');
  },
};

const schema = buildSchema(sdl);

// What a client has to get right: a plain field, arguments bound from variables,
// an alias and a fragment, a field error inside a non-null position, one
// operation named out of two, and a document the server refuses before running.
const requests = [
  {
    name: 'a plain field',
    document: '{ hello }',
  },
  {
    name: 'arguments from variables',
    document: 'query ($id: ID!) { user(id: $id) { id name } }',
    variables: { id: '1' },
  },
  {
    name: 'aliases and a fragment',
    document:
      '{ first: books { title } ...More } fragment More on Query { second: books { pages } }',
  },
  {
    name: 'a field error under a non-null field',
    document: '{ boom }',
  },
  {
    name: 'one operation named out of two',
    document: 'query A { hello } query B { books { title } }',
    operationName: 'B',
  },
  {
    name: 'a field the schema does not have',
    document: '{ missing }',
  },
  {
    name: 'a document that is not GraphQL',
    document: '{ hello',
    expect: 'refused',
  },
];

function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') {
    const keys = Object.keys(value).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function errorsOf(answer) {
  return (answer.errors ?? []).map((error) => ({
    message: error.message,
    path: error.path ?? [],
    locations: (error.locations ?? []).map((l) => `${l.line}:${l.column}`),
  }));
}

// The probe reads one request per line and writes one answer per line, so the
// two sides meet on a pipe rather than on a file neither of them owns.
function runProbe(binary, url, lines) {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, [url], { stdio: ['pipe', 'pipe', 'inherit'] });
    let out = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      out += chunk;
    });
    child.on('error', reject);
    child.on('close', (code) => {
      if (code !== 0) {
        reject(new Error(`the client probe exited with ${code}`));
        return;
      }
      resolve(out.split('\n').filter((line) => line.trim() !== ''));
    });
    child.stdin.end(lines.join('\n') + '\n');
  });
}

// No `onSubscribe`: this asks how the client reads answers, and a subscription
// needs a transport that reads as it goes, which a request/response client is
// not. `run-incremental.mjs` covers the postponed-work half.
const server = createServer(createHandler({ schema, rootValue }));

await new Promise((done) => server.listen(0, '127.0.0.1', done));
const url = `http://127.0.0.1:${server.address().port}/graphql`;

let failed = 0;
try {
  const lines = requests.map((entry) =>
    [
      entry.name,
      entry.variables ? JSON.stringify(entry.variables) : '',
      entry.operationName ?? '',
      entry.document,
    ].join('\t'),
  );
  const answers = await runProbe(resolveClientProbe(), url, lines);

  if (answers.length !== requests.length) {
    console.log(
      `FAIL: ${requests.length} requests were sent and ${answers.length} answers came back`,
    );
    failed += 1;
  }

  for (const [index, entry] of requests.entries()) {
    const line = answers[index];
    if (line === undefined) break;
    let answer;
    try {
      answer = JSON.parse(line);
    } catch {
      console.log(`FAIL ${entry.name}: the probe wrote a line that is not JSON`);
      console.log(`  ${line}`);
      failed += 1;
      continue;
    }
    // The client checks a document before spending a round trip on it, so a
    // document that is not GraphQL is refused here and never reaches the server.
    if (entry.expect === 'refused') {
      if (!answer.ok && answer.why.startsWith('invalid document')) {
        console.log(`ok   ${entry.name}`);
      } else {
        console.log(`FAIL ${entry.name}: the client sent it anyway`);
        console.log(`  ${JSON.stringify(answer)}`);
        failed += 1;
      }
      continue;
    }
    if (!answer.ok) {
      console.log(`FAIL ${entry.name}: the client refused the request`);
      console.log(`  ${answer.why}`);
      failed += 1;
      continue;
    }
    const reference = await graphql({
      schema,
      source: entry.document,
      rootValue,
      variableValues: entry.variables ?? {},
      operationName: entry.operationName,
    });
    const actualData = canonical(answer.answer.data ?? null);
    const wantData = canonical(reference.data ?? null);
    const actualErrors = canonical(errorsOf(answer.answer));
    const wantErrors = canonical(errorsOf(reference));
    if (actualData === wantData && actualErrors === wantErrors) {
      console.log(`ok   ${entry.name}`);
    } else {
      failed += 1;
      console.log(`FAIL ${entry.name}`);
      if (actualData !== wantData) {
        console.log(`  data\n    got  ${actualData}\n    want ${wantData}`);
      }
      if (actualErrors !== wantErrors) {
        console.log(`  errors\n    got  ${actualErrors}\n    want ${wantErrors}`);
      }
    }
  }
} finally {
  server.close();
}

if (failed === 0) {
  console.log(`\nclient interoperability: ${requests.length}/${requests.length} agree with graphql-js`);
  process.exit(0);
}
console.log(`\nclient interoperability: ${failed} of ${requests.length} disagree`);
process.exit(1);
