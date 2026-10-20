/**
 * Busca o URL direto do ZIP de um mod no MegaGames.
 * Recebe ?slug=<slug> (deve estar na KNOWN_SLUGS) e faz scraping de UMA página.
 */

// Slugs válidos — mesma lista de megagames-mods.js; slug não listado é rejeitado.
const KNOWN_SLUGS = new Set([
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
]);

// Hostnames permitidos para URLs de download
const ALLOWED_DOWNLOAD_HOSTS = new Set([
  "megagames.com",
  "www.megagames.com",
  "618b31e8.delivery.rocketcdn.me",
]);

function isSafeDownloadUrl(raw) {
  try {
    const u = new URL(raw);
    if (u.protocol !== "https:") return false;
    if (!ALLOWED_DOWNLOAD_HOSTS.has(u.hostname)) return false;
    if (!/\.(zip|rar|7z|pak)(\?|$)/i.test(u.pathname + u.search)) return false;
    return true;
  } catch {
    return false;
  }
}

module.exports = async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Cache-Control", "s-maxage=3600");

  if (req.method === "OPTIONS") {
    res.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
    return res.status(204).end();
  }

  const slug = (req.query.slug || "").trim();
  if (!slug || !KNOWN_SLUGS.has(slug)) {
    return res.status(400).json({ error: "slug inválido ou não reconhecido" });
  }

  const pageUrl = `https://megagames.com/mods/${slug}`;

  try {
    const pageRes = await fetch(pageUrl, {
      headers: {
        "User-Agent":
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
        Accept: "text/html,application/xhtml+xml",
        "Accept-Language": "en-US,en;q=0.9",
      },
      signal: AbortSignal.timeout(12000),
    });

    if (!pageRes.ok) {
      return res.status(pageRes.status).json({ error: `MegaGames retornou HTTP ${pageRes.status}` });
    }

    const html = await pageRes.text();

    // Extrai candidatos a ZIP/RAR/7z/pak do HTML
    const zipRe = /href="(https?:\/\/[^"<>\s]+\.(?:zip|rar|7z|pak)(?:\?[^"<>\s]*)?)"/gi;
    const zips = [];
    let m;
    while ((m = zipRe.exec(html)) !== null) {
      const u = m[1];
      if (isSafeDownloadUrl(u) && !zips.includes(u)) zips.push(u);
    }

    if (!zips.length) {
      return res.status(404).json({ error: "Nenhum ZIP encontrado nesta página", page_url: pageUrl });
    }

    // Prefere RocketCDN (CDN oficial do MegaGames)
    const rocketZips = zips.filter(u => {
      try { return new URL(u).hostname.endsWith("rocketcdn.me"); } catch { return false; }
    });
    const firstZip = rocketZips[0] || zips[0];

    return res.status(200).json({ zip_url: firstZip, all_zips: zips, page_url: pageUrl });
  } catch (e) {
    return res.status(500).json({ error: e.message, page_url: pageUrl });
  }
};
