/**
 * Public front door for the Hermes Teams relay on the assistant Mac mini.
 *
 * Cloudflare terminates HTTPS at https://hermes.northwoodstech.workers.dev and runs this Worker, which forwards
 * only two routes through the Workers VPC binding `UPSTREAM` (riding the Cloudflare Tunnel "engineering-mac"
 * that cloudflared keeps open *outbound* from the mini) to the relay at http://127.0.0.1:8787:
 *   POST /webhooks/teams   Microsoft's Bot Framework delivering Aaron's Teams messages
 *   GET  /health           a liveness check
 * Everything else is 404 here and never reaches the mini. The Worker stamps the secret FRONT_DOOR_KEY
 * (`wrangler secret put FRONT_DOOR_KEY`) so nothing can reach the relay except through this Worker; the relay
 * refuses requests without it. Nothing is stored or authenticated here beyond that: the relay checks Microsoft's
 * signature and the sender. Deploy: ./scripts/deploy-worker.sh (config in cloudflare/wrangler.jsonc).
 */

const DEFAULT_ORIGIN = "http://127.0.0.1:8787";
const DEFAULT_APP_NAME = "Hermes";
const FRONT_DOOR_HEADER = "x-front-door-key";
const HOP_BY_HOP = new Set(["connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade"]);

/** The only (method, path) pairs the door lets through. */
export function allowed(request) {
  const { pathname } = new URL(request.url);
  return (request.method === "POST" && pathname === "/webhooks/teams") || (request.method === "GET" && pathname === "/health");
}

/** Build the request that goes to the relay: same path and query, cleaned headers, streamed body. */
export function buildOriginRequest(request, origin = DEFAULT_ORIGIN, { frontDoorKey = "" } = {}) {
  const url = new URL(request.url);
  const target = new URL(url.pathname + url.search, origin);
  const headers = new Headers();
  for (const [name, value] of request.headers) {
    const key = name.toLowerCase();
    if (HOP_BY_HOP.has(key) || key === "host" || key === "x-real-ip" || key === FRONT_DOOR_HEADER || key.startsWith("cf-") || key.startsWith("x-forwarded-")) continue;
    headers.append(name, value);
  }
  const clientIp = request.headers.get("cf-connecting-ip");
  if (clientIp) headers.set("x-forwarded-for", clientIp);
  headers.set("x-forwarded-proto", "https");
  headers.set("x-forwarded-host", url.host);
  if (frontDoorKey) headers.set(FRONT_DOOR_HEADER, frontDoorKey);
  const init = { method: request.method, headers, redirect: "manual" };
  if (request.method !== "GET" && request.method !== "HEAD" && request.body) {
    init.body = request.body;
    init.duplex = "half";
  }
  return new Request(target, init);
}

function jsonResponse(status, body, extra = {}) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff", ...extra } });
}

export default {
  async fetch(request, env) {
    const appName = (env && env.APP_NAME) || DEFAULT_APP_NAME;
    if (!allowed(request)) return jsonResponse(404, { ok: false, error: "not found" });
    const upstream = env && env.UPSTREAM && typeof env.UPSTREAM.fetch === "function" ? env.UPSTREAM : null;
    if (!upstream) return jsonResponse(503, { ok: false, error: "offline", message: `${appName} is offline right now.` }, { "retry-after": "30" });
    const originRequest = buildOriginRequest(request, (env && env.ORIGIN) || DEFAULT_ORIGIN, { frontDoorKey: (env && env.FRONT_DOOR_KEY) || "" });
    try {
      return await upstream.fetch(originRequest);
    } catch (err) {
      console.log(JSON.stringify({ where: "vpc.fetch", app: appName, message: err && err.message }));
      return jsonResponse(503, { ok: false, error: "offline", message: `${appName} is offline right now.` }, { "retry-after": "30" });
    }
  },
};
