/**
 * Scrapes MegaGames for Star Wars Zero Company mods and returns
 * their direct ZIP download URLs (hosted on RocketCDN, no auth needed).
 * Cached 1 hour on Vercel edge.
 */
const LISTING_URL = "https://megagames.com/games/star-wars-zero-company/mod";
const MOD_BASE    = "https://megagames.com/mods/";
const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 SWMP/1.0";

async function fetchText(url) {
  const r = await fetch(url, {
    headers: { "User-Agent": UA, Accept: "text/html" },
    signal: AbortSignal.timeout(12000),
  });
  if (!r.ok) throw new Error(`HTTP ${r.status} for ${url}`);
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

function extractDesc(html) {
  // Try to get first paragraph of article
  const m = html.match(/<article[\s\S]*?<p[^>]*>([\s\S]*?)<\/p>/i);
  return m ? m[1].replace(/<[^>]+>/g, "").trim().slice(0, 200) : "";
}

function cleanName(title) {
  // Remove "Star Wars Zero Company " prefix and version suffix
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
    // 1. Get listing page
    const listHtml = await fetchText(LISTING_URL);

    // 2. Extract mod page slugs
    const slugRe = /href="https:\/\/megagames\.com\/mods\/(star-wars-zero-company[^"]+)"/gi;
    const slugs = new Set();
    let m;
    while ((m = slugRe.exec(listHtml)) !== null) {
      slugs.add(m[1]);
    }

    if (!slugs.size) {
      return res.status(200).json({ mods: [], error: "No mods found on listing page" });
    }

    // 3. Fetch each mod page in parallel
    const results = await Promise.allSettled(
      [...slugs].map(async (slug) => {
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
