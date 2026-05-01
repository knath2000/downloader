const STRIPE_API_BASE = "https://api.stripe.com/v1";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "POST" && url.pathname === "/checkout") {
      return createCheckout(request, env);
    }
    if (request.method === "GET" && url.pathname === "/license") {
      return getLicense(url, env);
    }
    if (request.method === "GET" && url.pathname === "/success") {
      return successPage(url, env);
    }
    if (request.method === "POST" && url.pathname === "/webhook") {
      return handleWebhook(request, env);
    }
    if (request.method === "GET" && url.pathname === "/cancel") {
      return html("Checkout canceled. You can return to VidDL and try again.");
    }

    return json({ error: "Not found" }, 404);
  }
};

async function createCheckout(request, env) {
  const body = await request.json().catch(() => ({}));
  const email = normalizeEmail(body.email);
  if (!email) {
    return json({ error: "email_required" }, 400);
  }

  const successUrl = `${new URL(request.url).origin}/success?session_id={CHECKOUT_SESSION_ID}&email=${encodeURIComponent(email)}`;
  const form = new URLSearchParams();
  form.set("mode", "payment");
  form.set("customer_email", email);
  form.set("line_items[0][price]", env.PMVDL_PRO_PRICE_ID);
  form.set("line_items[0][quantity]", "1");
  form.set("success_url", successUrl);
  form.set("cancel_url", env.CANCEL_URL);
  form.set("metadata[email]", email);
  form.set("payment_intent_data[metadata][email]", email);

  const response = await fetch(`${STRIPE_API_BASE}/checkout/sessions`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
      "Content-Type": "application/x-www-form-urlencoded"
    },
    body: form
  });

  const session = await response.json();
  if (!response.ok) {
    return json({ error: "stripe_checkout_failed", detail: session.error?.message }, 502);
  }

  return json({ url: session.url });
}

async function getLicense(url, env) {
  const email = normalizeEmail(url.searchParams.get("email"));
  if (!email) {
    return json({ active: false, email: null, status: "email_required" }, 400);
  }

  const record = await env.LICENSES.get(email, "json");
  return json({
    active: record?.status === "active",
    email,
    status: record?.status ?? "not_found"
  });
}

async function successPage(url, env) {
  const email = normalizeEmail(url.searchParams.get("email"));
  const appUrl = `${env.SUCCESS_SCHEME}?email=${encodeURIComponent(email)}`;
  const escapedEmail = escapeHtml(email);
  const escapedAppUrl = escapeHtml(appUrl);

  return html(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>VidDL Pro Activated</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0; background: #f6f7f9; color: #111827; }
    main { max-width: 520px; margin: 12vh auto; padding: 32px; background: white; border: 1px solid #e5e7eb; border-radius: 12px; box-shadow: 0 12px 40px rgba(0,0,0,.08); }
    h1 { font-size: 26px; margin: 0 0 12px; }
    p { line-height: 1.5; color: #4b5563; }
    a.button { display: inline-block; margin-top: 16px; padding: 10px 14px; border-radius: 8px; background: #2563eb; color: white; text-decoration: none; font-weight: 600; }
    .email { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; color: #111827; }
  </style>
</head>
<body>
  <main>
    <h1>Payment complete</h1>
    <p>Your VidDL Pro purchase was received${escapedEmail ? ` for <span class="email">${escapedEmail}</span>` : ""}. Return to VidDL to refresh your license.</p>
    <p>If VidDL does not open automatically, click the button below.</p>
    <a class="button" href="${escapedAppUrl}">Open VidDL</a>
  </main>
  <script>
    setTimeout(function () {
      window.location.href = ${JSON.stringify(appUrl)};
    }, 800);
  </script>
</body>
</html>`, 200, "text/html; charset=utf-8");
}

async function handleWebhook(request, env) {
  const payload = await request.text();
  const signature = request.headers.get("Stripe-Signature") ?? "";
  const valid = await verifyStripeSignature(payload, signature, env.STRIPE_WEBHOOK_SECRET);
  if (!valid) {
    return json({ error: "invalid_signature" }, 400);
  }

  const event = JSON.parse(payload);
  if (event.type === "checkout.session.completed" || event.type === "checkout.session.async_payment_succeeded") {
    await activateFromCheckoutSession(event.data.object, env);
  } else if (event.type === "charge.refunded") {
    await deactivateFromRefund(event.data.object, env);
  }

  return json({ received: true });
}

async function activateFromCheckoutSession(session, env) {
  if (session.payment_status && session.payment_status !== "paid") {
    return;
  }

  const email = normalizeEmail(session.customer_details?.email || session.customer_email || session.metadata?.email);
  if (!email) {
    return;
  }

  const record = {
    status: "active",
    email,
    stripeCustomerId: session.customer ?? null,
    stripeCheckoutSessionId: session.id,
    stripePaymentIntentId: session.payment_intent ?? null,
    updatedAt: new Date().toISOString()
  };

  await env.LICENSES.put(email, JSON.stringify(record));
  if (session.payment_intent) {
    await env.LICENSES.put(`payment:${session.payment_intent}`, email);
  }
}

async function deactivateFromRefund(charge, env) {
  if (!charge.refunded && charge.amount_refunded < charge.amount) {
    return;
  }

  let email = normalizeEmail(charge.billing_details?.email || charge.metadata?.email);
  if (!email && charge.payment_intent) {
    email = normalizeEmail(await env.LICENSES.get(`payment:${charge.payment_intent}`));
  }
  if (!email) {
    return;
  }

  const existing = await env.LICENSES.get(email, "json");
  await env.LICENSES.put(email, JSON.stringify({
    ...(existing ?? {}),
    status: "refunded",
    email,
    stripeChargeId: charge.id,
    updatedAt: new Date().toISOString()
  }));
}

async function verifyStripeSignature(payload, header, secret) {
  const parts = Object.fromEntries(header.split(",").map((part) => {
    const [key, value] = part.split("=");
    return [key, value];
  }));
  if (!parts.t || !parts.v1 || !secret) {
    return false;
  }

  const signedPayload = `${parts.t}.${payload}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(signedPayload));
  return timingSafeEqual(hex(signature), parts.v1);
}

function normalizeEmail(email) {
  return String(email ?? "").trim().toLowerCase();
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" }
  });
}

function html(body, status = 200, contentType = "text/plain; charset=utf-8") {
  return new Response(body, {
    status,
    headers: { "Content-Type": contentType }
  });
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function hex(buffer) {
  return [...new Uint8Array(buffer)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) {
    return false;
  }
  let mismatch = 0;
  for (let i = 0; i < a.length; i += 1) {
    mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return mismatch === 0;
}
