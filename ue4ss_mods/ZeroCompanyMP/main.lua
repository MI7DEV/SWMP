-- ZeroCompanyMP/main.lua — v0.2
-- Divisão automática de personagens: host=0..N-1, client=N..2N-1

local JSON_OK, json = pcall(require, "json")
local MOD_PATH   = debug.getinfo(1).short_src:match("^(.+)[/\\]") or "."
local CMD_FILE   = MOD_PATH .. "\\mp_command.json"
local RESULT_FILE= MOD_PATH .. "\\mp_result.json"
local SYNC_OUT   = MOD_PATH .. "\\mp_sync_out.json"
local SYNC_IN    = MOD_PATH .. "\\mp_sync_in.json"
local MODS_FILE  = MOD_PATH .. "\\mp_modlist.json"

-- ─── Estado local ─────────────────────────────────────────────────────────────

local my_role   = "host"   -- "host" | "client"  (definido pelo split recebido)
local my_units  = {}       -- índices das unidades que controlo
local all_units = {}       -- lista de todas as unidades encontradas
local split_active = false
local last_cmd_ts  = 0

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
    if JSON_OK then local ok,v = pcall(json.decode,s); return ok and v or nil end
    return nil
end

local function encode(t)
    if JSON_OK then local ok,v = pcall(json.encode,t); return ok and v or "{}" end
    return "{}"
end

-- ─── Lista de mods ────────────────────────────────────────────────────────────

local function get_mod_list()
    local mods = {}
    -- Tentar listar Mods/ via UE4SS
    -- Simplificado: lê mods.txt que o UE4SS usa
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

-- ─── Explorer ─────────────────────────────────────────────────────────────────

local function run_explorer()
    print("[ZeroCompanyMP] Explorer iniciando...")
    local classes = {}
    local raw_lines = {}
    local units = {}

    local gs = UEHelpers.GetGameStateBase()
    if gs and gs:IsValid() then
        local n = gs:GetFullName()
        table.insert(raw_lines, "GameState: " .. n)
        classes.game_state = n:match("([^%.]+)$") or n
    end

    local pc = UEHelpers.GetPlayerController()
    if pc and pc:IsValid() then
        local n = pc:GetFullName()
        table.insert(raw_lines, "PlayerController: " .. n)
        classes.player_controller = n:match("([^%.]+)$") or n
    end

    -- Managers
    local keywords = {"Turn","Battle","Squad","Unit","Action","Ability","Mission","Tactical","Combat"}
    for _, kw in ipairs(keywords) do
        local found = FindAllOf(kw .. "Manager")
        if found and #found > 0 then
            for _, o in ipairs(found) do
                if o:IsValid() then
                    local n = o:GetFullName()
                    local short = n:match("([^%.]+)$") or n
                    local key = kw:lower() .. "_manager"
                    if not classes[key] then
                        classes[key] = short
                        table.insert(raw_lines, kw .. "Manager: " .. n)
                    end
                end
            end
        end
    end

    -- Unidades jogáveis (Pawns com tag de personagem)
    local pawn_types = {"Character","Unit","Soldier","Trooper","Agent"}
    for _, pt in ipairs(pawn_types) do
        local found = FindAllOf(pt)
        if found then
            for i, o in ipairs(found) do
                if o:IsValid() and i <= 6 then
                    local n = o:GetFullName()
                    if n:match("/Script/SWZeroCompany") then
                        table.insert(units, n)
                        table.insert(raw_lines, "Unit[" .. (#units-1) .. "]: " .. n)
                    end
                end
            end
        end
    end
    classes.units = units

    -- UObjects do jogo
    local count = 0
    ForEachUObject(function(obj, _)
        if count >= 100 then return end
        if not obj:IsValid() then return end
        local name = obj:GetFullName()
        if name:match("^/Script/SWZeroCompany") then
            table.insert(raw_lines, name); count = count + 1
        end
    end)

    local result = {classes=classes, raw=table.concat(raw_lines,"\n"), ts=os.time()}
    local ok = write_file(RESULT_FILE, encode(result))
    if ok then
        print("[ZeroCompanyMP] Explorer: " .. #raw_lines .. " linhas, " .. #units .. " unidades.")
        -- Guardar lista de mods também
        local mod_result = {mods=get_mod_list(), ts=os.time()}
        write_file(MODS_FILE, encode(mod_result))
    end
end

-- ─── Split de personagens ──────────────────────────────────────────────────────

local function apply_split(split)
    if not split then return end
    my_units = split[my_role] or {}
    split_active = #my_units > 0
    print("[ZeroCompanyMP] Split ativo — eu controlo unidades: " ..
          table.concat(my_units, ",") .. " (role=" .. my_role .. ")")
end

local function is_my_unit(unit_index)
    for _, idx in ipairs(my_units) do
        if idx == unit_index then return true end
    end
    return false
end

-- ─── Polling de comandos ──────────────────────────────────────────────────────

local function poll()
    -- Comandos do servidor
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
            -- TODO: replay de ações quando classes forem conhecidas
            print("[ZeroCompanyMP] Ação recebida: " .. tostring(action.type))
        end
    end
end

-- ─── Init ─────────────────────────────────────────────────────────────────────

-- Enviar lista de mods ao arrancar
ExecuteWithDelay(2000, function()
    local mods = get_mod_list()
    local out = {type="mod_list", mods=mods, ts=os.time()}
    write_file(MOD_PATH .. "\\mp_modlist_out.json", encode(out))
    print("[ZeroCompanyMP] " .. #mods .. " mods encontrados.")
end)

print("==============================================")
print(" ZeroCompanyMP v0.2 carregado")
print(" Split: host=0,1  client=2,3  (ajusta após explorer)")
print("==============================================")

local function loop()
    poll()
    ExecuteWithDelay(1000, loop)
end
loop()
