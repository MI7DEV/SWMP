// Entrega um ZIP guardado na release "mods" do repositório privado (só com sessão iniciada).
// O ficheiro passa em streaming: GitHub (com GH_TOKEN) → esta função → browser.
const { Readable } = require("stream");
const { sessionUser } = require("./_session");

const REPO = process.env.SWMP_FILES_REPO || "MI7DEV/SWMP-files";
let assetCache = null, assetCacheAt = 0;

async function gh(path, accept) {
  return fetch(`https://api.github.com/repos/${REPO}${path}`, {
    headers: {
      Authorization: `Bearer ${process.env.GH_TOKEN}`,
      Accept: accept || "application/vnd.github+json",
      "User-Agent": "swmp-portal",
      "X-GitHub-Api-Version": "2022-11-28",
    },
  });
}

async function assets() {
  if (assetCache && Date.now() - assetCacheAt < 5 * 60 * 1000) return assetCache;
  const map = {};
  const r = await gh(`/releases/tags/mods`);
  if (!r.ok) throw new Error("release " + r.status);
  const rel = await r.json();
  for (let page = 1; page < 10; page++) {
    const r2 = await gh(`/releases/${rel.id}/assets?per_page=100&page=${page}`);
    const list = await r2.json();
    list.forEach((a) => { map[a.name] = { id: a.id, size: a.size }; });
    if (list.length < 100) break;
  }
  assetCache = map; assetCacheAt = Date.now();
  return map;
}

module.exports = async function handler(req, res) {
  if (!sessionUser(req)) return res.status(401).json({ error: "login" });
  const f = String((req.query && req.query.f) || "");
  if (!/^[A-Za-z0-9._-]{1,120}\.zip$/.test(f)) return res.status(400).json({ error: "nome" });
  try {
    const a = (await assets())[f];
    if (!a) return res.status(404).json({ error: "não existe" });
    const up = await gh(`/releases/assets/${a.id}`, "application/octet-stream");
    if (!up.ok || !up.body) return res.status(502).json({ error: "github " + up.status });
    res.setHeader("Content-Type", "application/zip");
    res.setHeader("Content-Length", String(a.size));
    res.setHeader("Cache-Control", "private, no-store");
    res.setHeader("Content-Disposition", `attachment; filename="${f}"`);
    res.status(200);
    Readable.fromWeb(up.body).pipe(res);
  } catch (e) {
    res.status(500).json({ error: String(e.message || e) });
  }
};
