/**
 * Wrangler validates `main` before the first Astro build produces dist/_worker.js.
 * P4-E3 replaces this stub with the real custom Worker entry.
 */
import { access, mkdir, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(fileURLToPath(new URL('..', import.meta.url)));
const target = join(root, 'dist/_worker.js/index.js');

try {
  await access(target);
} catch {
  await mkdir(dirname(target), { recursive: true });
  await writeFile(
    target,
    'export default { async fetch() { return new Response(null, { status: 404 }); } };\n',
  );
}
