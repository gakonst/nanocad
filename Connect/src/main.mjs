import { Client, Dialog, Transport } from 'nanocodex/connect';
import nativeCatalog from '../../Resources/connect-tool-catalog.json';
import { APP_ID, APP_ORIGIN, API_ORIGIN, createMemoryStorage } from './config.mjs';
import { authorizationCatalog } from './catalog.mjs';
import { envelopeFromSession } from './session.mjs';

const bridge = window.webkit?.messageHandlers?.nanocadConnect;
const configuration = window.nanoCADConnectConfiguration;
if (bridge && configuration && location.origin === APP_ORIGIN && location.pathname === '/nanocad-native/') {
  const memory = createMemoryStorage();
  const report = (type, fields={}) => bridge.postMessage({type,attemptID:configuration.attemptID,...fields});
  const connect = async () => {
    try {
      const catalog = await authorizationCatalog(nativeCatalog);
      const client = Client.create({
        appId:APP_ID, appOrigin:APP_ORIGIN, session:memory,
        auth:{challenge:API_ORIGIN+'/v1/connect/auth/challenge',verify:API_ORIGIN+'/v1/connect/auth',
          logout:API_ORIGIN+'/v1/connect/auth/logout',resources:['urn:nanocodex:agent:run','urn:nanocodex:agent:execution:sandbox'],returnToken:true},
        dialog:Dialog.popup({host:APP_ORIGIN+'/connect-dialog/'}), transport:Transport.http(API_ORIGIN),
      });
      const connection=await client.connection.connect({
        authorization:'hosted',permission:'agent.run',conversationId:configuration.conversationID,
        capabilities:{cloudAccounts:{chatgpt:true},agent:{finalMessages:true,actionSummaries:true,conversationHistory:true,rawTraces:true}},
        tools:catalog.tools,
      });
      const credentials=envelopeFromSession(memory,connection,{conversationId:configuration.conversationID},catalog.digest);
      report('connected',{credentials});
    } catch (error) {
      report('error',{code:typeof error?.code==='string' ? error.code : 'connect_failed', message:'The connection was not completed. Please try again.'});
    } finally { memory.clear(); }
  };
  report('ready',{origin:location.origin});
  // Use the public popup protocol in a native WKWebView sheet. No hosted helper or callback URL.
  void connect();
}
