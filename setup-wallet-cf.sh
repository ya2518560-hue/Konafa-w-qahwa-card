#!/bin/bash
set -e
: "${ISSUER_ID:?اكتب ISSUER_ID}"
: "${CLOUDFLARE_API_TOKEN:?اكتب CLOUDFLARE_API_TOKEN}"
: "${CLOUDFLARE_ACCOUNT_ID:?اكتب CLOUDFLARE_ACCOUNT_ID}"
PROJECT=konafa-w-qahwa
gcloud config set project $PROJECT
echo ">> تفعيل Google Wallet API"
gcloud services enable walletobjects.googleapis.com
SA_NAME=wallet-sa
SA_EMAIL=$SA_NAME@$PROJECT.iam.gserviceaccount.com
gcloud iam service-accounts describe $SA_EMAIL >/dev/null 2>&1 || gcloud iam service-accounts create $SA_NAME --display-name="Wallet issuer"
rm -f key.json
gcloud iam service-accounts keys create key.json --iam-account=$SA_EMAIL
mkdir -p worker && cd worker
cat > index.js <<'EOF_JS'
const enc = new TextEncoder();
const b64u = buf => { const b = new Uint8Array(buf); let s = ""; for (const x of b) s += String.fromCharCode(x); return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""); };
const j64 = o => b64u(enc.encode(JSON.stringify(o)));
let _key;
const getKey = env => _key || (_key = (() => {
  const k = JSON.parse(env.SA_JSON);
  const der = Uint8Array.from(atob(k.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), c => c.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
})());
const sign = async (env, claims) => {
  const h = j64({ alg: "RS256", typ: "JWT" }), p = j64(claims);
  const s = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", await getKey(env), enc.encode(h + "." + p));
  return h + "." + p + "." + b64u(s);
};
const token = async env => {
  const k = JSON.parse(env.SA_JSON), now = Math.floor(Date.now() / 1000);
  const jwt = await sign(env, { iss: k.client_email, scope: "https://www.googleapis.com/auth/wallet_object.issuer", aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600 });
  const r = await fetch("https://oauth2.googleapis.com/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: "grant_type=" + encodeURIComponent("urn:ietf:params:oauth:grant-type:jwt-bearer") + "&assertion=" + jwt });
  return (await r.json()).access_token;
};
const fromFs = f => Object.fromEntries(Object.entries(f).map(([k, v]) => [k, v.stringValue !== undefined ? v.stringValue : v.integerValue !== undefined ? +v.integerValue : v.doubleValue !== undefined ? v.doubleValue : v.booleanValue !== undefined ? v.booleanValue : null]));
const getDoc = async (env, col, id) => {
  const r = await fetch(`https://firestore.googleapis.com/v1/projects/${env.PROJECT}/databases/(default)/documents/${col}/${encodeURIComponent(id)}?key=${env.API_KEY}`);
  if (!r.ok) return null;
  return fromFs((await r.json()).fields || {});
};
const conf = async env => ({ name: "كنافة وقهوة", sub: "أصل النابلسية", need: 10, reward: "كنافة مجانية", ink: "#3b241b", ...(await getDoc(env, "config", "main") || {}) });
const adminEmail = async (env, tok) => {
  const r = await fetch("https://identitytoolkit.googleapis.com/v1/accounts:lookup?key=" + env.API_KEY, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ idToken: tok }) });
  if (!r.ok) return null;
  const j = await r.json();
  return j.users && j.users[0] && (j.users[0].email || "").toLowerCase();
};
const points = (c, f) => ({ label: "الأختام", balance: { string: `${c.stamps || 0} / ${f.need}` } });
const API = "https://walletobjects.googleapis.com/walletobjects/v1/loyaltyObject/";

export default {
  async fetch(req, env) {
    const cors = { "Access-Control-Allow-Origin": env.SITE_URL, "Access-Control-Allow-Headers": "Authorization,Content-Type", "Access-Control-Allow-Methods": "GET,POST,OPTIONS" };
    const out = (o, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    try {
      const u = new URL(req.url), path = u.pathname.replace(/\/+$/, "");
      const CLASS = `${env.ISSUER_ID}.konafa_card`;
      if (path.endsWith("/link")) {
        const id = String(u.searchParams.get("c") || "");
        const c = await getDoc(env, "customers", id);
        if (!c) return out({ error: "no customer" }, 404);
        const f = await conf(env);
        const cls = { id: CLASS, issuerName: f.name, programName: f.sub || f.name, reviewStatus: "UNDER_REVIEW", hexBackgroundColor: f.ink,
          programLogo: { sourceUri: { uri: env.LOGO_URL }, contentDescription: { defaultValue: { language: "ar", value: f.name } } } };
        const obj = { id: `${env.ISSUER_ID}.${id}`, classId: CLASS, state: "ACTIVE", accountId: id, accountName: c.name, loyaltyPoints: points(c, f),
          barcode: { type: "QR_CODE", value: "KQ:" + id, alternateText: c.phone }, textModulesData: [{ header: "الجائزة", body: f.reward }] };
        const jwt = await sign(env, { iss: JSON.parse(env.SA_JSON).client_email, aud: "google", typ: "savetowallet", iat: Math.floor(Date.now() / 1000), origins: [env.SITE_URL], payload: { loyaltyClasses: [cls], loyaltyObjects: [obj] } });
        return out({ url: "https://pay.google.com/gp/v/save/" + jwt });
      }
      if (path.endsWith("/sync")) {
        const em = await adminEmail(env, (req.headers.get("Authorization") || "").replace("Bearer ", ""));
        if (!em || em !== env.ADMIN_EMAIL.toLowerCase()) return out({ error: "forbidden" }, 403);
        const body = await req.json(), id = String(body.c || "");
        const c = await getDoc(env, "customers", id);
        if (!c) return out({ error: "no customer" }, 404);
        const f = await conf(env), at = await token(env), oid = env.ISSUER_ID + "." + id;
        const H = { Authorization: "Bearer " + at, "Content-Type": "application/json" };
        const r = await fetch(API + oid, { method: "PATCH", headers: H, body: JSON.stringify({ loyaltyPoints: points(c, f), accountName: c.name }) });
        if (r.status === 404) return out({ ok: true, saved: false });
        if (!r.ok) return out({ error: "wallet error" }, 502);
        if (body.msg) await fetch(API + oid + "/addMessage", { method: "POST", headers: H, body: JSON.stringify({ message: { header: f.name, body: String(body.msg).slice(0, 300), messageType: "TEXT_AND_NOTIFY" } }) });
        return out({ ok: true, saved: true });
      }
      return out({ error: "not found" }, 404);
    } catch (e) {
      return out({ error: "server error" }, 500);
    }
  },
};
EOF_JS
cat > wrangler.toml <<EOF_TOML
name = "konafa-wallet"
main = "index.js"
compatibility_date = "2024-11-01"
workers_dev = true

[vars]
ISSUER_ID = "$ISSUER_ID"
ADMIN_EMAIL = "ya2518560@gmail.com"
SITE_URL = "https://ya2518560-hue.github.io"
LOGO_URL = "https://ya2518560-hue.github.io/Konafa-w-qahwa-card/logo.png"
PROJECT = "konafa-w-qahwa"
API_KEY = "AIzaSyBQH9qXBtI7KYK_Hh_yx65aPwa7y5_J3vA"
EOF_TOML
echo ">> نشر الدالة على Cloudflare"
npx --yes wrangler@3 deploy
npx --yes wrangler@3 secret put SA_JSON < ../key.json
rm -f ../key.json
echo
echo "=============================="
echo "رابط الدالة هو اللي بينتهي بـ workers.dev (ظاهر فوق). حطه مكان PASTE."
echo "إيميل الـService Account (ضيفه في Wallet Console > Users بصلاحية Developer):"
echo "$SA_EMAIL"
echo "=============================="
