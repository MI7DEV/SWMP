// Sessão do portal: cookie "swmp_s" = "<user>.<expira>.<assinatura HMAC-SHA256>" (assinado com SWMP_SECRET).
// Partilhado entre as funções /api (CommonJS). O middleware.js tem a mesma verificação (Web Crypto).
const crypto = require("crypto");

const COOKIE = "swmp_s";
const MAX_AGE = 60 * 24 * 3600; // 60 dias

function b64url(buf) {
  return Buffer.from(buf).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function sign(payload) {
  return b64url(crypto.createHmac("sha256", process.env.SWMP_SECRET || "").update(payload).digest());
}

function makeToken(user) {
  const payload = `${user}.${Math.floor(Date.now() / 1000) + MAX_AGE}`;
  return `${payload}.${sign(payload)}`;
}

function readCookie(req, name) {
  const raw = req.headers.cookie || "";
  const m = raw.split(/;\s*/).find((c) => c.startsWith(name + "="));
  return m ? decodeURIComponent(m.slice(name.length + 1)) : "";
}

// Devolve o utilizador da sessão ou null
function sessionUser(req) {
  if (!process.env.SWMP_SECRET) return null;
  const tok = readCookie(req, COOKIE);
  const parts = tok.split(".");
  if (parts.length !== 3) return null;
  const [user, exp, sig] = parts;
  const want = sign(`${user}.${exp}`);
  if (sig.length !== want.length || !crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(want))) return null;
  if (Number(exp) < Date.now() / 1000) return null;
  return user;
}

// SWMP_USERS = "user:salt:hash,user2:salt:hash" (PBKDF2-SHA256, 120000 iterações, 32 bytes, hex)
function checkPassword(user, pass) {
  const entry = (process.env.SWMP_USERS || "").split(",").map((s) => s.trim().split(":")).find((e) => e[0] === user);
  if (!entry || entry.length !== 3) return false;
  const got = crypto.pbkdf2Sync(String(pass), entry[1], 120000, 32, "sha256");
  const want = Buffer.from(entry[2], "hex");
  return want.length === got.length && crypto.timingSafeEqual(got, want);
}

function cookieHeader(value, maxAge) {
  return `${COOKIE}=${encodeURIComponent(value)}; Path=/; Max-Age=${maxAge}; HttpOnly; Secure; SameSite=Lax`;
}

module.exports = { COOKIE, MAX_AGE, makeToken, sessionUser, checkPassword, cookieHeader };
