-- ZeroCompanyMP/main.lua — v0.18
-- Classes confirmadas via ZCSDK jmap (SWZeroCompany-5.6.1-199049.jmap)
-- Módulo do jogo: BitReactorGame

local JSON_OK, json = pcall(require, "json")
if not JSON_OK then
    -- O UE4SS do jogo não traz biblioteca "json" (por isso os comandos do co-op eram ignorados): JSON mínimo em Lua
    json = {}
    local function skip(s, i) return s:find("[^%s]", i) or #s + 1 end
    local ESC = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
    local function decode_string(s, i)
        local out, j = {}, i + 1
        while true do
            local c = s:sub(j, j)
            if c == "" then error("texto sem fim") end
            if c == '"' then return table.concat(out), j + 1 end
            if c == "\\" then
                local e = s:sub(j + 1, j + 1)
                if e == "u" then out[#out + 1] = utf8.char(tonumber(s:sub(j + 2, j + 5), 16)); j = j + 6
                else out[#out + 1] = ESC[e] or e; j = j + 2 end
            else out[#out + 1] = c; j = j + 1 end
        end
    end
    local decode_value
    decode_value = function(s, i)
        i = skip(s, i)
        local c = s:sub(i, i)
        if c == "{" then
            local t = {}; i = skip(s, i + 1)
            if s:sub(i, i) == "}" then return t, i + 1 end
            while true do
                local k; k, i = decode_string(s, skip(s, i))
                i = skip(s, i) + 1
                t[k], i = decode_value(s, i)
                i = skip(s, i)
                local d = s:sub(i, i); i = i + 1
                if d == "}" then return t, i end
            end
        elseif c == "[" then
            local t = {}; i = skip(s, i + 1)
            if s:sub(i, i) == "]" then return t, i + 1 end
            while true do
                t[#t + 1], i = decode_value(s, i)
                i = skip(s, i)
                local d = s:sub(i, i); i = i + 1
                if d == "]" then return t, i end
            end
        elseif c == '"' then return decode_string(s, i)
        elseif s:sub(i, i + 3) == "true" then return true, i + 4
        elseif s:sub(i, i + 4) == "false" then return false, i + 5
        elseif s:sub(i, i + 3) == "null" then return nil, i + 4
        end
        local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
        if not num then error("JSON inválido na posição " .. i) end
        return tonumber(num), i + #num
    end
    function json.decode(s) return (decode_value(s, 1)) end
    local function enc(v)
        local t = type(v)
        if t == "table" then
            local parts = {}
            if #v > 0 or next(v) == nil then
                for _, x in ipairs(v) do parts[#parts + 1] = enc(x) end
                return "[" .. table.concat(parts, ",") .. "]"
            end
            for k, x in pairs(v) do parts[#parts + 1] = enc(tostring(k)) .. ":" .. enc(x) end
            return "{" .. table.concat(parts, ",") .. "}"
        elseif t == "string" then
            return '"' .. v:gsub('[%c"\\]', function(ch) return string.format("\\u%04x", ch:byte()) end) .. '"'
        elseif t == "number" then
            if v ~= v or v == math.huge or v == -math.huge then return "0" end
            return tostring(v)
        elseif t == "boolean" then return tostring(v)
        end
        return "null"
    end
    function json.encode(v) return enc(v) end
    JSON_OK = true
end
-- caminho completo do script ("@C:\...\main.lua"); short_src é truncado ("...inaries\Win64") e não serve
local MOD_PATH    = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):match("^(.+)[/\\]") or "."
local CMD_FILE    = MOD_PATH .. "\\mp_command.json"
local RESULT_FILE = MOD_PATH .. "\\mp_result.json"
local SYNC_OUT    = MOD_PATH .. "\\mp_sync_out.json"
local SYNC_IN     = MOD_PATH .. "\\mp_sync_in.json"

-- ─── Classes confirmadas pelo jmap ────────────────────────────────────────────
-- /Script/BitReactorGame.TacticalGameState — .CurrentRound (int32), .CurrentTeamTurn (TSubclassOf<UTeamGameFlag>)
-- /Script/BitReactorGame.TurnGroupSubsystem — GetCurrentTurnTeamGameFlag(), IsActorOnCurrentlyActiveTeam()
-- /Game/Game/Core/Blueprints/BP_BrunoFunctionLibrary — :IsPlayerTurn() → {bIsPlayerTurn=bool}
-- /Game/Game/Core/Blueprints/BP_BrunoGameplayMaster — :RequestEndTurn()
-- /Game/Game/GameData/Logic/TurnCoordinator/BP_TacticalTurnCoordinator — .CurrentlyPresentingAbilities
-- /Script/BitReactorGame.BitReactorGameSquad — .SquadMembers (TArray), .PlayerSquad on TacticalGameState

local PLAYER_SQUAD_PROP  = "PlayerSquad"
local SQUAD_MEMBERS_PROP = "SquadMembers"
local GS_CLASS           = "/Script/BitReactorGame.TacticalGameState"

-- ─── Estado local ─────────────────────────────────────────────────────────────
local my_role        = "host"
local my_units       = {}    -- índices das unidades do meu jogador
local split_active   = false
local last_cmd_ts    = 0
local combat_active  = false
local last_round     = -1
local last_team_name = ""
local last_player_turn = nil
local sync_seq       = 0     -- sequência para deduplicação de mensagens
local combat_grace_until = 0 -- até aqui o mod não toca em objetos do jogo (início do combate)
local combat_started_at  = 0 -- os.time() do último TacticalGameState criado

-- ─── IO ───────────────────────────────────────────────────────────────────────
local function read_file(path)
    local f = io.open(path, "r"); if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end

local function write_file(path, s)
    local f = io.open(path, "w"); if not f then return false end
    f:write(s); f:close(); return true
end

local function decode(s)
    if not s or s == "" then return nil end
    if JSON_OK then local ok, v = pcall(json.decode, s); return ok and v or nil end
    return nil
end

local function encode(t)
    if JSON_OK then local ok, v = pcall(json.encode, t); return ok and v or "{}" end
    return "{}"
end

local function valid(obj)
    if obj == nil then return false end
    local ok, result = pcall(function() return obj:IsValid() end)
    return ok and result == true
end

-- ExecuteWithDelay corre numa thread da UE4SS que não é a do jogo; mexer em objetos do jogo daí crasha
-- (crash dump de 20/10: acesso nulo na UE4SS ao entrar em combate). Tudo o que toca no jogo passa por aqui.
local function in_game_thread(fn)
    ExecuteInGameThread(function()
        local ok, err = pcall(fn)
        if not ok then print("[ZeroCompanyMP] Erro: " .. tostring(err)) end
    end)
end

-- ─── Ficheiros pendentes do portal (o Chrome não pode escrever/apagar .dll) ───
-- O portal escreve "<x>.dll.swmp" e lista em mp_pending.json {"rename":[[de,para]],"remove":[...],"rmdir":[...]};
-- caminhos relativos à pasta SWZeroCompany. Aqui, ao arrancar o jogo, faz-se o que o browser não pôde.
local PENDING = MOD_PATH .. "\\mp_pending.json"
local GAME_ROOT = MOD_PATH:match("^(.*)[/\\][Bb]inaries[/\\][Ww]in64[/\\]")
local function game_abs(rel) return GAME_ROOT .. "\\" .. rel:gsub("/", "\\") end

local function process_pending()
    local raw = read_file(PENDING)
    if not raw or raw == "" or not GAME_ROOT then return end
    local ok, p = pcall(json.decode, raw)
    if not ok or type(p) ~= "table" then return end
    local left = { rename = {}, remove = {}, rmdir = {} }
    for _, r in ipairs(p.rename or {}) do
        local from, to = game_abs(r[1]), game_abs(r[2])
        os.remove(to)
        local okr, err = os.rename(from, to)
        if okr then print("[ZeroCompanyMP] Instalado: " .. r[2])
        elseif read_file(from) ~= nil then
            left.rename[#left.rename + 1] = r   -- ainda em uso: tenta no próximo arranque
            print("[ZeroCompanyMP] Pendente (em uso): " .. r[2] .. " — " .. tostring(err))
        end
    end
    for _, rel in ipairs(p.remove or {}) do
        local f = game_abs(rel)
        if read_file(f) ~= nil then
            local okd, err = os.remove(f)
            if okd then print("[ZeroCompanyMP] Removido: " .. rel)
            else left.remove[#left.remove + 1] = rel; print("[ZeroCompanyMP] Pendente (em uso): " .. rel .. " — " .. tostring(err)) end
        end
    end
    for _, rel in ipairs(p.rmdir or {}) do
        os.execute('rmdir /s /q "' .. game_abs(rel) .. '"')
        print("[ZeroCompanyMP] Pasta removida: " .. rel)
    end
    write_file(PENDING, json.encode(left))
end
pcall(process_pending)

-- ─── Detecção de turno (confirmado pelo jmap) ─────────────────────────────────
-- BP_BrunoFunctionLibrary:IsPlayerTurn() → retorna tabela com .bIsPlayerTurn
local function get_turn_state()
    local gs_list = FindAllOf("TacticalGameState")
    if not gs_list or #gs_list == 0 then return nil end
    local gs = gs_list[1]
    if not valid(gs) then return nil end

    local ok_round, round = pcall(function() return gs.CurrentRound end)
    local ok_team,  team  = pcall(function() return gs.CurrentTeamTurn end)
    if not (ok_round and ok_team) then return nil end

    local team_name = "unknown"
    -- no 1.º instante do combate CurrentTeamTurn ainda é nulo: GetFName num objeto nulo crasha a UE4SS
    -- (lê o endereço 0x18 — os crashes de 20/10 às 16:46 e 19:23); o pcall não apanha isto
    if valid(team) then
        local ok_fn, fn = pcall(function() return team:GetFName() end)
        if ok_fn and fn then
            local ok_s, s = pcall(function() return fn:ToString() end)
            if ok_s then team_name = s end
        end
    end

    return {round = round or 0, team_name = team_name}
end

-- BP_BrunoFunctionLibrary:IsPlayerTurn() — confirmado no jmap
-- retorna nil se não disponível, bool se encontrado
local function is_player_turn()
    local libs = FindAllOf("BP_BrunoFunctionLibrary_C")
    if not libs or #libs == 0 then return nil end
    for _, lib in ipairs(libs) do
        if valid(lib) then
            local ok, result = pcall(function() return lib:IsPlayerTurn() end)
            if ok and type(result) == "table" and result.bIsPlayerTurn ~= nil then
                return result.bIsPlayerTurn
            end
        end
    end
    return nil
end

-- ─── Broadcast de estado de turno via mp_sync_out.json ────────────────────────
local function broadcast_turn(ts_state, is_pturn)
    if not combat_active then return end
    sync_seq = sync_seq + 1
    local msg = {
        type     = "TURN_STATE",
        role     = my_role,
        round    = ts_state and ts_state.round or 0,
        team     = ts_state and ts_state.team_name or "unknown",
        is_player_turn = is_pturn,
        my_units = my_units,
        split    = split_active,
        ts       = os.time(),
        seq      = sync_seq,
    }
    write_file(SYNC_OUT, encode(msg))
end

-- ─── Explorer: encontra unidades via TacticalGameState ───────────────────────
local function run_explorer()
    print("[ZeroCompanyMP] Explorer v0.4 iniciando...")
    local classes = {}
    local units = {}
    local raw_lines = {}

    local gs_list = FindAllOf("TacticalGameState")
    if gs_list and #gs_list > 0 then
        for _, gs in ipairs(gs_list) do
            if valid(gs) then
                local gs_name = gs:GetFullName()
                table.insert(raw_lines, "TacticalGameState: " .. gs_name)
                classes.tactical_game_state = gs_name

                -- TacticalGameState.CurrentRound e CurrentTeamTurn (confirmados jmap)
                local ok_r, round = pcall(function() return gs.CurrentRound end)
                if ok_r then table.insert(raw_lines, "CurrentRound: " .. tostring(round)) end

                -- PlayerSquad → SquadMembers
                local ok_squad, squad = pcall(function() return gs[PLAYER_SQUAD_PROP] end)
                if ok_squad and valid(squad) then
                    table.insert(raw_lines, "PlayerSquad: " .. squad:GetFullName())
                    local ok_m, members = pcall(function() return squad[SQUAD_MEMBERS_PROP] end)
                    if ok_m and members ~= nil then
                        local ok_c, count = pcall(function() return members:GetArrayNum() end)
                        if ok_c and count then
                            table.insert(raw_lines, "SquadMembers count: " .. tostring(count))
                            for i = 1, math.min(count, 8) do
                                local ok_u, member = pcall(function() return members[i] end)
                                if ok_u and valid(member) then
                                    local mn = member:GetFullName()
                                    table.insert(units, mn)
                                    table.insert(raw_lines, "Unit[" .. (#units-1) .. "]: " .. mn)
                                end
                            end
                        end
                    end
                else
                    table.insert(raw_lines, "PlayerSquad nao acessivel (nao em combate?)")
                end
                break
            end
        end
    else
        table.insert(raw_lines, "TacticalGameState nao encontrado — abre uma batalha!")
    end

    -- TurnGroupSubsystem (confirmado jmap)
    local tgs = FindAllOf("TurnGroupSubsystem")
    if tgs and #tgs > 0 and valid(tgs[1]) then
        table.insert(raw_lines, "TurnGroupSubsystem: encontrado")
        classes.turn_group_subsystem = tgs[1]:GetFullName()
    end

    -- BP_BrunoFunctionLibrary (confirmado jmap — IsPlayerTurn)
    local bfl = FindAllOf("BP_BrunoFunctionLibrary_C")
    if bfl and #bfl > 0 and valid(bfl[1]) then
        table.insert(raw_lines, "BrunoFunctionLibrary: encontrado")
        classes.bruno_function_library = bfl[1]:GetFullName()
        -- Testar IsPlayerTurn()
        local ok_pt, pt = pcall(function() return bfl[1]:IsPlayerTurn() end)
        if ok_pt then
            table.insert(raw_lines, "IsPlayerTurn() acessivel: " .. tostring(ok_pt))
        end
    end

    -- BP_BrunoGameplayMaster (confirmado jmap — RequestEndTurn)
    local gm = FindAllOf("BP_BrunoGameplayMaster_C")
    if gm and #gm > 0 and valid(gm[1]) then
        table.insert(raw_lines, "BrunoGameplayMaster: encontrado (RequestEndTurn disponivel)")
        classes.bruno_gameplay_master = gm[1]:GetFullName()
    end

    -- ATacticalTurnCoordinator (jmap: CurrentlyPresentingAbilities)
    local ttc = FindAllOf("TacticalTurnCoordinator")
    if not (ttc and #ttc > 0) then ttc = FindAllOf("BP_TacticalTurnCoordinator_C") end
    if ttc and #ttc > 0 and valid(ttc[1]) then
        table.insert(raw_lines, "TacticalTurnCoordinator: encontrado")
        classes.turn_coordinator = ttc[1]:GetFullName()
    end

    classes.units        = units
    classes.game_module  = "BitReactorGame"
    classes.jmap_version = "5.6.1-199049"

    local result = {classes = classes, raw = table.concat(raw_lines, "\n"), ts = os.time()}
    write_file(RESULT_FILE, encode(result))
    print("[ZeroCompanyMP] Explorer: " .. #raw_lines .. " linhas, " .. #units .. " unidades.")
end

-- ─── Split de personagens ─────────────────────────────────────────────────────
local function apply_split(split)
    if not split then return end
    my_units = split[my_role] or {}
    split_active = #my_units > 0
    print("[ZeroCompanyMP] Split: " .. table.concat(my_units, ",") .. " (role=" .. my_role .. ")")
    broadcast_turn(get_turn_state(), is_player_turn())
end

local function is_my_unit(unit_index)
    if not split_active then return true end
    for _, idx in ipairs(my_units) do
        if idx == unit_index then return true end
    end
    return false
end

-- ─── Hook TacticalGameState (detect combate) ─────────────────────────────────
local function register_combat_hooks()
    local ok = pcall(function()
        NotifyOnNewObject(GS_CLASS, function(gs)
            if not valid(gs) then return end
            combat_active = true
            combat_grace_until = os.time() + 6   -- o mapa de combate ainda está a montar objetos
            combat_started_at = os.time()
            print("[ZeroCompanyMP] TacticalGameState: combate ativo.")
            ExecuteWithDelay(7000, function() in_game_thread(function()
                run_explorer()
                broadcast_turn(get_turn_state(), is_player_turn())
            end) end)
        end)
    end)
    if ok then print("[ZeroCompanyMP] Hook TacticalGameState: OK")
    else       print("[ZeroCompanyMP] AVISO: hook TacticalGameState falhou") end

    -- CombatPreparationArea como backup
    pcall(function()
        RegisterHook("/Script/BitReactorGame.CombatPreparationArea:TriggerCombatInit",
            function() combat_active = true end, nil)
    end)
end

-- ─── Poll principal ───────────────────────────────────────────────────────────
local last_sync_ts = 0

local function poll()
    -- Comandos do servidor Python
    local raw = read_file(CMD_FILE)
    if raw then
        local cmd = decode(raw)
        if cmd then
            local ts = cmd.ts or 0
            if ts > last_cmd_ts then
                last_cmd_ts = ts
                print("[ZeroCompanyMP] Cmd: " .. tostring(cmd.cmd))
                if     cmd.cmd == "explore"    then run_explorer()
                elseif cmd.cmd == "set_split"  then apply_split(cmd.split)
                elseif cmd.cmd == "set_role"   then my_role = cmd.role or "host"; apply_split(cmd.split)
                elseif cmd.cmd == "start_sync" then
                    print("[ZeroCompanyMP] Sincronizacao ativada.")
                    broadcast_turn(get_turn_state(), is_player_turn())
                end
            end
        end
    end

    -- Detectar mudança de turno (a cada ~2s durante combate)
    if combat_active then
        local now = os.time()
        if now - last_sync_ts >= 2 then
            last_sync_ts = now
            local ts_state = get_turn_state()
            local is_pturn = is_player_turn()

            local changed = false
            if ts_state then
                if ts_state.round ~= last_round or ts_state.team_name ~= last_team_name then
                    changed = true
                    last_round     = ts_state.round
                    last_team_name = ts_state.team_name
                    print(("[ZeroCompanyMP] Turno: round=%d team=%s player=%s"):format(
                        ts_state.round, ts_state.team_name, tostring(is_pturn)))
                end
            end
            if is_pturn ~= last_player_turn then
                changed = true
                last_player_turn = is_pturn
            end
            if changed then
                broadcast_turn(ts_state, is_pturn)
            end
        end
    end

    -- Acções recebidas do outro jogador
    local syn = read_file(SYNC_IN)
    if syn then
        local action = decode(syn)
        if action and action.ts and action.ts > (last_cmd_ts - 10) then
            if action.type == "TURN_STATE" then
                -- outro jogador reportou estado de turno (informativo)
            elseif action.type and action.type ~= "" then
                print("[ZeroCompanyMP] Acao recebida: " .. tostring(action.type))
            end
        end
    end
end

-- ─── Init ─────────────────────────────────────────────────────────────────────
register_combat_hooks()

ExecuteWithDelay(3000, function() in_game_thread(function()
    print("[ZeroCompanyMP] Verificando estado inicial...")
    local ts_state = get_turn_state()
    if ts_state then
        combat_active = true
        print(("[ZeroCompanyMP] Em combate: round=%d team=%s"):format(
            ts_state.round, ts_state.team_name))
        run_explorer()
    end
end) end)

print("==============================================")
print(" ZeroCompanyMP v0.18 carregado")
print(" Classes: confirmadas via ZCSDK jmap 5.6.1")
print(" IsPlayerTurn: BP_BrunoFunctionLibrary")
print(" RequestEndTurn: BP_BrunoGameplayMaster")
print(" TurnState: TacticalGameState.CurrentRound+CurrentTeamTurn")
print("==============================================")

-- ─── Cena atual (para a trilha sonora dinâmica do portal) ─────────────────────
-- Escreve mp_scene.json: {"scene":"menu|strategy|combat","map":"...","ts":N}
local SCENE_FILE   = MOD_PATH .. "\\mp_scene.json"
local last_scene   = ""
local last_map     = ""
local last_scene_t = 0
local last_track   = ""

local function current_map()
    local ok, name = pcall(function()
        local w = FindFirstOf("World")
        if not valid(w) then return "" end
        return w:GetFullName()
    end)
    return (ok and name) or ""
end

-- Tipo de música que o próprio jogo pediu (BrunoMusicSubSystem:PlayBrunoMusic, EMusicType do SDK)
local MUSIC_TYPES = { [1] = "menu", [2] = "strategy", [3] = "explore", [4] = "combat" }
local game_music  = ""

-- Faixa exata: as playlists (MusicPlaylistAsset) guardam um Cooldown_Counter por faixa; depois de o jogo
-- escolher a música, a faixa escolhida é a única cujo contador muda para o limite (fica em "cooldown").
local game_track = ""
local track_snap = {}

local function track_name(sw)
    if not valid(sw) then return nil end
    local ok, n = pcall(function() return sw:GetFName():ToString() end)
    if not ok or not n then return nil end
    return n:match("%-(.+)$") or n
end

local function scan_tracks()
    local snap = {}
    local list = FindAllOf("MusicPlaylistAsset")
    if not list then return snap end
    for _, a in ipairs(list) do
        local an = valid(a) and a:GetFName():ToString() or nil
        for _, field in ipairs(an and { "CombatMusicPlaylists", "ExploreMusicPlaylists" } or {}) do
            pcall(function()
                a[field]:ForEach(function(i, pl)
                    pl:get().MusicPlaylist:ForEach(function(j, tr)
                        local t = tr:get()
                        local nm = track_name(t.MusicTrackSwitch)
                        if nm then snap[an .. field .. i .. "." .. j] = { name = nm, c = t.Cooldown_Counter, th = t.Cooldown_Threshold } end
                    end)
                end)
            end)
        end
    end
    return snap
end

local function pick_changed_track()
    local now = scan_tracks()
    local found, many = nil, false
    for k, v in pairs(now) do
        local o = track_snap[k]
        if o and o.c ~= v.c then
            print(("[ZeroCompanyMP] Faixa %s: cooldown %s -> %s (limite %s)"):format(v.name, tostring(o.c), tostring(v.c), tostring(v.th)))
            if v.c == v.th or (o.c == 0 and v.c > 0) then
                if found and found ~= v.name then many = true end
                found = v.name
            end
        end
    end
    track_snap = now
    if found and not many then return found end
    return nil
end

pcall(function()
    RegisterHook("/Script/BitReactorGame.BrunoMusicSubSystem:PlayBrunoMusic",
        function(_self, _player, music_type)
            local ok, v = pcall(function() return music_type:get() end)
            if ok and MUSIC_TYPES[v] then
                game_music = MUSIC_TYPES[v]
                if v == 1 then game_track = "Shell_01" elseif v == 2 then game_track = "" end
                if v == 3 or v == 4 then pcall(function() track_snap = scan_tracks() end) end
            end
        end,
        function(_self, _player, music_type)
            -- pós-chamada: o jogo já escolheu a faixa
            local ok, v = pcall(function() return music_type:get() end)
            if ok and (v == 3 or v == 4) then
                local okp, nm = pcall(pick_changed_track)
                game_track = (okp and nm) or ""
                print("[ZeroCompanyMP] Musica do jogo: " .. tostring(MUSIC_TYPES[v]) .. " / " .. (game_track ~= "" and game_track or "?"))
            end
        end)
    print("[ZeroCompanyMP] Hook PlayBrunoMusic: OK")
end)

local function detect_scene()
    local map = current_map()
    if game_music ~= "" then return game_music, map end
    -- fallback por classes do SDK: TacticalGameState (missão), StrategyGameState (base/campanha)
    if valid(FindFirstOf("TacticalGameState")) then return "combat", map end
    if valid(FindFirstOf("StrategyGameState")) then return "strategy", map end
    return "menu", map
end

-- ─── Silenciar a música original enquanto a trilha do portal toca ─────────────
-- O portal escreve mp_music.json {"mute":true|false,"ts":N}; o volume original fica em mp_music_orig.txt
local MUSIC_CTRL = MOD_PATH .. "\\mp_music.json"
local MUSIC_ORIG = MOD_PATH .. "\\mp_music_orig.txt"
local muted_now  = nil

local function user_settings()
    local s = FindFirstOf("BitReactorUserSettingsLocal")
    if valid(s) then return s end
    return nil
end

-- ─── Trilha sonora dentro do jogo (sem a página aberta) ───────────────────────
-- O portal exporta as músicas para Scripts\swmp_music\ e a lista para mp_playlist.json:
-- {"on":bool,"seq":bool,"vol":0..1,"mute":bool,"track":{faixa:[ficheiros]},"group":{grupo:[ficheiros]},
--  "trackGroup":{faixa:grupo},"sceneGroup":{cena:grupo},"chain":{grupo:[grupos]}}
-- O mod arranca o leitor swmp_player.ps1 (processo filho do jogo) e diz-lhe o que tocar em mp_player.json.
local PLAYLIST_FILE = MOD_PATH .. "\\mp_playlist.json"
local PLAYER_CMD    = MOD_PATH .. "\\mp_player.json"
local PLAYER_STATE  = MOD_PATH .. "\\mp_player_state.json"
local PLAYER_PS1    = MOD_PATH .. "\\swmp_player.ps1"
local MUSIC_DIR     = MOD_PATH .. "\\swmp_music\\"
local ig = { raw = nil, pl = nil, key = "", playing = nil, file = "", seq = 0, order = {}, pos = {}, launched = false }

local function ig_has_songs(pl)
    if not pl or not pl.on then return false end
    for _, t in ipairs({ pl.track or {}, pl.group or {} }) do
        for _, files in pairs(t) do if type(files) == "table" and #files > 0 then return true end end
    end
    return false
end

local function ig_player_alive()
    local raw = read_file(PLAYER_STATE)
    local ts = raw and tonumber(raw:match('"ts"%s*:%s*(%d+)')) or 0
    return os.time() - ts < 6, raw
end

local function ig_launch()
    if not read_file(PLAYER_PS1) then print("[ZeroCompanyMP] Trilha: falta swmp_player.ps1"); return end
    -- comando fresco antes de arrancar (o da sessão anterior tem "ts" velho e o leitor desligava-se)
    write_file(PLAYER_CMD, json.encode({ file = "", vol = 0, seq = 0, ts = os.time() }))
    ig.file, ig.seq = "", 0
    -- "start" devolve logo; o leitor fecha-se sozinho quando o jogo fecha
    os.execute('start "" /B powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "'
        .. PLAYER_PS1 .. '" -Dir "' .. MOD_PATH .. '"')
    ig.launched, ig.launch_t = true, os.time()
    print("[ZeroCompanyMP] Trilha: leitor arrancado")
end

-- O que tocar agora: faixa exata (se tem troca) → grupo da cena → grupos vizinhos (igual ao portal)
local function ig_target(pl)
    local tr = last_track or ""
    local g = (pl.trackGroup or {})[tr] or (pl.sceneGroup or {})[last_scene] or "hub"
    local exact = (pl.track or {})[tr]
    if tr ~= "" and type(exact) == "table" and #exact > 0 then return tr, exact end
    for _, cg in ipairs((pl.chain or {})[g] or { g }) do
        local files = (pl.group or {})[cg]
        if type(files) == "table" and #files > 0 then return "all:" .. cg, files end
    end
    return "", {}
end

local function ig_pick(pl, key, files)
    if pl.seq then
        local p
        if ig.key == key then for i, f in ipairs(files) do if f == ig.playing then p = i end end end
        p = p or ig.pos["s:" .. key] or 0
        p = p % #files + 1
        ig.pos["s:" .. key] = p
        return files[p]
    end
    local o = ig.order[key]
    if not o or #o ~= #files or (ig.pos[key] or 1) > #o then
        o = {}
        for i, f in ipairs(files) do o[i] = f end
        for i = #o, 2, -1 do local j = math.random(i); o[i], o[j] = o[j], o[i] end
        if #o > 1 and o[1] == ig.playing then table.insert(o, table.remove(o, 1)) end
        ig.order[key] = o; ig.pos[key] = 1
    end
    local f = o[ig.pos[key]]
    ig.pos[key] = ig.pos[key] + 1
    return f
end

local function ig_send(file, restart)
    if file ~= ig.file or restart then ig.seq = ig.seq + 1; ig.file = file end
    local vol = tonumber(ig.pl and ig.pl.vol) or 0.7
    write_file(PLAYER_CMD, json.encode({ file = file, vol = vol, seq = ig.seq, ts = os.time() }))
end

local function ig_tick()
    local raw = read_file(PLAYLIST_FILE)
    if raw ~= ig.raw then
        ig.raw = raw
        local ok, pl = pcall(json.decode, raw or "")
        ig.pl = (ok and type(pl) == "table") and pl or nil
        ig.order, ig.pos = {}, {}
        -- lista nova/alterada no portal com o jogo aberto: arranca o leitor se ainda não estiver vivo
        if ig_has_songs(ig.pl) and not ig_player_alive() and os.time() - (ig.launch_t or 0) > 20 then ig_launch() end
    end
    local pl = ig.pl
    if not ig_has_songs(pl) then
        if ig.file ~= "" or ig.launched then ig.key, ig.playing = "", nil; ig_send("") end
        return
    end
    local key, files = ig_target(pl)
    local _, st = ig_player_alive()
    local ended = st and st:find('"ended"%s*:%s*true') and tonumber(st:match('"seq"%s*:%s*(%d+)')) == ig.seq
    if key ~= ig.key and not ended and ig.playing then
        -- mudou a cena mas a música atual também serve a nova: continua sem cortar
        for _, f in ipairs(files) do if f == ig.playing then ig.key = key end end
    end
    if key ~= ig.key or ended or not ig.playing then
        local f = ig_pick(pl, key, files)
        if f and f:match("^[%w_%-]+%.%w+$") then
            ig.key, ig.playing = key, f
            print("[ZeroCompanyMP] Trilha: " .. f .. " (" .. key .. ")")
            ig_send(MUSIC_DIR .. f, true)
            return
        end
    end
    ig_send(ig.file)   -- renova o sinal de vida para o leitor
end

-- arranque do jogo: se já há trilha configurada, o leitor começa logo (antes do menu)
do
    local raw = read_file(PLAYLIST_FILE)
    local ok, pl = pcall(json.decode, raw or "")
    if ok and ig_has_songs(pl) then
        math.randomseed(os.time())
        ig_launch()
    end
end

local function apply_music_mute()
    local raw = read_file(MUSIC_CTRL)
    local want = raw ~= nil and raw:find('"mute"%s*:%s*true') ~= nil
    -- o portal renova "ts" a cada poucos segundos; sem sinal há 20s (página fechada) → repõe a música
    local ts = raw and tonumber(raw:match('"ts"%s*:%s*(%d+)')) or 0
    if want and os.time() - ts > 20 then want = false end
    -- trilha dentro do jogo: silencia a original só se o leitor estiver mesmo a tocar
    if not want and ig.pl and ig.pl.mute and ig_has_songs(ig.pl) and ig_player_alive() then want = true end
    if want == muted_now then return end
    local s = user_settings()
    if not s then return end
    if want then
        local cur = s:GetMusicVolume()
        if cur and cur > 0.001 and not read_file(MUSIC_ORIG) then write_file(MUSIC_ORIG, tostring(cur)) end
        s:SetMusicVolume(0.0)
        print("[ZeroCompanyMP] Musica do jogo silenciada (trilha SWMP ativa)")
    elseif muted_now ~= nil or read_file(MUSIC_ORIG) then
        local orig = tonumber(read_file(MUSIC_ORIG) or "") or 1.0
        s:SetMusicVolume(orig)
        os.remove(MUSIC_ORIG)
        print("[ZeroCompanyMP] Musica do jogo reposta: " .. tostring(orig))
    end
    muted_now = want
end

local function update_scene()
    local now = os.time()
    local ok, scene, map = pcall(detect_scene)
    if not ok then return end
    -- reescreve a cada 10s mesmo sem mudanças (o portal usa o ts para saber se o jogo está vivo)
    if scene == last_scene and map == last_map and game_track == last_track and now - last_scene_t < 10 then return end
    if scene ~= last_scene then print("[ZeroCompanyMP] Cena: " .. scene .. " (" .. map .. ")") end
    last_scene, last_map, last_scene_t, last_track = scene, map, now, game_track
    local safe_map = map:gsub("\\", "/"):gsub('"', "")
    write_file(SCENE_FILE, ('{"scene":"%s","track":"%s","map":"%s","ts":%d}'):format(scene, game_track, safe_map, now))
end

local scene_tick = 0

-- ─── Batalha 1x1 (PvP hot-seat no PC do anfitrião; o amigo entra por Steam Remote Play Together) ─────
-- Jogador 1 joga o esquadrão; o Jogador 2 joga o lado inimigo COM a interface nativa (barra do esquadrão, radial,
-- ataques). Como (testado ao vivo em 20/10): o grupo de turno do jogador (BP_PlayerTurnGroup) passa também a ocupar
-- o lugar do grupo de IA na ordem dos turnos, e ao "terminar turno" (BP_BrunoGameplayMaster:RequestEndTurn) as
-- unidades trocam de equipa com BitReactorGameStatics_Unit:ChangeActorTeam (PlayerTeam <-> EnemyTeam). Assim o turno
-- do Jogador 2 é um turno de jogador normal com os inimigos como "esquadrão". Ao desligar repõe tudo.
-- Controlo: tecla F8 no jogo, ou o portal escreve mp_pvp_cmd.json {"cmd":"on|off","ts":N}.
local PVP_CMD    = MOD_PATH .. "\\mp_pvp_cmd.json"
local PVP_STATE  = MOD_PATH .. "\\mp_pvp.json"
local pvp_on     = false
local pvp_cmd_ts = 0
local pvp = { swapped = false, units = {}, ai = nil, ai_idx = nil, sub = nil, hooked = false }

-- Só com a cópia original da Steam: manifesto da app na biblioteca Steam e nenhum ficheiro de crack/emulador
-- (o SWMP-Host ainda verifica a assinatura Valve da steam_api64.dll e o registo da Steam)
local CRACK_MARKERS = { "steam_emu.ini", "steam_appid.txt", "steam_interfaces.txt", "steam_api64_o.dll", "steam_api64.cdx",
    "CODEX.ini", "CPY.ini", "3DMGAME.ini", "ali213.ini", "valve.ini", "SmartSteamEmu.ini", "ColdClientLoader.ini",
    "OnlineFix.ini", "OnlineFix64.dll", "cream_api.ini", "steam_settings\\steam_appid.txt", "steam_settings\\configs.user.ini" }
local genuine_ok, genuine_why = nil, ""

local function check_genuine()
    if genuine_ok ~= nil then return genuine_ok end
    -- MOD_PATH = <jogo>\SWZeroCompany\Binaries\Win64\ue4ss\Mods\ZeroCompanyMP\Scripts
    local win64 = MOD_PATH:match("^(.+)[/\\]ue4ss[/\\]Mods[/\\]") or ""
    local root, installdir = win64:match("^(.+[/\\]([^/\\]+))[/\\]SWZeroCompany[/\\]Binaries[/\\]Win64$")
    local why = {}
    if not root then
        why[#why + 1] = "pasta do jogo não reconhecida"
    else
        local steamapps = root:match("^(.+)[/\\]common[/\\][^/\\]+$")
        local acf = steamapps and read_file(steamapps .. "\\appmanifest_2075800.acf")
        if not acf then
            why[#why + 1] = "sem manifesto da Steam (appmanifest_2075800.acf)"
        else
            local dir = acf:match('"installdir"%s+"([^"]+)"')
            if not dir or dir:lower() ~= installdir:lower() then why[#why + 1] = "manifesto da Steam não corresponde à pasta do jogo" end
            if not acf:match('"LastOwner"%s+"7656119%d+"') then why[#why + 1] = "manifesto sem conta Steam dona do jogo" end
        end
        local dirs = { root, win64, root .. "\\Engine\\Binaries\\ThirdParty\\Steamworks\\Steamv157\\Win64" }
        for _, d in ipairs(dirs) do
            for _, m in ipairs(CRACK_MARKERS) do
                local f = io.open(d .. "\\" .. m, "rb")
                if f then f:close(); why[#why + 1] = "ficheiro de crack/emulador: " .. m end
            end
        end
    end
    genuine_ok = #why == 0
    genuine_why = table.concat(why, "; ")
    print("[ZeroCompanyMP] Jogo original (Steam): " .. (genuine_ok and "OK" or ("NÃO — " .. genuine_why)))
    return genuine_ok
end

local function pvp_pc()
    local pcs = FindAllOf("PlayerController")
    if pcs then for _, p in ipairs(pcs) do if valid(p) then return p end end end
    return nil
end

local function pvp_console(cmd)
    local pc = pvp_pc()
    local ok, err = pcall(function()
        local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        ksl:ExecuteConsoleCommand(pc, cmd, pc)
    end)
    print(("[ZeroCompanyMP] PvP consola '%s': %s"):format(cmd, ok and "ok" or tostring(err)))
end

local function pvp_subsys()
    local l = FindAllOf("TurnGroupSubsystem")
    if l then for _, x in ipairs(l) do if valid(x) then return x end end end
    return nil
end

-- Lista as equipas do combate (grupos de turno) e quem está a jogar agora
local function pvp_report()
    local out = { active = pvp_on, ts = os.time(), teams = {}, current = "", round = 0 }
    local ts = get_turn_state()
    if ts then out.current = ts.team_name; out.round = ts.round end
    local sub = pvp_subsys()
    if sub then
        pcall(function()
            sub.OrderedTurnGroups:ForEach(function(i, g)
                local grp = g:get()
                if not valid(grp) then return end
                local name = grp:GetFName():ToString()
                local flag = ""
                pcall(function() local f = grp.TeamGameFlag; if valid(f) then flag = f:GetFName():ToString() end end)
                out.teams[#out.teams + 1] = { group = name, flag = flag }
            end)
        end)
    end
    local chars = FindAllOf("BitReactorGameCharacter") or {}
    local n = 0
    for _, c in ipairs(chars) do if valid(c) then n = n + 1 end end
    out.units = n
    local parts = {}
    for _, t in ipairs(out.teams) do parts[#parts + 1] = ('{"group":"%s","flag":"%s"}'):format(t.group, t.flag) end
    check_genuine()
    write_file(PVP_STATE, ('{"active":%s,"round":%d,"current":"%s","side":%d,"units":%d,"teams":[%s],"genuine":%s,"why":%s,"ts":%d}'):format(
        tostring(pvp_on), out.round or 0, out.current or "", pvp.swapped and 2 or 1, n, table.concat(parts, ","), tostring(genuine_ok), json.encode(genuine_why), out.ts))
    return out
end

local TEAM_PATH = { P = "/Game/Game/GameData/Teams/PlayerTeam.PlayerTeam_C", E = "/Game/Game/GameData/Teams/EnemyTeam.EnemyTeam_C" }
local function pvp_statics()
    return StaticFindObject("/Script/BitReactorGame.Default__BitReactorGameStatics"),
           StaticFindObject("/Script/BitReactorGame.Default__BitReactorGameStatics_Unit")
end

local function team_name(st, a)
    local ok, t = pcall(function() return st:GetTeam(a) end)
    if ok and valid(t) then return t:GetFName():ToString() end
    return ""
end

-- unidades do mapa (não modelos/CDOs fora do nível: selecionar um desses crashou o jogo em 20/10)
local function level_units()
    local t = {}
    for _, c in ipairs(FindAllOf("BitReactorGameCharacter") or {}) do
        if valid(c) and c:GetFullName():find(":PersistentLevel%.") then t[#t + 1] = c end
    end
    return t
end

local function pvp_groups(sub)
    local pg, ai, ai_idx
    pcall(function()
        sub.OrderedTurnGroups:ForEach(function(i, g)
            local grp = g:get()
            if valid(grp) then
                local n = grp:GetFName():ToString()
                if n:find("^BP_PlayerTurnGroup") and not pg then pg = grp
                elseif n:find("^BP_AITurnGroup") then ai, ai_idx = grp, i end
            end
        end)
    end)
    return pg, ai, ai_idx
end

-- passa a seleção para o lado que vai jogar pelo mesmo caminho da tecla TAB (SelectNextCharacter): só assim a
-- câmara vai à unidade e o radial/barra de habilidades abre nela (SetSelectedCharacter direto deixava a UI presa).
-- Às vezes uma chamada não chega (o radial ficava no herói do J1, já inimigo): repete até a seleção ser do PlayerTeam.
local function pvp_select_side(tries)
    tries = tries or 0
    local st = pvp_statics()
    for _, c in ipairs(FindAllOf("SelectedCharacterComponent") or {}) do
        if valid(c) and c:GetFullName():find("PlayerController") then
            local ok, sel = pcall(function() return c:GetSelectedCharacter() end)
            if ok and valid(sel) and valid(st) and team_name(st, sel) == "PlayerTeam_C" then return end
            pcall(function() c:SelectNextCharacter() end)
            -- sem GetSelectedCharacter não dá para confirmar: fica a uma chamada, como antes
            if ok and tries < 6 then
                ExecuteWithDelay(700, function() in_game_thread(function() pvp_select_side(tries + 1) end) end)
            end
            return
        end
    end
end

-- Câmara: cada jogador vê por trás das suas unidades, virado para o inimigo. A câmara tática (Camroid) não
-- aceita BitReactorGameStatics_Camera:SetCameraYaw (devolve false); roda-se injetando a ação de rodar do próprio
-- jogo (IA_RotateCamera, a das teclas Q/E) frame a frame até o ângulo ficar a menos de 5° do alvo (~3°/frame).
local function cam_yaw()
    for _, m in ipairs(FindAllOf("PlayerCameraManager") or {}) do
        if valid(m) and not m:GetFullName():find("Default__") then
            local ok, r = pcall(function() return m:GetCameraRotation() end)
            if ok and r then return r.Yaw end
        end
    end
end

local function norm180(a) a = (a + 180) % 360; if a < 0 then a = a + 360 end; return a - 180 end

local cam_job = 0
local function cam_face(target)
    local ia = StaticFindObject("/Game/Game/Input/Actions/IA_RotateCamera.IA_RotateCamera")
    local sub
    for _, x in ipairs(FindAllOf("EnhancedInputLocalPlayerSubsystem") or {}) do if valid(x) then sub = x end end
    if not (valid(ia) and sub) then return end
    cam_job = cam_job + 1
    local job, steps = cam_job, 0
    local function step()
        in_game_thread(function()
            if job ~= cam_job then return end            -- um pedido mais recente substitui este
            local y = cam_yaw()
            if not y then return end
            local d = norm180(target - y)
            steps = steps + 1
            if math.abs(d) < 5 or steps > 240 then return end
            pcall(function() sub:InjectInputVectorForAction(ia, { X = d > 0 and 1.0 or -1.0, Y = 0.0, Z = 0.0 }, {}, {}) end)
            ExecuteWithDelay(16, step)
        end)
    end
    step()
end

-- missões com temporizador (resgate em Ryloth: BRGameTacticalTimer) acabavam o 1x1 a meio: a cada troca de vez o
-- tempo volta ao total (DurationToCount, mínimo 2: o jogo desconta 1 a cada fim de vez), nunca chega a zero
local function pvp_hold_timers()
    local n = 0
    for _, t in ipairs(FindAllOf("BRGameTacticalTimer") or {}) do
        if valid(t) and t:GetFullName():find(":PersistentLevel%.") then
            if pcall(function() t.DurationRemaining = math.max(t.DurationToCount, 2) end) then n = n + 1 end
        end
    end
    if n > 0 then print(("[ZeroCompanyMP] Batalha 1x1: %d temporizador(es) reposto(s)"):format(n)) end
end

-- troca as equipas de todas as unidades do jogador/inimigo (guarda o lado original para repor)
local function pvp_swap(want)
    if want == pvp.swapped then return end
    local st, su = pvp_statics()
    local tp, te = StaticFindObject(TEAM_PATH.P), StaticFindObject(TEAM_PATH.E)
    if not (valid(st) and valid(su) and valid(tp) and valid(te)) then print("[ZeroCompanyMP] PvP: equipas indisponíveis"); return end
    if want then
        pvp.units = {}
        for _, c in ipairs(level_units()) do
            local t = team_name(st, c)
            -- VIPs/capturados (Char_VIP_*) ficam fora da troca, senão aparecem na barra do J2
            if (t == "PlayerTeam_C" or t == "EnemyTeam_C") and not c:GetFullName():find("Char_VIP") then pvp.units[#pvp.units + 1] = { a = c, p = (t == "PlayerTeam_C") } end
        end
    end
    local n = 0
    for _, u in ipairs(pvp.units) do
        if valid(u.a) then
            local to = (u.p == want) and te or tp     -- trocado: jogador->inimigo e inimigo->jogador
            if pcall(function() su:ChangeActorTeam(u.a, to, true) end) then n = n + 1 end
        end
    end
    pvp.swapped = want
    if not want then pvp.units = {} end
    pvp_hold_timers()
    print(("[ZeroCompanyMP] Batalha 1x1: %s (%d unidades)"):format(want and "vez do JOGADOR 2" or "vez do JOGADOR 1", n))
    ExecuteWithDelay(1500, function() in_game_thread(pvp_select_side) end)
    if pvp.yaw1 then
        ExecuteWithDelay(2500, function() cam_face(want and norm180(pvp.yaw1 + 180) or pvp.yaw1) end)
    end
end

-- ao terminar cada turno de jogador alterna o lado (chamado pela UI e pelo portal: RequestEndTurn)
local function pvp_hook()
    if pvp.hooked then return end
    local ok, err = pcall(function()
        RegisterHook("/Game/Game/Core/Blueprints/BP_BrunoGameplayMaster.BP_BrunoGameplayMaster_C:RequestEndTurn", function()
            if not pvp_on then return end
            local okc, e = pcall(function() pvp_swap(not pvp.swapped) end)
            if not okc then print("[ZeroCompanyMP] PvP erro na troca: " .. tostring(e)) end
        end)
    end)
    pvp.hooked = ok
    print("[ZeroCompanyMP] PvP gancho RequestEndTurn: " .. (ok and "OK" or tostring(err)))
end

-- liga/desliga a ordem de turnos PvP (grupo do jogador no lugar do grupo de IA)
local function pvp_turn_order(on)
    local sub = pvp_subsys()
    if not sub then return false end
    if on then
        local pg, ai, ai_idx = pvp_groups(sub)
        if not (pg and ai and ai_idx) then print("[ZeroCompanyMP] PvP: grupos de turno não encontrados"); return false end
        pvp.sub, pvp.ai, pvp.ai_idx = sub, ai, ai_idx
        local ok = pcall(function() sub.OrderedTurnGroups[ai_idx] = pg end)
        print("[ZeroCompanyMP] PvP: turno inimigo passa a ser do Jogador 2 (" .. (ok and "ok" or "falhou") .. ")")
        return ok
    elseif pvp.sub == sub and pvp.ai and valid(pvp.ai) and pvp.ai_idx then
        pcall(function() sub.OrderedTurnGroups[pvp.ai_idx] = pvp.ai end)
        print("[ZeroCompanyMP] PvP: turno inimigo devolvido à IA")
    end
    pvp.sub, pvp.ai, pvp.ai_idx = nil, nil, nil
    return true
end

local function pvp_set(on)
    if on and not check_genuine() then
        print("[ZeroCompanyMP] Batalha 1x1 recusada — jogo não verificado como original: " .. genuine_why)
        pvp_on = false
        pcall(pvp_report)
        return
    end
    -- versões antigas deixavam a IA a planear sem agir: garante que fica desligado
    pvp_console("br.AI.Planner.SimulatePlanNoCommit 0")
    if on then
        if pvp_on then return end
        pvp_hook()
        if not pvp_turn_order(true) then pvp_on = false; pcall(pvp_report); return end
        pvp.yaw1 = cam_yaw()   -- a orientação do mapa no início = vista do Jogador 1
        pvp_on = true
    else
        pvp_on = false
        pcall(function() pvp_swap(false) end)
        pcall(function() pvp_turn_order(false) end)
    end
    print("[ZeroCompanyMP] Batalha 1x1 " .. (on and "LIGADA" or "DESLIGADA"))
    pcall(pvp_report)
end

-- novo combate/missão (outro TurnGroupSubsystem): o estado antigo já não vale
local function pvp_check_world()
    if pvp.sub and not valid(pvp.sub) then
        pvp.swapped, pvp.units, pvp.sub, pvp.ai, pvp.ai_idx = false, {}, nil, nil, nil
        if pvp_on then pvp_on = false; print("[ZeroCompanyMP] Batalha 1x1 terminou com a missão") end
    end
end

local function pvp_poll()
    pvp_check_world()
    local raw = read_file(PVP_CMD)
    if raw then
        local ts = tonumber(raw:match('"ts"%s*:%s*(%d+)')) or 0
        if ts > pvp_cmd_ts then
            pvp_cmd_ts = ts
            local cmd = raw:match('"cmd"%s*:%s*"(%a+)"')
            if cmd == "on" then pvp_set(true) elseif cmd == "off" then pvp_set(false) elseif cmd == "report" then pcall(pvp_report) end
        end
    end
    if pvp_on then pcall(pvp_report) end
end

pcall(function()
    RegisterKeyBind(Key.F8, function() ExecuteInGameThread(function() pvp_set(not pvp_on) end) end)
    RegisterKeyBind(Key.F7, function() ExecuteInGameThread(function() pcall(pvp_report); print("[ZeroCompanyMP] PvP relatório escrito") end) end)
    print("[ZeroCompanyMP] Batalha 1x1: F8 liga/desliga, F7 relatório")
end)
-- ignora comandos antigos que já estavam no ficheiro ao arrancar
do local raw = read_file(PVP_CMD); if raw then pvp_cmd_ts = tonumber(raw:match('"ts"%s*:%s*(%d+)')) or 0 end end

-- ─── Batalha Rápida: mapa escolhido → esquadrão → combate direto ──────────────
-- Usa o lançamento rápido que os programadores deixaram no jogo (B_QuickLaunchViewModel + BRG_MissionTestingSettings).
-- O portal escreve mp_qb_cmd.json {"cmd":"launch","world":"/Game/.../SK_Ryloth_010_Root.SK_Ryloth_010_Root","pvp":bool,"ts":N};
-- o mod escreve a lista de mapas em mp_qb_worlds.json e o estado em mp_qb.json.
local QB_CMD, QB_STATE, QB_WORLDS = MOD_PATH .. "\\mp_qb_cmd.json", MOD_PATH .. "\\mp_qb.json", MOD_PATH .. "\\mp_qb_worlds.json"
local qb = { cmd_ts = 0, pvp = false, restore = false, worlds_done = false, launched_at = 0 }
do local raw = read_file(QB_CMD); if raw then qb.cmd_ts = tonumber(raw:match('"ts"%s*:%s*(%d+)')) or 0 end end

local function qb_state(status)
    write_file(QB_STATE, json.encode({ status = status, ts = os.time() }))
    print("[ZeroCompanyMP] Batalha Rápida: " .. status)
end

local function qb_worlds()
    local gi = FindFirstOf("GameInstance")
    if not valid(gi) then return nil end
    local ok, ws = pcall(function() return gi:GetStartingWorlds() end)
    if not ok or type(ws) ~= "table" then return nil end
    local list = {}
    for _, w in ipairs(ws) do
        local v = w
        pcall(function() v = w:get() end)
        local e = {}
        pcall(function()
            e.Name, e.Category, e.WorldPath = v.Name:ToString(), v.Category:ToString(), v.WorldPath:ToString()
            e.bEuropa, e.bShowInQuickLaunch = v.bEuropa, v.bShowInQuickLaunch
            e.bAllowOnConsoles, e.bAllowInShipping = v.bAllowOnConsoles, v.bAllowInShipping
        end)
        if e.WorldPath and (e.Category:find("^Missions") or e.Category == "Story") then list[#list + 1] = e end
    end
    return list
end

-- o ViewModel do menu "MissionTest" escondido no menu principal (existe só no menu principal)
local function qb_vm()
    local any
    for _, vm in ipairs(FindAllOf("B_QuickLaunchViewModel") or {}) do
        if valid(vm) then
            local ctx
            pcall(function() ctx = vm.ContextObject end)
            if valid(ctx) and ctx:GetClass():GetFName():ToString():find("MissionTest") then return vm end
            any = any or vm
        end
    end
    return any
end

local function qb_mission_testing(on, world)
    local mt = StaticFindObject("/Script/BitReactorGame.Default__BRG_MissionTestingSettings")
    if not valid(mt) then return false end
    pcall(function() mt.bEnableMissionTesting = on end)
    if world then
        pcall(function() mt.Mission.World = world end)
        pcall(function() mt.Mission.MissionName = world.Name end)
    end
    return true
end

local function qb_launch(world_path, pvp)
    local list = qb_worlds()
    if not list then return qb_state("erro: lista de mapas indisponível") end
    local w
    for _, e in ipairs(list) do if e.WorldPath == world_path then w = e end end
    if not w then return qb_state("erro: mapa desconhecido") end
    local vm = qb_vm()
    if not vm then return qb_state("erro: volta ao menu principal do jogo e tenta de novo") end
    qb_mission_testing(true, w)
    local log = {}
    local function step(name, fn)
        local ok, r = pcall(fn)
        log[#log + 1] = name .. "=" .. (ok and tostring(r) or ("ERRO " .. tostring(r)))
        return ok, r
    end
    step("config", function() return vm:TrySettingMissionTestingConfigurations() end)
    step("mundo", function() return vm:SetDesiredWorld(w) end)
    step("esquadrão", function() return vm:TrySettingDesiredSquadFromMissionTesting() end)
    local _, ready = step("pronto", function() return vm:IsReadyForQuickLaunch() end)
    print("[ZeroCompanyMP] Batalha Rápida: " .. w.Name .. " — " .. table.concat(log, " "))
    step("lançar", function() return vm:TryQuickLaunching() end)
    qb.pvp, qb.restore, qb.launched_at = pvp and true or false, true, os.time()
    qb_state("a carregar " .. w.Name .. (pvp and " (1x1)" or "") .. " — " .. table.concat(log, " "))
end

local function qb_poll()
    if not qb.worlds_done then
        local list = qb_worlds()
        if list and #list > 0 then write_file(QB_WORLDS, json.encode(list)); qb.worlds_done = true end
    end
    local raw = read_file(QB_CMD)
    if not raw then return end
    local ts = tonumber(raw:match('"ts"%s*:%s*(%d+)')) or 0
    if ts <= qb.cmd_ts then return end
    qb.cmd_ts = ts
    local ok, c = pcall(json.decode, raw)
    if ok and type(c) == "table" and c.cmd == "launch" and type(c.world) == "string" then qb_launch(c.world, c.pvp) end
end

-- já em combate: desliga o Mission Testing (não mexe na campanha) e liga o 1x1 se foi pedido
local function qb_after_combat_start()
    if not qb.restore or combat_started_at < qb.launched_at then return end
    qb.restore = false
    qb_mission_testing(false)
    qb_state("em combate")
    if qb.pvp then qb.pvp = false; pvp_set(true) end
end

local tick_queued = false
local function tick()
    tick_queued = false
    scene_tick = scene_tick + 1
    if os.time() < combat_grace_until then
        -- início do combate: só a trilha (ficheiros), nada de objetos do jogo
        if scene_tick % 2 == 0 then pcall(ig_tick) end
        return
    end
    pcall(poll)
    pcall(pvp_poll)
    pcall(qb_poll)
    pcall(qb_after_combat_start)
    if scene_tick % 2 == 0 then pcall(update_scene); pcall(ig_tick); pcall(apply_music_mute) end
end
-- o temporizador corre fora da thread do jogo: só agenda; o trabalho com objetos do jogo corre na thread do jogo
-- (sem fila acumulada enquanto o jogo carrega um mapa)
local function loop()
    if not tick_queued then tick_queued = true; in_game_thread(tick) end
    ExecuteWithDelay(1000, loop)
end
loop()
