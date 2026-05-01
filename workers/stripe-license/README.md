# VidDL Stripe License Worker

Cloudflare Worker backend for VidDL Pro.

See `../../docs/STRIPE_PRO_LICENSE.md` for the current production IDs, checkout flow, deployment notes, and verification checklist.

## Setup

1. Create a KV namespace and put its ID in `wrangler.toml`.
2. Set secrets:

```sh
wrangler secret put STRIPE_SECRET_KEY
wrangler secret put STRIPE_WEBHOOK_SECRET
```

3. Confirm `PMVDL_PRO_PRICE_ID` is the active one-time Stripe price.
4. Deploy:

```sh
npm install
npm run deploy
```

5. Add a Stripe webhook endpoint pointing to:

```text
https://<worker-host>/webhook
```

Subscribe to `checkout.session.completed`, `checkout.session.async_payment_succeeded`, and `charge.refunded`.

6. In the app, set `licenseBackendBaseURL` in UserDefaults if the Worker URL differs from the fallback in `LicenseManager`.
