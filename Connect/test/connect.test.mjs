import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {APP_ID,APP_ORIGIN,API_ORIGIN,createMemoryStorage,validateEnvelope} from '../src/config.mjs';
import {authorizationCatalog} from '../src/catalog.mjs';
import {envelopeFromSession} from '../src/session.mjs';
const entries=JSON.parse(await readFile(new URL('../../Resources/connect-tool-catalog.json',import.meta.url)));
const catalog=await authorizationCatalog(entries);
const conversation='55bb85f5-ea0f-4374-a221-de3597f1b398';
const envelope={sandboxExecution:true,origin:API_ORIGIN,appID:APP_ID,appOrigin:APP_ORIGIN,grantID:'0x'+'a'.repeat(64),agentID:'agent-fixture',token:'x'.repeat(43),expiresAt:4102444800,conversationID:conversation,toolCatalogDigest:catalog.digest};
test('public Connect SDK matches the native tool contract exactly',()=>{
 assert.equal(catalog.digest,'0xab8780ca9aeab58e676f213b6a1e56a556121029ccafcf2f0cf0848ada68d84e');
 assert.equal(catalog.tools.length,2);
});
test('native handoff rejects wrong app, server, conversation, expired grant and tool approval',()=>{
 for(const change of [{sandboxExecution:false},{appID:'another-app'},{appOrigin:'https://untrusted.example'},{origin:'https://untrusted.example'},{conversationID:crypto.randomUUID()},{expiresAt:1},{toolCatalogDigest:'0x'+'0'.repeat(64)}]) assert.throws(()=>validateEnvelope({...envelope,...change},{conversationId:conversation},catalog.digest));
});
test('only matching hosted SDK session reaches the native bridge',()=>{
 const storage=createMemoryStorage();
 const connection={authorization:'hosted',agentId:envelope.agentID,grant:{id:envelope.grantID,status:'active',expiresAt:envelope.expiresAt,conversationId:conversation,appToolCatalogDigest:catalog.digest,connectors:['chatgpt'],capabilities:['chatgpt','agent.execution.sandbox'],visibility:{finalMessages:true,actionSummaries:true,conversationHistory:true,rawTraces:true}}};
 storage.setItem('fixture',JSON.stringify({token:envelope.token,grantId:envelope.grantID,connection:{agent_id:envelope.agentID,grant:{id:envelope.grantID}}}));
 assert.deepEqual(envelopeFromSession(storage,connection,{conversationId:conversation},catalog.digest),envelope);
 assert.throws(()=>envelopeFromSession(storage,{...connection,agentId:'another'},{conversationId:conversation},catalog.digest));
 assert.throws(()=>envelopeFromSession(storage,{...connection,authorization:'access_key'},{conversationId:conversation},catalog.digest));
 storage.clear();assert.equal(storage.getItem('fixture'),null);
 assert.throws(()=>envelopeFromSession(storage,connection,{conversationId:conversation},catalog.digest));
});
