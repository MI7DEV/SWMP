const NX_GAME = "starwarszerocompany";
const NX_BASE = "https://api.nexusmods.com/v1";

export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET");

  const apiKey = process.env.NX_KEY;
  if (!apiKey) {
    return res.status(500).json({ error: "API key not configured", mods: [] });
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

  res.setHeader("Cache-Control", "s-maxage=300, stale-while-revalidate=600");
  return res.status(200).json({ mods: mods.slice(0, 40) });
}
