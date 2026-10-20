-- Sonda 2 (SWMPDev): a que classes pertencem as funções do Quick Launch / Mission Testing, e que objetos
-- carregados têm QuickLaunch/DevShell/MissionTesting no nome. Pode demorar 1-3 s (percorre todos os objetos).
local want = { TryQuickLaunching = 1, IsReadyForQuickLaunch = 1, SetDesiredWorld = 1, AddCharacterToSquad = 1,
    TrySettingMissionTestingConfigurations = 1, LaunchMissionWithSquad = 1, LaunchMission = 1, GetStartingWorlds = 1,
    IsMissionTestingEnabled = 1, PrepMissionForLaunch = 1, GetMissionCentral = 1 }
local seen, n = {}, 0
ForEachUObject(function(obj)
    n = n + 1
    local ok, name = pcall(function() return obj:GetFName():ToString() end)
    if not ok or not name then return end
    if want[name] or name:find("QuickLaunch") or name:find("DevShell") or name:find("MissionTesting") or name:find("StartingWorld") then
        local full = "?"
        pcall(function() full = obj:GetFullName() end)
        if not seen[full] then seen[full] = true; out(full) end
    end
end)
out("objetos percorridos: " .. n)
