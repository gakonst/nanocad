export const APP_ID = 'com.gakonst.nanocad';
export const APP_ORIGIN = 'https://nanocodex.gakonst.workers.dev';
export const API_ORIGIN = 'https://nanocodex-connect-api.gakonst.workers.dev';
export function validateEnvelope(envelope, launch, digest, now = Date.now() / 1000) {
  if (envelope.sandboxExecution !== true || envelope.origin !== API_ORIGIN || envelope.appID !== APP_ID || envelope.appOrigin !== APP_ORIGIN ||
      !/^0x[0-9a-fA-F]{64}$/.test(envelope.grantID) || !/^[A-Za-z0-9_-]{1,128}$/.test(envelope.agentID) ||
      !/^[A-Za-z0-9_-]{43}$/.test(envelope.token) || !Number.isFinite(envelope.expiresAt) || envelope.expiresAt <= now ||
      envelope.conversationID !== launch.conversationId || envelope.toolCatalogDigest !== digest) {
    throw new Error('The approved NanoCAD connection did not match the request.');
  }
  return envelope;
}
export function createMemoryStorage() {
  const values = new Map();
  return { getItem: key => values.get(key) ?? null, setItem: (key,value) => values.set(key,String(value)),
    removeItem: key => values.delete(key), clear: () => values.clear(), snapshots: () => [...values.values()] };
}
