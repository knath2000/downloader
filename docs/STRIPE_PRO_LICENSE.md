# LustreStudio Pro License

LustreStudio Pro licensing is backed by Stripe Checkout and a Cloudflare Worker.

## Current Production Setup

- Worker URL: `https://pmvdl-license.knath2000.workers.dev`
- Stripe product: `prod_UQHUCYQlL9krzf` (rename its Stripe dashboard display to `LustreStudio Pro` before the next public checkout)
- Active testing price: `price_1TRRmdBlEcaRurIYAXvQkYAL` (`$0.99 USD`, one-time)
- Previous launch price: `price_1TRQveBlEcaRurIYvgK2Sd5P` (`$5.00 USD`, one-time)
- KV namespace binding: `LICENSES`
- KV namespace id: `bafe9f17a7a24cd8b32fd0cfdc4076ca`
- Checkout mode: `payment`
- Canonical app URL scheme: `pmvdl://`

Do not commit Stripe secret keys, webhook secrets, or `.dev.vars`.

## Flow

1. The macOS app posts `{ "email": "user@example.com" }` to `POST /checkout`.
2. The Worker creates a Stripe Checkout Session using `PMVDL_PRO_PRICE_ID`.
3. Stripe redirects to the hosted Worker success page:
   `https://pmvdl-license.knath2000.workers.dev/success?session_id={CHECKOUT_SESSION_ID}&email=...`
4. The success page offers `Open LustreStudio`, linking to:
   `pmvdl://license-success?email=...`
5. The Stripe webhook marks the normalized email active in KV after paid checkout completion.
6. The app refreshes license state through `GET /license?email=...`.

Webhook fulfillment is the source of truth. The success page is only the browser-to-app handoff.

## Lessons Learned

- Stripe Checkout should not directly use a custom scheme as `success_url`; a system browser can show an invalid URL page after payment.
- Use a hosted HTTPS success page first, then expose the custom scheme as a secondary handoff link.
- The app bundle registers `pmvdl`, so Worker and app handlers must use `pmvdl://license-success`, not `viddl://license-success`.
- Existing extraction URLs also use `pmvdl://extract?url=...`; changing app handlers to `pmvdl` preserves that flow.
- Stripe prices are immutable. To change the amount, create a new price and update `PMVDL_PRO_PRICE_ID`.
- `$0.99 USD` is valid because Stripe's USD minimum charge is below that amount.

## Deployment

From `workers/stripe-license`:

```sh
npm install
wrangler secret put STRIPE_SECRET_KEY
wrangler secret put STRIPE_WEBHOOK_SECRET
npm run deploy
```

Current Worker vars live in `workers/stripe-license/wrangler.toml`:

```toml
PMVDL_PRO_PRICE_ID = "price_1TRRmdBlEcaRurIYAXvQkYAL"
SUCCESS_SCHEME = "pmvdl://license-success"
CANCEL_URL = "https://pmvdl-license.knath2000.workers.dev/cancel"
```

To restore the `$5.00` price, set:

```toml
PMVDL_PRO_PRICE_ID = "price_1TRQveBlEcaRurIYvgK2Sd5P"
```

Then deploy the Worker again.

## Verification

Build the macOS app:

```sh
xcodebuild -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug build
```

Check the deployed success page:

```sh
curl -sS 'https://pmvdl-license.knath2000.workers.dev/success?session_id=cs_placeholder&email=test%40example.com' \
  | rg 'pmvdl://license-success|viddl://'
```

Expected:

- `pmvdl://license-success?...` is present.
- `viddl://` is absent.

Create a smoke checkout session:

```sh
curl -sS -X POST 'https://pmvdl-license.knath2000.workers.dev/checkout' \
  -H 'content-type: application/json' \
  --data '{"email":"pmvdl-checkout-smoke@example.com"}'
```

After running the app from Xcode, LaunchServices should register `pmvdl://` for the debug app. The success page's `Open LustreStudio` button should open the app and refresh the license state.
