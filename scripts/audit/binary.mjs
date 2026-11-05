// Where the conformance driver is: the build output of `moon build --target
// native`, which the workflow runs first. The repository root is found from this
// file, so the scripts run from any directory.
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

function repositoryRoot() {
  let here = dirname(fileURLToPath(import.meta.url));
  for (;;) {
    if (existsSync(join(here, 'moon.mod'))) return here;
    const parent = resolve(here, '..');
    if (parent === here) throw new Error('no moon.mod above the conformance scripts');
    here = parent;
  }
}

export function resolveBinary() {
  const root = repositoryRoot();
  const name = process.platform === 'win32' ? 'conformance.exe' : 'conformance';
  const candidates = ['debug', 'release'].map((mode) =>
    join(root, '_build', 'native', mode, 'build', 'tools', 'conformance', name),
  );
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }
  throw new Error(
    'the conformance driver is not built; run `moon build --target native` first',
  );
}
