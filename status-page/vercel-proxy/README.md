# Vercel front for the status page

Some Spanish ISPs block the Cloudflare IPs that `*.workers.dev` resolves to
(188.114.96.0/24, 188.114.97.0/24 — the LaLiga anti-piracy blocks, worst on match
days). From JP's networks the worker then times out while the rest of the internet
sees it fine.

This folder is a Vercel project (`pipeline-status`, team `benjisops`) that
only rewrites every path to the worker. Vercel fetches the worker from its own
network, so the browser never touches the blocked IPs. The worker's `PUBLIC_ORIGIN`
var (wrangler.jsonc) makes the Google sign-in return to this host, and the same URL is
registered as a redirect URI on the Google OAuth client.

Deploy: `cd status-page/vercel-proxy && vercel --prod --yes --scope benjisops`.
The hosts (Mac, VM) keep posting to the worker directly — only humans use this front.
