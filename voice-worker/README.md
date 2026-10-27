# Cenzio voice Worker

Cloudflare Worker that turns a voice transcript into review-only expense drafts through OpenRouter. The OpenRouter key is a Worker secret; the iOS app holds no credential. Nothing is stored or logged.

API: `POST /v1/drafts` (same request and response as the old `mcp-server` `/v1/drafts`, without the bearer token), `GET /health`.

## Deploy

```bash
cd voice-worker
npx wrangler login
npx wrangler deploy
npx wrangler secret put OPENROUTER_API_KEY
```

`deploy` prints the URL (`https://cenzio-voice.<subdomain>.workers.dev`). Put it in `VoiceAPI.endpoint` in `SmartSpend/Integrations/VoiceConnection.swift`.

## Cost protection

- Each client IP gets at most 10 requests a minute (`BURST` binding in `wrangler.toml`).
- Set a monthly **credit limit on the OpenRouter key** (openrouter.ai → Keys). This is the hard cap on spend.
- The endpoint is public; anyone who finds the URL can call it within these limits. App Attest verification is the next step if abuse appears.
