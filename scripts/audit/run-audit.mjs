// The GraphQL-over-HTTP specification's own audit, run against the application.
// Every required check must pass; a failed SHOULD is reported and fails the run
// too, so that a regression in a recommendation is as visible as one in a rule.
import { auditServer } from 'graphql-http';
import { Bridge, fetchOver } from './bridge.mjs';
import { resolveBinary } from './binary.mjs';

const bridge = new Bridge(resolveBinary());
const results = await auditServer({
  url: 'http://moongql.test/graphql',
  fetchFn: fetchOver(bridge),
});
await bridge.quit();

const failed = results.filter((r) => r.status === 'error' || r.status === 'warn');
const notices = results.filter((r) => r.status === 'notice');
for (const result of failed) {
  console.log(`${result.status.toUpperCase()} ${result.id} ${result.name}`);
  if (result.reason) console.log(`    ${result.reason}`);
}
for (const result of notices) {
  if (result.reason) console.log(`NOTICE ${result.id} ${result.name}: ${result.reason}`);
}
const passed = results.length - failed.length;
console.log(`graphql-http audit: ${passed}/${results.length} passed, ${failed.length} failed`);

if (failed.length) process.exit(1);
