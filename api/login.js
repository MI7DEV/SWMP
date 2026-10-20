const { makeToken, checkPassword, cookieHeader, MAX_AGE, sessionUser } = require("./_session");

module.exports = async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  if (req.method === "GET") {
    const user = sessionUser(req);
    return res.status(user ? 200 : 401).json({ user });
  }
  if (req.method !== "POST") return res.status(405).json({ error: "method" });
  let body = req.body;
  if (typeof body === "string") { try { body = JSON.parse(body); } catch (e) { body = {}; } }
  const user = String((body && body.user) || "").trim().toLowerCase();
  const pass = String((body && body.pass) || "");
  if (!/^[a-z0-9_-]{1,32}$/.test(user) || !pass || !checkPassword(user, pass)) {
    await new Promise((r) => setTimeout(r, 800)); // trava tentativas em série
    return res.status(401).json({ error: "Utilizador ou senha errados" });
  }
  res.setHeader("Set-Cookie", cookieHeader(makeToken(user), MAX_AGE));
  return res.status(200).json({ ok: true, user });
};
