-- ZeroCompanyMP/main.lua — v0.3
-- Classes confirmadas via source de mods públicos (SquadSixReforged, FastResonance)
-- Módulo do jogo: BitReactorGame (não SWZeroCompany como assumido em v0.2)

local JSON_OK, json = pcall(require, "json")
local MOD_PATH    = debug.getinfo(1).short_src:match("^(.+)[/\\]") or "."
local CMD_FILE    = MOD_PATH .. "\\mp_command.json"
local RESULT_FILE = MOD_PATH .. "\\mp_result.json"
local SYNC_OUT    = MOD_PATH .. "\\mp_sync_out.json"
local SYNC_IN     = MOD_PATH .. "\\mp_sync_in.json"

-- ─── Classe alvo do jogo ──────────────────────────────────────────────────────
-- Confirmado por SquadSixReforged/placement.lua (TACTICAL_GAME_STATE_CLASS)
local GS_CLASS        = "/Script/BitReactorGame.TacticalGameState"
-- Propriedades confirmadas por SquadSixReforged/placement.lua
local PLAYER_SQUAD_PROP  = "PlayerSquad"        -- BitReactorGameSquad
local SQUAD_MEMBERS_PROP = "SquadMembers"        -- TArray de unidades
local OWNING_TEAM_PROP   = "OwningTeam"
-- CombatPreparationArea para detectar início de combate
local PREP_AREA_CLASS = "/Script/BitReactorGame.CombatPreparationArea"

-- ─── Estado local ─────────────────────────────────────────────────────────────
local my_role      = "host"
local my_units     = {}
local split_active = false
local last_cmd_ts  = 0
local combat_active = false

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

-- ─── Explorer: encontra unidades via TacticalGameState ───────────────────────
local function run_explorer()
    print("[ZeroCompanyMP] Explorer v0.3 iniciando...")
    local classes = {}
    local units = {}
    local raw_lines = {}

    -- TacticalGameState — classe confirmada em BitReactorGame
    local gs_list = FindAllOf("TacticalGameState")
    if gs_list and #gs_list > 0 then
        for _, gs in ipairs(gs_list) do
            if valid(gs) then
                local gs_name = gs:GetFullName()
                classes.tactical_game_state = gs_name:match("([^%.]+)$") or gs_name
                table.insert(raw_lines, "TacticalGameState: " .. gs_name)

                -- Aceder ao squad do jogador via PlayerSquad.SquadMembers
                local ok_squad, squad = pcall(function() return gs[PLAYER_SQUAD_PROP] end)
                if ok_squad and valid(squad) then
                    table.insert(raw_lines, "PlayerSquad encontrado: " .. squad:GetFullName())
                    classes.player_squad = "BitReactorGameSquad"

                    local ok_members, members = pcall(function() return squad[SQUAD_MEMBERS_PROP] end)
                    if ok_members and members ~= nil then
                        local ok_count, count = pcall(function() return members:GetArrayNum() end)
                        if ok_count and count then
                            table.insert(raw_lines, "SquadMembers count: " .. tostring(count))
                            for i = 1, math.min(count, 8) do
                                local ok_m, member = pcall(function() return members[i] end)
                                if ok_m and valid(member) then
                                    local mn = member:GetFullName()
                                    table.insert(units, mn)
                                    table.insert(raw_lines, "Unit[" .. (#units-1) .. "]: " .. mn)
                                end
                            end
                        end
                    end
                else
                    table.insert(raw_lines, "PlayerSquad nao acessivel (combate ainda nao iniciado?)")
                end

                break -- só precisamos de um TacticalGameState
            end
        end
    else
        table.insert(raw_lines, "AVISO: TacticalGameState nao encontrado — abre o jogo numa batalha!")
        -- Fallback: tentar GameStateBase genérico
        local generic_gs = UEHelpers and UEHelpers.GetGameStateBase and UEHelpers.GetGameStateBase()
        if generic_gs and valid(generic_gs) then
            local n = generic_gs:GetFullName()
            table.insert(raw_lines, "GameStateBase (fallback): " .. n)
            classes.game_state_fallback = n:match("([^%.]+)$") or n
        end
    end

    -- Outros managers táticos (confirmados por SquadSixReforged: usa "BitReactorGame")
    local manager_types = {"Turn", "Battle", "Action", "Combat", "Unit", "Ability", "Mission", "Tactical"}
    for _, kw in ipairs(manager_types) do
        local found = FindAllOf(kw .. "Manager")
        if found and #found > 0 then
            for _, o in ipairs(found) do
                if valid(o) then
                    local n = o:GetFullName()
                    local short = n:match("([^%.]+)$") or n
                    local key = kw:lower() .. "_manager"
                    if not classes[key] then
                        classes[key] = short
                        table.insert(raw_lines, kw .. "Manager: " .. n)
                    end
                    break
                end
            end
        end
    end

    -- PlayerController
    local pc = UEHelpers and UEHelpers.GetPlayerController and UEHelpers.GetPlayerController()
    if pc and valid(pc) then
        local n = pc:GetFullName()
        table.insert(raw_lines, "PlayerController: " .. n)
        classes.player_controller = n:match("([^%.]+)$") or n
    end

    classes.units = units
    classes.game_module = "BitReactorGame"

    local result = {classes = classes, raw = table.concat(raw_lines, "\n"), ts = os.time()}
    local ok = write_file(RESULT_FILE, encode(result))
    if ok then
        print("[ZeroCompanyMP] Explorer: " .. #raw_lines .. " linhas, " .. #units .. " unidades.")
    end
end

-- ─── Split de personagens ─────────────────────────────────────────────────────
local function apply_split(split)
    if not split then return end
    my_units = split[my_role] or {}
    split_active = #my_units > 0
    print("[ZeroCompanyMP] Split ativo — unidades: " ..
          table.concat(my_units, ",") .. " (role=" .. my_role .. ")")
end

local function is_my_unit(unit_index)
    for _, idx in ipairs(my_units) do
        if idx == unit_index then return true end
    end
    return false
end

-- ─── Hook CombatPreparationArea para detectar início de combate ──────────────
-- Confirmado por SquadSixReforged/placement.lua
local function register_combat_hooks()
    local ok = pcall(function()
        NotifyOnNewObject(GS_CLASS, function(gs)
            if not valid(gs) then return end
            combat_active = true
            print("[ZeroCompanyMP] TacticalGameState detectado — combate ativo.")
            -- Re-run explorer se ainda não temos unidades
            if #(results_units or {}) == 0 then
                ExecuteWithDelay(2000, function()
                    run_explorer()
                end)
            end
        end)
    end)
    if ok then
        print("[ZeroCompanyMP] Hook TacticalGameState registado.")
    else
        print("[ZeroCompanyMP] AVISO: hook TacticalGameState falhou.")
    end

    -- Hook para TriggerCombatInit na área de prep
    pcall(function()
        RegisterHook("/Script/BitReactorGame.CombatPreparationArea:TriggerCombatInit",
            function()
                print("[ZeroCompanyMP] TriggerCombatInit — combate a iniciar.")
                combat_active = true
            end,
            nil
        )
    end)
end

-- ─── Lista de mods instalados ─────────────────────────────────────────────────
local function get_mod_list()
    local mods = {}
    local mods_txt = MOD_PATH .. "\\..\\mods.txt"
    local content = read_file(mods_txt)
    if content then
        for line in content:gmatch("[^\r\n]+") do
            local name = line:match("^(%S+)%s*:")
            if name and name ~= "ZeroCompanyMP" then
                table.insert(mods, name)
            end
        end
    end
    return mods
end

-- ─── Poll de comandos do servidor Python ─────────────────────────────────────
local function poll()
    local raw = read_file(CMD_FILE)
    if raw then
        local cmd = decode(raw)
        if cmd then
            local ts = cmd.ts or 0
            if ts > last_cmd_ts then
                last_cmd_ts = ts
                print("[ZeroCompanyMP] Cmd: " .. tostring(cmd.cmd))

                if cmd.cmd == "explore" then
                    run_explorer()
                elseif cmd.cmd == "set_split" then
                    apply_split(cmd.split)
                elseif cmd.cmd == "set_role" then
                    my_role = cmd.role or "host"
                    apply_split(cmd.split)
                elseif cmd.cmd == "start_sync" then
                    print("[ZeroCompanyMP] Sincronização ativada.")
                end
            end
        end
    end

    -- Ações recebidas do outro jogador
    local syn = read_file(SYNC_IN)
    if syn then
        local action = decode(syn)
        if action and action.ts and action.ts > (last_cmd_ts - 1) then
            print("[ZeroCompanyMP] Ação recebida: " .. tostring(action.type))
        end
    end
end

-- ─── Init ─────────────────────────────────────────────────────────────────────
register_combat_hooks()

ExecuteWithDelay(2000, function()
    local mods = get_mod_list()
    print("[ZeroCompanyMP] " .. #mods .. " mods encontrados.")
end)

print("==============================================")
print(" ZeroCompanyMP v0.3 carregado")
print(" Módulo jogo: BitReactorGame (confirmado)")
print(" TacticalGameState hook: ativo")
print(" Para explorar: enviar cmd 'explore' com jogo numa batalha")
print("==============================================")

local function loop()
    poll()
    ExecuteWithDelay(1000, loop)
end
loop()
