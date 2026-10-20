const NX_BASE = "https://api.nexusmods.com/v1";
const NX_GAME = "starwarszerocompany";
const NX_HDRS = {
  "User-Agent": "SWMP/0.3 (ZeroCompanyModPortal)",
  Accept: "application/json",
};

module.exports = async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Cache-Control", "no-store");

  if (req.method === "OPTIONS") {
    res.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type");
    return res.status(204).end();
  }

  const mod_id = (req.query.mod_id || "").trim();
  if (!mod_id || !/^\d+$/.test(mod_id)) {
    return res.status(400).json({ error: "mod_id inválido" });
  }

  const apiKey = (process.env.NX_KEY || "").trim();
  if (!apiKey) {
    return res.status(503).json({ error: "NX_KEY não configurada" });
  }

  const headers = { ...NX_HDRS, apikey: apiKey };

  try {
    // 1. Get file list for this mod
    const filesRes = await fetch(
      `${NX_BASE}/games/${NX_GAME}/mods/${mod_id}/files.json`,
      { headers, signal: AbortSignal.timeout(8000) }
    );
    if (!filesRes.ok) {
      return res.status(filesRes.status).json({ error: `Nexus retornou ${filesRes.status}` });
    }
    const filesData = await filesRes.json();
    const files = filesData.files || filesData;
    if (!files || !files.length) {
      return res.status(404).json({ error: "Nenhum ficheiro encontrado para este mod" });
    }

    // Pick the primary file: MAIN category first, then the file with most downloads
    const mainFile =
      files.find(f => f.category_name === "MAIN") ||
      files.find(f => f.category_name === "Main") ||
      files.sort((a, b) => (b.size || 0) - (a.size || 0))[0];

    const fileId = mainFile.file_id || mainFile.id;

    // 2. Get download link
    const dlRes = await fetch(
      `${NX_BASE}/games/${NX_GAME}/mods/${mod_id}/files/${fileId}/download_link.json`,
      { headers, signal: AbortSignal.timeout(8000) }
    );

    if (dlRes.status === 403 || dlRes.status === 401) {
      // Free account — cannot get CDN link; let local server handle fallback
      return res.status(200).json({
        need_premium: true,
        fallback_url: `https://www.nexusmods.com/${NX_GAME}/mods/${mod_id}?tab=files`,
        file_name: mainFile.file_name || mainFile.name || "mod",
      });
    }

    if (!dlRes.ok) {
      return res.status(dlRes.status).json({ error: `Link de download: HTTP ${dlRes.status}` });
    }

    const links = await dlRes.json();
    const cdnUrl = (links[0] || {}).URI;
    if (!cdnUrl) {
      return res.status(500).json({ error: "URL de download não encontrado na resposta Nexus" });
    }

    return res.status(200).json({
      url: cdnUrl,
      file_name: mainFile.file_name || mainFile.name || "mod",
    });
  } catch (e) {
    return res.status(500).json({ error: e.message });
  }
};
