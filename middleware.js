// Portal privado: tudo exige sessão (cookie swmp_s assinado — ver api/_session.js), exceto a página de login
// e o ZIP do UE4SS que o SWMP-Host.exe descarrega sozinho.
export const config = {
  matcher: ["/((?!login\\.html|api/login|favicon\\.ico|mods/UE4SS_v3\\.0\\.1-1181_StarWarsZeroCompany\\.zip).*)"],
};

const enc = new TextEncoder();

function b64url(buf) {
  let s = "";
  new Uint8Array(buf).forEach((b) => { s += String.fromCharCode(b); });
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function valid(token, secret) {
  const parts = (token || "").split(".");
  if (parts.length !== 3 || !secret) return false;
  const [user, exp, sig] = parts;
  if (Number(exp) < Date.now() / 1000) return false;
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const want = b64url(await crypto.subtle.sign("HMAC", key, enc.encode(`${user}.${exp}`)));
  if (want.length !== sig.length) return false;
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= want.charCodeAt(i) ^ sig.charCodeAt(i);
  return diff === 0;
}

export default async function middleware(request) {
  const cookie = request.headers.get("cookie") || "";
  const m = cookie.split(/;\s*/).find((c) => c.startsWith("swmp_s="));
  const token = m ? decodeURIComponent(m.slice(7)) : "";
  if (await valid(token, process.env.SWMP_SECRET)) return; // segue normalmente
  const url = new URL(request.url);
  if (url.pathname.startsWith("/api/") || /\.(json|zip|lua|js)$/i.test(url.pathname)) {
    return new Response(JSON.stringify({ error: "login" }), { status: 401, headers: { "content-type": "application/json" } });
  }
  const to = new URL("/login.html", url);
  to.searchParams.set("next", url.pathname + url.search + url.hash);
  return Response.redirect(to, 302);
}
