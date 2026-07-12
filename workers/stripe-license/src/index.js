const STRIPE_API_BASE = "https://api.stripe.com/v1";
const FREE_DOWNLOAD_LIMIT = 3;
const TRIAL_RATE_LIMIT = 12;
const MOVE_TOKEN_TTL = 900;
const STRIPE_SIGNATURE_TOLERANCE = 300;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "POST" && url.pathname === "/checkout") {
      return createCheckout(request, env);
    }
    if (request.method === "POST" && url.pathname === "/license/status") {
      return getLicenseStatus(request, env);
    }
    if (request.method === "POST" && url.pathname === "/license/move/request") {
      return requestLicenseMove(request, env);
    }
    if (request.method === "GET" && url.pathname === "/license/move/confirm") {
      return confirmLicenseMove(url, env);
    }
    if (request.method === "POST" && url.pathname === "/trial/sync") {
      return syncTrial(request, env);
    }
    if (request.method === "POST" && url.pathname === "/trial/use") {
      return useTrial(request, env);
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
  const hwid = normalizeHwid(body.hwid);
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
  if (hwid) {
    form.set("metadata[hwid]", hwid);
    form.set("payment_intent_data[metadata][hwid]", hwid);
  }

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

async function getLicenseStatus(request, env) {
  const body = await request.json().catch(() => ({}));
  const email = normalizeEmail(body.email);
  const hwid = normalizeHwid(body.hwid);
  if (!email) {
    return json({ active: false, email: null, status: "inactive" });
  }

  const record = await env.LICENSES.get(email, "json");
  const active = record?.status === "active" && Boolean(hwid) && record.redeemedByHwid === hwid;
  return json({
    active,
    email: active ? email : null,
    status: active ? "active" : "inactive"
  });
}

async function requestLicenseMove(request, env) {
  const body = await request.json().catch(() => ({}));
  const email = normalizeEmail(body.email);
  const hwid = normalizeHwid(body.hwid);
  const rateKey = `move-rate:${await sha256Hex(`${email}|${request.headers.get("CF-Connecting-IP") ?? "unknown"}`)}`;
  if (!(await allowRate(env, rateKey, 3, 900))) {
    return json({ accepted: true });
  }

  if (email && hwid) {
    const record = await env.LICENSES.get(email, "json");
    if (record?.status === "active") {
      const token = randomToken();
      await env.LICENSES.put(`move:${token}`, JSON.stringify({ email, hwid }), { expirationTtl: MOVE_TOKEN_TTL });
      const link = `${new URL(request.url).origin}/license/move/confirm?token=${encodeURIComponent(token)}`;
      await sendMoveEmail(email, link, env);
    }
  }

  return json({ accepted: true });
}

async function confirmLicenseMove(url, env) {
  const token = String(url.searchParams.get("token") ?? "").trim();
  if (!token || token.length > 128) return html("This transfer link is invalid or expired.", 400);

  const key = `move:${token}`;
  const move = await env.LICENSES.get(key, "json");
  if (!move?.email || !move?.hwid) return html("This transfer link is invalid or expired.", 410);
  await env.LICENSES.delete(key);

  const record = await env.LICENSES.get(move.email, "json");
  if (!record || record.status !== "active") return html("This license is no longer active.", 410);
  await env.LICENSES.put(move.email, JSON.stringify({ ...record, redeemedByHwid: move.hwid, updatedAt: new Date().toISOString() }));
  return html(`<p>VidDL Pro was moved to this Mac. Return to VidDL and refresh the license.</p>`);
}

async function sendMoveEmail(email, link, env) {
  if (!env.RESEND_API_KEY || !env.RESEND_FROM_EMAIL) return false;
  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      from: env.RESEND_FROM_EMAIL,
      to: [email],
      subject: "Move your VidDL Pro license",
      html: `<p>Confirm moving VidDL Pro to this Mac:</p><p><a href="${escapeHtml(link)}">Move license</a></p><p>This link expires in 15 minutes.</p>`
    })
  });
  return response.ok;
}

async function syncTrial(request, env) {
  const body = await request.json().catch(() => ({}));
  const hwid = normalizeHwid(body.hwid);
  if (!hwid) return json({ error: "invalid_trial_request" }, 400);
  if (!(await allowRate(env, `trial-rate:${hwid}`, TRIAL_RATE_LIMIT, 60))) return json({ error: "rate_limited" }, 429);

  const now = new Date().toISOString();
  const record = await getTrialRecord(env, hwid, now);
  record.lastSeen = now;
  await putTrialRecord(env, hwid, record);

  const active = await trialHasActiveLicense(env, record);
  return json({
    count: record.count ?? 0,
    isPro: active,
    redeemedEmail: active ? record.redeemedByEmail : null
  });
}

async function useTrial(request, env) {
  const body = await request.json().catch(() => ({}));
  const hwid = normalizeHwid(body.hwid);
  if (!hwid) return json({ error: "invalid_trial_request" }, 400);

  const now = new Date().toISOString();
  const record = await getTrialRecord(env, hwid, now);
  record.lastSeen = now;

  const active = await trialHasActiveLicense(env, record);
  if (active) {
    await putTrialRecord(env, verified.hwid, record);
    return json({
      allowed: true,
      count: record.count ?? 0,
      remaining: FREE_DOWNLOAD_LIMIT,
      isPro: true
    });
  }

  if (!(await allowRate(env, `trial-use-rate:${hwid}`, TRIAL_RATE_LIMIT, 60))) {
    return json({ allowed: false, count: Number(record.count ?? 0), remaining: 0, isPro: false }, 429);
  }

  const count = Number(record.count ?? 0);
  if (count >= FREE_DOWNLOAD_LIMIT) {
    await putTrialRecord(env, verified.hwid, record);
    return json({
      allowed: false,
      count,
      remaining: 0,
      isPro: false
    });
  }

  record.count = count + 1;
  // Cloudflare KV is eventually consistent. A concurrent scripted attacker may squeeze
  // one extra trial use during propagation; that is acceptable for the casual reinstall threat model.
  await putTrialRecord(env, verified.hwid, record);
  return json({
    allowed: true,
    count: record.count,
    remaining: Math.max(0, FREE_DOWNLOAD_LIMIT - record.count),
    isPro: false
  });
}

async function successPage(url, env) {
  const appUrl = `${env.SUCCESS_SCHEME}`;
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
    <p>Your VidDL Pro purchase was received. Return to VidDL to refresh your license.</p>
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
  const verified = await verifyStripeSignature(payload, signature, env.STRIPE_WEBHOOK_SECRET);
  if (!verified.valid) {
    return json({ error: "invalid_signature" }, 400);
  }

  const event = await parseJSON(payload);
  if (!event?.id || verified.timestamp < Math.floor(Date.now() / 1000) - 30 * 24 * 60 * 60) {
    return json({ error: "invalid_event" }, 400);
  }
  const eventKey = `stripe:event:${event.id}`;
  if (await env.LICENSES.get(eventKey)) return json({ received: true, duplicate: true });

  if (event.type === "checkout.session.completed" || event.type === "checkout.session.async_payment_succeeded") {
    await activateFromCheckoutSession(event.data.object, env);
  } else if (event.type === "charge.refunded") {
    await deactivateFromRefund(event.data.object, env);
  }

  await env.LICENSES.put(eventKey, "1", { expirationTtl: 30 * 24 * 60 * 60 });
  return json({ received: true });
}

async function activateFromCheckoutSession(session, env) {
  if (session.payment_status && session.payment_status !== "paid") {
    return;
  }

  const email = normalizeEmail(session.customer_details?.email || session.customer_email || session.metadata?.email);
  const hwid = normalizeHwid(session.metadata?.hwid);
  if (!email) {
    return;
  }

  const record = {
    status: "active",
    email,
    stripeCustomerId: session.customer ?? null,
    stripeCheckoutSessionId: session.id,
    stripePaymentIntentId: session.payment_intent ?? null,
    redeemedByHwid: hwid || null,
    updatedAt: new Date().toISOString()
  };

  await env.LICENSES.put(email, JSON.stringify(record));
  if (session.payment_intent) {
    await env.LICENSES.put(`payment:${session.payment_intent}`, email);
  }
  if (hwid) {
    const now = new Date().toISOString();
    const trial = await getTrialRecord(env, hwid, now);
    trial.redeemedByEmail = email;
    trial.lastSeen = now;
    await putTrialRecord(env, hwid, trial);
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
  const parts = header.split(",").reduce((result, part) => {
    const [key, value] = part.trim().split("=", 2);
    if (key === "v1") result.v1.push(value ?? "");
    else if (key === "t") result.t = value;
    return result;
  }, { t: null, v1: [] });
  const timestamp = Number(parts.t);
  if (!Number.isFinite(timestamp) || Math.abs(Math.floor(Date.now() / 1000) - timestamp) > STRIPE_SIGNATURE_TOLERANCE || !parts.v1.length || !secret) {
    return { valid: false, timestamp };
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
  return { valid: parts.v1.some((candidate) => timingSafeEqual(hex(signature), candidate)), timestamp };
}

function normalizeEmail(email) {
  const value = String(email ?? "").trim().toLowerCase();
  return value.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value) ? value : "";
}

function normalizeHwid(hwid) {
  const value = String(hwid ?? "").trim();
  if (!value || value === "unknown" || value.length > 128 || /[^A-Za-z0-9._:-]/.test(value)) {
    return "";
  }
  return value;
}

async function parseJSON(value) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

async function getTrialRecord(env, hwid, now) {
  const existing = await env.LICENSES.get(`trial:${hwid}`, "json");
  return existing ?? {
    count: 0,
    firstSeen: now,
    lastSeen: now,
    redeemedByEmail: null
  };
}

async function putTrialRecord(env, hwid, record) {
  await env.LICENSES.put(`trial:${hwid}`, JSON.stringify(record));
}

async function allowRate(env, key, limit, ttl) {
  const current = Number(await env.LICENSES.get(key) ?? "0");
  if (current >= limit) return false;
  await env.LICENSES.put(key, String(current + 1), { expirationTtl: ttl });
  return true;
}

function randomToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return base64url(bytes);
}

async function sha256Hex(value) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return hex(digest);
}

async function trialHasActiveLicense(env, trialRecord) {
  const email = normalizeEmail(trialRecord.redeemedByEmail);
  if (!email) {
    return false;
  }
  const license = await env.LICENSES.get(email, "json");
  return license?.status === "active";
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" }
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

function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
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
