import { hostedAppToolCatalog, hostedToolCatalogDigest } from 'nanocodex/tools/hosted-catalog';

export function canonicalJSON(value) {
  if (Array.isArray(value)) return '[' + value.map(canonicalJSON).join(',') + ']';
  if (value && typeof value === 'object') return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonicalJSON(value[key])).join(',') + '}';
  return JSON.stringify(value);
}
function catalogJSON(entries) { return '[' + entries.map(canonicalJSON).sort().join(',') + ']'; }

export async function authorizationCatalog(entries) {
  if (!Array.isArray(entries) || entries.length === 0) throw new Error('NanoCAD tool catalog is missing.');
  const tools = entries.map(entry => ({
    name: entry.definition.name,
    definition: entry.definition,
    provider: entry.provider,
    remoteName: entry.remote_name,
    parallelSafe: entry.parallel_safe,
    ...(entry.summary === undefined ? {} : { summary: entry.summary }),
    timeoutMs: entry.timeout_ms,
    handler() { throw new Error('CAD tools execute only in the native NanoCAD app.'); },
  }));
  const emitted = hostedAppToolCatalog(tools);
  if (catalogJSON(emitted) !== catalogJSON(entries)) throw new Error('NanoCAD tool catalog does not match the Connect SDK.');
  const digest = await hostedToolCatalogDigest(emitted);
  const nativeBytes = new TextEncoder().encode('nanocodex-app-tool-catalog-v1\0' + catalogJSON(entries));
  const nativeHash = '0x' + [...new Uint8Array(await crypto.subtle.digest('SHA-256', nativeBytes))].map(x => x.toString(16).padStart(2, '0')).join('');
  if (digest !== nativeHash) throw new Error('NanoCAD tool catalog digest does not match the native app.');
  return { tools, digest };
}
