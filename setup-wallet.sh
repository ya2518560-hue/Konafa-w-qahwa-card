#!/bin/bash
set -e
: "${ISSUER_ID:?لازم تكتب ISSUER_ID قبل الأمر}"
PROJECT=konafa-w-qahwa
REGION=europe-west1
export ADMIN_EMAIL="ya2518560@gmail.com"
export SITE_URL="https://ya2518560-hue.github.io"
export LOGO_URL="https://ya2518560-hue.github.io/Konafa-w-qahwa-card/logo.png"
gcloud config set project $PROJECT
echo ">> تفعيل الخدمات"
gcloud services enable walletobjects.googleapis.com cloudfunctions.googleapis.com run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com
SA_NAME=wallet-sa
SA_EMAIL=$SA_NAME@$PROJECT.iam.gserviceaccount.com
gcloud iam service-accounts describe $SA_EMAIL >/dev/null 2>&1 || gcloud iam service-accounts create $SA_NAME --display-name="Wallet issuer"
rm -f key.json
gcloud iam service-accounts keys create key.json --iam-account=$SA_EMAIL
PN=$(gcloud projects describe $PROJECT --format='value(projectNumber)')
gcloud projects add-iam-policy-binding $PROJECT --member="serviceAccount:$PN-compute@developer.gserviceaccount.com" --role="roles/cloudbuild.builds.builder" --quiet >/dev/null || true
mkdir -p wallet && cd wallet
cat > index.js <<'EOF_JS'
const crypto = require("crypto");
const admin = require("firebase-admin");
const { GoogleAuth } = require("google-auth-library");
admin.initializeApp();
const db = admin.firestore();
const KEY = JSON.parse(process.env.SA_JSON);
const ISSUER = process.env.ISSUER_ID, ADMIN = process.env.ADMIN_EMAIL;
const SITE = process.env.SITE_URL, LOGO = process.env.LOGO_URL;
const CLASS = `${ISSUER}.konafa_card`;
const auth = new GoogleAuth({ credentials: KEY, scopes: ["https://www.googleapis.com/auth/wallet_object.issuer"] });
const b64 = x => Buffer.from(x).toString("base64url");

async function cfg() {
  const s = await db.collection("config").doc("main").get();
  return { name: "كنافة وقهوة", sub: "أصل النابلسية", need: 10, reward: "كنافة مجانية", ink: "#3b241b", ...(s.exists ? s.data() : {}) };
}
const points = (c, f) => ({ label: "الأختام", balance: { string: `${c.stamps} / ${f.need}` } });
const obj = (id, c, f) => ({
  id: `${ISSUER}.${id}`, classId: CLASS, state: "ACTIVE", accountId: id, accountName: c.name,
  loyaltyPoints: points(c, f),
  barcode: { type: "QR_CODE", value: "KQ:" + id, alternateText: c.phone },
  textModulesData: [{ header: "الجائزة", body: f.reward }],
});
const cls = f => ({
  id: CLASS, issuerName: f.name, programName: f.sub || f.name, reviewStatus: "UNDER_REVIEW",
  hexBackgroundColor: f.ink,
  programLogo: { sourceUri: { uri: LOGO }, contentDescription: { defaultValue: { language: "ar", value: f.name } } },
});
function sign(payload) {
  const h = b64(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const p = b64(JSON.stringify({ iss: KEY.client_email, aud: "google", typ: "savetowallet", iat: Math.floor(Date.now() / 1000), origins: [SITE], payload }));
  const s = crypto.createSign("RSA-SHA256").update(h + "." + p).sign(KEY.private_key, "base64url");
  return `${h}.${p}.${s}`;
}
const API = "https://walletobjects.googleapis.com/walletobjects/v1/loyaltyObject/";

exports.wallet = async (req, res) => {
  res.set({ "Access-Control-Allow-Origin": SITE, "Access-Control-Allow-Headers": "Authorization,Content-Type", "Access-Control-Allow-Methods": "GET,POST,OPTIONS" });
  if (req.method === "OPTIONS") return res.status(204).send("");
  try {
    const path = req.path.replace(/\/+$/, "");
    if (path.endsWith("/link")) {
      const id = String(req.query.c || "");
      const s = await db.collection("customers").doc(id).get();
      if (!s.exists) return res.status(404).json({ error: "no customer" });
      const f = await cfg();
      return res.json({ url: "https://pay.google.com/gp/v/save/" + sign({ loyaltyClasses: [cls(f)], loyaltyObjects: [obj(id, s.data(), f)] }) });
    }
    if (path.endsWith("/sync")) {
      const u = await admin.auth().verifyIdToken((req.get("Authorization") || "").replace("Bearer ", ""));
      if (u.email !== ADMIN) return res.status(403).json({ error: "forbidden" });
      const id = String((req.body || {}).c || "");
      const s = await db.collection("customers").doc(id).get();
      if (!s.exists) return res.status(404).json({ error: "no customer" });
      const f = await cfg(), c = s.data(), oid = ISSUER + "." + id;
      try {
        await auth.request({ url: API + oid, method: "PATCH", data: { loyaltyPoints: points(c, f), accountName: c.name } });
        const msg = req.body.msg;
        if (msg) await auth.request({ url: API + oid + "/addMessage", method: "POST", data: { message: { header: f.name, body: String(msg).slice(0, 300), messageType: "TEXT_AND_NOTIFY" } } });
        return res.json({ ok: true, saved: true });
      } catch (e) {
        if (e.response && e.response.status === 404) return res.json({ ok: true, saved: false });
        throw e;
      }
    }
    res.status(404).json({ error: "not found" });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "server error" });
  }
};
EOF_JS
cat > package.json <<'EOF_PK'
{
  "name": "wallet",
  "main": "index.js",
  "dependencies": {
    "@google-cloud/functions-framework": "^3.4.0",
    "firebase-admin": "^12.0.0",
    "google-auth-library": "^9.0.0"
  }
}
EOF_PK
python3 - <<'PY' > env.yaml
import json,os
k=json.dumps(json.load(open("../key.json")))
for n in ["ISSUER_ID","ADMIN_EMAIL","SITE_URL","LOGO_URL"]:
    print(n+": "+json.dumps(os.environ[n]))
print("SA_JSON: "+json.dumps(k))
PY
echo ">> نشر الدالة (ياخد 2-4 دقايق)"
gcloud functions deploy wallet --gen2 --runtime=nodejs20 --region=$REGION --source=. --entry-point=wallet --trigger-http --allow-unauthenticated --env-vars-file=env.yaml --quiet
rm -f env.yaml ../key.json
URL=$(gcloud functions describe wallet --gen2 --region=$REGION --format='value(serviceConfig.uri)')
echo
echo "=============================="
echo "رابط الدالة (حطه مكان PASTE في WALLET_URL):"
echo "$URL"
echo
echo "إيميل الـService Account (ضيفه في Wallet Console > Users بصلاحية Developer):"
echo "$SA_EMAIL"
echo "=============================="
