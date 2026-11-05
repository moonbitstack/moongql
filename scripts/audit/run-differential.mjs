// The same corpus through graphql-js and through this library, compared response
// by response: `data` must match exactly, and errors must match in what they say
// and where they point. A difference here is a difference from the reference
// implementation of the specification.
import { graphql } from 'graphql';
import { schema } from './reference.mjs';
import { corpus } from './corpus.mjs';
import { Bridge } from './bridge.mjs';
import { resolveBinary } from './binary.mjs';

const bridge = new Bridge(resolveBinary());

// Object key order is not part of a response's meaning, so keys are sorted before
// the two are compared as text.
function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') {
    const keys = Object.keys(value).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

// Errors are compared by where they point, not by how they are worded: the
// specification fixes a response's shape and the path an error is reported at,
// and leaves the sentence to the implementation. A wording difference is not a
// behavioural one; a missing error, a moved path or a moved location is.
function errorsOf(answer) {
  return (answer.errors ?? []).map((error) => ({
    path: error.path ?? [],
    locations: (error.locations ?? []).map((l) => `${l.line}:${l.column}`),
  }));
}

let failed = 0;
for (const entry of corpus) {
  const variables = entry.variables ?? {};
  const body = JSON.stringify({ query: entry.query, variables });
  const answer = await bridge.http({
    method: 'POST',
    path: '/graphql',
    headers: [
      ['content-type', 'application/json'],
      ['accept', 'application/graphql-response+json'],
    ],
    body,
  });

  const reference = await graphql({
    schema,
    source: entry.query,
    variableValues: variables,
  });

  let actual;
  try {
    actual = JSON.parse(answer.body);
  } catch {
    console.log(`FAIL ${entry.name}: the answer is not JSON`);
    console.log(`  ${answer.body}`);
    failed += 1;
    continue;
  }

  const referenceData = reference.data === undefined ? null : reference.data;
  const actualData = actual.data === undefined ? null : actual.data;
  const errorsAgree = canonical(errorsOf(actual)) === canonical(errorsOf(reference));

  if (canonical(referenceData) !== canonical(actualData)) {
    console.log(`FAIL ${entry.name}: data differs`);
    console.log(`  reference: ${canonical(referenceData)}`);
    console.log(`  ours:      ${canonical(actualData)}`);
    failed += 1;
  } else if (!errorsAgree) {
    console.log(`FAIL ${entry.name}: errors differ`);
    console.log(`  reference: ${canonical(errorsOf(reference))}`);
    console.log(`  ours:      ${canonical(errorsOf(actual))}`);
    failed += 1;
  }
}

await bridge.quit();
console.log(`differential: ${corpus.length - failed}/${corpus.length} agree with graphql-js`);
if (failed) process.exit(1);
