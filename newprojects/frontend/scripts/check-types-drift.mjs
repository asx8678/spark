/**
 * Types drift placeholder — activated in P2-E2 (openapi-typescript from backend spec).
 * @see plan §6.3, A9
 */
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const frontendRoot = join(fileURLToPath(new URL('..', import.meta.url)));
const committed = join(frontendRoot, 'src/lib/api-types.ts');
const openapi = join(frontendRoot, '../backend/priv/static/openapi.json');
const dir = mkdtempSync(join(tmpdir(), 'immo-types-'));
const generated = join(dir, 'api-types.ts');

execFileSync('npx', ['openapi-typescript', openapi, '-o', generated], {
  cwd: frontendRoot,
  stdio: 'inherit',
});

const expected = readFileSync(committed, 'utf8').trimEnd();
const actual = readFileSync(generated, 'utf8').trimEnd();

if (expected !== actual) {
  writeFileSync(join(frontendRoot, 'src/lib/api-types.generated.ts'), actual);
  console.error(
    'api-types drift: src/lib/api-types.ts is out of date with backend/priv/static/openapi.json',
  );
  console.error('Diff hint written to src/lib/api-types.generated.ts (not committed).');
  process.exit(1);
}

console.log('Types drift check passed (placeholder; full codegen in P2-E2).');
