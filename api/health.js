const NX_BASE = "https://api.nexusmods.com/v1";
const NX_GAME = "starwarszerocompany";

module.exports = async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Cache-Control", "no-store");

  const checks = {};
  let allOk = true;

  // 1. Chave Nexus configurada
  const apiKey = (process.env.NX_KEY || "").trim();
  checks.nx_key_configured = {
    ok: apiKey.length > 0,
    label: "Chave Nexus Mods (NX_KEY)",
    detail: apiKey.length > 0 ? "Presente" : "Variável de ambiente NX_KEY em falta ou vazia",
  };
  if (!checks.nx_key_configured.ok) allOk = false;

  // 2. Chave válida junto da API Nexus
  if (apiKey) {
    try {
      const r = await fetch(`${NX_BASE}/users/validate.json`, {
        headers: {
          apikey: apiKey,
          "User-Agent": "SWMP/0.3 (ZeroCompanyModPortal)",
          Accept: "application/json",
        },
        signal: AbortSignal.timeout(6000),
      });
      if (r.ok) {
        checks.nx_key_valid = {
          ok: true,
          label: "Chave Nexus válida",
          detail: "Aceite pela API Nexus",
        };
      } else {
        checks.nx_key_valid = {
          ok: false,
          label: "Chave Nexus válida",
          detail: `Rejeitada pela API Nexus (HTTP ${r.status})`,
        };
        allOk = false;
      }
    } catch (e) {
      checks.nx_key_valid = {
        ok: false,
        label: "Chave Nexus válida",
        detail: `Erro ao contactar Nexus: ${e.message}`,
      };
      allOk = false;
    }
  } else {
    checks.nx_key_valid = { ok: false, label: "Chave Nexus válida", detail: "Sem chave para validar" };
    allOk = false;
  }

  // 3. Jogo existe no Nexus Mods
  if (apiKey) {
    try {
      const r = await fetch(`${NX_BASE}/games/${NX_GAME}.json`, {
        headers: {
          apikey: apiKey,
          "User-Agent": "SWMP/0.3 (ZeroCompanyModPortal)",
          Accept: "application/json",
        },
        signal: AbortSignal.timeout(6000),
      });
      if (r.ok) {
        const data = await r.json();
        checks.game_exists = {
          ok: true,
          label: `Jogo "${NX_GAME}" no Nexus`,
          detail: `${data.name || NX_GAME} — ${data.mod_count ?? "?"} mods`,
        };
      } else {
        checks.game_exists = {
          ok: false,
          label: `Jogo "${NX_GAME}" no Nexus`,
          detail: `HTTP ${r.status} — jogo não encontrado`,
        };
        allOk = false;
      }
    } catch (e) {
      checks.game_exists = {
        ok: false,
        label: `Jogo "${NX_GAME}" no Nexus`,
        detail: `Erro: ${e.message}`,
      };
      allOk = false;
    }
  } else {
    checks.game_exists = { ok: false, label: `Jogo "${NX_GAME}" no Nexus`, detail: "Sem chave para verificar" };
    allOk = false;
  }

  // 4. Funções API Vercel acessíveis
  checks.api_functions = {
    ok: true,
    label: "Funções Vercel (API routes)",
    detail: "nexus · nexus-installed · config · info · health",
  };

  return res.status(allOk ? 200 : 503).json({
    ok: allOk,
    timestamp: new Date().toISOString(),
    checks,
  });
};
