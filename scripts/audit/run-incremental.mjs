// The same deferred and streamed documents through graphql-js and through this
// library, compared payload by payload: the initial result, then every patch, in
// the order a client receives them. `@defer` and `@stream` are where an
// implementation is most free to invent its own shape, so the two sides are held
// to the same bytes rather than to the same data.
import { experimentalExecuteIncrementally, parse } from 'graphql';
import { schema } from './reference.mjs';
import { incrementalCorpus } from './incremental.mjs';
import { Bridge } from './bridge.mjs';
import { resolveBinary } from './binary.mjs';

const bridge = new Bridge(resolveBinary());

// Object key order is not part of a payload's meaning, so keys are sorted before
// the two are compared as text — the same rule the whole-response differential
// uses. Arrays keep their order: the order of patches, of pending entries and of
// streamed items is part of what the client sees.
function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') {
    const keys = Object.keys(value).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

// One multipart document, split back into the payloads it carries.
function payloadsOf(body, boundary) {
  return body
    .split(`--${boundary}`)
    .slice(1)
    .map((part) => part.replace(/^--\s*$/, '').trim())
    .filter((part) => part !== '')
    .map((part) => {
      const at = part.indexOf('\r\n\r\n');
      return part.slice(at < 0 ? 0 : at + 4).trim();
    })
    .filter((part) => part !== '');
}

async function ours(entry) {
  const answer = await bridge.http({
    method: 'POST',
    path: '/graphql',
    headers: [
      ['content-type', 'application/json'],
      ['accept', 'multipart/mixed; boundary="-"; deferSpec=20220824'],
    ],
    body: JSON.stringify({
      query: entry.query,
      variables: entry.variables ?? {},
    }),
  });
  return payloadsOf(answer.body, '-');
}

async function theirs(entry) {
  const result = await experimentalExecuteIncrementally({
    schema,
    document: parse(entry.query),
    variableValues: entry.variables ?? {},
  });
  if (result.initialResult === undefined) {
    return [JSON.stringify(result)];
  }
  const out = [JSON.stringify(result.initialResult)];
  for await (const patch of result.subsequentResults) {
    out.push(JSON.stringify(patch));
  }
  return out;
}

let failed = 0;
for (const entry of incrementalCorpus) {
  const actual = await ours(entry);
  const reference = await theirs(entry);
  const want = reference.map((text) => canonical(JSON.parse(text)));
  const got = actual.map((text) => canonical(JSON.parse(text)));
  if (want.length !== got.length) {
    console.log(
      `FAIL ${entry.name}: ${want.length} payload(s) expected, ${got.length} arrived`,
    );
    for (const [i, text] of got.entries()) console.log(`  ours[${i}]: ${text}`);
    for (const [i, text] of want.entries()) console.log(`  ref [${i}]: ${text}`);
    failed += 1;
    continue;
  }
  let differed = false;
  for (let i = 0; i < want.length; i += 1) {
    if (want[i] !== got[i]) {
      console.log(`FAIL ${entry.name}: payload ${i} differs`);
      console.log(`  reference: ${want[i]}`);
      console.log(`  ours:      ${got[i]}`);
      differed = true;
      failed += 1;
      break;
    }
  }
  if (!differed && process.env.MOONGQL_VERBOSE) {
    console.log(`ok ${entry.name}`);
  }
}

if (failed) {
  console.log(`incremental differential: ${failed} failure(s)`);
  process.exit(1);
}
console.log(
  `incremental differential: ${incrementalCorpus.length}/${incrementalCorpus.length} payload sequences agree with graphql-js`,
);
await bridge.quit();
