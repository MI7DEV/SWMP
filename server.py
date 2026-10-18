#!/usr/bin/env python3
"""
Zero Company MP — Servidor relay
HOST  → http://localhost:8766
AMIGO → http://<IP_DO_HOST>:8766
"""

import asyncio, json, socket, subprocess, time, threading, shutil, io
import urllib.request, urllib.error, urllib.parse, zipfile, base64, os, re
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
import websockets

RELAY_PORT = 8765
HTTP_PORT  = 8766

# ─── Localizar jogo ───────────────────────────────────────────────────────────

_ROOTS = [
    Path(r"D:\SteamLibrary\steamapps\common\Star Wars Zero Company"),
    Path(r"C:\Program Files (x86)\Steam\steamapps\common\Star Wars Zero Company"),
    Path(r"C:\Program Files\Steam\steamapps\common\Star Wars Zero Company"),
    Path(r"E:\SteamLibrary\steamapps\common\Star Wars Zero Company"),
    Path(r"F:\SteamLibrary\steamapps\common\Star Wars Zero Company"),
]
GAME_ROOT   = next((p for p in _ROOTS if (p / "SWZeroCompany.exe").exists()), None)
WIN64       = (GAME_ROOT / "SWZeroCompany/Binaries/Win64") if GAME_ROOT else None
MOD_DIR     = (WIN64 / "Mods/ZeroCompanyMP") if WIN64 else None
MODS_DIR    = (WIN64 / "Mods") if WIN64 else None
PAK_DIR     = (GAME_ROOT / "SWZeroCompany/Content/Paks/~mods") if GAME_ROOT else None
CMD_FILE    = (MOD_DIR / "mp_command.json") if MOD_DIR else None
RESULT_FILE = (MOD_DIR / "mp_result.json")  if MOD_DIR else None
SYNC_OUT    = (MOD_DIR / "mp_sync_out.json")if MOD_DIR else None
DOWNLOADS   = Path.home() / "Downloads"

# ─── Estado global ────────────────────────────────────────────────────────────

_clients: dict     = {}
_game_running      = False
_explorer_done     = False
_local_ip          = "127.0.0.1"
_install_status    = "pending"
_install_log: list = []
_mod_lists: dict   = {}
_char_split: dict  = {}
_pending_dl: str | None = None   # nome do mod aguardando download manual
_dl_seen: set      = set()       # ficheiros já vistos em Downloads/
_loop              = None         # asyncio event loop (set in main)

# ─── Utilitários ──────────────────────────────────────────────────────────────

def detect_local_ip():
    global _local_ip
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            _local_ip = s.getsockname()[0]
    except Exception:
        pass

def is_game_running() -> bool:
    try:
        out = subprocess.check_output(
            ["tasklist", "/FI", "IMAGENAME eq SWZeroCompany.exe"],
            encoding="utf-8", errors="replace",
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
        return "SWZeroCompany.exe" in out
    except Exception:
        return False

def list_mods() -> list:
    if not MODS_DIR or not MODS_DIR.exists():
        return []
    skip = {"ZeroCompanyMP", "shared", "keybinds"}
    mods = []
    for d in MODS_DIR.iterdir():
        if d.is_dir() and d.name not in skip and (d / "main.lua").exists():
            mods.append(d.name)
    return sorted(mods)

def list_paks() -> list:
    """Lista mods .pak instalados."""
    if not PAK_DIR or not PAK_DIR.exists():
        return []
    return [f.stem for f in PAK_DIR.glob("*_P.pak")]

async def broadcast(msg: dict, only: str | None = None):
    targets = ([_clients[only]] if only and only in _clients
               else list(_clients.values()))
    for ws in targets:
        try:
            await ws.send(json.dumps(msg))
        except Exception:
            pass

# ─── Auto-install (UE4SS + mod) ───────────────────────────────────────────────

async def _ilog(msg: str, c: str = ""):
    _install_log.append((msg, c))
    if "host" in _clients:
        await broadcast({"type": "LOG", "msg": msg, "c": c}, only="host")

def _download_ue4ss(win64: Path):
    api_url = "https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/latest"
    req = urllib.request.Request(api_url, headers={
        "User-Agent": "ZeroCompanyMP/1.0", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        release = json.loads(r.read())
    asset_url = None
    for a in release.get("assets", []):
        n = a["name"].lower()
        if n.endswith(".zip") and "ue4ss" in n and "xinput" not in n and "dev" not in n:
            asset_url = a["browser_download_url"]; break
    if not asset_url:
        raise RuntimeError("Asset UE4SS.zip não encontrado.")
    with urllib.request.urlopen(
            urllib.request.Request(asset_url, headers={"User-Agent": "ZeroCompanyMP/1.0"}),
            timeout=180) as r:
        data = r.read()
    win64.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        names = z.namelist()
        prefix = ""
        tops = {n.split("/")[0] for n in names if n.strip("/")}
        if len(tops) == 1:
            cand = list(tops)[0] + "/"
            if all(n.startswith(cand) or n == cand for n in names):
                prefix = cand
        for member in names:
            rel = member[len(prefix):]
            if not rel or rel.endswith("/"):
                continue
            dst = win64 / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            with z.open(member) as src, open(dst, "wb") as out:
                shutil.copyfileobj(src, out)

def _install_mp_mod(win64: Path, mod_dst: Path):
    mod_src = Path(__file__).parent / "ue4ss_mods" / "ZeroCompanyMP"
    if not mod_src.exists():
        raise RuntimeError(f"Pasta de mod não encontrada: {mod_src}")
    mod_dst.mkdir(parents=True, exist_ok=True)
    for f in mod_src.rglob("*"):
        if f.is_file():
            dst = mod_dst / f.relative_to(mod_src)
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, dst)
    (mod_dst / "enabled.txt").write_text("", encoding="utf-8")
    mods_txt = win64 / "Mods" / "mods.txt"
    entry = "ZeroCompanyMP : 1"
    if mods_txt.exists():
        content = mods_txt.read_text(encoding="utf-8")
        if "ZeroCompanyMP" not in content:
            mods_txt.write_text(content.rstrip() + "\n" + entry + "\n", encoding="utf-8")
    else:
        mods_txt.write_text(entry + "\n", encoding="utf-8")

async def auto_install():
    global _install_status
    if not GAME_ROOT or not WIN64:
        _install_status = "not_needed"
        await _ilog("Jogo não encontrado.", "gold"); return
    _install_status = "running"
    await _ilog("🔧 Verificando instalação...", "blue")
    if not (WIN64 / "dwmapi.dll").exists():
        await _ilog("UE4SS não encontrado — a baixar...", "blue")
        try:
            await asyncio.to_thread(_download_ue4ss, WIN64)
            await _ilog("✓ UE4SS instalado.", "green")
        except Exception as e:
            await _ilog(f"✗ Erro UE4SS: {e}", "red"); _install_status = "failed"; return
    else:
        await _ilog("✓ UE4SS já instalado.", "green")
    if MOD_DIR and not (MOD_DIR / "main.lua").exists():
        await _ilog("A instalar mod ZeroCompanyMP...", "blue")
        try:
            await asyncio.to_thread(_install_mp_mod, WIN64, MOD_DIR)
            await _ilog("✓ Mod instalado.", "green")
        except Exception as e:
            await _ilog(f"✗ Erro mod: {e}", "red"); _install_status = "failed"; return
    else:
        await _ilog("✓ Mod já instalado.", "green")
    _install_status = "done"
    await _ilog("✓ Tudo pronto! Abre o jogo.", "gold")

# ─── Config persistente ───────────────────────────────────────────────────────

CONFIG_FILE = Path(__file__).parent / "config.json"

def _load_config() -> dict:
    try:
        if CONFIG_FILE.exists():
            return json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
    except Exception:
        pass
    return {}

def _save_config(cfg: dict):
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2), encoding="utf-8")

# ─── Nexus Mods ───────────────────────────────────────────────────────────────

_NEXUS_DOMAIN  = "starwarszerocompany"
_nexus_game_id: int | None = None

_NX_HDRS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) ZeroCompanyMP/1.0",
    "Accept":     "application/json",
}

def _nxreq(url, extra_headers=None, timeout=20):
    h = {**_NX_HDRS, **(extra_headers or {})}
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

def _nx_find_game(api_key: str = "") -> dict | None:
    global _nexus_game_id, _NEXUS_DOMAIN
    candidates = [
        "starwarszerocompany",
        "star-wars-zero-company",
        "swzerocompany",
    ]
    extra = {"apikey": api_key} if api_key else {}
    for domain in candidates:
        try:
            g = _nxreq(f"https://api.nexusmods.com/v1/games/{domain}.json", extra)
            _nexus_game_id = g["id"]
            _NEXUS_DOMAIN = g["domain_name"]
            return g
        except Exception:
            continue
    # Fallback: buscar na lista completa de jogos
    if api_key:
        try:
            games = _nxreq("https://api.nexusmods.com/v1/games.json?include_unapproved=0", extra)
            for g in (games if isinstance(games, list) else []):
                name = (g.get("name") or "").lower()
                if "zero company" in name or "zwero" in name:
                    _nexus_game_id = g["id"]
                    _NEXUS_DOMAIN = g["domain_name"]
                    return g
        except Exception:
            pass
    return None

def _nx_top30(api_key: str = "") -> dict:
    """Busca top 30 mods por endorsements via Nexus API."""
    global _nexus_game_id
    if not api_key:
        return {
            "error": ("API key obrigatória — é gratuita!\n"
                      "Obtém em: nexusmods.com → perfil → API Keys → \"Generate\" → copia e cola aqui."),
            "mods": [],
            "need_key": True,
        }

    if _nexus_game_id is None:
        g = _nx_find_game(api_key)
        if g is None:
            return {
                "error": ("Jogo 'Star Wars Zero Company' não encontrado no Nexus Mods.\n"
                          "Pode ainda não ter página pública. "
                          "Experimenta pesquisar em nexusmods.com/search/?search_id=mods&q=zero+company"),
                "mods": [],
                "nexus_search": "https://www.nexusmods.com/search/?search_id=mods&q=star+wars+zero+company",
            }

    extra = {"apikey": api_key}
    # Tentar endpoints de mods ordenados
    mods = []
    for endpoint in ["trending", "latest_added", "latest_updated"]:
        try:
            raw = _nxreq(
                f"https://api.nexusmods.com/v1/games/{_NEXUS_DOMAIN}/mods/{endpoint}.json",
                extra, timeout=20)
            batch = raw if isinstance(raw, list) else raw.get("mods", [])
            for m in batch:
                if not any(x.get("mod_id") == m.get("mod_id") for x in mods):
                    mods.append(m)
        except Exception:
            pass

    if not mods:
        return {
            "error": ("Nenhum mod encontrado para este jogo no Nexus.\n"
                      "O jogo pode ser muito recente ou não ter mods publicados ainda."),
            "mods": [],
            "nexus_search": f"https://www.nexusmods.com/{_NEXUS_DOMAIN}/mods/",
        }

    # Ordenar por endorsements
    mods.sort(key=lambda m: m.get("endorsement_count", 0), reverse=True)

    # Marcar quais já estão instalados
    installed = set(list_mods()) | set(list_paks())
    for m in mods:
        safe = re.sub(r"[^\w\- ]", "", m.get("name", "")).strip()
        m["installed"] = (safe in installed or m.get("name", "") in installed
                          or any(safe.lower() in i.lower() for i in installed))

    return {"mods": mods[:30], "total": len(mods), "game_id": _nexus_game_id,
            "domain": _NEXUS_DOMAIN}

def _nx_mod_files(api_key: str, mod_id: int) -> list:
    url = (f"https://api.nexusmods.com/v1/games/{_NEXUS_DOMAIN}"
           f"/mods/{mod_id}/files.json")
    r = _nxreq(url, {"apikey": api_key})
    return r.get("files", r) if isinstance(r, dict) else r

def _nx_download_link(api_key: str, mod_id: int, file_id: int) -> list:
    url = (f"https://api.nexusmods.com/v1/games/{_NEXUS_DOMAIN}"
           f"/mods/{mod_id}/files/{file_id}/download_link.json")
    return _nxreq(url, {"apikey": api_key})

# ─── Instalação de mods ───────────────────────────────────────────────────────

def _safe_name(name: str) -> str:
    return re.sub(r"[^\w\-]", "_", name).strip("_") or f"mod_{int(time.time())}"

def _add_to_mods_txt(mod_name: str):
    if not MODS_DIR: return
    mods_txt = MODS_DIR / "mods.txt"
    entry = f"{mod_name} : 1"
    if mods_txt.exists():
        content = mods_txt.read_text(encoding="utf-8")
        if mod_name not in content:
            mods_txt.write_text(content.rstrip() + "\n" + entry + "\n", encoding="utf-8")
    else:
        mods_txt.write_text(entry + "\n", encoding="utf-8")

def _extract_zip(data: bytes, mod_name: str) -> str:
    """Extrai um zip para a pasta de mods adequada.
    Detecta automaticamente se é mod Lua (Win64/Mods) ou pak (~mods)."""
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        names = z.namelist()
        # Detectar pasta raiz única
        prefix = ""
        tops = {n.split("/")[0] for n in names if n.strip("/")}
        if len(tops) == 1:
            cand = list(tops)[0] + "/"
            if all(n.startswith(cand) or n == cand for n in names):
                prefix = cand

        # Detetar se é mod pak
        pak_files = [n for n in names if n.endswith("_P.pak") or n.endswith(".pak")]
        lua_files  = [n for n in names if "main.lua" in n]

        safe = _safe_name(mod_name)

        if pak_files and not lua_files:
            # Mod pak → extrai para ~mods/
            if PAK_DIR:
                PAK_DIR.mkdir(parents=True, exist_ok=True)
                for member in pak_files:
                    fname = Path(member).name
                    with z.open(member) as src, open(PAK_DIR / fname, "wb") as out:
                        shutil.copyfileobj(src, out)
                return fname  # return pak filename as identifier
        else:
            # Mod Lua/BP → extrai para Mods/safe/
            if MODS_DIR:
                mod_dst = MODS_DIR / safe
                mod_dst.mkdir(parents=True, exist_ok=True)
                mod_dst_resolved = mod_dst.resolve()
                for member in names:
                    rel = member[len(prefix):]
                    # Reject absolute paths, '..' traversal and directory entries
                    if not rel or rel.endswith("/") or ".." in rel.split("/"):
                        continue
                    dst = (mod_dst / rel).resolve()
                    # Zip Slip protection: must be a descendant of mod_dst
                    try:
                        dst.relative_to(mod_dst_resolved)
                    except ValueError:
                        continue
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    with z.open(member) as src, open(dst, "wb") as out:
                        shutil.copyfileobj(src, out)
                _add_to_mods_txt(safe)
                return safe
    return safe

def _install_from_bytes(data: bytes, name: str) -> str:
    """Instala mod a partir de bytes. Suporta zip."""
    # Detectar formato
    if data[:4] in (b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08"):
        return _extract_zip(data, name)
    # Arquivo pak puro
    if data[:4] == b"\x95\xE2\x1E\xBC" or name.endswith(".pak"):
        if PAK_DIR:
            PAK_DIR.mkdir(parents=True, exist_ok=True)
            safe = _safe_name(name)
            dst = PAK_DIR / (safe + "_P.pak")
            dst.write_bytes(data)
            return dst.name
    raise RuntimeError("Formato não suportado. Instala manualmente via Vortex/MO2.")

def _uninstall_mod(mod_name: str) -> bool:
    # Strict name validation: only alphanumeric, underscore, hyphen; no path chars
    safe = _safe_name(mod_name)
    if not safe or not re.fullmatch(r'[A-Za-z0-9_\-]+', safe):
        return False
    removed = False
    # Lua mod
    if MODS_DIR:
        base = MODS_DIR.resolve()
        mod_path = (MODS_DIR / safe).resolve()
        # Must be a direct child of MODS_DIR — no subdirectory traversal
        if mod_path.parent != base:
            return False
        if mod_path.exists() and mod_path.is_dir():
            shutil.rmtree(mod_path); removed = True
        mods_txt = MODS_DIR / "mods.txt"
        if mods_txt.exists():
            lines = [l for l in mods_txt.read_text(encoding="utf-8").splitlines()
                     if not l.strip().startswith(safe)]
            mods_txt.write_text("\n".join(lines) + "\n", encoding="utf-8")
    # pak mod — only match exact safe name prefix, files only
    if PAK_DIR and safe:
        pak_base = PAK_DIR.resolve()
        for pak in PAK_DIR.glob(f"{safe}*"):
            if pak.is_file() and pak.resolve().parent == pak_base:
                pak.unlink(); removed = True
    return removed

async def _nx_install_ws(ws, mod_id: int, mod_name: str,
                          api_key: str, file_id: int | None):
    """Tenta instalar via API (premium) ou abre browser (free)."""
    global _pending_dl

    if api_key and file_id:
        await ws.send(json.dumps({"type":"LOG","c":"blue",
                                   "msg":f"A baixar '{mod_name}'..."}))
        try:
            links = await asyncio.to_thread(_nx_download_link, api_key, mod_id, file_id)
            dl_url = links[0]["URI"]
            req = urllib.request.Request(dl_url, headers=_NX_HDRS)
            data = await asyncio.to_thread(
                lambda: urllib.request.urlopen(req, timeout=300).read())
            installed_name = await asyncio.to_thread(_install_from_bytes, data, mod_name)
            await ws.send(json.dumps({"type":"NEXUS_INSTALLED","mod_name":installed_name,
                                       "orig_name":mod_name}))
            await ws.send(json.dumps({"type":"LOG","c":"green",
                                       "msg":f"✓ '{mod_name}' instalado!"}))
            return
        except urllib.error.HTTPError as e:
            if e.code not in (403, 401):
                await ws.send(json.dumps({"type":"LOG","c":"red",
                                           "msg":f"Erro download: {e}"}))
                return
            # 403 → conta gratuita → fallback para browser
        except Exception as e:
            await ws.send(json.dumps({"type":"LOG","c":"red","msg":f"Erro: {e}"}))
            return

    # Fallback: abre browser + aguarda download na pasta Downloads
    _pending_dl = mod_name
    nx_url = f"https://www.nexusmods.com/{_NEXUS_DOMAIN}/mods/{mod_id}?tab=files"
    await ws.send(json.dumps({
        "type": "NEXUS_OPEN_BROWSER",
        "url":  nx_url,
        "mod_name": mod_name,
    }))
    await ws.send(json.dumps({"type":"LOG","c":"gold",
                               "msg":f"Página aberta no browser — clica 'Manual Download' no Nexus. Instalo automaticamente quando o ficheiro chegar à pasta Downloads."}))

# ─── Sync de mods (entre jogadores) ──────────────────────────────────────────

def _get_mod_b64(mod_name: str) -> dict:
    mod_path = MODS_DIR / mod_name if MODS_DIR else None
    if not mod_path or not mod_path.exists():
        return {}
    files = {}
    for f in mod_path.rglob("*"):
        if f.is_file():
            rel = str(f.relative_to(mod_path)).replace("\\", "/")
            files[rel] = base64.b64encode(f.read_bytes()).decode()
    return files

def _install_b64(mod_name: str, files: dict):
    if not MODS_DIR: return
    mod_path = MODS_DIR / mod_name
    mod_path.mkdir(parents=True, exist_ok=True)
    for rel, b64 in files.items():
        dst = mod_path / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(base64.b64decode(b64))
    _add_to_mods_txt(mod_name)

async def do_mod_sync():
    if "host" not in _mod_lists or "client" not in _mod_lists:
        return
    host_s   = set(_mod_lists["host"])
    client_s = set(_mod_lists["client"])
    host_only   = host_s - client_s
    client_only = client_s - host_s
    if not host_only and not client_only:
        await broadcast({"type":"MOD_SYNC_RESULT","status":"ok","msg":"Mods iguais ✓"})
        return
    for m in host_only:
        files = await asyncio.to_thread(_get_mod_b64, m)
        await broadcast({"type":"MOD_INSTALL","mod":m,"files":files}, only="client")
    for m in client_only:
        await broadcast({"type":"MOD_REQUEST","mod":m}, only="client")
    await broadcast({"type":"MOD_SYNC_RESULT","status":"syncing",
                     "host_only":list(host_only),"client_only":list(client_only)})

# ─── Divisão de personagens ───────────────────────────────────────────────────

def compute_char_split(unit_count: int, has_mods: bool) -> dict:
    pp = 3 if has_mods or unit_count > 4 else 2
    return {"host":list(range(pp)),"client":list(range(pp,pp*2)),"per_player":pp}

# ─── WebSocket relay ──────────────────────────────────────────────────────────

async def ws_handler(ws):
    global _explorer_done, _char_split, _pending_dl
    role = None
    try:
        raw  = await asyncio.wait_for(ws.recv(), timeout=20)
        data = json.loads(raw)
        role = data.get("role")
        if role not in ("host","client"):
            return
        _clients[role] = ws
        other = "client" if role == "host" else "host"

        await ws.send(json.dumps({
            "type":"STATE","game_running":_game_running,
            "explorer_done":_explorer_done,"local_ip":_local_ip,
            "relay_port":RELAY_PORT,"game_found":GAME_ROOT is not None,
            "friend":other in _clients,"install_status":_install_status,
            "my_mods":list_mods(),"char_split":_char_split,
        }))
        if role == "host":
            for lm,lc in _install_log:
                try: await ws.send(json.dumps({"type":"LOG","msg":lm,"c":lc}))
                except Exception: pass
        if other in _clients:
            await broadcast({"type":"PEER_CONNECTED","role":role})

        async for raw in ws:
            try: msg = json.loads(raw)
            except Exception: continue
            t = msg.get("type","")

            if t == "EXPLORER_START" and role == "host":
                if CMD_FILE:
                    CMD_FILE.parent.mkdir(parents=True, exist_ok=True)
                    CMD_FILE.write_text(json.dumps({"cmd":"explore","ts":time.time()}))
                    await ws.send(json.dumps({"type":"LOG","c":"blue","msg":"Comando enviado ao jogo..."}))
                else:
                    await ws.send(json.dumps({"type":"LOG","c":"gold","msg":"Jogo não encontrado."}))

            elif t == "MOD_LIST":
                _mod_lists[role] = msg.get("mods",[])
                if "host" in _mod_lists and "client" in _mod_lists:
                    await do_mod_sync()

            elif t == "MOD_UPLOAD" and role == "client":
                mn = msg.get("mod"); files = msg.get("files",{})
                if mn and files and MODS_DIR:
                    await asyncio.to_thread(_install_b64, mn, files)
                    await broadcast({"type":"LOG","c":"green","msg":f"✓ Mod '{mn}' instalado no host."},only="host")

            elif t == "NEXUS_INSTALL" and role == "host":
                await _nx_install_ws(ws,
                    int(msg.get("mod_id",0)),
                    msg.get("name","Mod"),
                    msg.get("key",""),
                    int(msg["file_id"]) if msg.get("file_id") else None)

            elif t == "NEXUS_UNINSTALL" and role == "host":
                mn = msg.get("name","")
                if mn:
                    ok = _uninstall_mod(mn)
                    c = "green" if ok else "red"
                    m = f"✓ '{mn}' desinstalado." if ok else f"'{mn}' não encontrado."
                    await ws.send(json.dumps({"type":"LOG","c":c,"msg":m}))
                    if ok: await ws.send(json.dumps({"type":"NEXUS_UNINSTALLED","mod_name":mn}))

            elif t == "NEXUS_GET_FILES" and role == "host":
                api_key = msg.get("key","")
                mod_id  = int(msg.get("mod_id",0))
                try:
                    files = await asyncio.to_thread(_nx_mod_files, api_key, mod_id)
                    await ws.send(json.dumps({"type":"NEXUS_FILES","mod_id":mod_id,"files":files}))
                except Exception as e:
                    await ws.send(json.dumps({"type":"LOG","c":"red","msg":f"Erro ao obter ficheiros: {e}"}))

            elif t == "SYNC_ACTION" and other in _clients:
                await _clients[other].send(json.dumps(msg))

            elif t == "SET_CHAR_SPLIT" and role == "host":
                _char_split = msg.get("split",{})
                await broadcast({"type":"CHAR_SPLIT","split":_char_split})

    except Exception:
        pass
    finally:
        if role:
            _clients.pop(role, None); _mod_lists.pop(role, None)
            await broadcast({"type":"PEER_DISCONNECTED","role":role})

# ─── Watchers ─────────────────────────────────────────────────────────────────

async def watch_explorer():
    global _explorer_done, _char_split
    last = 0.0
    while True:
        await asyncio.sleep(1)
        if not RESULT_FILE or not RESULT_FILE.exists(): continue
        try:
            mtime = RESULT_FILE.stat().st_mtime
            if mtime <= last: continue
            last = mtime
            data = json.loads(RESULT_FILE.read_text(encoding="utf-8"))
            _explorer_done = True
            unit_count = len(data.get("classes",{}).get("units",[]))
            has_mods   = len(list_mods()) > 0
            _char_split = compute_char_split(unit_count or 4, has_mods)
            await broadcast({"type":"EXPLORER_RESULT","data":data,"char_split":_char_split},only="host")
            if CMD_FILE:
                CMD_FILE.write_text(json.dumps({"cmd":"set_split","split":_char_split,"ts":time.time()}))
        except Exception: pass

async def watch_game():
    global _game_running
    while True:
        running = is_game_running()
        if running != _game_running:
            _game_running = running
            await broadcast({"type":"GAME_STATUS","running":running})
        await asyncio.sleep(3)

async def watch_sync_out():
    last = 0.0
    while True:
        await asyncio.sleep(0.5)
        if not SYNC_OUT or not SYNC_OUT.exists(): continue
        try:
            mtime = SYNC_OUT.stat().st_mtime
            if mtime <= last: continue
            last = mtime
            data = json.loads(SYNC_OUT.read_text(encoding="utf-8"))
            if "client" in _clients:
                await _clients["client"].send(json.dumps({"type":"SYNC_ACTION","data":data}))
        except Exception: pass

async def watch_downloads():
    """Deteta novos arquivos na pasta Downloads e instala mods automaticamente."""
    global _pending_dl, _dl_seen
    if not DOWNLOADS.exists():
        return
    # Inicializar conjunto de ficheiros já existentes
    _dl_seen = set(DOWNLOADS.iterdir())

    while True:
        await asyncio.sleep(2)
        try:
            current = set(DOWNLOADS.iterdir())
            new_files = current - _dl_seen
            _dl_seen = current

            for f in new_files:
                if f.suffix.lower() not in (".zip", ".rar", ".7z", ".pak"):
                    continue
                # Notificar sempre (mesmo sem _pending_dl) pois pode ser uma instalação manual
                name = _pending_dl or f.stem
                if "host" not in _clients:
                    continue
                await broadcast({"type":"LOG","c":"blue",
                                  "msg":f"📦 Ficheiro detetado: {f.name} — a instalar..."}, only="host")
                try:
                    if f.suffix.lower() in (".zip",):
                        installed = await asyncio.to_thread(_install_from_bytes, f.read_bytes(), name)
                    elif f.suffix.lower() == ".pak":
                        if PAK_DIR:
                            PAK_DIR.mkdir(parents=True, exist_ok=True)
                            safe = _safe_name(name)
                            dst = PAK_DIR / (safe + "_P.pak")
                            shutil.copy2(f, dst)
                            installed = dst.name
                    else:
                        await broadcast({"type":"LOG","c":"gold",
                                          "msg":f"Formato .{f.suffix[1:]} não suportado — instala via Vortex."},only="host")
                        continue

                    await broadcast({"type":"NEXUS_INSTALLED","mod_name":installed,
                                      "orig_name":_pending_dl or f.stem}, only="host")
                    await broadcast({"type":"LOG","c":"green",
                                      "msg":f"✓ '{installed}' instalado!"}, only="host")
                    _pending_dl = None
                except Exception as e:
                    await broadcast({"type":"LOG","c":"red",
                                      "msg":f"Erro ao instalar {f.name}: {e}"}, only="host")
        except Exception:
            pass

# ─── HTTP ─────────────────────────────────────────────────────────────────────

_THIS = Path(__file__).parent

class _HTTP(BaseHTTPRequestHandler):
    def do_GET(self):
        from_local = self.client_address[0] in ("127.0.0.1","::1")
        raw_path   = self.path
        path       = raw_path.split("?")[0]
        params: dict = {}
        if "?" in raw_path:
            for part in raw_path.split("?",1)[1].split("&"):
                if "=" in part:
                    k,v = part.split("=",1)
                    params[urllib.parse.unquote_plus(k)] = urllib.parse.unquote_plus(v)

        if path == "/api/info":
            info: dict = {
                "local_ip":_local_ip,"relay_port":RELAY_PORT,
                "game_running":_game_running,"game_found":GAME_ROOT is not None,
                "explorer_done":_explorer_done,"install_status":_install_status,
                "my_mods":list_mods(),"pak_mods":list_paks(),
            }
            if from_local:
                info["install_log"] = _install_log[-12:]
            body = json.dumps(info).encode()
            return self._reply(200,"application/json", body)

        if path == "/api/config":
            cfg = _load_config()
            # Não expor a key completa — só confirmar se existe
            body = json.dumps({"has_key": bool(cfg.get("nx_key")), "domain": cfg.get("nx_domain","")}).encode()
            return self._reply(200,"application/json", body)

        if path == "/api/save-key":
            key = params.get("k","").strip()
            if key and len(key) > 20:
                cfg = _load_config()
                cfg["nx_key"] = key
                _save_config(cfg)
                body = b'{"status":"ok"}'
            else:
                body = b'{"status":"error","msg":"key invalida"}'
            return self._reply(200,"application/json", body)

        if path == "/api/nexus/browse":
            try:
                api_key = params.get("key", "").strip() or _load_config().get("nx_key", "")
                body = json.dumps(_nx_top30(api_key)).encode()
                return self._reply(200,"application/json", body)
            except Exception as e:
                return self._reply(500,"application/json",
                                   json.dumps({"error":str(e),"mods":[]}).encode())

        if path == "/api/nexus/installed":
            body = json.dumps({"mods":list_mods(),"paks":list_paks()}).encode()
            return self._reply(200,"application/json", body)

        if path == "/api/install-log":
            if not from_local:
                return self._reply(403,"application/json", b'{"error":"forbidden"}')
            body = json.dumps({"log": _install_log, "status": _install_status}).encode()
            return self._reply(200,"application/json", body)

        if path == "/api/nexus/install-start":
            if not from_local:
                return self._reply(403,"application/json", b'{"error":"forbidden"}')
            id_str = params.get("id","0")
            if not id_str.isdigit():
                return self._reply(400,"application/json", b'{"error":"bad id"}')
            mod_id = int(id_str)
            mod_name = params.get("name","Mod")[:100]
            if _loop is not None:
                asyncio.run_coroutine_threadsafe(_nx_install_http(mod_id, mod_name), _loop)
                return self._reply(200,"application/json", b'{"status":"started"}')
            return self._reply(503,"application/json", b'{"error":"loop not ready"}')

        if path == "/api/nexus/uninstall":
            name = params.get("name","")
            if name:
                ok = _uninstall_mod(name)
                body = json.dumps({"status":"ok" if ok else "not_found"}).encode()
            else:
                body = b'{"status":"error","msg":"name required"}'
            return self._reply(200,"application/json", body)

        # Páginas HTML
        if from_local or "mode=host" in raw_path:
            f = _THIS / "host.html"
        else:
            f = _THIS / "client.html"
        if f.exists():
            self._reply(200,"text/html; charset=utf-8", f.read_bytes())
        else:
            self._reply(404,"text/plain", b"not found")

    def _reply(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", len(body))
        self.send_header("Access-Control-Allow-Origin","*")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass

def _run_http():
    HTTPServer(("0.0.0.0", HTTP_PORT), _HTTP).serve_forever()

# ─── Entry point ──────────────────────────────────────────────────────────────

class _MockWS:
    """Fake WebSocket that routes messages to _install_log via _ilog."""
    async def send(self, msg_json: str):
        try:
            msg = json.loads(msg_json)
            t = msg.get("type", "")
            if t == "LOG":
                await _ilog(msg.get("msg", ""), msg.get("c", ""))
            elif t == "NEXUS_INSTALLED":
                await _ilog(f"✓ '{msg.get('orig_name','')}' instalado.", "green")
            elif t == "NEXUS_OPEN_BROWSER":
                import webbrowser
                webbrowser.open(msg.get("url", ""))
                await _ilog(msg.get("msg", "Abre o browser para download manual."), "gold")
        except Exception:
            pass


async def _nx_install_http(mod_id: int, mod_name: str):
    """Install a Nexus mod triggered from the HTTP API (no WebSocket)."""
    api_key = _load_config().get("nx_key", "")
    file_id = None
    if api_key:
        try:
            files = await asyncio.to_thread(_nx_mod_files, api_key, mod_id)
            main_file = next(
                (f for f in files if f.get("category_name") in ("MAIN", "Main")),
                files[0] if files else None,
            )
            if main_file:
                file_id = main_file.get("file_id") or main_file.get("id")
        except Exception as e:
            await _ilog(f"Não foi possível listar ficheiros: {e}", "red")
    await _nx_install_ws(_MockWS(), mod_id, mod_name, api_key, file_id)


async def main():
    global _loop
    _loop = asyncio.get_running_loop()
    detect_local_ip()
    threading.Thread(target=_run_http, daemon=True).start()
    print(f"\n{'='*52}\n  Zero Company MP\n{'='*52}")
    if GAME_ROOT: print(f"  Jogo: {GAME_ROOT}")
    else: print("  AVISO: jogo não encontrado")
    print(f"  HOST  → http://localhost:{HTTP_PORT}")
    print(f"  AMIGO → http://{_local_ip}:{HTTP_PORT}")
    print(f"{'='*52}\n")

    # Pre-descobrir o game ID do Nexus em background
    threading.Thread(target=_nx_find_game, daemon=True).start()

    async with websockets.serve(ws_handler, "0.0.0.0", RELAY_PORT):
        asyncio.create_task(auto_install())
        await asyncio.gather(
            watch_explorer(), watch_game(), watch_sync_out(), watch_downloads()
        )

if __name__ == "__main__":
    asyncio.run(main())
