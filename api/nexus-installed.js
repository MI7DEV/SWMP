module.exports = function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  // Vercel has no access to the local mod folder — return empty list
  res.status(200).json({ mods: [], paks: [] });
}
