"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { createJwtVerifier, createConnectorClient, cleanText, splitMessage, RelayError } = require("../lib/teams");

const APP_ID = "11111111-2222-3333-4444-555555555555";
const { publicKey, privateKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = publicKey.export({ format: "jwk" });
const KID = "key-1";
const NOW = 1_800_000_000_000;
const SERVICE_URL = "https://smba.trafficmanager.net/amer/";
const ACTIVITY = { serviceUrl: SERVICE_URL };

function sign(payload, { kid = KID, alg = "RS256", key = privateKey } = {}) {
  const enc = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const input = `${enc({ alg, typ: "JWT", kid })}.${enc(payload)}`;
  const sig = crypto.sign("RSA-SHA256", Buffer.from(input), key).toString("base64url");
  return `${input}.${sig}`;
}

function claims(extra = {}) {
  return {
    iss: "https://api.botframework.com",
    aud: APP_ID,
    exp: Math.floor(NOW / 1000) + 600,
    nbf: Math.floor(NOW / 1000) - 60,
    serviceurl: SERVICE_URL,
    ...extra,
  };
}

function fakeFetch(calls = []) {
  return async (url, init) => {
    calls.push({ url: String(url), init });
    const u = String(url);
    if (u.includes("openidconfiguration")) return { ok: true, json: async () => ({ jwks_uri: "https://login.botframework.com/keys" }) };
    if (u.includes("/keys")) return { ok: true, json: async () => ({ keys: [{ kid: KID, kty: jwk.kty, n: jwk.n, e: jwk.e }] }) };
    if (u.includes("oauth2/v2.0/token")) return { ok: true, json: async () => ({ access_token: "tok-1", expires_in: 3600 }) };
    return { ok: true, json: async () => ({ id: "activity-1" }) };
  };
}

test("verifier accepts a token signed by a published key", async () => {
  const v = createJwtVerifier({ appId: APP_ID, fetch: fakeFetch(), now: () => NOW });
  const payload = await v.verify(`Bearer ${sign(claims())}`, ACTIVITY);
  assert.equal(payload.aud, APP_ID);
});

test("verifier rejects wrong audience, expiry, bad signature, unknown key, missing header", async () => {
  const v = createJwtVerifier({ appId: APP_ID, fetch: fakeFetch(), now: () => NOW });
  await assert.rejects(v.verify(`Bearer ${sign(claims({ aud: "other" }))}`, ACTIVITY), (e) => e instanceof RelayError && e.status === 401);
  await assert.rejects(v.verify(`Bearer ${sign(claims({ exp: Math.floor(NOW / 1000) - 3600 }))}`, ACTIVITY), /expired/i);
  const other = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey;
  await assert.rejects(v.verify(`Bearer ${sign(claims(), { key: other })}`, ACTIVITY), /signature/i);
  await assert.rejects(v.verify(`Bearer ${sign(claims(), { kid: "nope" })}`, ACTIVITY), /unknown signing key/i);
  await assert.rejects(v.verify("", ACTIVITY), /bearer/i);
});

test("verifier rejects a serviceUrl claim that differs from the activity", async () => {
  const v = createJwtVerifier({ appId: APP_ID, fetch: fakeFetch(), now: () => NOW });
  await assert.rejects(v.verify(`Bearer ${sign(claims({ serviceurl: "https://evil.example/" }))}`, ACTIVITY), /serviceUrl/i);
});

test("connector caches the token and posts to the conversation", async () => {
  const calls = [];
  const c = createConnectorClient({ appId: APP_ID, appPassword: "pw", tenantId: () => "tenant-1", fetch: fakeFetch(calls), now: () => NOW });
  await c.sendToConversation(SERVICE_URL, "a:1", { type: "message", text: "hi" });
  await c.sendToConversation(SERVICE_URL, "a:1", { type: "typing" });
  assert.equal(calls.filter((x) => x.url.includes("oauth2")).length, 1);
  const post = calls.find((x) => x.url.endsWith("/v3/conversations/a%3A1/activities"));
  assert.ok(post, "posted to the conversation activities path");
  assert.equal(post.init.headers.Authorization, "Bearer tok-1");
  assert.equal(JSON.parse(post.init.body).text, "hi");
});

test("connector needs a tenant before it can get a token", async () => {
  const c = createConnectorClient({ appId: APP_ID, appPassword: "pw", tenantId: () => null, fetch: fakeFetch() });
  await assert.rejects(c.sendToConversation(SERVICE_URL, "a:1", { type: "typing" }), /tenant/i);
});

test("cleanText strips mentions and html", () => {
  assert.equal(cleanText('<at id="0">Hermes</at> what&#39;s <b>new</b>?'), "what's new?");
  assert.equal(cleanText(undefined), "");
});

test("splitMessage keeps paragraphs together under the limit and hard-splits a giant one", () => {
  const paras = Array.from({ length: 6 }, (_, i) => `p${i} ${"x".repeat(40)}`);
  const parts = splitMessage(paras.join("\n\n"), 100);
  assert.ok(parts.length > 1);
  assert.ok(parts.every((p) => p.length <= 100));
  assert.equal(parts.join("\n\n"), paras.join("\n\n"));
  assert.deepEqual(splitMessage("short", 100), ["short"]);
  const giant = splitMessage("z".repeat(250), 100);
  assert.deepEqual(giant.map((p) => p.length), [100, 100, 50]);
});
