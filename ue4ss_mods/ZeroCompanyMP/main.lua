-- ZeroCompanyMP/main.lua — v0.22
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
print(" ZeroCompanyMP v0.22 carregado")
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

-- ─── Co-op (modo história, o amigo entra por Steam Remote Play Together) ──────────────────────────
-- Cada personagem do esquadrão é do Jogador 1 ou do Jogador 2. O turno do jogador passa a acontecer duas vezes por
-- ronda (um segundo BP_PlayerTurnGroup logo a seguir ao primeiro em OrderedTurnGroups): na 1.ª vez joga o J1, na 2.ª o
-- J2, depois a IA. Em cada vez, selecionar um personagem do outro salta para o seguinte do dono da vez.
-- Controlo: tecla F9 no jogo (divisão alternada), ou o portal escreve mp_coop_cmd.json
-- {"cmd":"on|off","owners":{"Char_Hero_X_C_0":2,...},"ts":N}; estado em mp_coop.json.
local COOP_CMD, COOP_STATE = MOD_PATH .. "\\mp_coop_cmd.json", MOD_PATH .. "\\mp_coop.json"
local coop_on, coop_cmd_ts = false, 0
local coop = { phase = 1, owners = {}, sub = nil, saved = nil, hooked = false }
do local raw = read_file(COOP_CMD); if raw then coop_cmd_ts = tonumber(raw:match('"ts"%s*:%s*(%d+)')) or 0 end end

local function coop_squad()
    local st = pvp_statics()
    local t = {}
    if not valid(st) then return t end
    for _, c in ipairs(level_units()) do
        if team_name(st, c) == "PlayerTeam_C" and not c:GetFullName():find("Char_VIP") then t[#t + 1] = c end
    end
    return t
end

local function coop_report()
    local parts = {}
    for _, c in ipairs(coop_squad()) do
        local n = c:GetFName():ToString()
        parts[#parts + 1] = ('{"name":%s,"owner":%d}'):format(json.encode(n), coop.owners[n] or 1)
    end
    write_file(COOP_STATE, ('{"active":%s,"phase":%d,"units":[%s],"ts":%d}'):format(tostring(coop_on), coop.phase, table.concat(parts, ","), os.time()))
end

-- dono por omissão: alterna J1/J2 pela ordem do esquadrão
local function coop_default_owners()
    local i = 0
    for _, c in ipairs(coop_squad()) do
        local n = c:GetFName():ToString()
        if not coop.owners[n] then i = i + 1; coop.owners[n] = (i % 2 == 1) and 1 or 2 else i = i + 1 end
    end
end

local function coop_selected()
    for _, c in ipairs(FindAllOf("SelectedCharacterComponent") or {}) do
        if valid(c) and c:GetFullName():find("PlayerController") then
            local ok, s = pcall(function() return c:GetSelectedCharacter() end)
            return c, (ok and valid(s)) and s or nil
        end
    end
end

-- seleciona um personagem do dono da vez (até 8 tentativas — o TAB do jogo percorre o esquadrão)
local function coop_select_phase()
    local comp, sel = coop_selected()
    if not comp then return end
    for _ = 1, 8 do
        if sel and (coop.owners[sel:GetFName():ToString()] or 1) == coop.phase then return end
        pcall(function() comp:SelectNextCharacter() end)
        local ok, s = pcall(function() return comp:GetSelectedCharacter() end)
        sel = (ok and valid(s)) and s or nil
    end
end

-- o 2.º turno do jogador conta mais uma vez nos temporizadores de missão: devolve essa unidade
local function coop_timer_fix()
    for _, t in ipairs(FindAllOf("BRGameTacticalTimer") or {}) do
        if valid(t) and t:GetFullName():find(":PersistentLevel%.") then
            pcall(function() if t.DurationRemaining < t.DurationToCount then t.DurationRemaining = t.DurationRemaining + 1 end end)
        end
    end
end

local function coop_hook()
    if coop.hooked then return end
    coop.hooked = pcall(function()
        RegisterHook("/Game/Game/Core/Blueprints/BP_BrunoGameplayMaster.BP_BrunoGameplayMaster_C:RequestEndTurn", function()
            if not coop_on then return end
            local was = coop.phase
            coop.phase = (was == 1) and 2 or 1
            if was == 1 then pcall(coop_timer_fix) end
            print(("[ZeroCompanyMP] Co-op: vez do JOGADOR %d"):format(coop.phase))
            if coop.phase == 2 then ExecuteWithDelay(1500, function() in_game_thread(coop_select_phase) end) end
        end)
    end)
end

-- 2.º BP_PlayerTurnGroup logo a seguir ao primeiro (guarda a ordem original para repor)
local function coop_turn_order(on)
    local sub = pvp_subsys()
    if not sub then return false end
    local arr = sub.OrderedTurnGroups
    if on then
        local list, pg, pgi = {}, nil, nil
        arr:ForEach(function(i, g)
            local grp = g:get()
            list[#list + 1] = grp
            if valid(grp) and not pg and grp:GetFName():ToString():find("^BP_PlayerTurnGroup") then pg, pgi = grp, i end
        end)
        if not pg then print("[ZeroCompanyMP] Co-op: grupo de turno do jogador não encontrado"); return false end
        local n = #list
        local ok = pcall(function()
            arr[n + 1] = list[n]
            for i = n, pgi + 2, -1 do arr[i] = list[i - 1] end
            arr[pgi + 1] = pg
        end)
        coop.sub, coop.saved = sub, list
        print(("[ZeroCompanyMP] Co-op: turno do jogador duplicado (%d grupos -> %d) %s"):format(n, arr:GetArrayNum(), ok and "ok" or "falhou"))
        return ok
    elseif coop.sub == sub and coop.saved then
        pcall(function()
            arr:Empty()
            for i, g in ipairs(coop.saved) do arr[i] = g end
        end)
        print("[ZeroCompanyMP] Co-op: ordem de turnos reposta")
    end
    coop.sub, coop.saved = nil, nil
    return true
end

local function coop_set(on, owners)
    if type(owners) == "table" then
        for n, o in pairs(owners) do coop.owners[n] = (tonumber(o) == 2) and 2 or 1 end
    end
    if on then
        if not check_genuine() then print("[ZeroCompanyMP] Co-op recusado — jogo não verificado como original: " .. genuine_why); return end
        if pvp_on then pvp_set(false) end
        if not coop_on then
            coop_hook()
            if not coop_turn_order(true) then return end
            coop.phase = 1
            coop_on = true
        end
        coop_default_owners()
        coop_select_phase()
    elseif coop_on then
        coop_on = false
        pcall(function() coop_turn_order(false) end)
    end
    print("[ZeroCompanyMP] Co-op " .. (coop_on and "LIGADO" or "DESLIGADO"))
    pcall(coop_report)
end

local function coop_poll()
    if coop.sub and not valid(coop.sub) then              -- missão acabou: a ordem de turnos foi com ela
        coop.sub, coop.saved = nil, nil
        if coop_on then coop_on = false; print("[ZeroCompanyMP] Co-op terminou com a missão") end
    end
    local raw = read_file(COOP_CMD)
    if raw then
        local ts = tonumber(raw:match('"ts"%s*:%s*(%d+)')) or 0
        if ts > coop_cmd_ts then
            coop_cmd_ts = ts
            local ok, c = pcall(json.decode, raw)
            if ok and type(c) == "table" then
                if c.cmd == "on" then coop_set(true, c.owners)
                elseif c.cmd == "off" then coop_set(false)
                elseif c.cmd == "owners" then coop_set(coop_on, c.owners) end
            end
        end
    end
    if coop_on then
        -- personagem do outro jogador selecionado: passa para um do dono da vez
        local _, sel = coop_selected()
        if sel and (coop.owners[sel:GetFName():ToString()] or 1) ~= coop.phase then coop_select_phase() end
    end
    if combat_active then pcall(coop_report) end
end

pcall(function()
    RegisterKeyBind(Key.F9, function() ExecuteInGameThread(function() coop_set(not coop_on) end) end)
    print("[ZeroCompanyMP] Co-op: F9 liga/desliga")
end)

-- ─── Co-op em dois PCs (cada um com o seu jogo) ──────────────────────────────────────────────────────
-- O portal de cada PC liga-se ao do outro (WebRTC) e faz a ponte com o mod por ficheiros:
--   mp_net_cmd.json  {"cmd":"on|off","role":"host|client","ts":N}   (portal → mod)
--   mp_net_out.json  {"msgs":[{seq,...}],"ts":N}                      (mod → portal → outro PC)
--   mp_net_in.json   {"msgs":[{seq,...}],"ts":N}                      (outro PC → portal → mod)
-- O HOST decide tudo: corre o co-op normal (vez do J1 = host, vez do J2 = convidado, depois a IA). As ações do
-- convidado chegam como {t="act"} e o host repete-as: movimento = TeleportActor; habilidade = alvo por
-- SetAITargetingDataOverride + TryActivatePlannedAbility + IA_ConfirmTarget (testado 21/10: dispara, acerta e mata
-- pelo caminho normal do jogo). Depois de cada ação o host manda {t="snap"} (posições, vida, PA, mortos, vez).
-- O CONVIDADO joga os seus (dono 2) no jogo dele; ali o dano não conta (IncomingDamageMultiplier = 0) e a IA não
-- age (grupo da IA trocado pelo do jogador): tudo o que importa vem dos snaps do host.
local NET_CMD, NET_OUT, NET_IN = MOD_PATH .. "\\mp_net_cmd.json", MOD_PATH .. "\\mp_net_out.json", MOD_PATH .. "\\mp_net_in.json"
local net = { on = false, role = nil, cmd_ts = 0, out = {}, seq = 0, in_seq = 0, queue = {}, busy_until = 0,
              phase = 1, owners = {}, snap_due = 0, hooked = false, pending = {}, ap_seen = {}, last_act = {} }
do local raw = read_file(NET_CMD); if raw then net.cmd_ts = tonumber(raw:match('"ts"%s*:%s*(%d+)')) or 0 end end
do local raw = read_file(NET_OUT); if raw then local ok, d = pcall(json.decode, raw)     -- a numeração continua
    if ok and type(d) == "table" and type(d.msgs) == "table" then for _, m in ipairs(d.msgs) do net.seq = math.max(net.seq, tonumber(m.seq) or 0) end end end end
do local raw = read_file(NET_IN); if raw then local ok, d = pcall(json.decode, raw)
    if ok and type(d) == "table" and type(d.msgs) == "table" then for _, m in ipairs(d.msgs) do net.in_seq = math.max(net.in_seq, tonumber(m.seq) or 0) end end end end

local NET_SKIP = { GA_TeamTurnEnd_C = 1, GA_TeamTurnStart_C = 1, GA_TacticalEncounterEnded_C = 1, GA_TacticalEncounterStarted_C = 1,
    GA_OnJoinedCombat_C = 1, GA_UnitDamageListener_C = 1, GA_InjuryListener_C = 1, GA_OverwatchCancellationListener_C = 1,
    GA_EvasionListener_C = 1, GA_OutOfHealth_C = 1, GA_Displaced_C = 1, GA_ProgressionHealthManager_C = 1, GA_Passive_Difficulty_C = 1 }

local function net_send(msg)
    net.seq = net.seq + 1
    msg.seq = net.seq
    net.out[#net.out + 1] = msg
    while #net.out > 40 do table.remove(net.out, 1) end
    write_file(NET_OUT, json.encode({ msgs = net.out, ts = os.time() }))
end

local function unit_by_name(n)
    for _, c in ipairs(level_units()) do if c:GetFName():ToString() == n then return c end end
end

local function attr_set(u, set_name)
    local found
    pcall(function()
        u.AbilitySystemComponent.SpawnedAttributes:ForEach(function(_, e)
            local s = e:get()
            if valid(s) and s:GetClass():GetFName():ToString() == set_name then found = s end
        end)
    end)
    return found
end

-- estado de todas as unidades do mapa (o host manda isto ao convidado)
local function net_snapshot()
    local st, su = pvp_statics()
    local units = {}
    for _, c in ipairs(level_units()) do
        local l, r = c:K2_GetActorLocation(), c:K2_GetActorRotation()
        local cs = attr_set(c, "BitReactorCombatSet")
        local u = { n = c:GetFName():ToString(), x = l.X, y = l.Y, z = l.Z, yaw = r.Yaw, hp = c:GetHealth(),
                    team = team_name(st, c), dead = su:IsUnitDead(c) }
        if cs then u.ap = cs.ActionPoints.CurrentValue; u.map = cs.MovementActionPoints.CurrentValue end
        units[#units + 1] = u
    end
    local owners = {}
    for n, o in pairs(coop.owners) do owners[n] = o end
    net_send({ t = "snap", phase = coop.phase, owners = owners, units = units })
end

-- convidado: aplica o estado do host
local function net_apply_snap(m)
    local _, su = pvp_statics()
    net.phase = tonumber(m.phase) or net.phase
    if type(m.owners) == "table" then net.owners = m.owners end
    local by = {}
    for _, c in ipairs(level_units()) do by[c:GetFName():ToString()] = c end
    for _, u in ipairs(m.units or {}) do
        local c = by[u.n]
        if c and valid(c) then
            if u.dead then
                if not su:IsUnitDead(c) then pcall(function() c:K2_DestroyActor() end) end
            else
                local l = c:K2_GetActorLocation()
                if math.abs(l.X - u.x) > 30 or math.abs(l.Y - u.y) > 30 then
                    pcall(function() su:TeleportActor(c, { X = u.x, Y = u.y, Z = u.z }, { Pitch = 0, Yaw = u.yaw or 0, Roll = 0 }, false, true) end)
                end
                local hs = attr_set(c, "BitReactorHealthSet")
                if hs and u.hp then pcall(function() hs.Health.BaseValue = u.hp; hs.Health.CurrentValue = u.hp end) end
                -- PA: das unidades que não são do convidado sempre; das dele só quando a vez dele começa
                local cs = attr_set(c, "BitReactorCombatSet")
                if cs and u.ap and (tonumber(net.owners[u.n]) ~= 2 or m.phase_start) then
                    pcall(function() cs.ActionPoints.CurrentValue = u.ap; cs.MovementActionPoints.CurrentValue = u.map or 0 end)
                end
            end
        end
    end
    -- referência para detetar a próxima ação que gaste PA (todas as unidades do mapa, estejam ou não no estado)
    for _, c in ipairs(level_units()) do
        local cs = attr_set(c, "BitReactorCombatSet")
        if cs then pcall(function() net.ap_seen[c:GetFName():ToString()] = cs.ActionPoints.CurrentValue + cs.MovementActionPoints.CurrentValue end) end
    end
end

-- convidado: no jogo dele o dano não conta (só o host decide quem leva dano e quem morre)
local function net_client_no_damage()
    for _, c in ipairs(level_units()) do
        local hs = attr_set(c, "BitReactorHealthSet")
        if hs then pcall(function() hs.IncomingDamageMultiplier.BaseValue = 0; hs.IncomingDamageMultiplier.CurrentValue = 0 end) end
    end
end

-- host: seleciona a unidade que vai agir (o IA_ConfirmTarget confirma a mira da unidade selecionada)
local function net_select(u)
    local comp, sel = coop_selected()
    if not comp then return end
    local want = u:GetFName():ToString()
    for _ = 1, 10 do
        if sel and sel:GetFName():ToString() == want then return true end
        pcall(function() comp:SelectNextCharacter() end)
        local ok, s = pcall(function() return comp:GetSelectedCharacter() end)
        sel = (ok and valid(s)) and s or nil
    end
end

local function net_confirm()
    local ia = StaticFindObject("/Game/Game/Input/Actions/IA_ConfirmTarget.IA_ConfirmTarget")
    local sub
    for _, x in ipairs(FindAllOf("EnhancedInputLocalPlayerSubsystem") or {}) do if valid(x) then sub = x end end
    if valid(ia) and sub then pcall(function() sub:InjectInputVectorForAction(ia, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {}) end) end
end

-- host: repete uma ação do convidado
local function net_replay(m)
    local u = unit_by_name(m.unit or "")
    if not (u and valid(u)) then print("[ZeroCompanyMP] 2PCs: unidade desconhecida " .. tostring(m.unit)); return end
    if (coop.owners[m.unit] or 1) ~= 2 or coop.phase ~= 2 then print("[ZeroCompanyMP] 2PCs: ação fora da vez ignorada (" .. tostring(m.unit) .. ")"); return end
    local _, su = pvp_statics()
    if m.ab and m.ab:find("Move") then
        if m.x then pcall(function() su:TeleportActor(u, { X = m.x, Y = m.y, Z = m.z }, { Pitch = 0, Yaw = m.yaw or 0, Roll = 0 }, false, true) end) end
        local cs = attr_set(u, "BitReactorCombatSet")
        if cs and m.ap then pcall(function() cs.ActionPoints.CurrentValue = m.ap; cs.MovementActionPoints.CurrentValue = m.map or 0 end) end
        print(("[ZeroCompanyMP] 2PCs: %s moveu-se"):format(m.unit))
        net.snap_due = os.clock() + 0.5
        return
    end
    local asc = u.AbilitySystemComponent
    local cls
    pcall(function() asc.ActivatableAbilities.Items:ForEach(function(_, e)
        local s = e:get()
        local ok, n = pcall(function() return s.Ability:GetClass():GetFName():ToString() end)
        if ok and n == m.ab then cls = s.Ability:GetClass() end
    end) end)
    if not cls then print("[ZeroCompanyMP] 2PCs: " .. m.unit .. " não tem " .. tostring(m.ab)); return end
    net_select(u)
    local lib = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
    local tgt = m.target and unit_by_name(m.target)
    local ok, r = pcall(function()
        if tgt and valid(tgt) then
            asc:SetSuggestedTarget(tgt)                       -- a mira abre neste alvo (o override sozinho não chega)
            asc:SetAITargetingDataOverride(lib:AbilityTargetDataFromActor(tgt))
        end
        return asc:TryActivatePlannedAbility(asc:GetAbilitySpecHandleFromClass(cls, false), nil)
    end)
    print(("[ZeroCompanyMP] 2PCs: %s usa %s em %s (%s)"):format(m.unit, m.ab, tostring(m.target), ok and tostring(r) or ("ERRO " .. tostring(r))))
    net.busy_until = os.clock() + 12                       -- espera pela mira + animação antes da próxima ação
    net.snap_due = os.clock() + 10
    -- a mira abre no alvo por omissão (o alvo da mira aberta lê-se em GetSuggestedTarget, um frame depois de abrir):
    -- troca (TAB do jogo) até ser o pedido e confirma. Se não chegar lá, dispara no que houver e regista (os dois
    -- jogos estão no mesmo estado, por isso a mira deve abrir no mesmo alvo — confirmar no teste real).
    local function cur()
        local n
        pcall(function() local a = asc:GetSuggestedTarget(); if valid(a) then n = a:GetFName():ToString() end end)
        return n
    end
    local function inject(path)
        local ia = StaticFindObject(path)
        local sub
        for _, x in ipairs(FindAllOf("EnhancedInputLocalPlayerSubsystem") or {}) do if valid(x) then sub = x end end
        if valid(ia) and sub then pcall(function() sub:InjectInputVectorForAction(ia, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {}) end) end
    end
    local tries = 0
    local function step()
        in_game_thread(function()
            local c = cur()
            print(("[ZeroCompanyMP] 2PCs: mira de %s passo %d: %s (pedido %s)"):format(m.unit, tries, tostring(c), tostring(m.target)))
            if not c and tries < 10 then tries = tries + 1; ExecuteWithDelay(300, step); return end   -- mira ainda a abrir
            if not m.target or not c or c == m.target then net_confirm(); return end
            if tries >= 18 then
                print(("[ZeroCompanyMP] 2PCs: AVISO alvo %s não apareceu na mira de %s — disparou em %s"):format(m.target, m.unit, tostring(c)))
                net_confirm()
                return
            end
            tries = tries + 1
            inject(tries % 2 == 1 and "/Game/Game/Input/Actions/IA_SelectNextTarget.IA_SelectNextTarget"
                                   or "/Game/Game/Input/Actions/IA_SelectNextTarget_OTS.IA_SelectNextTarget_OTS")
            ExecuteWithDelay(400, step)
        end)
    end
    ExecuteWithDelay(500, step)
end

-- capturas (as duas pontas): no fim de cada habilidade guarda só a instância; lê-se fora do gancho
local function net_hook()
    if net.hooked then return end
    net.hooked = pcall(function()
        -- habilidade paga (custo cobrado) = ação real; no gancho só se guarda a referência (ler mais crasha)
        RegisterHook("/Script/BitReactorGame.BitReactorAbilitySystemComponent:HandleAbilityCommitted", function(_, ab)
            if not net.on then return end
            local ok, a = pcall(function() return ab:get() end)
            if ok and a then net.pending[#net.pending + 1] = { a = a, t = os.clock() } end
        end)
        -- a habilidade que o jogador escolheu (ex. GA_StandardShot_*): a paga costuma ser a "PFA" que ela lança
        RegisterHook("/Script/BitReactorGame.BitReactorAbilitySystemComponent:HandleAbilityActivated", function(_, ab)
            if not net.on then return end
            local ok, a = pcall(function() return ab:get() end)
            if ok and a then net.pending[#net.pending + 1] = { a = a, t = os.clock(), act = true } end
        end)
        RegisterHook("/Game/Game/Core/Blueprints/BP_BrunoGameplayMaster.BP_BrunoGameplayMaster_C:RequestEndTurn", function()
            if not net.on then return end
            if net.role == "client" then
                if net.phase == 2 then net_send({ t = "endphase" }); print("[ZeroCompanyMP] 2PCs: fim da minha vez enviado ao host") end
            else
                net.snap_due = os.clock() + 2
                net.phase_start = true
            end
        end)
    end)
end

-- processa as habilidades pagas (fora do gancho). Convidado: manda {t="act"} das suas unidades na sua vez, se a
-- ação gastou PA; movimento só quando a unidade parou (posição final). Host: qualquer ação → manda o estado.
local function net_process_pending()
    local keep = {}
    for _, p in ipairs(net.pending) do
        local a = p.a
        if valid(a) then
            local cn = a:GetClass():GetFName():ToString()
            local owner
            pcall(function() owner = a:GetOwningActorFromActorInfo() end)
            if p.act then
                -- ativação: lembra a escolha do jogador (não as "PFA", que são lançadas por ela)
                if not NET_SKIP[cn] and not cn:find("PFA") and valid(owner) then net.last_act[owner:GetFName():ToString()] = { cn = cn, t = p.t } end
            elseif not NET_SKIP[cn] and valid(owner) and owner:GetFullName():find(":PersistentLevel%.") then
                local on = owner:GetFName():ToString()
                if net.role ~= "client" then
                    net.snap_due = os.clock() + 4              -- deixa a animação acabar antes de mandar o estado
                    local tn
                    pcall(function() local ta = a.TargetActor; if valid(ta) then tn = ta:GetFName():ToString() end end)
                    local la = net.last_act[on]
                    print(("[ZeroCompanyMP] 2PCs: [host] %s escolheu %s, pagou %s → %s"):format(on, la and la.cn or "?", cn, tostring(tn)))
                elseif tonumber(net.owners[on]) == 2 and net.phase == 2 then
                    local l, r = owner:K2_GetActorLocation(), owner:K2_GetActorRotation()
                    local moving = cn:find("Move") and (not p.lx or math.abs(p.lx - l.X) + math.abs(p.ly - l.Y) > 5) and os.clock() - p.t < 20
                    if moving then
                        p.lx, p.ly = l.X, l.Y; keep[#keep + 1] = p     -- ainda a andar: volta a ver no próximo ciclo
                    else
                        local cs = attr_set(owner, "BitReactorCombatSet")
                        local ap, map = 0, 0
                        if cs then ap, map = cs.ActionPoints.CurrentValue, cs.MovementActionPoints.CurrentValue end
                        local last = net.ap_seen[on]
                        net.ap_seen[on] = ap + map
                        if not last or ap + map < last - 0.01 then
                            local m = { t = "act", unit = on, ab = cn, ap = ap, map = map, x = l.X, y = l.Y, z = l.Z, yaw = r.Yaw }
                            local la = net.last_act[on]
                            if la and p.t - la.t < 15 and not cn:find("Move") then m.ab = la.cn; m.paid = cn end
                            pcall(function() local ta = a.TargetActor; if valid(ta) then m.target = ta:GetFName():ToString() end end)
                            net_send(m)
                            print(("[ZeroCompanyMP] 2PCs: enviado %s %s → %s"):format(on, cn, tostring(m.target)))
                        end
                    end
                end
            end
        end
    end
    net.pending = keep
end

local function net_set(on, role)
    if on then
        if not check_genuine() then print("[ZeroCompanyMP] 2PCs recusado — jogo não verificado como original: " .. genuine_why); return end
        net.role = (role == "client") and "client" or "host"
        net.on = true
        if net.role == "client" and coop_on then coop_set(false) end   -- no convidado a vez vem do host
        net_hook()
        print("[ZeroCompanyMP] 2PCs LIGADO como " .. (net.role == "host" and "ANFITRIÃO" or "CONVIDADO"))
    else
        -- convidado: devolve o turno à IA e o dano normal (senão o jogo fica sem turno inimigo)
        if net.role == "client" then
            pcall(function() pvp_turn_order(false) end)
            for _, c in ipairs(level_units()) do
                local hs = attr_set(c, "BitReactorHealthSet")
                if hs then pcall(function() hs.IncomingDamageMultiplier.BaseValue = 1; hs.IncomingDamageMultiplier.CurrentValue = 1 end) end
            end
        end
        net.on = false
        print("[ZeroCompanyMP] 2PCs DESLIGADO")
    end
end

local function net_poll()
    local raw = read_file(NET_CMD)
    if raw then
        local ts = tonumber(raw:match('"ts"%s*:%s*(%d+)')) or 0
        if ts > net.cmd_ts then
            net.cmd_ts = ts
            local ok, c = pcall(json.decode, raw)
            if ok and type(c) == "table" then net_set(c.cmd == "on", c.role) end
        end
    end
    if not net.on then return end
    -- mensagens do outro PC
    local rin = read_file(NET_IN)
    if rin then
        local ok, d = pcall(json.decode, rin)
        if ok and type(d) == "table" and type(d.msgs) == "table" then
            for _, m in ipairs(d.msgs) do
                local s = tonumber(m.seq) or 0
                if s > net.in_seq then
                    net.in_seq = s
                    if net.role == "host" then
                        if m.t == "act" then net.queue[#net.queue + 1] = m
                        elseif m.t == "endphase" and coop_on and coop.phase == 2 then
                            for _, gm in ipairs(FindAllOf("BP_BrunoGameplayMaster_C") or {}) do
                                if valid(gm) and not gm:GetFullName():find("Default__") then pcall(function() gm:RequestEndTurn() end); break end
                            end
                        end
                    elseif m.t == "snap" then
                        local okA, e = pcall(net_apply_snap, m)
                        if not okA then print("[ZeroCompanyMP] 2PCs erro ao aplicar estado: " .. tostring(e)) end
                    end
                end
            end
        end
    end
    pcall(net_process_pending)
    if not combat_active then return end
    if net.role == "host" then
        if not coop_on then coop_set(true) end              -- o host corre o co-op normal (vez J1 / vez J2)
        if #net.queue > 0 and os.clock() >= net.busy_until then
            local m = table.remove(net.queue, 1)
            pcall(net_replay, m)
        end
        if net.snap_due > 0 and os.clock() >= net.snap_due then
            net.snap_due = 0
            local okS, e = pcall(net_snapshot)
            if okS and net.phase_start then net.out[#net.out].phase_start = true; net.phase_start = false
                write_file(NET_OUT, json.encode({ msgs = net.out, ts = os.time() })) end
            if not okS then print("[ZeroCompanyMP] 2PCs snap erro: " .. tostring(e)) end
        end
    else
        -- convidado: sem IA local e sem dano local (uma vez por combate)
        if not pvp.sub or not valid(pvp.sub) then
            if pvp_turn_order(true) then net_client_no_damage() end
        end
    end
end

-- ─── Batalha Rápida: mapa escolhido → esquadrão → combate direto ──────────────
-- Usa o lançamento rápido que os programadores deixaram no jogo (B_QuickLaunchViewModel + BRG_MissionTestingSettings).
-- O portal escreve mp_qb_cmd.json {"cmd":"launch","world":"/Game/.../SK_Ryloth_010_Root.SK_Ryloth_010_Root","pvp":bool,"ts":N};
-- o mod escreve a lista de mapas em mp_qb_worlds.json e o estado em mp_qb.json.
local QB_CMD, QB_STATE, QB_WORLDS = MOD_PATH .. "\\mp_qb_cmd.json", MOD_PATH .. "\\mp_qb.json", MOD_PATH .. "\\mp_qb_worlds.json"
local qb = { cmd_ts = 0, pvp = false, restore = false, worlds_done = false, launched_at = 0 }
-- ao arrancar ignora pedidos antigos; um pedido dos últimos 5 min (portal: "lançar e abrir o jogo") ainda corre
do local raw = read_file(QB_CMD); if raw then
    local ts = tonumber(raw:match('"ts"%s*:%s*(%d+)')) or 0
    qb.cmd_ts = (os.time() - ts < 300) and 0 or ts
end end

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

-- esquadrão escolhido no portal: caminhos de classe (/Game/.../Char_Hero_X.Char_Hero_X_C) escritos no
-- DefaultMissionSquad (lista de SoftClass que o lançamento de testes usa); sem lista fica o esquadrão de testes
local function qb_set_squad(paths)
    if type(paths) ~= "table" or #paths == 0 then return "padrão" end
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local mt = StaticFindObject("/Script/BitReactorGame.Default__BRG_MissionTestingSettings")
    if not (valid(ksl) and valid(mt)) then return "indisponível" end
    local arr = mt.DefaultMissionSquad
    pcall(function() arr:Empty() end)
    local n = 0
    for _, p in ipairs(paths) do
        if type(p) == "string" and p:find("^/Game/[%w_/%.%-]+_C$") then
            if pcall(function() arr[arr:GetArrayNum() + 1] = ksl:Conv_SoftClassPathToSoftClassRef(ksl:MakeSoftClassPath(p)) end) then n = n + 1 end
        end
    end
    return n
end

local function qb_launch(world_path, pvp, squad)
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
    step("lista", function() return qb_set_squad(squad) end)
    step("config", function() return vm:TrySettingMissionTestingConfigurations() end)
    step("mundo", function() return vm:SetDesiredWorld(w) end)
    step("esquadrão", function() return vm:TrySettingDesiredSquadFromMissionTesting() end)
    local _, ready = step("pronto", function() return vm:IsReadyForQuickLaunch() end)
    print("[ZeroCompanyMP] Batalha Rápida: " .. w.Name .. " — " .. table.concat(log, " "))
    step("lançar", function() return vm:TryQuickLaunching() end)
    qb.pvp, qb.restore, qb.launched_at = pvp and true or false, true, os.time()
    qb_state("a carregar " .. w.Name .. (pvp and " (1x1)" or "") .. " — " .. table.concat(log, " "))
end

-- todas as unidades jogáveis (registo de assets: /Game/Game/Core/Pawns) para o portal escolher as equipas
local QB_UNITS = MOD_PATH .. "\\mp_units.json"
local function qb_units()
    local h = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if not valid(h) then return nil end
    local ar = h:GetAssetRegistry()
    local t = {}
    ar:GetAssetsByPath(FName("/Game/Game/Core/Pawns"), t, true, false)
    local seen, list = {}, {}
    for _, a in ipairs(t) do
        local ok, pk, nm = pcall(function() local d = a:get(); return d.PackageName:ToString(), d.AssetName:ToString() end)
        if ok then
            local base = nm:gsub("_C$", "")
            local grp = pk:match("/EnemyCharacters/([^/]+)/") and ("Inimigos: " .. pk:match("/EnemyCharacters/([^/]+)/"))
                or (pk:find("/CampaignCharacters/") and "Campanha") or ((pk:find("/HeroCharacters/") or pk:find("/Pawns/Char_Hero_")) and "Heróis")
            if grp and base:find("^Char_") and not seen[base] and not pk:find("/VIP/") and not pk:find("/WeaponTesting/")
                and not base:find("Base") and not base:find("Cine") and not base:find("Prototype") and not base:find("ExploreNPC")
                and not base:find("Tutorial") and not base:find("DEPRICATED") and not base:find("_TEMP") and base ~= "Char_Hero_Humanoid" then
                seen[base] = true
                list[#list + 1] = { name = base:gsub("^Char_Hero_", ""):gsub("^Char_Enemy_", ""):gsub("^Char_", ""):gsub("_", " "), path = pk .. "." .. base .. "_C", group = grp }
            end
        end
    end
    table.sort(list, function(x, y) if x.group ~= y.group then return x.group < y.group end return x.name < y.name end)
    return list
end

local function qb_poll()
    if not qb.worlds_done then
        local list = qb_worlds()
        if list and #list > 0 then
            write_file(QB_WORLDS, json.encode(list)); qb.worlds_done = true
            local ok, units = pcall(qb_units)
            if ok and units and #units > 0 then write_file(QB_UNITS, json.encode(units)) end
            print("[ZeroCompanyMP] Unidades para o portal: " .. (ok and units and #units or tostring(units)))
        end
    end
    local raw = read_file(QB_CMD)
    if not raw then return end
    local ts = tonumber(raw:match('"ts"%s*:%s*(%d+)')) or 0
    if ts <= qb.cmd_ts then return end
    -- o portal pode pedir a batalha antes de o jogo abrir: espera (até 5 min) que o menu principal esteja pronto
    if not qb_vm() and os.time() - ts < 300 then
        if not qb.waiting then qb.waiting = true; qb_state("à espera do menu principal do jogo…") end
        return
    end
    qb.waiting = false
    qb.cmd_ts = ts
    local ok, c = pcall(json.decode, raw)
    if ok and type(c) == "table" and c.cmd == "launch" and type(c.world) == "string" then
        qb_launch(c.world, c.pvp, c.squad)
        qb.squad, qb.team_b = c.squad, tonumber(c.team_b)
    end
end

-- Modo batalha: o esquadrão lançado tem as duas equipas (A primeiro, as últimas team_b entradas são a B).
-- Já no mapa, a equipa B ocupa as posições dos inimigos do mapa (TeleportActor), esses inimigos saem
-- (K2_DestroyActor, testado estável em 21/10) e a B passa a EnemyTeam — o 1x1 depois alterna as duas.
-- unidades empilhadas no mesmo ponto (o mapa só tem 4 pontos de entrada por lado): cada uma que caia em cima de
-- outra procura, em anéis de 150 uu à volta, um sítio que o TeleportActor aceite
local function qb_spread(su, units)
    local placed = {}
    local function near(l)
        for _, p in ipairs(placed) do if math.abs(p.X - l.X) < 60 and math.abs(p.Y - l.Y) < 60 then return true end end
        return false
    end
    for _, u in ipairs(units) do
        local l = u:K2_GetActorLocation()
        local L = { X = l.X, Y = l.Y, Z = l.Z }
        if near(L) then
            local r = u:K2_GetActorRotation()
            local R = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
            local done = false
            for ring = 1, 5 do
                for dx = -ring, ring do
                    for dy = -ring, ring do
                        if not done and (math.abs(dx) == ring or math.abs(dy) == ring) then
                            local T = { X = L.X + dx * 150, Y = L.Y + dy * 150, Z = L.Z }
                            if not near(T) then
                                local ok, moved = pcall(function() return su:TeleportActor(u, T, R, false, false) end)
                                if ok and moved then done = true; L = T end
                            end
                        end
                    end
                end
                if done then break end
            end
        end
        placed[#placed + 1] = L
    end
end

local function qb_battle_setup(squad, team_b)
    if type(squad) ~= "table" then return end
    team_b = team_b or 0
    local st, su = pvp_statics()
    local te = StaticFindObject(TEAM_PATH.E)
    if not (valid(st) and valid(su) and valid(te)) then return end
    local want = {}                                   -- classe -> quantas unidades dessa classe são da equipa B
    for i = #squad - team_b + 1, #squad do local p = squad[i]; if type(p) == "string" then want[p] = (want[p] or 0) + 1 end end
    local heroes_a, heroes_b, enemies = {}, {}, {}
    for _, c in ipairs(level_units()) do
        local t = team_name(st, c)
        if t == "EnemyTeam_C" then enemies[#enemies + 1] = c
        elseif t == "PlayerTeam_C" then
            local cls = c:GetClass():GetFullName():gsub("^%S+%s+", "")
            if (want[cls] or 0) > 0 then want[cls] = want[cls] - 1; heroes_b[#heroes_b + 1] = c
            else heroes_a[#heroes_a + 1] = c end
        end
    end
    pcall(qb_spread, su, heroes_a)
    -- logo no início o jogo ainda volta a pôr as unidades nos pontos de entrada: espalha outra vez depois
    ExecuteWithDelay(4000, function() in_game_thread(function()
        local alive_a, alive_b = {}, {}
        for _, u in ipairs(heroes_a) do if valid(u) then alive_a[#alive_a + 1] = u end end
        for _, u in ipairs(heroes_b) do if valid(u) then alive_b[#alive_b + 1] = u end end
        pcall(qb_spread, su, alive_a); pcall(qb_spread, su, alive_b)
    end) end)
    if team_b < 1 then return end
    local spots = {}
    for _, e in ipairs(enemies) do
        local l, r = e:K2_GetActorLocation(), e:K2_GetActorRotation()
        spots[#spots + 1] = { L = { X = l.X, Y = l.Y, Z = l.Z }, R = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } }
    end
    -- o TeleportActor recusa alguns pontos (devolve false): tenta o ponto seguinte até um aceitar
    -- mais unidades B do que inimigos no mapa: as que sobram vão (forçado) para o 1.º ponto e o qb_spread espalha-as
    local next_spot, first = 1, nil
    for _, h in ipairs(heroes_b) do
        local moved = false
        while next_spot <= #spots and not moved do
            local s = spots[next_spot]
            next_spot = next_spot + 1
            local ok, r = pcall(function() return su:TeleportActor(h, s.L, s.R, false, false) end)
            moved = ok and r
            if moved and not first then first = s end
        end
        if not moved and first then pcall(function() su:TeleportActor(h, first.L, first.R, false, true) end) end
        pcall(function() su:ChangeActorTeam(h, te, true) end)
    end
    pcall(qb_spread, su, heroes_b)
    if #heroes_b > 0 then
        for _, e in ipairs(enemies) do if valid(e) then pcall(function() e:K2_DestroyActor() end) end end
    end
    print(("[ZeroCompanyMP] Modo batalha: equipa B = %d unidades, %d inimigos do mapa removidos"):format(#heroes_b, #heroes_b > 0 and #enemies or 0))
end

-- já em combate: desliga o Mission Testing (não mexe na campanha) e liga o 1x1 se foi pedido
local function qb_after_combat_start()
    if not qb.restore or combat_started_at < qb.launched_at then return end
    qb.restore = false
    qb_mission_testing(false)
    qb_state("em combate")
    if qb.squad then
        local okb, e = pcall(qb_battle_setup, qb.squad, qb.team_b)
        if not okb then print("[ZeroCompanyMP] Modo batalha erro: " .. tostring(e)) end
        qb.squad, qb.team_b = nil, nil
    end
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
    pcall(coop_poll)
    pcall(net_poll)
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
