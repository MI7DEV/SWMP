/**
 * Devolve mods do Star Wars Zero Company do MegaGames com links ZIP diretos.
 * Usa lista hardcoded + scraping da página de listagem para novos mods.
 * Cached 1 hora no Vercel edge.
 */
const MOD_BASE = "https://megagames.com/mods/";
const LISTING_URL = "https://megagames.com/games/star-wars-zero-company/mod";
const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 SWMP/1.0";

// Slugs conhecidos (obtidos via browser - lista base garantida)
const KNOWN_SLUGS = [
  "star-wars-zero-company-cheaper-actions-mod-v1-3-1",
  "star-wars-zero-company-swift-combat-and-retaliation-mod-v2-2-0",
  "star-wars-zero-company-skip-tutorial-level-and-permadeath-and-beskar-switcher-mod-v1-0",
  "star-wars-zero-company-fast-resonance-mod-v1-0-2",
  "star-wars-zero-company-mission-and-campaign-time-control-mod-v1-0",
  "star-wars-zero-company-all-player-weapon-buff-mod-v1-0",
  "star-wars-zero-company-more-contacts-mod-v1-0",
  "star-wars-zero-company-more-capacitors-mod-v1-0",
  "star-wars-zero-company-upgrade-discounts-and-durations-mod-v2-0",
  "star-wars-zero-company-blackmarket-discounts-mod-v2-0",
  "star-wars-zero-company-operations-tweaks-mod-v5-0",
  "star-wars-zero-company-ultimate-engine-tweaks-anti-stutters-more-performance-lower-latency-better-clarity-lossless-mod-v1-0",
  "star-wars-zero-company-full-customization-mod-mandalorian-padawan-and-more-mod-v1-3",
  "star-wars-zero-company-ue4ss-for-star-wars-zero-company-mod-v1-0",
];

async function fetchText(url) {
  const r = await fetch(url, {
    headers: { "User-Agent": UA, Accept: "text/html" },
    signal: AbortSignal.timeout(8000),
  });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.text();
}

function extractZips(html) {
  const re = /href="(https:\/\/[^"]+\.(?:zip|rar|7z|pak)(?:\?[^"]*)?)"/gi;
  const seen = new Set();
  const zips = [];
  let m;
  while ((m = re.exec(html)) !== null) {
    if (!seen.has(m[1])) { seen.add(m[1]); zips.push(m[1]); }
  }
  return zips;
}

function extractTitle(html) {
  const m = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i);
  return m ? m[1].replace(/<[^>]+>/g, "").trim() : "";
}

function cleanName(title) {
  return title
    .replace(/^Star Wars Zero Company\s*/i, "")
    .replace(/\s+Mod\s+v[\d.]+\s*$/i, "")
    .replace(/\s+v[\d.]+\s*$/i, "")
    .trim();
}

module.exports = async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Cache-Control", "s-maxage=3600, stale-while-revalidate=7200");

  if (req.method === "OPTIONS") {
    res.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
    return res.status(204).end();
  }

  try {
    // Discover new slugs from the listing page (static HTML only)
    const extraSlugs = new Set(KNOWN_SLUGS);
    try {
      const listHtml = await fetchText(LISTING_URL);
      const slugRe = /href="https:\/\/megagames\.com\/mods\/(star-wars-zero-company[^"]+)"/gi;
      let m;
      while ((m = slugRe.exec(listHtml)) !== null) extraSlugs.add(m[1]);
    } catch { /* ignore listing errors, fall back to hardcoded */ }

    const allSlugs = [...extraSlugs];

    // Fetch each mod page in parallel to get ZIP URLs
    const results = await Promise.allSettled(
      allSlugs.map(async (slug) => {
        const pageUrl = MOD_BASE + slug;
        const html = await fetchText(pageUrl);
        const zips = extractZips(html);
        if (!zips.length) return null;
        const title = extractTitle(html);
        return {
          slug,
          page_url: pageUrl,
          name: title || slug.replace(/-/g, " "),
          short_name: cleanName(title || slug.replace(/-/g, " ")),
          zips,
          first_zip: zips[0],
        };
      })
    );

    const mods = results
      .filter((r) => r.status === "fulfilled" && r.value)
      .map((r) => r.value);

    return res.status(200).json({ mods, total: mods.length });
  } catch (e) {
    return res.status(500).json({ error: e.message, mods: [] });
  }
};
