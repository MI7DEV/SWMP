-- Sonda 3 (SWMPDev): o menu QuickLaunchDebugMenu vivo, o seu ViewModel, os mundos de arranque e o Mission Testing.
local function props(obj, max)
    local t, n = {}, 0
    pcall(function()
        local cls = obj:GetClass()
        while cls and cls:IsValid() do
            cls:ForEachProperty(function(p)
                n = n + 1
                if n > (max or 80) then return end
                local name = p:GetFName():ToString()
                local v = "?"
                pcall(function()
                    local x = obj[name]
                    if type(x) == "userdata" then
                        local ok, fn = pcall(function() return x:IsValid() and x:GetFullName() end)
                        if ok and fn then v = fn else
                            local okn, num = pcall(function() return x:GetArrayNum() end)
                            v = okn and ("[" .. tostring(num) .. "]") or tostring(x)
                        end
                    else v = tostring(x) end
                end)
                t[#t + 1] = name .. "=" .. v
            end)
            local ok, sup = pcall(function() return cls:GetSuperStruct() end)
            if not ok or not sup or not sup:IsValid() then break end
            local sn = sup:GetFName():ToString()
            if sn == "UserWidget" or sn == "Object" or sn == "Widget" then break end
            cls = sup
        end
    end)
    return table.concat(t, "\n    ")
end
local function funcs(path)
    local t = {}
    local cls = StaticFindObject(path)
    if cls and cls:IsValid() then pcall(function() cls:ForEachFunction(function(f) t[#t + 1] = f:GetFName():ToString() end) end) end
    return table.concat(t, " ")
end
out("== funções QuickLaunchDebugMenu: " .. funcs("/Script/Bruno.QuickLaunchDebugMenu"))
out("== funções B_QuickLaunchViewModel: " .. funcs("/Script/Bruno.B_QuickLaunchViewModel"))
out("== funções BrunoStrategyStatics: " .. funcs("/Script/Bruno.BrunoStrategyStatics"))
out("== funções BrunoMissionCentral: " .. funcs("/Script/Bruno.BrunoMissionCentral"))
local menu = FindFirstOf("QuickLaunchDebugMenu")
if menu and menu:IsValid() then
    out("== menu vivo: " .. menu:GetFullName())
    out("    " .. props(menu, 120))
end
local vms = FindAllOf("B_QuickLaunchViewModel") or {}
for _, vm in ipairs(vms) do
    if vm:IsValid() then out("== VM vivo: " .. vm:GetFullName()); out("    " .. props(vm, 80)) end
end
local mt = StaticFindObject("/Script/BitReactorGame.Default__BRG_MissionTestingSettings")
if mt and mt:IsValid() then out("== MissionTestingSettings CDO"); out("    " .. props(mt, 40)) end
local gi = FindFirstOf("GameInstance")
if gi and gi:IsValid() then
    out("== GameInstance: " .. gi:GetFullName())
    local ok, worlds = pcall(function() return gi:GetStartingWorlds() end)
    out("    GetStartingWorlds ok=" .. tostring(ok) .. " -> " .. tostring(worlds))
    if ok and type(worlds) == "userdata" then
        pcall(function()
            worlds:ForEach(function(i, w)
                local s = w:get()
                local name, inq, ship = "?", "?", "?"
                pcall(function() name = s.StartingWorld:ToString() end)
                pcall(function() inq = tostring(s.bShowInQuickLaunch) end)
                pcall(function() ship = tostring(s.bAllowInShipping) end)
                out(("    [%d] %s quick=%s shipping=%s"):format(i, name, inq, ship))
            end)
        end)
    end
end
