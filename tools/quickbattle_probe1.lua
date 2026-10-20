-- Sonda 1 (SWMPDev): onde vivem o "Mission Testing" / QuickLaunch / DevShell e o que expõem.
-- Copiar o conteúdo para ue4ss\Mods\SWMPDev\Scripts\dev_in.lua com o jogo aberto; resultado em dev_out.txt.
local function props(obj, filter)
    local t = {}
    pcall(function()
        obj:GetClass():ForEachProperty(function(p)
            local n = p:GetFName():ToString()
            if not filter or n:lower():find(filter) then
                local v = "?"
                pcall(function() v = tostring(obj[n]) end)
                t[#t + 1] = n .. "=" .. v
            end
        end)
    end)
    return table.concat(t, ", ")
end
local function funcs(cls)
    local t = {}
    pcall(function() cls:ForEachFunction(function(f) t[#t + 1] = f:GetFName():ToString() end) end)
    return table.concat(t, " ")
end
for _, mod in ipairs({ "BitReactorGame", "Bruno", "BRGame", "BitReactor" }) do
    for _, c in ipairs({ "MissionTestingSettings", "BrunoMissionTestingSettings", "BRGMissionTestingSettings",
                         "MissionCentral", "BrunoMissionCentral", "BrunoCheatManager", "BrunoGameInstance",
                         "BRGamePIEMissionData", "BrunoCampaignSubsystem", "BrunoMissionSubsystem" }) do
        local cls = StaticFindObject("/Script/" .. mod .. "." .. c)
        if cls and cls:IsValid() then
            out("== /Script/" .. mod .. "." .. c)
            out("  funções: " .. funcs(cls))
            local cdo = StaticFindObject("/Script/" .. mod .. ".Default__" .. c)
            if cdo and cdo:IsValid() then out("  CDO: " .. props(cdo)) end
        end
    end
end
-- instâncias vivas com missão no nome
for _, n in ipairs({ "MissionCentral", "BrunoGameInstance", "GameInstance" }) do
    local o = FindFirstOf(n)
    if o and o:IsValid() then out("vivo " .. n .. ": " .. o:GetFullName()); out("  " .. props(o, "mission")) end
end
