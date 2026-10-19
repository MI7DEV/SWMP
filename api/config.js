export default function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  // On Vercel there is no server-side key storage — always report no key
  res.status(200).json({ has_key: false, domain: "" });
}
