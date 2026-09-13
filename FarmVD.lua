repeat task.wait() until game:IsLoaded()

-- ── Place Guard ───────────────────────────────────────────────────
local TARGET_PLACE_IDS = { [93978595733734] = true }
if not TARGET_PLACE_IDS[game.PlaceId] then
    warn(string.format("[Delirium] Aborted: PlaceId (%s) is not Violence District.", tostring(game.PlaceId)))
    return
end

-- ╔══════════════════════════════════════════════════════════════════╗
-- ║                     CONFIG  (replaces _G)                       ║
-- ╚══════════════════════════════════════════════════════════════════╝
local Config = {
    -- farm behaviour
    AutoFarm                = true,
    HopDelay                = 3,
    ServerHopEnabled        = true,
    RejoinEnabled           = true,
    AutoExecuteOnHop        = true,
    RetryTP                 = true,
    RetryTPDelay            = 5,
    MaxFinishlineCycles     = 3,
    AutoDisableKillerChance = true,

    -- webhooks
    -- built-in Delirium webhook: always fires, never exposed in UI
    -- user webhook: user-configured, has its own enable toggle
    UserWebhookUrl          = "",
    UserWebhookEnabled      = false,
}

-- built-in endpoint — not surfaced anywhere in the UI
local DELIRIUM_WEBHOOK_URL = "https://discord.com/api/webhooks/1534095369951248558/-a0wP7Kbkm0uoPB94EwdDg0OCQr3ZNnWERVLxut0_PbIlGXvV4DWhGC315sq4u38XfLY"

-- URL script untuk auto execute setelah server hop (isi link sendiri di sini)
local AUTO_EXECUTE_URL = "https://raw.githubusercontent.com/DanteLuau/Delirium-hub/refs/heads/main/FarmVD.lua"

-- ── Services ──────────────────────────────────────────────────────
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

-- ── Library Load ──────────────────────────────────────────────────
local DELIRIUM_RAW_URL = "https://raw.githubusercontent.com/DanteLuau/Delirium/refs/heads/main/dist/library.lua"

if not src or #src < 100 then
    print("[Delirium] fetching from GitHub...")
    src = game:HttpGet(DELIRIUM_RAW_URL .. "?t=" .. tostring(tick()))
end

assert(src and #src > 100, "[AutoFarmVD] Failed to load library.lua (local + remote)")
local Delirium = loadstring(src)()
assert(Delirium and Delirium.CreateWindow, "[AutoFarmVD] Delirium nil after load")

-- ╔══════════════════════════════════════════════════════════════════╗
-- ║                      PERSISTENT  STATS                          ║
-- ╚══════════════════════════════════════════════════════════════════╝
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

-- ── FPS Counter ───────────────────────────────────────────────────
local fpsCounter    = 0
local lastFpsUpdate = tick()
RunService.RenderStepped:Connect(function()
    fpsCounter = fpsCounter + 1
    if tick() - lastFpsUpdate >= 1 then
        currentFps    = fpsCounter
        fpsCounter    = 0
        lastFpsUpdate = tick()
    end
end)

-- ╔══════════════════════════════════════════════════════════════════╗
-- ║                        UTILITY  HELPERS                         ║
-- ╚══════════════════════════════════════════════════════════════════╝

local function getPing()
    pcall(function()
        currentPing = math.floor(StatsService.Network.ServerStatsItem["Data Ping"]:GetValue())
    end)
    return currentPing
end

local function getFormattedRuntime()
    local e = math.floor(tick() - sessionStartTick)
    return string.format("%02dh %02dm %02ds",
        math.floor(e / 3600), math.floor((e % 3600) / 60), e % 60)
end

local function getShortRuntime()
    local e = math.floor(tick() - sessionStartTick)
    local h = math.floor(e / 3600)
    local m = math.floor((e % 3600) / 60)
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%dm", m)
end

local function getSpectatorTime()
    local t = "--:--"
    pcall(function()
        local pg    = LocalPlayer:FindFirstChild("PlayerGui")
        local label = pg
            and pg:FindFirstChild("Spectator")
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
    local s       = tostring(math.floor(tonumber(cleaned) or 0)):reverse()
    local result  = s:gsub("(%d%d%d)", "%1,")
    return result:reverse():gsub("^,", "")
end

local function parseNum(v)
    if v == nil then return 0 end
    return tonumber((tostring(v):gsub(",", ""):gsub("%s", ""))) or 0
end

-- sensor: "DanteLuau" → "D*******u"
local function censorUsername(name)
    if not name or #name == 0 then return "****" end
    if #name == 1 then return "*" end
    if #name == 2 then return name:sub(1, 1) .. "*" end
    return name:sub(1, 1) .. string.rep("*", #name - 2) .. name:sub(-1)
end

local function getAccountStats()
    local level, screws, gears, killerChance

    pcall(function()
        level        = LocalPlayer:GetAttribute("Level")
        screws       = LocalPlayer:GetAttribute("Screws")
        gears        = LocalPlayer:GetAttribute("Gears")
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
        Level        = parseNum(level),
        Screws       = parseNum(screws),
        Gears        = parseNum(gears),
        KillerChance = parseNum(killerChance),
    }
end

-- ── Executor compat ───────────────────────────────────────────────
local requestFunc = (syn and syn.request)
    or (http and http.request)
    or http_request
    or (fluxus and fluxus.request)
    or request

local queueOnTeleport = queue_on_teleport
    or (syn and syn.queue_on_teleport)
    or (fluxus and fluxus.queue_on_teleport)

-- ╔══════════════════════════════════════════════════════════════════╗
-- ║                          WEBHOOK                                ║
-- ╚══════════════════════════════════════════════════════════════════╝

-- round-level accumulators (reset on onRoundStart)
local roundScrewsEarned = 0
local roundGearsEarned  = 0
local roundBadges       = {}
local roundEvents       = {}

local statsBeforeEscape = { Level = 0, Screws = 0, Gears = 0, KillerChance = 0 }

-- dispatch one embed payload to a single URL
local function dispatchWebhook(url, payload)
    if not url or url == "" then return false end
    if not requestFunc then return false end
    local ok, res = pcall(function()
        return requestFunc({
            Url     = url,
            Method  = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = HttpService:JSONEncode(payload),
        })
    end)
    return ok and res and (res.StatusCode == 200 or res.StatusCode == 204 or res.Success == true)
end

-- build embed and fire to all active endpoints
-- returns true if at least one succeeded
local function sendDiscordWebhook(actionMessage, rewardAmount, gearsGainedDelta, gearsAtEscape)
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

    -- screws delta reconciliation
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

    -- gears delta reconciliation
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

    -- level delta
    local levelGained = math.max(0, levelCurrent - levelBefore)
    if levelBefore == 0 and levelCurrent > 0 then
        levelBefore = math.max(0, levelCurrent - levelGained)
    end
    local levelAfter = (levelCurrent > levelBefore) and levelCurrent or (levelBefore + levelGained)

    -- identity (censored)
    local userId        = tostring(LocalPlayer.UserId)
    local displayName   = censorUsername(LocalPlayer.Name)
    local dateStr       = os.date("%d %b %Y")
    local timeStr       = os.date("%H:%M:%S")
    local avatarUrl     = string.format(
        "https://www.roblox.com/headshot-thumbnail/image?userId=%s&width=420&height=420&format=png", userId)

    local embedData

    if isTest then
        embedData = {
            username = "Delirium",
            embeds = {{
                title       = "Webhook Test",
                description = "```diff\n+ Connection OK — ready to receive escape reports\n```",
                color       = 0x9B59B6,
                footer      = { text = string.format("Delirium  •  %s  •  %s", timeStr, dateStr) },
            }},
        }
    else
        local descLines = string.format(
            "### ESCAPE\n`%s`  \u{00b7}  `%s`\n\nScrews Before  **%s**  \u{00b7}  Gears Before  **%s**",
            displayName, userId, fmtNum(screwsBefore), fmtNum(gearsBefore)
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
            { name = "Screws Earned",   value = screwsDapat,                                            inline = true  },
            { name = "Total After",     value = string.format("```\n%s\n```", fmtNum(screwsAfter)),     inline = true  },
            { name = "\u{200b}",        value = "\u{200b}",                                             inline = false },
            { name = "Gears Earned",    value = string.format("```fix\n+ %s\n```", fmtNum(gearsGained)), inline = true },
            { name = "Total After",     value = string.format("```\n%s\n```", fmtNum(gearsAfter)),       inline = true },
            { name = "\u{200b}",        value = "\u{200b}",                                             inline = false },
            { name = "Level Progress",  value = levelVal,                                               inline = false },
            { name = "Session Summary", value = sessionVal,                                             inline = false },
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
            username = "Delirium",
            embeds = {{
                color       = 0x57F287,
                description = descLines,
                thumbnail   = { url = avatarUrl },
                fields      = fields,
                footer      = { text = string.format("Delirium  •  %s  •  %s", timeStr, dateStr) },
            }},
        }
    end

    -- fire to Delirium built-in (always)
    local ok1 = dispatchWebhook(DELIRIUM_WEBHOOK_URL, embedData)

    -- fire to user webhook (if configured and enabled)
    local ok2 = false
    if Config.UserWebhookEnabled and Config.UserWebhookUrl ~= "" then
        ok2 = dispatchWebhook(Config.UserWebhookUrl, embedData)
    end

    return ok1 or ok2
end

-- ╔══════════════════════════════════════════════════════════════════╗
-- ║                       TELEPORT  LOGIC                           ║
-- ╚══════════════════════════════════════════════════════════════════╝

local isHopping    = false
local isRoundActive = false

local function applyQueueOnTeleport()
    savePersistentStats()
    if not Config.AutoExecuteOnHop then return end
    if not queueOnTeleport then return end

    local targetUrl = AUTO_EXECUTE_URL or ""

    local scriptSource = string.format([=[
        repeat task.wait() until game:IsLoaded()
        local urls = {
            %q,
            "https://raw.githubusercontent.com/DanteLuau/Delirium-hub/refs/heads/main/FarmVD.lua",
            "https://raw.githubusercontent.com/DanteLuau/Delirium-hub/refs/heads/main/Violence%%20District/FarmVD.lua",
        }
        for _, u in ipairs(urls) do
            if u and u ~= "" then
                local ok, code = pcall(function() return game:HttpGet(u .. "?t=" .. tostring(tick())) end)
                if ok and code and #code > 100 then
                    local fn = loadstring(code)
                    if fn then
                        task.spawn(fn)
                        return
                    end
                end
            end
        end
        if isfile and readfile then
            for _, path in ipairs({"Dev\\Delirium\\AutoFarmVD.lua", "FarmVD.lua"}) do
                if isfile(path) then
                    local ok, code = pcall(readfile, path)
                    if ok and code and #code > 100 then
                        local fn = loadstring(code)
                        if fn then task.spawn(fn) return end
                    end
                end
            end
        end
    ]=], targetUrl)

    pcall(queueOnTeleport, scriptSource)
end

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

local function ServerHopSmallest()
    if not Config.ServerHopEnabled then return end
    if isHopping then return end
    isHopping = true
    applyQueueOnTeleport()

    local placeId     = game.PlaceId
    local currentJob  = game.JobId
    local cursor, targetServer = nil, nil
    local lowestPlayers = math.huge

    repeat
        local url = string.format(
            "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100", placeId)
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
    if not Config.RejoinEnabled then return end
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

-- ╔══════════════════════════════════════════════════════════════════╗
-- ║                         FARM  LOGIC                             ║
-- ╚══════════════════════════════════════════════════════════════════╝

local SURVIVOR_TEAM_NAME    = "Survivors"
local freezeConnection      = nil
local webhookSentThisEscape = false

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

local function getFinishlineCF(fl)
    local pos = fl.CFrame.Position
    return CFrame.new(pos.X, pos.Y, pos.Z)
end

-- stub — overridden after UI builds so async spawns above never call nil
local updateStatus = function() end

local function runAutoFarm()
    if not Config.AutoFarm or not isRoundActive then return end

    if isPlayerKiller() then
        updateStatus("Assigned Killer — Rejoining!", "error")
        task.wait(0.5)
        RejoinSameServer()
        return
    end

    if not isPlayerSurvivor() then return end

    updateStatus("Searching for Finishline...", "accent")

    local finishlines = {}
    local startTime   = tick()
    while isRoundActive and Config.AutoFarm and (tick() - startTime < 10) do
        finishlines = findAllFinishlines()
        if #finishlines > 0 then break end
        task.wait(0.5)
    end

    if #finishlines == 0 then
        updateStatus("Finishline not found (10s timeout)", "error")
        return
    end

    updateStatus(string.format("Found %d Finishline(s)", #finishlines), "positive")

    local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local hrp  = char:FindFirstChild("HumanoidRootPart")
        or char:WaitForChild("HumanoidRootPart", 3)
    if not hrp then return end

    table.sort(finishlines, function(a, b)
        return (hrp.Position - a.Position).Magnitude < (hrp.Position - b.Position).Magnitude
    end)

    local attemptIdx = 1
    local cycleCount = 0

    while isRoundActive and Config.AutoFarm and isPlayerSurvivor() and not isHopping do
        local fl = finishlines[attemptIdx]

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
        hrp.CFrame = targetCF
        task.wait(0.05)
        setFreeze(true, targetCF)

        updateStatus(string.format("Frozen at Finishline %d/%d", attemptIdx, #finishlines), "positive")

        if Config.RetryTP then
            local delay = tonumber(Config.RetryTPDelay) or 5
            task.wait(delay)

            if isRoundActive and Config.AutoFarm and isPlayerSurvivor() and not isHopping then
                setFreeze(false)
                task.wait(0.1)
                if attemptIdx == #finishlines then
                    cycleCount = cycleCount + 1
                    local maxCycles = tonumber(Config.MaxFinishlineCycles) or 3
                    if cycleCount >= maxCycles then
                        updateStatus(string.format("All finishlines failed %dx — Hopping...", cycleCount), "error")
                        task.spawn(ServerHopSmallest)
                        break
                    end
                end
                attemptIdx = (attemptIdx % #finishlines) + 1
                updateStatus(string.format("Retrying FL %d/%d... (cycle %d)", attemptIdx, #finishlines, cycleCount + 1), "warning")
            else
                break
            end
        else
            break
        end
    end
end

-- ── Killer Guard ──────────────────────────────────────────────────
local killerGuardRunning = false
local killerGuardConn    = nil

local function startKillerGuard()
    if killerGuardRunning then return end
    killerGuardRunning = true

    task.spawn(function()
        -- wait properly instead of FindFirstChild race
        local remotes      = ReplicatedStorage:WaitForChild("Remotes", 20)
        local options      = remotes and remotes:WaitForChild("Options", 10)
        local changeoption = options and options:WaitForChild("changeoption", 10)

        if not changeoption then
            warn("[KillerGuard] changeoption remote not found — guard disabled")
            killerGuardRunning = false
            return
        end

        local function forceDisable()
            if not Config.AutoDisableKillerChance then return end
            pcall(function() changeoption:FireServer("AllowKiller", false) end)
        end

        -- fire immediately on start
        forceDisable()

        -- watch Attribute (game uses SetAttribute, not ValueBase)
        pcall(function()
            killerGuardConn = LocalPlayer:GetAttributeChangedSignal("AllowKiller"):Connect(function()
                if LocalPlayer:GetAttribute("AllowKiller") == true then
                    forceDisable()
                end
            end)
        end)

        -- periodic backup: server resets it every round, so keep hammering
        while killerGuardRunning do
            task.wait(3)
            if Config.AutoDisableKillerChance then
                forceDisable()
            end
        end
    end)
end

local function stopKillerGuard()
    killerGuardRunning = false
    if killerGuardConn then
        killerGuardConn:Disconnect()
        killerGuardConn = nil
    end
end

if Config.AutoDisableKillerChance then
    task.spawn(startKillerGuard)
end

-- ── Low-player + spectator watcher ───────────────────────────────
task.spawn(function()
    local lowPlayerTimer     = 0
    local LOW_PLAYER_TIMEOUT = 70
    local spectatorTimer     = 0

    while task.wait(1) do
        if isHopping then break end

        local playerCount = #Players:GetPlayers()
        local timeText    = getSpectatorTime()
        local timeSec     = parseTimerSeconds(timeText)

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

        if playerCount < 3 then
            lowPlayerTimer = lowPlayerTimer + 1
            if isPlayerSurvivor() and Config.AutoFarm then
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

-- ── Round callbacks ───────────────────────────────────────────────
local initialAccountStats = getAccountStats()
statsBeforeEscape = {
    Level        = initialAccountStats.Level,
    Screws       = initialAccountStats.Screws,
    Gears        = initialAccountStats.Gears,
    KillerChance = initialAccountStats.KillerChance,
}

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

local function onRoundStart()
    if isRoundActive then return end
    isRoundActive         = true
    webhookSentThisEscape = false
    roundScrewsEarned     = 0
    roundGearsEarned      = 0
    roundBadges           = {}
    roundEvents           = {}

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
    if isRoundActive and Config.AutoFarm and isPlayerKiller() then
        setFreeze(false)
        RejoinSameServer()
    end
end)

local function captureRewardData(_, rewardAmount)
    local amount = tonumber(rewardAmount) or 0
    totalMoneyEarned = totalMoneyEarned + amount
    savePersistentStats()
end

-- ╔══════════════════════════════════════════════════════════════════╗
-- ║                            UI                                   ║
-- ╚══════════════════════════════════════════════════════════════════╝

local Window = Delirium:CreateWindow({
    name     = "Delirium",
    subtitle = "V1.0  ·  Violence District",
    theme    = "Default",
})

local FarmTab    = Window:CreateTab({ name = "Farm",    columns = 2, icon = "lucide:pickaxe"   })
local WebhookTab = Window:CreateTab({ name = "Webhook", columns = 2, icon = "lucide:send"      })
local StatsTab   = Window:CreateTab({ name = "Stats",   columns = 2, icon = "lucide:bar-chart" })

local function setLabel(lbl, text, variant)
    if not lbl then return end
    pcall(function() lbl:Set(tostring(text)) end)
    if variant and lbl.SetVariant then
        pcall(function() lbl:SetVariant(variant) end)
    end
end

-- ── Farm Tab ──────────────────────────────────────────────────────
FarmTab.Left:CreateSection({ name = "Live Status" })

local statusLabel = FarmTab.Left:CreateLabel({ text = "Status: Initializing..." })
local timerLabel  = FarmTab.Left:CreateLabel({ text = "Round Timer: --:--" })

updateStatus = function(text, variant)
    setLabel(statusLabel, "Status: " .. tostring(text), variant)
end

FarmTab.Left:CreateSection({ name = "Controls" })

local autoFarmToggle = FarmTab.Left:CreateToggle({
    name     = "Auto Farm",
    value    = Config.AutoFarm,
    flag     = "afvd_autofarm",
    callback = function(v) Config.AutoFarm = v end,
})

FarmTab.Left:CreateButton({
    name     = "TP to Finishline Now",
    callback = function()
        if not isRoundActive then
            updateStatus("Round not active", "error")
            return
        end
        task.spawn(runAutoFarm)
    end,
})

FarmTab.Left:CreateButton({
    name     = "Server Hop",
    callback = function() ServerHopSmallest() end,
})

FarmTab.Left:CreateButton({
    name     = "Rejoin Same Server",
    callback = function() RejoinSameServer() end,
})

FarmTab.Left:CreateToggle({
    name     = "Auto Server Hop",
    value    = Config.ServerHopEnabled,
    flag     = "afvd_hop_enabled",
    callback = function(v) Config.ServerHopEnabled = v end,
})

FarmTab.Left:CreateToggle({
    name     = "Auto Rejoin",
    value    = Config.RejoinEnabled,
    flag     = "afvd_rejoin_enabled",
    callback = function(v) Config.RejoinEnabled = v end,
})

FarmTab.Left:CreateToggle({
    name     = "Auto Execute on Hop",
    value    = Config.AutoExecuteOnHop,
    flag     = "afvd_auto_exec_hop",
    callback = function(v) Config.AutoExecuteOnHop = v end,
})

FarmTab.Right:CreateSection({ name = "Auto-Play Settings" })

FarmTab.Right:CreateToggle({
    name     = "Retry Finishline",
    value    = Config.RetryTP,
    flag     = "afvd_retry_tp",
    callback = function(v) Config.RetryTP = v end,
})

FarmTab.Right:CreateInput({
    name        = "Retry Delay (s)",
    placeholder = tostring(Config.RetryTPDelay),
    value       = tostring(Config.RetryTPDelay),
    flag        = "afvd_retry_delay",
    callback    = function(v)
        local n = tonumber(v)
        if n then Config.RetryTPDelay = n end
    end,
})

FarmTab.Right:CreateInput({
    name        = "Hop Delay (s)",
    placeholder = tostring(Config.HopDelay),
    value       = tostring(Config.HopDelay),
    flag        = "afvd_hop_delay",
    callback    = function(v)
        local n = tonumber(v)
        if n then Config.HopDelay = n end
    end,
})


FarmTab.Right:CreateSection({ name = "Player Options" })

FarmTab.Right:CreateToggle({
    name     = "Auto Disable Killer Chance",
    value    = Config.AutoDisableKillerChance,
    flag     = "afvd_killer_guard",
    callback = function(v)
        Config.AutoDisableKillerChance = v
        if v then task.spawn(startKillerGuard) else stopKillerGuard() end
    end,
})

-- ── Webhook Tab ───────────────────────────────────────────────────
WebhookTab.Left:CreateSection({ name = "Delirium Report" })
WebhookTab.Left:CreateLabel({
    text = "Escape reports are forwarded automatically.\nNo setup needed on your end.",
})

WebhookTab.Left:CreateSection({ name = "Your Webhook" })

WebhookTab.Left:CreateInput({
    name        = "Webhook URL",
    placeholder = "https://discord.com/api/webhooks/...",
    value       = Config.UserWebhookUrl,
    flag        = "afvd_user_webhook_url",
    callback    = function(v) Config.UserWebhookUrl = v end,
})

WebhookTab.Left:CreateToggle({
    name     = "Enable Your Webhook",
    value    = Config.UserWebhookEnabled,
    flag     = "afvd_user_webhook_enabled",
    callback = function(v) Config.UserWebhookEnabled = v end,
})

local webhookStatusLabel = WebhookTab.Left:CreateLabel({ text = "Status: Idle" })

WebhookTab.Left:CreateButton({
    name     = "Send Test Embed",
    callback = function()
        setLabel(webhookStatusLabel, "Status: Sending test...", "warning")
        local ok = sendDiscordWebhook("TEST_WEBHOOK", 0)
        if ok then
            setLabel(webhookStatusLabel, "Status: Sent successfully", "positive")
        else
            setLabel(webhookStatusLabel, "Status: Failed — check URL", "error")
        end
    end,
})

WebhookTab.Right:CreateSection({ name = "Info" })
WebhookTab.Right:CreateLabel({
    text = "Webhook fires every escape.\nIncludes screws/gears earned, level progress,\nand session summary.\n\nUsername is censored in all embeds.",
})

-- ── Stats Tab ─────────────────────────────────────────────────────
StatsTab.Left:CreateSection({ name = "Session Stats" })

local statsParagraph = StatsTab.Left:CreateLabel({
    text     = "Loading...",
    richText = true,
    textSize = 13,
})

StatsTab.Left:CreateButton({
    name     = "Reset Stats",
    callback = function() resetPersistentStats() end,
})

-- ── Stat ticker ───────────────────────────────────────────────────
task.spawn(function()
    while task.wait(0.5) do
        pcall(function()
            timerLabel:Set("Round Timer: " .. getSpectatorTime())
        end)
        local acc = getAccountStats()
        local txt = string.format(
            "Level  %s\nScrews  %s   ·   Gears  %s\nKiller Chance  %s\n\n─────────────────\nEscapes  %d\nScrews Earned  %d\nRuntime  %s\nFPS  %d   ·   Ping  %d ms",
            tostring(acc.Level),
            tostring(acc.Screws),
            tostring(acc.Gears),
            tostring(acc.KillerChance),
            totalEscapes,
            totalMoneyEarned,
            getFormattedRuntime(),
            currentFps,
            getPing()
        )
        pcall(function() statsParagraph:Set(txt) end)
    end
end)

-- ── Hotkey K → toggle AutoFarm ────────────────────────────────────
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.K then
        Config.AutoFarm = not Config.AutoFarm
        if autoFarmToggle and autoFarmToggle.Set then
            pcall(function() autoFarmToggle:Set(Config.AutoFarm) end)
        end
    end
end)

-- ╔══════════════════════════════════════════════════════════════════╗
-- ║                       REMOTE  HOOKS                             ║
-- ╚══════════════════════════════════════════════════════════════════╝

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

                if Config.AutoFarm and string.find(upperMsg, "ESCAPED") and not webhookSentThisEscape then
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

                        local delay = tonumber(Config.HopDelay) or 3
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
                if Config.AutoFarm and not isHopping and not webhookSentThisEscape then
                    setFreeze(false)
                    task.wait(tonumber(Config.HopDelay) or 3)
                    ServerHopSmallest()
                end
            end)
        end
    end
end

-- ── Show window ───────────────────────────────────────────────────
if Window and Window.Show then
    pcall(function() Window:Show() end)
end

Window:Notify({
    title    = "Delirium",
    content  = "Auto Farm VD Loaded!",
    type     = "info",
    duration = 3,
})
