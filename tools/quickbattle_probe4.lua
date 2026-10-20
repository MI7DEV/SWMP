-- Sonda 4 (SWMPDev): mundos de arranque, pacote de Mission Testing, esquadrão por omissão e o widget MissionTest.
local function s(x)
    if type(x) ~= "userdata" then return tostring(x) end
    local ok, v = pcall(function() return x:ToString() end); if ok and v then return v end
    ok, v = pcall(function() return x:IsValid() and x:GetFullName() end); if ok and v then return v end
    return tostring(x)
end
local function structfields(st)
    local t = {}
    pcall(function()
        local def = st:GetStruct()
        def:ForEachProperty(function(p) local n = p:GetFName():ToString(); local v = "?"; pcall(function() v = s(st[n]) end); t[#t + 1] = n .. "=" .. v end)
    end)
    return table.concat(t, " | ")
end
local gi = FindFirstOf("GameInstance")
local ok, worlds = pcall(function() return gi:GetStartingWorlds() end)
if ok and type(worlds) == "table" then
    out("== mundos de arranque: " .. #worlds)
    for i, w in ipairs(worlds) do
        local v = w
        pcall(function() v = w:get() end)
        local line = structfields(v)
        if line == "" then
            local parts = {}
            for _, f in ipairs({ "StartingWorld", "bShowInQuickLaunch", "bAllowInShipping", "bAllowOnConsoles", "MissionDefinitions" }) do
                local val = "?"; pcall(function() val = s(v[f]) end); parts[#parts + 1] = f .. "=" .. val
            end
            line = table.concat(parts, " | ")
        end
        out(("[%d] %s"):format(i, line))
    end
end
local mt = StaticFindObject("/Script/BitReactorGame.Default__BRG_MissionTestingSettings")
pcall(function() out("== Mission pkg: " .. structfields(mt.Mission)) end)
pcall(function()
    out("== DefaultMissionSquad:")
    mt.DefaultMissionSquad:ForEach(function(i, e) out("   " .. i .. ": " .. s(e:get())) end)
end)
local menu = FindFirstOf("QuickLaunchDebugMenu")
pcall(function() out("== menu CurrentSelectedTacticalWorld: " .. structfields(menu.CurrentSelectedTacticalWorld)) end)
pcall(function() out("   campanha=" .. s(menu.CurrentSelectedCampaign) .. " fação=" .. s(menu.SelectedFaction) .. " região=" .. s(menu.SelectedRegionTag) .. " local=" .. s(menu.SelectedMapLocationTag)) end)
local w = FindFirstOf("BP_Menu_MainMenu_MissionTest_C")
if w and w:IsValid() then
    out("== widget MissionTest: " .. w:GetFullName())
    local fns = {}
    pcall(function() w:GetClass():ForEachFunction(function(f) fns[#fns + 1] = f:GetFName():ToString() end) end)
    out("   funções: " .. table.concat(fns, " "))
    local ps = {}
    pcall(function() w:GetClass():ForEachProperty(function(p) local n = p:GetFName():ToString(); local v = "?"; pcall(function() v = s(w[n]) end); ps[#ps + 1] = n .. "=" .. v end) end)
    out("   props: " .. table.concat(ps, " | "))
    pcall(function() out("   visibilidade=" .. tostring(w:GetVisibility()) .. " noEcrã=" .. tostring(w:IsInViewport())) end)
end
