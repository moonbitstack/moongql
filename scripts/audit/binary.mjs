// Where the conformance driver is: the build output of `moon build --target
// native`, which the workflow runs first. The layout under `_build` differs
// between the platforms, so the binary is found by name rather than by path, and
// the repository root is found from this file so the scripts run from anywhere.
import { existsSync, readdirSync, statSync } from 'node:fs';
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

function findFile(directory, names, depth) {
  if (depth < 0) return null;
  let entries;
  try {
    entries = readdirSync(directory);
  } catch {
    return null;
  }
  for (const entry of entries) {
    if (names.includes(entry)) {
      const candidate = join(directory, entry);
      if (statSync(candidate).isFile()) return candidate;
    }
  }
  for (const entry of entries) {
    const child = join(directory, entry);
    try {
      if (!statSync(child).isDirectory()) continue;
    } catch {
      continue;
    }
    const found = findFile(child, names, depth - 1);
    if (found) return found;
  }
  return null;
}

export function resolveBinary() {
  // The native backend names its executables `.exe` on every platform, so both
  // spellings are looked for rather than chosen by the one running this.
  const build = join(repositoryRoot(), '_build', 'native');
  const found = findFile(build, ['conformance.exe', 'conformance'], 6);
  if (found) return found;
  throw new Error(
    `the conformance driver is not built; run \`moon build --target native\` first (looked under ${build})`,
  );
}
