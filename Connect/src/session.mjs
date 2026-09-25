import { APP_ID, APP_ORIGIN, API_ORIGIN, validateEnvelope } from './config.mjs';

export function envelopeFromSession(storage, connection, launch, digest) {
  const sessions = storage.snapshots().map(value => { try { return JSON.parse(value); } catch { return null; } });
  const candidates = sessions.filter(value => value?.grantId === connection.grant.id);
  if (candidates.length !== 1 || connection.authorization !== 'hosted' || connection.grant.status !== 'active' ||
      connection.grant.conversationId !== launch.conversationId || connection.grant.appToolCatalogDigest !== digest ||
      !connection.grant.connectors.includes('chatgpt') || !connection.grant.capabilities.includes('agent.execution.sandbox') ||
      !['finalMessages', 'actionSummaries', 'conversationHistory', 'rawTraces'].every(field => connection.grant.visibility[field] === true)) {
    throw new Error('The approved NanoCAD connection did not match the request.');
  }
  const session = candidates[0];
  if (session.connection?.agent_id !== connection.agentId || session.connection?.grant?.id !== connection.grant.id) {
    throw new Error('The NanoCAD session did not match the approved connection.');
  }
  return validateEnvelope({
    origin: API_ORIGIN, appID: APP_ID, appOrigin: APP_ORIGIN,
    grantID: connection.grant.id, agentID: connection.agentId, token: session.token,
    expiresAt: connection.grant.expiresAt, conversationID: launch.conversationId,
    toolCatalogDigest: digest, sandboxExecution:true,
  }, launch, digest);
}
