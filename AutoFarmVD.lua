repeat task.wait() until game:IsLoaded()

-- ==========================================
-- GAME PLACE ID FILTER GUARD
-- ==========================================
local TARGET_PLACE_IDS = {
    [93978595733734] = true,
}

if not TARGET_PLACE_IDS[game.PlaceId] then
    warn(string.format("[AutoFarmVD] Aborted: PlaceId (%s) is not Violence District.", tostring(game.PlaceId)))
    return
end

-- ==========================================
-- CONFIGURATION & DEFAULT GLOBALS
-- ==========================================
if _G.WebhookUrl            == nil then _G.WebhookUrl            = "https://discord.com/api/webhooks/1534095369951248558/-a0wP7Kbkm0uoPB94EwdDg0OCQr3ZNnWERVLxut0_PbIlGXvV4DWhGC315sq4u38XfLY" end
if _G.AutoFarm              == nil then _G.AutoFarm              = true  end
if _G.HopDelay              == nil then _G.HopDelay              = 3     end
if _G.WebhookEnabled        == nil then _G.WebhookEnabled        = true  end
if _G.ServerHopEnabled      == nil then _G.ServerHopEnabled      = true  end
if _G.RejoinEnabled         == nil then _G.RejoinEnabled         = true  end
if _G.RetryTP               == nil then _G.RetryTP               = true  end
if _G.RetryTPDelay          == nil then _G.RetryTPDelay          = 5     end
if _G.AutoDisableKillerChance == nil then _G.AutoDisableKillerChance = true  end
if _G.MaxFinishlineCycles   == nil then _G.MaxFinishlineCycles   = 3     end

-- ==========================================
-- SERVICES & VARIABLES
-- ==========================================
local HttpService       = game:GetService("HttpService")
local TeleportService   = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local Players           = game:GetService("Players")
local CoreGui           = game:GetService("CoreGui")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local GuiService        = game:GetService("GuiService")
local StatsService      = game:GetService("Stats")

local LocalPlayer = Players.LocalPlayer

-- ==========================================
-- LOAD DELIRIUM
-- ==========================================
-- Try local paths first (relative to executor working dir), fallback to raw GitHub URL.
local DELIRIUM_LOCAL_PATHS = {
    [["dist\\Delirium.lua",                        -- cwd = Dev\Delirium
    "Dev\\Delirium\\dist\\Delirium.lua",          -- cwd = Workspace
    "Delirium\\dist\\Delirium.lua",]]              -- cwd = Dev
}
local DELIRIUM_RAW_URL = "https://raw.githubusercontent.com/DanteLuau/Delirium-Projects/refs/heads/main/dist/Delirium.lua"

local src
if type(readfile) == "function" and type(isfile) == "function" then
    for _, path in ipairs(DELIRIUM_LOCAL_PATHS) do
        if isfile(path) then
            local ok, content = pcall(readfile, path)
            if ok and content and #content > 100 then
                src = content
                print("[AutoFarmVD] Delirium loaded from local: " .. path)
                break
            end
        end
    end
end

if not src or #src < 100 then
    print("[AutoFarmVD] Local not found, fetching from GitHub...")
    src = game:HttpGet(DELIRIUM_RAW_URL)
end

assert(src and #src > 100, "[AutoFarmVD] Failed to load Delirium.lua (local + remote)")
local Delirium = loadstring(src)()
assert(Delirium and Delirium.CreateWindow, "[AutoFarmVD] Delirium nil setelah load")

-- ==========================================
-- SAVE / LOAD SYSTEM
-- ==========================================
local SAVE_FILE_NAME = "AutoFarmV4_StatsSave.json"

local sessionStartTick  = tick()
local totalEscapes      = 0
local totalMoneyEarned  = 0
local currentFps        = 0
local currentPing       = 0

local function loadPersistentStats()
    if isfile and readfile and isfile(SAVE_FILE_NAME) then
        pcall(function()
            local data = HttpService:JSONDecode(readfile(SAVE_FILE_NAME))
            if data then
                totalEscapes     = data.totalEscapes     or 0
                totalMoneyEarned = data.totalMoneyEarned or 0
                sessionStartTick = data.sessionStartTick or tick()
            end
        end)
    else
        sessionStartTick = tick()
    end
end

local function savePersistentStats()
    if writefile then
        pcall(function()
            writefile(SAVE_FILE_NAME, HttpService:JSONEncode({
                totalEscapes     = totalEscapes,
                totalMoneyEarned = totalMoneyEarned,
                sessionStartTick = sessionStartTick,
            }))
        end)
    end
end

local function resetPersistentStats()
    totalEscapes     = 0
    totalMoneyEarned = 0
    sessionStartTick = tick()
    savePersistentStats()
end

loadPersistentStats()

-- ==========================================
-- FPS / PING / RUNTIME
-- ==========================================
local fpsCounter    = 0
local lastFpsUpdate = tick()
RunService.RenderStepped:Connect(function()
    fpsCounter = fpsCounter + 1
    if tick() - lastFpsUpdate >= 1 then
        currentFps  = fpsCounter
        fpsCounter  = 0
        lastFpsUpdate = tick()
    end
end)

local function getPing()
    pcall(function()
        currentPing = math.floor(StatsService.Network.ServerStatsItem["Data Ping"]:GetValue())
    end)
    return currentPing
end

local function getFormattedRuntime()
    local e = math.floor(tick() - sessionStartTick)
    return string.format("%02dh %02dm %02ds", math.floor(e/3600), math.floor((e%3600)/60), e%60)
end

-- ==========================================
-- SPECTATOR & GAME READERS
-- ==========================================
local function getSpectatorTime()
    local t = "--:--"
    pcall(function()
        local pg    = LocalPlayer:FindFirstChild("PlayerGui")
        local label = pg and pg:FindFirstChild("Spectator")
            and pg.Spectator:FindFirstChild("time")
            and pg.Spectator.time:FindFirstChild("TimerLabel")
        if label and label:IsA("TextLabel") then t = label.Text end
    end)
    return t
end

local function parseTimerSeconds(s)
    if not s or s == "--:--" then return nil end
    local m, sec = s:match("(%d+):(%d+)")
    if m and sec then return (tonumber(m) * 60) + tonumber(sec) end
    return nil
end

local function fmtNum(v)
    local cleaned = (tostring(v or 0):gsub(",", ""):gsub("%s", ""))
    local s = tostring(math.floor(tonumber(cleaned) or 0)):reverse()
    local result = s:gsub("(%d%d%d)", "%1,")
    return result:reverse():gsub("^,", "")
end

local function parseNum(v)
    if v == nil then return 0 end
    local cleaned = (tostring(v):gsub(",", ""):gsub("%s", ""))
    return tonumber(cleaned) or 0
end

local function getAccountStats()
    local level, screws, gears, killerChance

    pcall(function()
        level       = LocalPlayer:GetAttribute("Level")
        screws      = LocalPlayer:GetAttribute("Screws")
        gears       = LocalPlayer:GetAttribute("Gears")
        killerChance = LocalPlayer:GetAttribute("KillerChance")
    end)

    pcall(function()
        local info = LocalPlayer:FindFirstChild("PlayerGui")
            and LocalPlayer.PlayerGui:FindFirstChild("Spectator")
            and LocalPlayer.PlayerGui.Spectator:FindFirstChild("Info")
            and LocalPlayer.PlayerGui.Spectator.Info:FindFirstChild("Your")
        if info then
            if (level == nil or level == 0) and info:FindFirstChild("Border") and info.Border:FindFirstChild("Level") then
                level = info.Border.Level.Text
            end
            if (screws == nil or screws == 0) and info:FindFirstChild("Screws") then screws = info.Screws.Text end
            if (gears  == nil or gears  == 0) and info:FindFirstChild("Gears")  then gears  = info.Gears.Text  end
            if (killerChance == nil or killerChance == 0) and info:FindFirstChild("KillerChance") then
                killerChance = info.KillerChance.Text
            end
        end
    end)

    pcall(function()
        local ls = LocalPlayer:FindFirstChild("leaderstats")
        if ls then
            if (screws == nil or screws == 0) and ls:FindFirstChild("Screws") then screws = ls.Screws.Value end
            if (level  == nil or level  == 0) and ls:FindFirstChild("Level")  then level  = ls.Level.Value  end
            if (gears  == nil or gears  == 0) and ls:FindFirstChild("Gears")  then gears  = ls.Gears.Value  end
        end
    end)

    return {
        Level       = parseNum(level),
        Screws      = parseNum(screws),
        Gears       = parseNum(gears),
        KillerChance = parseNum(killerChance),
    }
end

-- ==========================================
-- EXECUTOR & HTTP DETECTION
-- ==========================================
local requestFunc = (syn and syn.request)
    or (http and http.request)
    or http_request
    or (fluxus and fluxus.request)
    or request

local queueOnTeleport = queue_on_teleport
    or (syn and syn.queue_on_teleport)
    or (fluxus and fluxus.queue_on_teleport)

-- ==========================================
-- STATE VARIABLES
-- ==========================================
local isRoundActive          = false
local isHopping              = false
local freezeConnection       = nil
local SURVIVOR_TEAM_NAME     = "Survivors"
local webhookSentThisEscape  = false

local initialAccountStats    = getAccountStats()
local statsBeforeEscape      = {
    Level       = initialAccountStats.Level,
    Screws      = initialAccountStats.Screws,
    Gears       = initialAccountStats.Gears,
    KillerChance = initialAccountStats.KillerChance,
}

local roundScrewsEarned = 0
local roundGearsEarned  = 0
local roundBadges       = {}
local roundEvents       = {}

task.spawn(function()
    for _ = 1, 30 do
        if not isRoundActive then
            local live = getAccountStats()
            if live.Screws > 0 or live.Level > 0 then
                if statsBeforeEscape.Screws == 0 or statsBeforeEscape.Screws == nil then
                    statsBeforeEscape.Screws = live.Screws
                end
                if statsBeforeEscape.Level  == 0 or statsBeforeEscape.Level  == nil then
                    statsBeforeEscape.Level  = live.Level
                end
                if statsBeforeEscape.Gears  == 0 or statsBeforeEscape.Gears  == nil then
                    statsBeforeEscape.Gears  = live.Gears
                end
                break
            end
        end
        task.wait(0.2)
    end
end)

local function applyQueueOnTeleport()
    savePersistentStats()
    local scriptSource = [=[
        repeat task.wait() until game:IsLoaded()
        local src = (readfile and isfile and isfile("Dev\\Delirium\\AutoFarmVD.lua") and readfile("Dev\\Delirium\\AutoFarmVD.lua"))
            or game:HttpGet("https://raw.githubusercontent.com/DanteLuau/Delirium-Projects/refs/heads/main/AutoFarmVD.lua")
        loadstring(src)()
    ]=]
    if queueOnTeleport then pcall(queueOnTeleport, scriptSource) end
end

-- ==========================================
-- AUTO RECONNECT / REJOIN
-- ==========================================
local function autoReconnect(reason)
    if isHopping then return end
    isHopping = true
    warn(string.format("[AUTO RECONNECT] %s", tostring(reason)))
    applyQueueOnTeleport()
    task.wait(2)
    pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
end

GuiService.ErrorMessageChanged:Connect(function()
    autoReconnect("GuiService Error")
end)

task.spawn(function()
    local overlay = CoreGui:WaitForChild("RobloxPromptGui", 10)
        and CoreGui.RobloxPromptGui:FindFirstChild("promptOverlay")
    if overlay then
        overlay.ChildAdded:Connect(function(c)
            if c.Name == "ErrorPrompt" then autoReconnect("Roblox Error Prompt") end
        end)
        if overlay:FindFirstChild("ErrorPrompt") then autoReconnect("Existing Error Prompt") end
    end
end)

TeleportService.TeleportInitFailed:Connect(function()
    autoReconnect("TeleportInitFailed")
end)

-- ==========================================
-- DISCORD WEBHOOK
-- ==========================================
local function getShortRuntime()
    local e = math.floor(tick() - sessionStartTick)
    local h = math.floor(e / 3600)
    local m = math.floor((e % 3600) / 60)
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%dm", m)
end

local function sendDiscordWebhook(actionMessage, rewardAmount, gearsGainedDelta, gearsAtEscape)
    if not _G.WebhookEnabled then return false end
    local url = _G.WebhookUrl
    if not url or url == "" then return false end
    if not requestFunc then return false end

    local isTest       = (actionMessage == "TEST_WEBHOOK")
    local escapeReward = parseNum(rewardAmount)

    local statsAfter  = getAccountStats()
    local before      = statsBeforeEscape

    local screwsBefore  = parseNum(before.Screws)
    local gearsBefore   = parseNum(before.Gears)
    local levelBefore   = parseNum(before.Level)
    local currentScrews = parseNum(statsAfter.Screws)
    local gearsCurrent  = parseNum(statsAfter.Gears)
    local levelCurrent  = parseNum(statsAfter.Level)

    local totalScrewsGained = roundScrewsEarned
    if totalScrewsGained == 0 then totalScrewsGained = escapeReward end
    local attrDelta = math.max(0, currentScrews - screwsBefore)
    if attrDelta > totalScrewsGained then totalScrewsGained = attrDelta end
    if screwsBefore == 0 and currentScrews > 0 then
        screwsBefore = math.max(0, currentScrews - totalScrewsGained)
    end

    local screwsAfter = currentScrews
    if screwsAfter <= screwsBefore and totalScrewsGained > 0 then
        screwsAfter = screwsBefore + totalScrewsGained
    elseif screwsAfter > screwsBefore and totalScrewsGained == 0 then
        totalScrewsGained = screwsAfter - screwsBefore
    end

    local gearsGained = 0
    if gearsGainedDelta and gearsGainedDelta > 0 then
        gearsGained = gearsGainedDelta
        gearsBefore = gearsAtEscape or gearsBefore
    else
        gearsGained = math.max(0, gearsCurrent - gearsBefore)
    end
    if gearsBefore == 0 and gearsCurrent > 0 then
        gearsBefore = math.max(0, gearsCurrent - gearsGained)
    end
    local gearsAfter = gearsBefore + gearsGained

    local levelGained = math.max(0, levelCurrent - levelBefore)
    if levelBefore == 0 and levelCurrent > 0 then
        levelBefore = math.max(0, levelCurrent - levelGained)
    end
    local levelAfter = (levelCurrent > levelBefore) and levelCurrent or (levelBefore + levelGained)

    local userId    = tostring(LocalPlayer.UserId)
    local dateStr   = os.date("%d %b %Y")
    local timeStr   = os.date("%H:%M:%S")
    local avatarUrl = string.format("https://www.roblox.com/headshot-thumbnail/image?userId=%s&width=420&height=420&format=png", userId)

    local embedData

    if isTest then
        embedData = {
            username = "AutoFarm VD",
            embeds = {{
                title       = "Webhook Test",
                description = "```diff\n+ Connection OK — ready to receive escape reports\n```",
                color       = 0x9B59B6,
                footer      = { text = string.format("AutoFarm VD  •  %s  •  %s", timeStr, dateStr) },
            }},
        }
    else
        local descLines = string.format(
            "### ESCAPE CONFIRMED\n**`%s`**  ·  `%s`\n\nScrews Before  **%s**  ·  Gears Before  **%s**",
            LocalPlayer.Name, userId, fmtNum(screwsBefore), fmtNum(gearsBefore)
        )

        local screwsDapat = #roundBadges > 0
            and string.format("```diff\n+ %s\n```\n*includes %d badge bonus*", fmtNum(totalScrewsGained), #roundBadges)
            or  string.format("```diff\n+ %s\n```", fmtNum(totalScrewsGained))

        local levelVal = (levelGained > 0)
            and string.format("**%s** → **%s**  `+%d`", fmtNum(levelBefore), fmtNum(levelAfter), levelGained)
            or  string.format("**%s** *(no change)*", fmtNum(levelAfter))

        local sessionVal = string.format(
            "**%d** escape  ·  **+%s** screws  ·  %s runtime",
            totalEscapes, fmtNum(totalMoneyEarned), getShortRuntime()
        )

        local fields = {
            { name = "Screws Earned",  value = screwsDapat,                                  inline = true  },
            { name = "Total After",    value = string.format("```\n%s\n```", fmtNum(screwsAfter)), inline = true  },
            { name = "\u{200b}",        value = "\u{200b}",                                   inline = false },
            { name = "Gears Earned",   value = string.format("```fix\n+ %s\n```", fmtNum(gearsGained)), inline = true },
            { name = "Total After",    value = string.format("```\n%s\n```", fmtNum(gearsAfter)),       inline = true },
            { name = "\u{200b}",        value = "\u{200b}",                                   inline = false },
            { name = "Level Progress",  value = levelVal,                                     inline = false },
            { name = "Session Summary", value = sessionVal,                                   inline = false },
        }

        if #roundBadges > 0 then
            local lines = {}
            for _, b in ipairs(roundBadges) do
                table.insert(lines, string.format("• **%s**: +%s Screws", b.Name, fmtNum(b.Amount)))
            end
            table.insert(fields, 7, {
                name   = "Badges Unlocked",
                value  = table.concat(lines, "\n"),
                inline = false,
            })
        end

        embedData = {
            username = "AutoFarm VD",
            embeds = {{
                color       = 0x57F287,
                description = descLines,
                thumbnail   = { url = avatarUrl },
                fields      = fields,
                footer      = { text = string.format("AutoFarm VD  •  %s  •  %s", timeStr, dateStr) },
            }},
        }
    end

    local ok, res = pcall(function()
        return requestFunc({
            Url     = url,
            Method  = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = HttpService:JSONEncode(embedData),
        })
    end)
    return ok and res and (res.StatusCode == 200 or res.StatusCode == 204 or res.Success == true)
end

-- ==========================================
-- REWARD DATA CAPTURE
-- ==========================================
local function captureRewardData(_, rewardAmount)
    local amount = tonumber(rewardAmount) or 0
    totalMoneyEarned = totalMoneyEarned + amount
    savePersistentStats()
end

-- ==========================================
-- SERVER HOP & REJOIN
-- ==========================================
local function ServerHopSmallest()
    if not _G.ServerHopEnabled then return end
    if isHopping then return end
    isHopping = true
    applyQueueOnTeleport()

    local placeId    = game.PlaceId
    local currentJob = game.JobId
    local cursor, targetServer = nil, nil
    local lowestPlayers = math.huge

    repeat
        local url = string.format("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100", placeId)
        if cursor then url = url .. "&cursor=" .. cursor end

        local ok, res = pcall(function()
            if requestFunc then return requestFunc({ Url = url, Method = "GET" }) end
        end)
        if ok and res and res.Body then
            local dec = HttpService:JSONDecode(res.Body)
            if dec and dec.data then
                for _, sv in ipairs(dec.data) do
                    if sv.id ~= currentJob and sv.playing < sv.maxPlayers and sv.playing < lowestPlayers then
                        lowestPlayers = sv.playing
                        targetServer  = sv
                    end
                end
                if targetServer and targetServer.playing <= 2 then break end
                cursor = dec.nextPageCursor
            else break end
        else break end
        task.wait(0.2)
    until not cursor

    if targetServer then
        TeleportService.TeleportInitFailed:Connect(function()
            isHopping = false
            task.wait(2)
            ServerHopSmallest()
        end)
        TeleportService:TeleportToPlaceInstance(placeId, targetServer.id, LocalPlayer)
    else
        isHopping = false
        task.wait(3)
        ServerHopSmallest()
    end
end

local function RejoinSameServer()
    if not _G.RejoinEnabled then return end
    if isHopping then return end
    isHopping = true
    applyQueueOnTeleport()
    TeleportService.TeleportInitFailed:Connect(function()
        isHopping = false
        task.wait(2)
        RejoinSameServer()
    end)
    TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
end

-- ==========================================
-- TEAM HELPERS
-- ==========================================
local function isPlayerSurvivor()
    return LocalPlayer.Team and string.lower(LocalPlayer.Team.Name) == string.lower(SURVIVOR_TEAM_NAME)
end

local function isPlayerKiller()
    if not LocalPlayer.Team then return false end
    local t = string.lower(LocalPlayer.Team.Name)
    return string.find(t, "killer") ~= nil
        or (t ~= string.lower(SURVIVOR_TEAM_NAME) and t ~= "spectator" and t ~= "neutral")
end

local function isPlayerSpectator()
    if not LocalPlayer.Team then return true end
    local t = string.lower(LocalPlayer.Team.Name)
    if t == "spectator" or t == "spectators" or t == "neutral" then return true end
    return not isPlayerSurvivor() and not isPlayerKiller()
end

-- ==========================================
-- FREEZE-TP ENGINE  (replaces noclip)
-- ==========================================
--
-- Noclip skips server-side finishline touch validation.
-- Freeze-TP: character is teleported to the finishline center,
-- CanCollide stays true so the server detects the overlap correctly,
-- then locked in place via Heartbeat to prevent physics pushback.
--
local function setFreeze(enable, targetCF)
    if enable then
        if not freezeConnection and targetCF then
            freezeConnection = RunService.Heartbeat:Connect(function()
                local char = LocalPlayer.Character
                if not char then return end
                local hrp = char:FindFirstChild("HumanoidRootPart")
                if not hrp then return end
                hrp.AssemblyLinearVelocity  = Vector3.zero
                hrp.AssemblyAngularVelocity = Vector3.zero
                hrp.CFrame = targetCF
            end)
        end
    else
        if freezeConnection then
            freezeConnection:Disconnect()
            freezeConnection = nil
        end
    end
end

-- ==========================================
-- FINISHLINE FINDER
-- ==========================================
-- VD has 2 finishlines on some maps (both named "Fininshline").
-- Collects ALL matching instances from the Map model.
local function findAllFinishlines()
    local list = {}
    local map  = Workspace:FindFirstChild("Map")
    if not map then return list end
    for _, d in ipairs(map:GetDescendants()) do
        if d.Name == "Fininshline" and d:IsA("BasePart") then
            table.insert(list, d)
        end
    end
    return list
end

-- Target CFrame: horizontal center of the finishline part.
-- Using the Y center so the character overlaps the part,
-- triggering both Touched and server overlap validation.
local function getFinishlineCF(fl)
    local pos = fl.CFrame.Position
    return CFrame.new(pos.X, pos.Y, pos.Z)
end

-- ==========================================
-- AUTO FARM CORE
-- ==========================================
-- updateStatus is defined after UI init below,
-- called here via forward declaration.
local updateStatus  -- forward declared, diisi setelah UI init

local function runAutoFarm()
    if not _G.AutoFarm or not isRoundActive then return end

    -- Assigned killer — rejoin immediately
    if isPlayerKiller() then
        updateStatus("Assigned Killer — Rejoining!", "error")
        task.wait(0.5)
        RejoinSameServer()
        return
    end

    if not isPlayerSurvivor() then return end

    updateStatus("Searching for Finishline...", "accent")

    -- Wait for Map and finishline to appear (max 10s)
    local finishlines = {}
    local startTime   = tick()
    while isRoundActive and _G.AutoFarm and (tick() - startTime < 10) do
        finishlines = findAllFinishlines()
        if #finishlines > 0 then break end
        task.wait(0.5)
    end

    if #finishlines == 0 then
        updateStatus("Finishline not found (10s timeout)", "error")
        return
    end

    updateStatus(string.format("Found %d Finishline(s)", #finishlines), "positive")

    -- Sort by distance to HRP
    local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local hrp  = char:FindFirstChild("HumanoidRootPart")
        or char:WaitForChild("HumanoidRootPart", 3)
    if not hrp then return end

    table.sort(finishlines, function(a, b)
        return (hrp.Position - a.Position).Magnitude < (hrp.Position - b.Position).Magnitude
    end)

    -- Loop retry: coba satu per satu finishline sampai escape atau round selesai
    local attemptIdx = 1
    local cycleCount  = 0
    while isRoundActive and _G.AutoFarm and isPlayerSurvivor() and not isHopping do
        local fl = finishlines[attemptIdx]

        -- Validate: ensure finishline still exists in workspace
        if not fl or not fl.Parent then
            finishlines = findAllFinishlines()
            if #finishlines == 0 then
                updateStatus("Finishline gone from map", "error")
                break
            end
            attemptIdx = 1
            fl = finishlines[1]
        end

        local targetCF = getFinishlineCF(fl)

        -- Teleport to finishline center, then freeze
        hrp.CFrame = targetCF
        task.wait(0.05)
        setFreeze(true, targetCF)

        updateStatus(string.format("Frozen at Finishline %d/%d", attemptIdx, #finishlines), "positive")

        if _G.RetryTP then
            local delay = tonumber(_G.RetryTPDelay) or 5
            task.wait(delay)

            -- Still alive and survivor — try next finishline
            if isRoundActive and _G.AutoFarm and isPlayerSurvivor() and not isHopping then
                setFreeze(false)
                task.wait(0.1)
                -- Detect full cycle completion
                if attemptIdx == #finishlines then
                    cycleCount = cycleCount + 1
                    local maxCycles = tonumber(_G.MaxFinishlineCycles) or 3
                    if cycleCount >= maxCycles then
                        updateStatus(string.format("All finishlines failed %dx — Hopping...", cycleCount), "error")
                        task.spawn(ServerHopSmallest)
                        break
                    end
                end
                attemptIdx = (attemptIdx % #finishlines) + 1
                updateStatus(string.format("Retrying Finishline %d/%d... (cycle %d)", attemptIdx, #finishlines, cycleCount + 1), "warning")
            else
                break
            end
        else
            -- No retry — stay frozen until round ends
            break
        end
    end
end

-- ==========================================
-- ALLOW KILLER GUARD
-- ==========================================
local allowKillerChecked = false
local killerGuardLoop    = nil

local function startKillerGuard()
    if killerGuardLoop then return end
    pcall(function()
        local remotes      = ReplicatedStorage:FindFirstChild("Remotes")
        local options      = remotes and remotes:FindFirstChild("Options")
        local changeoption = options and options:FindFirstChild("changeoption")
        if not changeoption then return end

        local function forceDisable()
            if _G.AutoDisableKillerChance then
                changeoption:FireServer("AllowKiller", false)
            end
        end

        local akObj = nil
        for _, folder in ipairs({ LocalPlayer:FindFirstChild("Options"), LocalPlayer:FindFirstChild("Settings"), LocalPlayer:FindFirstChild("Data"), LocalPlayer }) do
            if folder then
                local f = folder:FindFirstChild("AllowKiller")
                if f and f:IsA("ValueBase") then akObj = f; break end
            end
        end

        if akObj then
            if akObj.Value == true then forceDisable() end
            killerGuardLoop = akObj.Changed:Connect(function(v)
                if v == true then forceDisable() end
            end)
        else
            if not allowKillerChecked then
                allowKillerChecked = true
                forceDisable()
            end
        end
    end)
end

local function stopKillerGuard()
    if killerGuardLoop then
        killerGuardLoop:Disconnect()
        killerGuardLoop = nil
    end
end

if _G.AutoDisableKillerChance then
    task.spawn(startKillerGuard)
end

-- ==========================================
-- SERVER HOP LOOP WATCHER
-- ==========================================
task.spawn(function()
    local lowPlayerTimer      = 0
    local LOW_PLAYER_TIMEOUT  = 70
    local spectatorTimer      = 0

    while task.wait(1) do
        if isHopping then break end

        local playerCount = #Players:GetPlayers()
        local timeText    = getSpectatorTime()
        local timeSec     = parseTimerSeconds(timeText)

        -- Spectator timeout
        if isPlayerSpectator() then
            if timeSec and timeSec > 60 then
                spectatorTimer = spectatorTimer + 1
                updateStatus(string.format("Spectator (>1m) — Hop in %ds", 20 - spectatorTimer), "warning")
                if spectatorTimer >= 20 then
                    updateStatus("Spectator Timeout — Hopping...", "error")
                    ServerHopSmallest()
                    break
                end
            else
                spectatorTimer = 0
                updateStatus(string.format("Waiting for next round... (%s)", timeText), "accent")
            end
        else
            spectatorTimer = 0
        end

        -- Low player hop
        if playerCount < 3 then
            lowPlayerTimer = lowPlayerTimer + 1
            if isPlayerSurvivor() and _G.AutoFarm then
                updateStatus(string.format("Low Players (%dp) — Hop in %ds", playerCount, LOW_PLAYER_TIMEOUT - lowPlayerTimer), "warning")
            end
            if lowPlayerTimer >= LOW_PLAYER_TIMEOUT then
                updateStatus("Low Players — Hopping...", "error")
                ServerHopSmallest()
                break
            end
        else
            lowPlayerTimer = 0
        end
    end
end)

-- ==========================================
-- ROUND START / STOP HANDLERS
-- ==========================================
local function onRoundStart()
    if isRoundActive then return end
    isRoundActive           = true
    webhookSentThisEscape   = false
    roundScrewsEarned       = 0
    roundGearsEarned        = 0
    roundBadges             = {}
    roundEvents             = {}

    local live = getAccountStats()
    if live.Screws > 0 or statsBeforeEscape.Screws == 0 then
        statsBeforeEscape = {
            Level        = live.Level,
            Screws       = live.Screws,
            Gears        = live.Gears,
            KillerChance = live.KillerChance,
        }
    end
    task.spawn(runAutoFarm)
end

local function onRoundEnd()
    if not isRoundActive then return end
    isRoundActive = false
    setFreeze(false)
    local live = getAccountStats()
    if live.Screws > 0 then
        statsBeforeEscape = {
            Level        = live.Level,
            Screws       = live.Screws,
            Gears        = live.Gears,
            KillerChance = live.KillerChance,
        }
    end
end

LocalPlayer:GetPropertyChangedSignal("Team"):Connect(function()
    if isRoundActive and _G.AutoFarm and isPlayerKiller() then
        setFreeze(false)
        RejoinSameServer()
    end
end)

-- ==========================================
-- DELIRIUM UI
-- ==========================================
local Window = Delirium:CreateWindow({
    Name          = "AutoFarm VD",
    Subtitle      = "V1.0  ·  Violence District",
    UnloadOnClose = false,
})

local FarmTab    = Window:CreateTab({ Name = "Farm"    })
local WebhookTab = Window:CreateTab({ Name = "Webhook" })
local StatsTab   = Window:CreateTab({ Name = "Stats"   })

-- ---- Farm Tab ----
local StatusSection  = FarmTab:CreateSection("Live Status")
local ControlSection = FarmTab:CreateSection("Controls")
local SettingSection = FarmTab:CreateSection("Auto-Play Settings")
local PlayerSection  = FarmTab:CreateSection("Player Options")

local statusLabel = StatusSection:CreateLabel({ Title = "Status",      Value = "Initializing...", Variant = "warning" })
local timerLabel  = StatusSection:CreateLabel({ Title = "Round Timer", Value = "--:--",           Variant = "default" })

-- Forward-decl filled here
updateStatus = function(text, variant)
    statusLabel:SetValue(text)
    if variant then statusLabel:SetVariant(variant) end
end

-- Controls
local autoFarmToggle = ControlSection:CreateToggle({
    Title    = "Auto Farm",
    Default  = _G.AutoFarm,
    Callback = function(v) _G.AutoFarm = v end,
})

ControlSection:CreateButton({
    Title    = "TP to Finishline Now",
    Callback = function()
        if not isRoundActive then
            updateStatus("Round not active", "error")
            return
        end
        task.spawn(runAutoFarm)
    end,
})

ControlSection:CreateButton({
    Title    = "Server Hop",
    Callback = function() ServerHopSmallest() end,
})

ControlSection:CreateButton({
    Title    = "Rejoin Same Server",
    Callback = function() RejoinSameServer() end,
})

ControlSection:CreateToggle({
    Title    = "Auto Server Hop",
    Default  = _G.ServerHopEnabled,
    Callback = function(v) _G.ServerHopEnabled = v end,
})

ControlSection:CreateToggle({
    Title    = "Auto Rejoin",
    Default  = _G.RejoinEnabled,
    Callback = function(v) _G.RejoinEnabled = v end,
})

-- Auto-Play Settings
SettingSection:CreateToggle({
    Title    = "Retry TP Finishline",
    Default  = _G.RetryTP,
    Callback = function(v) _G.RetryTP = v end,
})

SettingSection:CreateTextbox({
    Title       = "Retry Delay (seconds)",
    Placeholder = tostring(_G.RetryTPDelay),
    Default     = tostring(_G.RetryTPDelay),
    Callback    = function(v)
        local n = tonumber(v)
        if n then _G.RetryTPDelay = n end
    end,
})

SettingSection:CreateTextbox({
    Title       = "Max Finishline Cycles (before hop)",
    Placeholder = tostring(_G.MaxFinishlineCycles),
    Default     = tostring(_G.MaxFinishlineCycles),
    Callback    = function(v)
        local n = tonumber(v)
        if n and n >= 1 then _G.MaxFinishlineCycles = math.floor(n) end
    end,
})

SettingSection:CreateTextbox({
    Title       = "Hop Delay (seconds)",
    Placeholder = tostring(_G.HopDelay),
    Default     = tostring(_G.HopDelay),
    Callback    = function(v)
        local n = tonumber(v)
        if n then _G.HopDelay = n end
    end,
})

-- Player Options
local killerChanceToggle = PlayerSection:CreateToggle({
    Title    = "Auto Disable Killer Chance",
    Default  = _G.AutoDisableKillerChance,
    Callback = function(v)
        _G.AutoDisableKillerChance = v
        if v then
            task.spawn(startKillerGuard)
        else
            stopKillerGuard()
        end
    end,
})

PlayerSection:CreateButton({
    Title    = "Disable Killer Chance Now",
    Callback = function()
        pcall(function()
            local remotes = ReplicatedStorage:FindFirstChild("Remotes")
            local options = remotes and remotes:FindFirstChild("Options")
            local chg     = options and options:FindFirstChild("changeoption")
            if chg then chg:FireServer("AllowKiller", false) end
        end)
    end,
})

-- ---- Webhook Tab ----
local WebhookSection = WebhookTab:CreateSection("Discord Webhook")

WebhookSection:CreateTextbox({
    Title       = "Webhook URL",
    Placeholder = "https://discord.com/api/webhooks/...",
    Default     = _G.WebhookUrl,
    Callback    = function(v) _G.WebhookUrl = v end,
})

WebhookSection:CreateToggle({
    Title    = "Enable Webhook",
    Default  = _G.WebhookEnabled,
    Callback = function(v) _G.WebhookEnabled = v end,
})

local webhookStatusLabel = WebhookSection:CreateLabel({ Title = "Status", Value = "Idle", Variant = "default" })

WebhookSection:CreateButton({
    Title    = "Send Test Embed",
    Callback = function()
        webhookStatusLabel:SetValue("Sending test embed...")
        webhookStatusLabel:SetVariant("warning")
        local ok = sendDiscordWebhook("TEST_WEBHOOK", 0)
        if ok then
            webhookStatusLabel:SetValue("Sent successfully")
            webhookStatusLabel:SetVariant("positive")
        else
            webhookStatusLabel:SetValue("Failed — check URL")
            webhookStatusLabel:SetVariant("error")
        end
    end,
})

-- ---- Stats Tab ----
local StatsSection  = StatsTab:CreateSection("Session Stats")
local statsParagraph = StatsSection:CreateParagraph({
    Title   = "Overview",
    Content = "Loading...",
})

StatsSection:CreateButton({
    Title    = "Reset Stats",
    Callback = function() resetPersistentStats() end,
})

-- ==========================================
-- UI UPDATE LOOP
-- ==========================================
task.spawn(function()
    while task.wait(0.5) do
        timerLabel:SetValue(getSpectatorTime())
        local acc = getAccountStats()
        statsParagraph:SetContent(string.format(
            "Level  %s\nScrews  %s   ·   Gears  %s\nKiller Chance  %s\n\n─────────────────\nEscape  %d\nScrews Earned  %d\nRuntime  %s\nFPS  %d   ·   Ping  %d ms",
            tostring(acc.Level),
            tostring(acc.Screws),
            tostring(acc.Gears),
            tostring(acc.KillerChance),
            totalEscapes,
            totalMoneyEarned,
            getFormattedRuntime(),
            currentFps,
            getPing()
        ))
    end
end)

-- ==========================================
-- KEYBIND K
-- ==========================================
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.K then
        _G.AutoFarm = not _G.AutoFarm
        if autoFarmToggle.SetValue then autoFarmToggle:SetValue(_G.AutoFarm) end
    end
end)

-- ==========================================
-- REMOTE LISTENERS
-- ==========================================
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if Remotes then
    local TimeUpdateEvent = Remotes:FindFirstChild("TimeUpdateEvent")
    if TimeUpdateEvent then
        TimeUpdateEvent.OnClientEvent:Connect(function(state)
            if state == "Round" then
                onRoundStart()
            elseif state == "Intermission" then
                onRoundEnd()
            end
        end)
    end

    local RoundEvent = Remotes:FindFirstChild("Round")
    if RoundEvent then
        RoundEvent.OnClientEvent:Connect(function(active)
            if active then onRoundStart() else onRoundEnd() end
        end)
    end

    local GameRemotes = Remotes:FindFirstChild("Game")
    if GameRemotes then
        local PlayerActionEvent = GameRemotes:FindFirstChild("PlayerActionEvent")
        if PlayerActionEvent then
            PlayerActionEvent.OnClientEvent:Connect(function(actionMessage, rewardAmount)
                local msg      = tostring(actionMessage or "")
                local upperMsg = string.upper(msg)
                local amount   = parseNum(rewardAmount)

                captureRewardData(actionMessage, amount)
                if amount > 0 then roundScrewsEarned = roundScrewsEarned + amount end

                if string.find(upperMsg, "BADGE") then
                    table.insert(roundBadges, { Name = msg, Amount = amount })
                end

                table.insert(roundEvents, { Message = msg, Amount = amount })

                if _G.AutoFarm and string.find(upperMsg, "ESCAPED") and not webhookSentThisEscape then
                    webhookSentThisEscape = true
                    totalEscapes = totalEscapes + 1
                    savePersistentStats()
                    setFreeze(false)

                    task.spawn(function()
                        updateStatus("Escaped! Calculating rewards...", "warning")

                        local gearsAtEscape = LocalPlayer:GetAttribute("Gears") or 0
                        local gearsNewValue = nil
                        local con = LocalPlayer:GetAttributeChangedSignal("Gears"):Connect(function()
                            gearsNewValue = LocalPlayer:GetAttribute("Gears") or 0
                        end)
                        local waitStart = tick()
                        while tick() - waitStart < 3 do
                            if gearsNewValue ~= nil then
                                task.wait(0.1)
                                gearsNewValue = LocalPlayer:GetAttribute("Gears") or 0
                                break
                            end
                            task.wait(0.1)
                        end
                        con:Disconnect()

                        local gearsGainedDelta = nil
                        if gearsNewValue ~= nil then
                            local delta = gearsNewValue - gearsAtEscape
                            if delta > 0 then gearsGainedDelta = delta end
                        end

                        local ok = sendDiscordWebhook(actionMessage, amount, gearsGainedDelta, gearsAtEscape)
                        if ok then
                            updateStatus("Escaped! Webhook sent", "positive")
                        else
                            updateStatus("Escaped!", "positive")
                        end

                        local delay = tonumber(_G.HopDelay) or 3
                        for i = delay, 1, -1 do
                            updateStatus(string.format("Hopping in %ds...", i), "warning")
                            task.wait(1)
                        end
                        updateStatus("Teleporting...", "positive")
                        ServerHopSmallest()
                    end)
                end
            end)
        end

        local showresults = GameRemotes:FindFirstChild("showresults")
        if showresults then
            showresults.OnClientEvent:Connect(function()
                if _G.AutoFarm and not isHopping and not webhookSentThisEscape then
                    setFreeze(false)
                    task.wait(tonumber(_G.HopDelay) or 3)
                    ServerHopSmallest()
                end
            end)
        end
    end
end

-- ==========================================
-- SHOW WINDOW
-- ==========================================
if Window and Window.Show then Window:Show() end

print("[AutoFarmVD] v4.1 loaded — Freeze-TP engine active, dual finishline support.")
