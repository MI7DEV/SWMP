-- ZeroCompanyMP/main.lua — v0.6
-- Classes confirmadas via ZCSDK jmap (SWZeroCompany-5.6.1-199049.jmap)
-- Módulo do jogo: BitReactorGame

local JSON_OK, json = pcall(require, "json")
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
    if team then
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
            print("[ZeroCompanyMP] TacticalGameState: combate ativo.")
            ExecuteWithDelay(2000, function()
                run_explorer()
                broadcast_turn(get_turn_state(), is_player_turn())
            end)
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

ExecuteWithDelay(3000, function()
    print("[ZeroCompanyMP] Verificando estado inicial...")
    local ts_state = get_turn_state()
    if ts_state then
        combat_active = true
        print(("[ZeroCompanyMP] Em combate: round=%d team=%s"):format(
            ts_state.round, ts_state.team_name))
        run_explorer()
    end
end)

print("==============================================")
print(" ZeroCompanyMP v0.6 carregado")
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
    local ok, n = pcall(function() return sw:GetFName():ToString() end)
    if not ok or not n then return nil end
    return n:match("%-(.+)$") or n
end

local function scan_tracks()
    local snap = {}
    local list = FindAllOf("MusicPlaylistAsset")
    if not list then return snap end
    for _, a in ipairs(list) do
        local an = a:GetFName():ToString()
        for _, field in ipairs({ "CombatMusicPlaylists", "ExploreMusicPlaylists" }) do
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

local function apply_music_mute()
    local raw = read_file(MUSIC_CTRL)
    local want = raw ~= nil and raw:find('"mute"%s*:%s*true') ~= nil
    -- o portal renova "ts" a cada poucos segundos; sem sinal há 20s (página fechada) → repõe a música
    local ts = raw and tonumber(raw:match('"ts"%s*:%s*(%d+)')) or 0
    if want and os.time() - ts > 20 then want = false end
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
local function loop()
    poll()
    scene_tick = scene_tick + 1
    if scene_tick % 2 == 0 then pcall(update_scene); pcall(apply_music_mute) end
    ExecuteWithDelay(1000, loop)
end
loop()
