module.exports = function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Cache-Control", "no-store");
  res.status(200).json({ ok: true, checks: [{ label: "Portal SWMP", ok: true }] });
};
