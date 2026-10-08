"use strict";
/**
 * Microsoft Teams plumbing, adapted from the AVL Help Desk's Teams bot (2026-09-12):
 *   inbound   Microsoft POSTs an activity with `Authorization: Bearer <RS256 JWT>`
 *             (iss https://api.botframework.com, aud = our Bot ID, keys from the OpenID document)
 *   outbound  token: POST https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token (client credentials)
 *             reply: POST {serviceUrl}/v3/conversations/{conversationId}/activities
 */
const crypto = require("node:crypto");

const OPENID_URL = "https://login.botframework.com/v1/.well-known/openidconfiguration";
const ISSUER = "https://api.botframework.com";
const SCOPE = "https://api.botframework.com/.default";
const GLOBAL_SERVICE_URL = "https://smba.trafficmanager.net/teams/";
const CLOCK_SKEW_MS = 5 * 60 * 1000;
const KEYS_TTL_MS = 24 * 3600 * 1000;
/** An unknown `kid` forces one key refresh, then not again for this long, so forged tokens can't make the
 *  relay hammer Microsoft's key endpoint. */
const KEYS_FORCE_COOLDOWN_MS = 60 * 1000;
/** Teams accepts about 28 KB per message; stay under it with room for markup. */
const MAX_MESSAGE_CHARS = 25000;

class RelayError extends Error {
  constructor(status, message) {
    super(message);
    this.name = "RelayError";
    this.status = status;
  }
}

function decodeJwt(token) {
  const parts = String(token).split(".");
  if (parts.length !== 3) throw new Error("not a JWT");
  const header = JSON.parse(Buffer.from(parts[0], "base64url").toString("utf8"));
  const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
  return { header, payload, signature: Buffer.from(parts[2], "base64url"), signingInput: `${parts[0]}.${parts[1]}` };
}

const normalizeUrl = (u) => String(u || "").trim().replace(/\/+$/, "").toLowerCase();

/** Validates the JWT Microsoft attaches to every request it sends to the bot. */
function createJwtVerifier({ appId, fetch = globalThis.fetch, now = () => Date.now(), openIdUrl = OPENID_URL }) {
  let cache = { keys: null, fetchedAt: 0 };
  let lastForcedAt = -Infinity;

  async function loadKeys(force) {
    if (!force && cache.keys && now() - cache.fetchedAt < KEYS_TTL_MS) return cache.keys;
    if (force) {
      if (now() - lastForcedAt < KEYS_FORCE_COOLDOWN_MS) return cache.keys || [];
      lastForcedAt = now();
    }
    const metaRes = await fetch(openIdUrl);
    if (!metaRes.ok) throw new Error(`OpenID metadata fetch failed: ${metaRes.status}`);
    const meta = await metaRes.json();
    const keysRes = await fetch(meta.jwks_uri);
    if (!keysRes.ok) throw new Error(`JWKS fetch failed: ${keysRes.status}`);
    const jwks = await keysRes.json();
    cache = { keys: Array.isArray(jwks.keys) ? jwks.keys : [], fetchedAt: now() };
    return cache.keys;
  }

  async function verify(authHeader, activity) {
    const m = /^Bearer\s+(.+)$/i.exec(String(authHeader || ""));
    if (!m) throw new RelayError(401, "Missing bearer token");
    let jwt;
    try {
      jwt = decodeJwt(m[1].trim());
    } catch {
      throw new RelayError(401, "Malformed token");
    }
    const { header, payload } = jwt;
    if (header.alg !== "RS256") throw new RelayError(401, "Unexpected token algorithm");
    if (payload.iss !== ISSUER) throw new RelayError(401, "Unexpected token issuer");
    const aud = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    if (!aud.includes(appId)) throw new RelayError(401, "Token is not for this bot");
    const t = now();
    if (typeof payload.exp !== "number" || payload.exp * 1000 < t - CLOCK_SKEW_MS) throw new RelayError(401, "Token expired");
    if (typeof payload.nbf === "number" && payload.nbf * 1000 > t + CLOCK_SKEW_MS) throw new RelayError(401, "Token not yet valid");
    const claimedService = payload.serviceurl || payload.serviceUrl;
    if (activity && activity.serviceUrl && claimedService && normalizeUrl(claimedService) !== normalizeUrl(activity.serviceUrl)) {
      throw new RelayError(401, "Token serviceUrl does not match the activity");
    }
    let keys = await loadKeys(false);
    let jwk = keys.find((k) => k.kid === header.kid);
    if (!jwk) {
      keys = await loadKeys(true);
      jwk = keys.find((k) => k.kid === header.kid);
    }
    if (!jwk) throw new RelayError(401, "Unknown signing key");
    let ok = false;
    try {
      const key = crypto.createPublicKey({ key: { kty: jwk.kty, n: jwk.n, e: jwk.e }, format: "jwk" });
      ok = crypto.verify("RSA-SHA256", Buffer.from(jwt.signingInput), key, jwt.signature);
    } catch {
      ok = false;
    }
    if (!ok) throw new RelayError(401, "Bad token signature");
    return payload;
  }

  return { verify, loadKeys };
}

/** Bot -> Bot Framework REST calls with a cached client-credentials token. */
function createConnectorClient({ appId, appPassword, tenantId, fetch = globalThis.fetch, now = () => Date.now() }) {
  let token = null;
  const resolveTenant = () => (typeof tenantId === "function" ? tenantId() : tenantId);

  async function getToken() {
    if (token && token.expiresAt > now() + 60 * 1000) return token.value;
    const tenant = resolveTenant();
    if (!tenant) throw new Error("Teams tenant id unknown yet; it is learned from the first message Teams delivers");
    const url = `https://login.microsoftonline.com/${encodeURIComponent(tenant)}/oauth2/v2.0/token`;
    const body = new URLSearchParams({ grant_type: "client_credentials", client_id: appId, client_secret: appPassword, scope: SCOPE });
    const res = await fetch(url, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: body.toString() });
    const json = await res.json().catch(() => ({}));
    if (!res.ok || !json.access_token) throw new Error(`Teams token request failed: ${res.status} ${json.error_description || json.error || ""}`.trim());
    token = { value: json.access_token, expiresAt: now() + (Number(json.expires_in) || 3600) * 1000 };
    return token.value;
  }

  async function call(serviceUrl, path, body) {
    const bearer = await getToken();
    const url = `${String(serviceUrl || GLOBAL_SERVICE_URL).replace(/\/+$/, "")}/${path}`;
    const res = await fetch(url, { method: "POST", headers: { Authorization: `Bearer ${bearer}`, "Content-Type": "application/json" }, body: JSON.stringify(body) });
    const json = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(`Teams connector POST ${path} failed: ${res.status} ${(json.error && json.error.message) || json.message || ""}`.trim());
    return json;
  }

  return {
    getToken,
    sendToConversation: (serviceUrl, conversationId, activity) => call(serviceUrl, `v3/conversations/${encodeURIComponent(conversationId)}/activities`, activity),
  };
}

/** Strip @mention markup and HTML that Teams puts in message text. */
function cleanText(text) {
  return String(text || "")
    .replace(/<at[^>]*>.*?<\/at>/gi, "")
    .replace(/<\/?(p|div|br|li)[^>]*>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/[ \t]+/g, " ")
    .replace(/\s*\n\s*/g, "\n")
    .trim();
}

function chunk(s, max) {
  const out = [];
  for (let i = 0; i < s.length; i += max) out.push(s.slice(i, i + max));
  return out;
}

/** Split a long markdown answer into messages of at most `max` characters, at paragraph breaks. */
function splitMessage(text, max = MAX_MESSAGE_CHARS) {
  const s = String(text || "").trim();
  if (s.length <= max) return [s];
  const parts = [];
  let current = "";
  for (const para of s.split(/\n\n+/)) {
    for (const piece of para.length > max ? chunk(para, max) : [para]) {
      if (!current) {
        current = piece;
      } else if (current.length + 2 + piece.length <= max) {
        current += `\n\n${piece}`;
      } else {
        parts.push(current);
        current = piece;
      }
    }
  }
  if (current) parts.push(current);
  return parts;
}

module.exports = { RelayError, createJwtVerifier, createConnectorClient, cleanText, splitMessage, decodeJwt, OPENID_URL, ISSUER, SCOPE, GLOBAL_SERVICE_URL, MAX_MESSAGE_CHARS };
