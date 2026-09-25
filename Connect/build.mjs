import { build } from 'esbuild';
import { readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { authorizationCatalog } from './src/catalog.mjs';
const manifest=JSON.parse(await readFile('../Resources/connect-tool-catalog.json'));
const {digest}=await authorizationCatalog(manifest);
const result = await build({entryPoints:['src/main.mjs'],outfile:'../Resources/connect.js',bundle:true,platform:'browser',format:'iife',target:'safari17',minify:true,sourcemap:false,legalComments:'eof',metafile:true,logLevel:'warning'});
const roots = new Set();
for (const input of Object.keys(result.metafile.inputs)) {
  const match = input.match(/^(.*node_modules\/(?:@[^/]+\/)?[^/]+)\//);
  if (match) roots.add(match[1]);
}
const notices = [];
for (const root of [...roots].sort()) {
  const pkg = JSON.parse(await readFile(path.join(root,'package.json')));
  const files = (await readdir(root)).filter(name => /^(licen[cs]e|copying|notice)(\.|$|-)/i.test(name)).sort();
  const texts = [];
  for (const name of files) {
    try { texts.push(await readFile(path.join(root,name),'utf8')); } catch {}
  }
  if (['nanocodex','nanocodex-tools'].includes(pkg.name)) texts.push(await readFile('../docs/NANOCODEX-LICENSE-MIT.txt','utf8'));
  if (pkg.name === '@cfworker/json-schema') texts.push(await readFile('licenses/cfworker-MIT.txt','utf8'));
  if (!texts.length) throw new Error(`Missing distribution license for ${pkg.name}`);
  notices.push(`${pkg.name} ${pkg.version} (${pkg.license ?? 'see license'})\n${texts.join('\n').replace(/[ \t]+$/gm, '')}`);
}
await writeFile('../Resources/connect-licenses.txt', 'NanoCAD Connect JavaScript dependency notices\n\n' + notices.join('\n\n---\n\n'));
console.log(`Bundled public Connect dialog SDK; catalog ${digest}`);
