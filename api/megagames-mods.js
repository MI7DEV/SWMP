/**
 * Devolve lista de mods Star Wars Zero Company do MegaGames.
 * Lista hardcoded (instantânea) — ZIP URLs buscados on-demand por /api/megagames-zip.
 */
const MODS = [
  { slug: "star-wars-zero-company-cheaper-actions-mod-v1-3-1",         short_name: "Cheaper Actions" },
  { slug: "star-wars-zero-company-swift-combat-and-retaliation-mod-v2-2-0", short_name: "Swift Combat & Retaliation" },
  { slug: "star-wars-zero-company-skip-tutorial-level-and-permadeath-and-beskar-switcher-mod-v1-0", short_name: "Skip Tutorial / Permadeath / Beskar Switcher" },
  { slug: "star-wars-zero-company-fast-resonance-mod-v1-0-2",          short_name: "Fast Resonance" },
  { slug: "star-wars-zero-company-mission-and-campaign-time-control-mod-v1-0", short_name: "Mission & Campaign Time Control" },
  { slug: "star-wars-zero-company-all-player-weapon-buff-mod-v1-0",    short_name: "All Player Weapon Buff" },
  { slug: "star-wars-zero-company-more-contacts-mod-v1-0",             short_name: "More Contacts" },
  { slug: "star-wars-zero-company-more-capacitors-mod-v1-0",           short_name: "More Capacitors" },
  { slug: "star-wars-zero-company-upgrade-discounts-and-durations-mod-v2-0", short_name: "Upgrade Discounts & Durations" },
  { slug: "star-wars-zero-company-blackmarket-discounts-mod-v2-0",     short_name: "Blackmarket Discounts" },
  { slug: "star-wars-zero-company-operations-tweaks-mod-v5-0",         short_name: "Operations Tweaks" },
  { slug: "star-wars-zero-company-ultimate-engine-tweaks-anti-stutters-more-performance-lower-latency-better-clarity-lossless-mod-v1-0", short_name: "Ultimate Engine Tweaks (Anti-Stutter / Performance)" },
  { slug: "star-wars-zero-company-full-customization-mod-mandalorian-padawan-and-more-mod-v1-3", short_name: "Full Customization (Mandalorian, Padawan & More)" },
  { slug: "star-wars-zero-company-ue4ss-for-star-wars-zero-company-mod-v1-0", short_name: "UE4SS Compatibility Build" },
];

module.exports = function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Cache-Control", "s-maxage=86400");
  if (req.method === "OPTIONS") {
    res.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
    return res.status(204).end();
  }
  const mods = MODS.map(m => ({
    ...m,
    page_url: "https://megagames.com/mods/" + m.slug,
  }));
  return res.status(200).json({ mods, total: mods.length });
};
