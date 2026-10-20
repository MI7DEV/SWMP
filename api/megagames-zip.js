/**
 * Busca o URL direto do ZIP de um mod no MegaGames.
 * Recebe ?slug=<slug> e faz scraping de UMA página.
 * Timeout curto (10s) é suficiente para uma única página.
 */
module.exports = async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Cache-Control", "s-maxage=3600");

  if (req.method === "OPTIONS") {
    res.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
    return res.status(204).end();
  }

  const slug = (req.query.slug || "").trim().replace(/[^a-z0-9-]/gi, "");
  if (!slug) {
    return res.status(400).json({ error: "slug obrigatório" });
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

    // Extrai todos os links de ZIP/RAR/7z do RocketCDN ou qualquer domínio
    const zipRe = /href="(https?:\/\/[^"]+\.(?:zip|rar|7z|pak)(?:\?[^"]*)?)"/gi;
    const zips = [];
    let m;
    while ((m = zipRe.exec(html)) !== null) {
      const u = m[1];
      if (!zips.includes(u)) zips.push(u);
    }

    if (!zips.length) {
      return res.status(404).json({ error: "Nenhum ZIP encontrado nesta página", page_url: pageUrl });
    }

    // Prefere links do RocketCDN (CDN direto do MegaGames)
    const rocketZips = zips.filter(u => u.includes("rocketcdn") || u.includes("delivery.rocketcdn"));
    const firstZip = rocketZips[0] || zips[0];

    return res.status(200).json({ zip_url: firstZip, all_zips: zips, page_url: pageUrl });
  } catch (e) {
    return res.status(500).json({ error: e.message, page_url: pageUrl });
  }
};
