const NX_GAME = "starwarszerocompany";
const NX_BASE = "https://api.nexusmods.com/v1";

export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET");

  // Accept key from request header (avoids query-string exposure in logs/cache/history)
  // Falls back to server-side env var (used when NX_KEY is set on Vercel)
  const headerKey = (req.headers["x-nexus-key"] || "").trim();
  const apiKey = headerKey || process.env.NX_KEY || "";
  const usingEnvKey = !headerKey && !!process.env.NX_KEY;

  if (!apiKey) {
    return res.status(200).json({
      error: "API key obrigatória — é gratuita! Obtém em nexusmods.com → perfil → API Keys.",
      mods: [],
      need_key: true,
      nexus_search: "https://www.nexusmods.com/search/?search_id=mods&q=star+wars+zero+company",
    });
  }

  const headers = {
    apikey: apiKey,
    "User-Agent": "SWMP/0.3 (ZeroCompanyModPortal)",
    Accept: "application/json",
  };

  const endpoints = ["trending", "latest_added", "latest_updated"];
  const seen = new Set();
  const mods = [];

  await Promise.allSettled(
    endpoints.map(async (ep) => {
      try {
        const r = await fetch(`${NX_BASE}/games/${NX_GAME}/mods/${ep}.json`, {
          headers,
        });
        if (!r.ok) return;
        const data = await r.json();
        const batch = Array.isArray(data) ? data : data.mods ?? [];
        for (const m of batch) {
          const id = m.mod_id ?? m.id;
          if (!id || !m.name || seen.has(id)) continue;
          seen.add(id);
          mods.push({
            mod_id: id,
            name: m.name,
            summary: m.summary ?? "",
            description: m.description ?? "",
            picture_url: m.picture_url ?? null,
            endorsement_count: m.endorsement_count ?? 0,
            mod_downloads: m.mod_downloads ?? 0,
            version: m.version ?? "?",
            author: m.author ?? "",
          });
        }
      } catch {}
    })
  );

  mods.sort((a, b) => b.endorsement_count - a.endorsement_count);

  // Only cache when using the shared server-side key; user-supplied keys must not be cached
  if (usingEnvKey) {
    res.setHeader("Cache-Control", "s-maxage=300, stale-while-revalidate=600");
  } else {
    res.setHeader("Cache-Control", "no-store");
  }
  return res.status(200).json({ mods: mods.slice(0, 40) });
}
