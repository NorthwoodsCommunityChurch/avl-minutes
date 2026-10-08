#!/bin/bash
# Deploy the Cloudflare Worker front door (cloudflare/worker.mjs) and check it answers.
#   bash hermes-teams/scripts/deploy-worker.sh
# Needs `npx --yes wrangler@4 login` on this Mac (Aaron's work-email Cloudflare account).
set -euo pipefail
cd "$(dirname "$0")/.."
npx --yes wrangler@4 deploy --config cloudflare/wrangler.jsonc 2>&1 | grep -v "^$" | tail -4
echo "health through the door: $(curl -s --max-time 20 https://hermes.northwoodstech.workers.dev/health || echo "no answer")"
