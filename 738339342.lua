-- FE2.lua — Flood Escape 2 Hub

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS         = game:GetService("ReplicatedStorage")
local lp         = Players.LocalPlayer

if _G.DanteCleanup then
    pcall(_G.DanteCleanup)
    _G.DanteCleanup = nil
end

local RAW_URL    = "https://raw.githubusercontent.com/DanteLuau/Delirium/refs/heads/main/dist/library.lua?v=" .. tick()
local LOCAL_PATH = "C:\\Users\\Admin\\AppData\\Local\\Real\\workspace\\Delirium\\dist\\library.lua"
local Delirium

do
    local ok, r = pcall(function() return loadstring(game:HttpGet(RAW_URL))() end)
    if ok and r and r.CreateWindow then
        Delirium = r
    else
        local ok2, r2 = pcall(function()
            local rf = (getgenv and getgenv().readfile) or _G.readfile or readfile
            return loadstring(rf(LOCAL_PATH))()
        end)
        if ok2 and r2 and r2.CreateWindow then Delirium = r2
        else error("[Delirium] Failed to load library") end
    end
end

local SaveManager = Delirium.SaveManager

local resizeHitbox
local setStatus
local watchForExitRegion
local unweldHrp
local mapIndex = { map = nil, buttons = {}, exits = {} }

local hrp, hum

local function syncChar(char)
    if unweldHrp then unweldHrp() end
    hrp = char:WaitForChild("HumanoidRootPart", 5)
    hum = char:WaitForChild("Humanoid", 5)
    task.spawn(function()
        local hitbox = char:WaitForChild("FE2_Hitbox", 10)
        if hitbox and resizeHitbox then resizeHitbox() end
    end)
end
syncChar(lp.Character or lp.CharacterAdded:Wait())
lp.CharacterAdded:Connect(syncChar)

local Remote = RS:WaitForChild("Remote", 10)

local function resolveRemote(names, timeout)
    for _, n in ipairs(names) do
        local r = Remote:FindFirstChild(n)
        if r then return r end
    end
    if timeout and timeout > 0 then
        local t0 = tick()
        while tick() - t0 < timeout do
            for _, n in ipairs(names) do
                local r = Remote:FindFirstChild(n)
                if r then return r end
            end
            task.wait(0.2)
        end
    end
    return nil
end

local remGoalLocator  = resolveRemote({"UpdGoalLocator", "FiIxfRCqDOTWRKHqFMoRjSaAxXOutMzD"}, 5)
local remPress        = resolveRemote({"PressedMapButton", "igzyswprgEbMOxwZWHUxvFWNJhDtaODb"}, 3)
local remGameState    = resolveRemote({"UpdateGameState", "FBbJEWQDfbOPQZBNaWtXPmnKTDndEbbK"}, 3)
local remJoinWaiting  = resolveRemote({"AddedWaiting"}, 3)
local remLeaveWaiting = resolveRemote({"RemoveWaiting", "AdzorVwoIZcjrHzQYQGTUPhODshWJNUN"}, 3)
local remLoaded       = resolveRemote({"LoadedMap"}, 3)
local remSurvived     = resolveRemote({"Survived"}, 3)

local loadedBus     = Instance.new("BindableEvent")
local survivedBus   = Instance.new("BindableEvent")
local goalBus       = Instance.new("BindableEvent")
local exitRegionBus = Instance.new("BindableEvent")

local currentState = nil

if remGameState then
    remGameState.OnClientEvent:Connect(function(s)
        -- Normalise: only accept known states; anything unknown = lobby (nil)
        if s ~= "ingame" and s ~= "loading" and s ~= "waiting" then s = nil end
        currentState = s
        if setStatus then
            setStatus(("<b>State:</b> %s"):format(s == nil and "lobby" or tostring(s)))
        end
    end)
end

local function detectStateFromUI()
    local gui     = lp:FindFirstChild("PlayerGui")
    local gameGui = gui and gui:FindFirstChild("GameGui")
    if not gameGui then return nil end

    local hud = gameGui:FindFirstChild("HUD")
    if not hud then return nil end

    local gs = hud:FindFirstChild("Main") and hud.Main:FindFirstChild("GameStats")
    if not gs then return nil end

    -- Loading is the hardest override — always wins
    local loading = gameGui:FindFirstChild("Loading")
    if loading and loading.Visible then return "loading" end

    -- Waiting/queue screen — check before stale ingame HUD
    local waiting = gameGui:FindFirstChild("Waiting")
    if waiting and waiting.Visible then return "waiting" end

    -- Stats visible = lobby/summary screen, definitively NOT ingame
    -- Must be checked BEFORE Ingame, since Ingame can stay stale after survive
    if gs:FindFirstChild("Stats") and gs.Stats.Visible then return nil end

    -- Ingame HUD active — last resort, can be stale, always cross-check with isIngame()
    if gs:FindFirstChild("Ingame") and gs.Ingame.Visible then return "ingame" end

    return nil
end

local function getState()
    return currentState or detectStateFromUI()
end

local function isIngame()
    local char = lp.Character
    local h    = char and char:FindFirstChildOfClass("Humanoid")
    if not h or h.Health <= 0 then return false end

    local gui     = lp:FindFirstChild("PlayerGui")
    local gameGui = gui and gui:FindFirstChild("GameGui")
    local loading = gameGui and gameGui:FindFirstChild("Loading")
    if loading and loading.Visible then return false end

    if getState() ~= "ingame" then return false end

    -- Sanity: Multiplayer map must exist and be non-trivial
    -- Prevents false positives when Ingame HUD is stale post-survive
    local mp = workspace:FindFirstChild("Multiplayer")
    local m  = mp and (mp:FindFirstChild("Map") or mp:FindFirstChild("NewMap"))
    if not m or #m:GetDescendants() <= 10 then return false end

    return true
end

local function isLoading()
    local pgui    = lp and lp:FindFirstChild("PlayerGui")
    local gameGui = pgui and pgui:FindFirstChild("GameGui")
    local loading = gameGui and gameGui:FindFirstChild("Loading")
    return loading and loading.Visible or false
end

local function waitForLoadingDone(timeoutSecs)
    timeoutSecs = timeoutSecs or 60
    local t0 = tick()
    while isLoading() do
        if not state then return false end
        if not state.autoPlay then return false end
        if tick() - t0 > timeoutSecs then return false end
        task.wait(0.2)
    end
    task.wait(0.3)
    return true
end

local didSurvive      = false
local currentGoalPart = nil
local pressedCount    = 0

if remLoaded then
    remLoaded.OnClientEvent:Connect(function() loadedBus:Fire() end)
end

if remSurvived then
    remSurvived.OnClientEvent:Connect(function(success)
        if success ~= false then
            didSurvive = true
            survivedBus:Fire()
            -- Failsafe: if UpdateGameState never fires lobby state after survive,
            -- force currentState to nil so isIngame() / autoQueue unblock
            task.delay(12, function()
                if currentState == "ingame" then
                    currentState = nil
                end
            end)
        end
    end)
end

local function extractGoalPart(obj)
    if typeof(obj) == "Instance" then
        if obj:IsA("BasePart") then return obj end
        if obj:IsA("Model") then return obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart") end
    elseif type(obj) == "table" then
        for _, v in pairs(obj) do
            if typeof(v) == "Instance" then
                if v:IsA("BasePart") then return v end
                if v:IsA("Model") then return v.PrimaryPart or v:FindFirstChildWhichIsA("BasePart") end
            end
        end
    end
    return nil
end

if remGoalLocator then
    remGoalLocator.OnClientEvent:Connect(function(_, p2, _, p4, _)
        currentGoalPart = extractGoalPart(p2)
        goalBus:Fire(currentGoalPart)
    end)
end

local cfg = {
    pressTimeout   = 8,
    betweenDelay   = 0.2,
    queueInterval  = 2.5,
    pressFireCount = 6,
    approachOffset = 3.5,
    approachSteps  = 8,
    approachFire   = 5,
}

local state = {
    autoPlay     = false,
    autoQueue    = false,
    godMode      = false,
    autoRescue   = false,
    autoLostPage = false,
}

-- ─── Exit Region Cache ────────────────────────────────────────────────────────
-- Some maps have multiple ExitRegions but the server only hooks Touched on one.
-- We learn which one is correct and persist it so next run goes straight there.
local exitCache     = {}
local EXIT_CACHE_FILE = "FE2_ExitCache.json"
do
    local ok, raw = pcall(readfile, EXIT_CACHE_FILE)
    if ok and type(raw) == "string" and raw ~= "" then
        local HS = game:GetService("HttpService")
        local ok2, parsed = pcall(HS.JSONDecode, HS, raw)
        if ok2 and type(parsed) == "table" then exitCache = parsed end
    end
end

--- Returns a stable string fingerprint for one ExitRegion part.
local function exitFP(part)
    local p = part.Position
    return math.round(p.X) .. "," .. math.round(p.Y) .. "," .. math.round(p.Z)
end

--- Returns a cache key that uniquely identifies a map by its exit layout.
--- Sorted so insertion order doesn't matter.
local function mapExitKey(exits)
    local fps = {}
    for _, ep in ipairs(exits) do fps[#fps + 1] = exitFP(ep) end
    table.sort(fps)
    return table.concat(fps, "|")
end

local function saveExitCache()
    pcall(function()
        local HS = game:GetService("HttpService")
        writefile(EXIT_CACHE_FILE, HS:JSONEncode(exitCache))
    end)
end
-- ──────────────────────────────────────────────────────────────────────────────

local function getMap()
    local mp = workspace:FindFirstChild("Multiplayer")
    if not mp then return nil end
    local m = mp:FindFirstChild("Map") or mp:FindFirstChild("NewMap")
    return (m and #m:GetDescendants() > 10) and m or nil
end

local function getMapRoot()
    local mp = workspace:FindFirstChild("Multiplayer")
    if not mp then return nil, nil end
    return mp:FindFirstChild("Map"), mp:FindFirstChild("NewMap")
end

local function findExits(map)
    local t = {}
    if not map then return t end
    for _, v in ipairs(map:GetDescendants()) do
        if v:IsA("BasePart") and v.Name == "ExitRegion" then
            t[#t+1] = v
        end
    end
    return t
end

local function findRescueContact(map)
    local rescue = map:FindFirstChild("_Rescue", true)
    if not rescue then return nil end
    return rescue:FindFirstChild("Contact", true)
end

local function findLostPage(map)
    for _, v in ipairs(map:GetDescendants()) do
        if v:IsA("BasePart") and v.Name == "_LostPage" then return v end
    end
    return nil
end

local _exitWatchConns = {}
local _exitFound      = false

local function clearExitWatch()
    for _, c in ipairs(_exitWatchConns) do pcall(function() c:Disconnect() end) end
    _exitWatchConns = {}
    _exitFound      = false
end

watchForExitRegion = function(map)
    clearExitWatch()
    if not map then return end

    for _, v in ipairs(map:GetDescendants()) do
        if v:IsA("BasePart") and v.Name == "ExitRegion" then
            if not table.find(mapIndex.exits, v) then
                table.insert(mapIndex.exits, v)
            end
        end
    end

    local addConn = map.DescendantAdded:Connect(function(v)
        if v:IsA("BasePart") and v.Name == "ExitRegion" then
            _exitFound = true
            if not table.find(mapIndex.exits, v) then
                table.insert(mapIndex.exits, v)
            end
            exitRegionBus:Fire(v)
        end
    end)
    table.insert(_exitWatchConns, addConn)
end

local function getTotalButtons()
    local pgui    = lp and lp:FindFirstChild("PlayerGui")
    local gameGui = pgui and pgui:FindFirstChild("GameGui")
    local loading = gameGui and gameGui:FindFirstChild("Loading")
    if loading then
        local count = loading:FindFirstChild("Count", true)
        if count and count.Parent and count.Parent.Name == "Button"
            and tonumber(count.Text) and tonumber(count.Text) > 0 then
            return tonumber(count.Text)
        end
        local btn = loading:FindFirstChild("Button", true)
        local c   = btn and btn:FindFirstChild("Count")
        if c and tonumber(c.Text) and tonumber(c.Text) > 0 then
            return tonumber(c.Text)
        end
    end
    return nil
end

local function getCurrentButtonDisplay()
    local pgui    = lp and lp:FindFirstChild("PlayerGui")
    local gameGui = pgui and pgui:FindFirstChild("GameGui")
    local hud     = gameGui and gameGui:FindFirstChild("HUD")
    if hud then
        local btns = hud:FindFirstChild("Buttons", true)
        local c    = btns and btns:FindFirstChild("Count")
        if c then return c.Text end
    end
    return nil
end

local function isButtonModel(instance)
    if not instance:IsA("Model") then return false end
    if instance.Name:sub(1,1) == "_" then return false end
    local mapA, mapB = getMapRoot()
    if instance == mapA or instance == mapB then return false end

    for _, d in ipairs(instance:GetDescendants()) do
        if d:IsA("BillboardGui") and
            (d:FindFirstChild("ButtonIcon") or d:FindFirstChild("Count") or d:FindFirstChild("XP")) then
            return true
        end
    end

    for _, c in ipairs(instance:GetChildren()) do
        if c:IsA("BasePart") and c:FindFirstChildOfClass("TouchTransmitter") then
            if not c.Name:sub(1,1):find("_") then return true end
        end
    end

    return false
end

local function getButtonHitPart(model)
    for _, c in ipairs(model:GetChildren()) do
        if c:IsA("BasePart") and c:FindFirstChildOfClass("TouchTransmitter") then return c end
    end
    for _, c in ipairs(model:GetChildren()) do
        if c:IsA("Part") and not c:IsA("UnionOperation") then return c end
    end
    for _, c in ipairs(model:GetChildren()) do
        if c:IsA("BasePart") and not c:IsA("UnionOperation") then return c end
    end
    for _, c in ipairs(model:GetChildren()) do
        if c:IsA("BasePart") then return c end
    end
    return nil
end

local function getButtonBillboard(model)
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BillboardGui") and (d:FindFirstChild("ButtonIcon") or d:FindFirstChild("Count")) then
            return d
        end
    end
    return model:FindFirstChildWhichIsA("BillboardGui", true)
end

local function getButtonState(model)
    local bb = getButtonBillboard(model)
    if not bb then return "UNKNOWN" end
    local border = bb:FindFirstChild("Border")
    local icon   = bb:FindFirstChild("ButtonIcon")

    if icon then
        local c = icon.ImageColor3
        if math.abs(c.R - 0.498) < 0.02 and math.abs(c.G - 0.498) < 0.02 then
            return "PRESSED"
        end
    end

    local hasFuse, hasGroup = false, false
    for _, d in ipairs(model:GetDescendants()) do
        if d.ClassName == "ObjectValue" then
            if d.Name == "Fuse" then hasFuse = true else hasGroup = true end
        end
    end

    if border then
        local c = border.ImageColor3
        if c.R > 0.85 and c.G < 0.15 and c.B < 0.15 then return "FUSE_ACTIVE" end
        if c.G > 0.85 and c.R < 0.15 and c.B < 0.15 then return "CURRENT" end
    end

    if hasFuse  then return "FUSE"  end
    if hasGroup then return "GROUP" end
    return "LOCKED"
end

local function scanButtons(map)
    local buttons = {}
    if not map then return buttons end
    local mapA, mapB = getMapRoot()
    for _, desc in ipairs(map:GetDescendants()) do
        if isButtonModel(desc) then
            if desc == mapA or desc == mapB then continue end
            local hitPart = getButtonHitPart(desc)
            local bb      = getButtonBillboard(desc)
            local st      = getButtonState(desc)
            local num     = nil
            if bb then
                local cl = bb:FindFirstChild("Count")
                if cl then num = tonumber(cl.Text) end
            end
            table.insert(buttons, { model = desc, part = hitPart, billboard = bb, number = num, state = st })
        end
    end
    table.sort(buttons, function(a, b)
        local an, bn = a.number, b.number
        if an and bn then return an < bn end
        if an then return true end
        if bn then return false end
        if a.part and b.part then
            return (a.part.Position.X^2 + a.part.Position.Z^2) < (b.part.Position.X^2 + b.part.Position.Z^2)
        end
        return false
    end)
    for i, btn in ipairs(buttons) do
        if not btn.number then btn.number = i end
    end
    return buttons
end

task.spawn(function()
    local lastMap, lastScanTime = nil, 0
    while true do
        local map = getMap()
        if map then
            local now        = tick()
            local shouldScan = (map ~= lastMap) or (#mapIndex.buttons == 0 and now - lastScanTime > 3)
            if shouldScan then
                lastMap, lastScanTime = map, now
                mapIndex.map     = map
                mapIndex.buttons = scanButtons(map)
                mapIndex.exits   = findExits(map)
                watchForExitRegion(map)
            else
                if #mapIndex.exits == 0 then
                    local ex = findExits(map)
                    if #ex > 0 then mapIndex.exits = ex end
                end
            end
        else
            if lastMap ~= nil then
                lastMap = nil
                mapIndex.map, mapIndex.buttons, mapIndex.exits = nil, {}, {}
                clearExitWatch()
            end
        end
        task.wait(1.5)
    end
end)

local HITBOX_SIZE = Vector3.new(4, 4, 4)

resizeHitbox = function()
    local char   = lp.Character
    if not char then return end
    local hitbox = char:FindFirstChild("FE2_Hitbox")
    if hitbox and hitbox:IsA("BasePart") then hitbox.Size = HITBOX_SIZE end
end

local function getHitboxRig()
    local char   = lp.Character
    if not char then return nil, nil, nil end
    local hrpPart = char:FindFirstChild("HumanoidRootPart")
    local hitbox  = char:FindFirstChild("FE2_Hitbox")
    local weld    = hitbox and hitbox:FindFirstChild("HitboxWeld")
    return hrpPart, hitbox, weld
end

local function restoreHitbox()
    local hrpPart, hitbox, weld = getHitboxRig()
    if hitbox and weld and hrpPart then
        hitbox.CFrame = hrpPart.CFrame * CFrame.new(0, -0.75, 0)
        weld.Enabled  = true
    end
end

local _buttonWeld = nil

local function weldHrpToButton(part)
    if _buttonWeld then
        pcall(function() _buttonWeld:Destroy() end)
        _buttonWeld = nil
    end
    if not hrp or not part or not part.Parent then return end
    local w  = Instance.new("WeldConstraint")
    w.Part0  = hrp
    w.Part1  = part
    w.Parent = hrp
    _buttonWeld = w
end

unweldHrp = function()
    if _buttonWeld then
        pcall(function() _buttonWeld:Destroy() end)
        _buttonWeld = nil
    end
end

local function triggerSlide(active)
    local char        = lp.Character
    local animate     = char and char:FindFirstChild("Animate")
    local slidingEvent = animate and animate:FindFirstChild("Sliding")
    if slidingEvent then pcall(function() slidingEvent:Fire(active) end) end
end

local function approachAndPress(part)
    if not hrp or not hum or not part or not part.Parent then return false end
    if not isIngame() then return false end

    local targetPos = part.Position
    local lookAt    = targetPos + Vector3.new(0, 1.2, 0)

    hrp.AssemblyLinearVelocity  = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero

    local delta   = targetPos - hrp.Position
    local flatDir = Vector3.new(delta.X, 0, delta.Z)
    if flatDir.Magnitude > 0.5 then
        flatDir = flatDir.Unit
    else
        flatDir = part.CFrame.LookVector
        if flatDir.Magnitude < 0.1 then flatDir = Vector3.new(0, 0, -1) end
    end

    local tiltCF = CFrame.Angles(math.rad(8), 0, math.rad(-5))
    local endCF  = CFrame.lookAt(lookAt, lookAt + flatDir) * tiltCF

    if (hrp.Position - targetPos).Magnitude >= 4.5 then
        hrp.CFrame = CFrame.lookAt(lookAt - flatDir * cfg.approachOffset, lookAt) * tiltCF
    end

    triggerSlide(true)

    -- Pre-rotate character toward button before lerp; makes server trigger faster.
    hrp.CFrame = endCF * CFrame.new(0, 0, 0.3)
    RunService.Heartbeat:Wait()
    hrp.CFrame = endCF
    if firetouchinterest then pcall(firetouchinterest, hrp, part, 0) end
    RunService.Heartbeat:Wait()

    local walkStartCF = hrp.CFrame
    for step = 1, cfg.approachSteps do
        local alpha = step / cfg.approachSteps
        hrp.CFrame  = walkStartCF:Lerp(endCF, alpha)
        if step == cfg.approachFire and firetouchinterest then
            pcall(firetouchinterest, hrp, part, 0)
        end
        RunService.Heartbeat:Wait()
    end

    if firetouchinterest then pcall(firetouchinterest, hrp, part, 1) end

    hrp.CFrame = endCF * CFrame.new(0, 0, 0.3)
    RunService.Heartbeat:Wait()
    hrp.CFrame = endCF
    if firetouchinterest then pcall(firetouchinterest, hrp, part, 0) end
    RunService.Heartbeat:Wait()
    if firetouchinterest then pcall(firetouchinterest, hrp, part, 1) end

    triggerSlide(false)
    weldHrpToButton(part)

    if remPress then pcall(remPress.FireServer, remPress, part) end
    return true
end

local function pressButton(part)
    if not hrp or not part or not part.Parent then return false end
    if not isIngame() then return false end
    return approachAndPress(part)
end

local function cleanupPress()
    unweldHrp()
    restoreHitbox()
end

local function triggerTouched(part)
    if not hrp or not part or not part.Parent then return end
    triggerSlide(true)
    hrp.CFrame = CFrame.new(part.Position)
    task.wait(0.03)
    hrp.CFrame = CFrame.new(part.Position + Vector3.new(0.1, 0, 0))
    task.wait(0.03)
    hrp.CFrame = CFrame.new(part.Position)
    if firetouchinterest then
        pcall(firetouchinterest, hrp, part, 0)
        task.wait(0.05)
        pcall(firetouchinterest, hrp, part, 1)
    end
    triggerSlide(false)
end

local function doRescue(map)
    if not state.autoRescue then return false end
    if not isIngame() then return false end
    local contact = findRescueContact(map)
    if not contact then return false end
    if not state.autoRescue then return false end
    if setStatus then setStatus("<b>Rescue:</b> Triggering...") end
    triggerTouched(contact)
    task.wait(0.1)
    return true
end

local function doLostPage(map)
    if not state.autoLostPage then return false end
    if not isIngame() then return false end
    local page = findLostPage(map)
    if not page then return false end
    if not state.autoLostPage then return false end
    if setStatus then setStatus("<b>Lost Page:</b> Collecting...") end
    triggerTouched(page)
    task.wait(0.1)
    return true
end

RunService.Heartbeat:Connect(function()
    if state.godMode and hum and hum.Health < hum.MaxHealth then
        hum.Health = hum.MaxHealth
    end
end)

local function getQueueRemote(name)
    local r = RS:FindFirstChild("Remote")
        or game:GetService("ReplicatedStorage"):FindFirstChild("Remote")
    return r and r:FindFirstChild(name)
end

local function fireJoinQueue()
    local event = getQueueRemote("AddedWaiting") or remJoinWaiting
    if event then pcall(function() event:FireServer() end); return true end
    return false
end

local function fireLeaveQueue()
    local event = getQueueRemote("RemoveWaiting") or remLeaveWaiting
    if event then pcall(function() event:FireServer() end); return true end
    return false
end

local function isInLift()
    -- Do NOT trust currentState == "waiting" here: after re-inject or config
    -- restore, currentState can be stale, causing auto-queue to block forever.
    -- Use the actual Waiting GUI as ground truth instead.
    local pgui       = lp and lp:FindFirstChild("PlayerGui")
    local gameGui    = pgui and pgui:FindFirstChild("GameGui")
    local waitingGui = gameGui and gameGui:FindFirstChild("Waiting")
    if waitingGui and waitingGui.Visible then return true end
    local liftWait = pgui and pgui:FindFirstChild("LiftWaitVisual")
    if liftWait and liftWait.Enabled then return true end
    return false
end

task.spawn(function()
    while true do
        task.wait(cfg.queueInterval)
        if state.autoQueue and not isIngame() and not isLoading() and not isInLift() then
            fireJoinQueue()
        end
    end
end)

local Window, statusLabel, autoPlayThread, autoPlayToggle

setStatus = function(txt)
    if statusLabel then statusLabel:Set(txt) end
end

local function runAutoPlay()
    local lastMap = nil

    while state.autoPlay do
        setStatus("<b>Auto Play:</b> Waiting...")
        didSurvive   = false
        pressedCount = 0

        while state.autoPlay and not isIngame() do task.wait(0.3) end
        if not state.autoPlay then break end

        if isLoading() then
            setStatus("<b>Auto Play:</b> Loading map...")
            if not waitForLoadingDone(60) then
                setStatus("<b>Auto Play:</b> Timeout, retrying...")
                task.wait(2); continue
            end
        end

        local map = getMap()
        if not map or map == lastMap then task.wait(0.5); continue end

        local idxDeadline = tick() + 6
        while mapIndex.map ~= map and tick() < idxDeadline do task.wait(0.1) end

        if not _exitFound then watchForExitRegion(map) end

        if state.autoRescue   then doRescue(map)   end
        if state.autoLostPage then doLostPage(map) end
        if not state.autoPlay then break end

        local total = getTotalButtons() or #mapIndex.buttons
        if total and #mapIndex.buttons < total then
            local tWait = tick() + 6
            while tick() < tWait and #mapIndex.buttons < total and state.autoPlay do
                mapIndex.buttons = scanButtons(map)
                task.wait(0.3)
            end
        end
        total = getTotalButtons() or #mapIndex.buttons
        setStatus(("<b>Auto Play:</b> %d button(s) — starting..."):format(total))

        local pressedParts    = {}
        local roundDone       = false
        local lastGoalTime    = tick()
        local GOAL_TIMEOUT    = 45
        local lastTargetPart  = nil
        local lastTargetTime  = tick()
        local sameTargetRetry = 0
        local STUCK_THRESHOLD = 8
        local MAX_SAME_RETRY  = 2

        if currentGoalPart and currentGoalPart.Parent then lastGoalTime = tick() end

        local goalConn = goalBus.Event:Connect(function()
            lastGoalTime    = tick()
            lastTargetPart  = nil
            sameTargetRetry = 0
        end)

        while state.autoPlay and not roundDone do
            if not isIngame() then break end

            local char = lp.Character
            local h    = char and char:FindFirstChildOfClass("Humanoid")
            if not h or h.Health <= 0 then
                setStatus("<b>Dead</b> — stopped"); break
            end

            if _exitFound then roundDone = true; break end
            if getCurrentButtonDisplay() == "🏁" then roundDone = true; break end
            if total > 0 and pressedCount >= total then roundDone = true; break end

            local targetPart = nil

            if currentGoalPart and currentGoalPart.Parent then
                if not pressedParts[currentGoalPart] then
                    local pm = currentGoalPart.Parent
                    local ls = (pm and pm:IsA("Model")) and getButtonState(pm) or nil
                    if ls ~= "PRESSED" then targetPart = currentGoalPart end
                end
            end

            if not targetPart then
                for _, btn in ipairs(mapIndex.buttons) do
                    btn.state = getButtonState(btn.model)
                end
                for _, btn in ipairs(mapIndex.buttons) do
                    if btn.state == "CURRENT" and btn.part and btn.part.Parent
                        and not pressedParts[btn.part] then
                        targetPart = btn.part; break
                    end
                end
            end

            if targetPart then
                if targetPart == lastTargetPart then
                    local stuckSec = tick() - lastTargetTime
                    if stuckSec > STUCK_THRESHOLD then
                        sameTargetRetry += 1
                        if sameTargetRetry > MAX_SAME_RETRY then
                            pressedParts[targetPart] = true
                            mapIndex.buttons = scanButtons(map)
                            for _, btn in ipairs(mapIndex.buttons) do
                                if not state.autoPlay or _exitFound then break end
                                if btn.part and btn.part.Parent and not pressedParts[btn.part]
                                    and getButtonState(btn.model) ~= "PRESSED" then
                                    pressButton(btn.part)
                                    task.wait(0.2)
                                    cleanupPress()
                                end
                            end
                            lastTargetPart  = nil
                            lastTargetTime  = tick()
                            sameTargetRetry = 0
                            lastGoalTime    = tick()
                            task.wait(cfg.betweenDelay)
                            continue
                        end
                        lastTargetTime = tick()
                        pressButton(targetPart)
                        task.wait(0.3)
                        cleanupPress()
                        task.wait(cfg.betweenDelay)
                        continue
                    end
                else
                    lastTargetPart  = targetPart
                    lastTargetTime  = tick()
                    sameTargetRetry = 0
                end
            end

            if not targetPart and (tick() - lastGoalTime) > GOAL_TIMEOUT then
                local scanned = #mapIndex.buttons > 0 and mapIndex.buttons or scanButtons(map)
                for _, btn in ipairs(scanned) do
                    if not state.autoPlay or _exitFound then break end
                    if btn.part and btn.part.Parent and not pressedParts[btn.part]
                        and getButtonState(btn.model) ~= "PRESSED" then
                        pressButton(btn.part)
                        task.wait(0.1)
                        cleanupPress()
                    end
                end
                lastGoalTime = tick()
                task.wait(cfg.betweenDelay)
                continue
            end

            if not targetPart then
                setStatus("<b>Auto Play:</b> Waiting for goal...")
                task.wait(0.25); continue
            end

            local curDisplay = getCurrentButtonDisplay()
            local dispNum    = tonumber(curDisplay) or (pressedCount + 1)
            setStatus(("<b>Button %d/%d</b> — pressing..."):format(dispNum, total))

            local prevGoal  = currentGoalPart
            pressButton(targetPart)

            local t0        = tick()
            local lastPress = t0
            local confirmed = false

            while tick() - t0 < cfg.pressTimeout and state.autoPlay do
                if _exitFound then
                    confirmed = true; roundDone = true; break
                end
                if getCurrentButtonDisplay() == "🏁" then
                    confirmed = true; roundDone = true
                    pressedParts[targetPart] = true; break
                end
                if currentGoalPart ~= prevGoal then
                    confirmed                = true
                    pressedCount            += 1
                    pressedParts[targetPart] = true
                    lastTargetPart           = nil
                    lastTargetTime           = tick()
                    sameTargetRetry          = 0
                    if total > 0 and pressedCount >= total then roundDone = true end
                    break
                end
                if (tick() - lastPress) > 1 and targetPart.Parent then
                    pressButton(targetPart); lastPress = tick()
                end
                task.wait(0.04)
            end

            cleanupPress()
            if roundDone then break end

            if not confirmed then
                if _exitFound then roundDone = true; break end
                if total > 0 and pressedCount >= total then roundDone = true; break end
                if pressedCount > 0 and #findExits(map) > 0 then roundDone = true; break end
                if targetPart == lastTargetPart then
                    lastTargetTime = lastTargetTime - STUCK_THRESHOLD
                end
            end

            task.wait(cfg.betweenDelay)
        end

        goalConn:Disconnect()
        if not state.autoPlay then break end

        setStatus("<b>Escape:</b> Finding exit...")
        if not _exitFound then watchForExitRegion(map) end

        -- Collect all exits; some maps have 2 ExitRegions but server only
        -- hooks Touched on one of them — so we cycle through all until survived fires.
        local allExits = {}
        for _, v in ipairs(mapIndex.exits) do table.insert(allExits, v) end

        if #allExits == 0 then
            local exitConn = exitRegionBus.Event:Connect(function(part)
                if not table.find(allExits, part) then table.insert(allExits, part) end
            end)
            local exitDeadline = tick() + 30
            while #allExits == 0 and tick() < exitDeadline and state.autoPlay do
                local ex = findExits(map)
                if #ex > 0 then allExits = ex; break end
                task.wait(0.25)
            end
            exitConn:Disconnect()
        end

        if not state.autoPlay then break end

        if #allExits == 0 then
            setStatus("<b>Escape:</b> No exit found")
        end

        -- Cache lookup: build map key from exit layout, resolve best starting index.
        local cacheKey  = mapExitKey(allExits)
        local cachedFP  = cacheKey ~= "" and exitCache[cacheKey] or nil
        local exitIdx   = 1
        if cachedFP then
            for i, ep in ipairs(allExits) do
                if exitFP(ep) == cachedFP then exitIdx = i; break end
            end
        end

        local sc        = survivedBus.Event:Connect(function() didSurvive = true end)
        local dl2       = tick() + 60
        local lastTouch = 0
        local lastSwap  = tick()

        -- Initial teleport + touch to first exit
        local function touchExit(ep)
            if not ep or not ep.Parent or not hrp then return end
            hrp.CFrame = CFrame.new(ep.Position)
            if firetouchinterest then
                pcall(firetouchinterest, hrp, ep, 0)
                task.wait(0.05)
                pcall(firetouchinterest, hrp, ep, 1)
            end
        end

        if #allExits > 0 then
            touchExit(allExits[exitIdx])
            local label = cachedFP and "<b>Escape:</b> Cached exit " or "<b>Escape:</b> Exit "
            setStatus((label .. "%d/%d"):format(exitIdx, #allExits))
        end

        while not didSurvive and tick() < dl2 and state.autoPlay do
            if getMap() ~= map then break end

            local now = tick()
            local ep  = allExits[exitIdx]

            -- Cycle to next exit every 5s if survived hasn't fired
            if #allExits > 1 and now - lastSwap >= 5 then
                exitIdx  = (exitIdx % #allExits) + 1
                lastSwap = now
                ep       = allExits[exitIdx]
                touchExit(ep)
                setStatus(("<b>Escape:</b> Exit %d/%d"):format(exitIdx, #allExits))
            elseif now - lastTouch >= 1 then
                -- Re-fire touch on current exit every 1s
                if ep and ep.Parent and hrp and firetouchinterest then
                    pcall(firetouchinterest, hrp, ep, 0)
                end
                lastTouch = now
            end

            task.wait(0.25)
        end
        sc:Disconnect()

        -- Persist which exit worked so next time we go straight there.
        if didSurvive and cacheKey ~= "" and #allExits > 1 then
            local winFP = exitFP(allExits[exitIdx])
            if exitCache[cacheKey] ~= winFP then
                exitCache[cacheKey] = winFP
                saveExitCache()
            end
        end

        if didSurvive then
            setStatus(("<b>Survived!</b> %d button(s)."):format(pressedCount))
            if Window then
                Window:Notify({
                    title   = "Auto Play",
                    content = ("Survived! %d button(s)."):format(pressedCount),
                    type    = "success",
                    duration = 3,
                })
            end
        else
            setStatus("<b>Done</b> — next map...")
        end

        lastMap = map
        task.wait(2)
    end

    cleanupPress()
    setStatus("<b>Auto Play:</b> Stopped")
end

SaveManager:SetFolder("Dante_FE2")
SaveManager:SetAutoSaveInterval(30)

Delirium:Boot("Flood Escape 2 Hub", function(win)
    Window = win

    local tab = Window:CreateTab({ name = "Auto", icon = "lucide:bot" })

    tab:CreateSection({ name = "Status" })
    statusLabel = tab:CreateLabel({ text = "<b>Auto Play:</b> Idle", richText = true })

    local _censorName = false

    local function formatName(displayName, userName)
        local function censor(s)
            if #s <= 2 then return s end
            return s:sub(1,1) .. string.rep("*", #s - 2) .. s:sub(-1)
        end
        local d = _censorName and censor(displayName) or displayName
        local u = _censorName and censor(userName) or userName
        return d .. " (@" .. u .. ")"
    end

    tab:CreateSection({ name = "Features" })

    autoPlayToggle = tab:CreateToggle({
        name        = "Auto Play",
        flag        = "AutoPlay",
        value       = false,
        description = "Auto complete map buttons until survived.",
        callback    = function(v)
            state.autoPlay = v
            if v then
                if autoPlayThread then task.cancel(autoPlayThread) end
                autoPlayThread = task.spawn(runAutoPlay)
            else
                if autoPlayThread then task.cancel(autoPlayThread); autoPlayThread = nil end
                cleanupPress()
                setStatus("<b>Auto Play:</b> Stopped")
            end
            Window:Notify({
                title    = "Auto Play",
                content  = v and "Enabled" or "Disabled",
                type     = v and "success" or "warning",
                duration = 2,
            })
        end,
    })

    tab:CreateToggle({
        name        = "God Mode",
        flag        = "GodMode",
        value       = false,
        description = "Auto heals to full HP every Heartbeat.",
        callback    = function(v)
            state.godMode = (v == true)
            Window:Notify({
                title    = "God Mode",
                content  = state.godMode and "Enabled" or "Disabled",
                type     = state.godMode and "success" or "warning",
                duration = 2,
            })
            SaveManager:ScheduleAutoSave()
        end,
    })

    tab:CreateToggle({
        name        = "Rescue",
        flag        = "AutoRescue",
        value       = false,
        description = "Auto trigger rescue contact.",
        callback    = function(v)
            state.autoRescue = (v == true)
            Window:Notify({
                title    = "Rescue",
                content  = state.autoRescue and "Enabled" or "Disabled",
                type     = state.autoRescue and "success" or "warning",
                duration = 2,
            })
            SaveManager:ScheduleAutoSave()
        end,
    })

    tab:CreateToggle({
        name        = "Lost Page",
        flag        = "AutoLostPage",
        value       = false,
        description = "Auto collect Lost Page in map.",
        callback    = function(v)
            state.autoLostPage = (v == true)
            Window:Notify({
                title    = "Lost Page",
                content  = state.autoLostPage and "Enabled" or "Disabled",
                type     = state.autoLostPage and "success" or "warning",
                duration = 2,
            })
            SaveManager:ScheduleAutoSave()
        end,
    })

    tab:CreateToggle({
        name        = "Auto Queue",
        flag        = "AutoQueue",
        value       = false,
        description = "Auto join the lift queue in lobby.",
        callback    = function(v)
            state.autoQueue = v
            if v then
                task.spawn(function()
                    -- Brief wait so GUI state settles after config restore before
                    -- we check isInLift() — prevents a false-positive blocking fire.
                    task.wait(0.5)
                    if not isIngame() and not isLoading() and not isInLift() then
                        fireJoinQueue()
                    end
                end)
            else
                if isInLift() then fireLeaveQueue() end
            end
            Window:Notify({
                title    = "Auto Queue",
                content  = v and "Enabled" or "Disabled",
                type     = v and "success" or "warning",
                duration = 2,
            })
            SaveManager:ScheduleAutoSave()
        end,
    })

    do
        local _whUrl       = Delirium.Flags:Get("WebhookURL") or ""
        local _whAutoSend  = false
        local _whStreak    = 0
        local _whMapName   = "Unknown"
        local _whRating    = "?"
        local _whRunXp     = "?"
        local _whIntensity = "?"
        local _whMapImg    = nil

        local reqFn = (syn and syn.request)
            or (http and http.request)
            or (type(request) == "function" and request)
            or nil

        local function censorStr(s)
            if #s <= 2 then return s end
            return s:sub(1,1) .. string.rep("*", #s - 2) .. s:sub(-1)
        end

        local function getMapImageIdFromHUD()
            local pg2  = lp:FindFirstChild("PlayerGui")
            local gg2  = pg2 and pg2:FindFirstChild("GameGui")
            local hud2 = gg2 and gg2:FindFirstChild("HUD")
            if not hud2 then return nil end
            local mapTest = hud2:FindFirstChild("MapTest", true)
            if mapTest then
                local logo = mapTest:FindFirstChild("Logo")
                if logo and logo.Image ~= "" then
                    return logo.Image:match("id=(%d+)") or logo.Image:match("rbxassetid://(%d+)")
                end
            end
            return nil
        end

        local function fetchAvatarUrl(userId)
            local ok2, raw2 = pcall(
                game.HttpGet, game,
                "https://thumbnails.roblox.com/v1/users/avatar-headshot?userIds=" .. tostring(userId) ..
                "&size=150x150&format=Png&isCircular=false"
            )
            if not ok2 then return nil end
            return raw2:match('"imageUrl":"([^"]+)"')
        end

        local function readWidgetLabel()
            local pg = lp:FindFirstChild("PlayerGui")

            local ok, txt = pcall(function()
                return pg.TopbarStandard.Holders.Left.Widget.IconButton.Menu.IconSpot.Contents.IconLabelContainer.IconLabel.Text
            end)
            if ok and txt and txt ~= "" then
                local name     = txt:match(":%s*(.-)%s*⭐")
                local rat      = txt:match("⭐%s*([%d%.]+)")
                local rxp      = txt:match("Current Run:%s*(%d+)XP")
                local iF, iT   = txt:match("Intensity:%s*([%d%.]+)%s*[^%d%.]+%s*([%d%.]+)")
                if name and name ~= "" then _whMapName   = name end
                if rat             then _whRating    = rat  end
                if rxp             then _whRunXp     = rxp  end
                if iF and iT       then _whIntensity = iF .. " → " .. iT end
            end

            local okImg, img = pcall(function()
                return pg.TopbarStandard.Holders.Left.Widget.IconButton.Menu.IconSpot.Contents.IconImage.Image
            end)
            if okImg and img and img ~= "" then
                local id = img:match("rbxassetid://(%d+)") or img:match("^(%d+)$")
                if id then _whMapImg = id end
            end
            -- Fallback: read from HUD MapTest Logo if widget image is empty
            if not _whMapImg or _whMapImg == "" then
                local hudId = getMapImageIdFromHUD()
                if hudId then _whMapImg = hudId end
            end
        end

        local function getXpInfo()
            local pg  = lp:FindFirstChild("PlayerGui")
            local gg  = pg and pg:FindFirstChild("GameGui")
            local hud = gg and gg:FindFirstChild("HUD")
            if not hud then return "?", "?" end

            local xpStats = hud:FindFirstChild("XPStats", true)
            if not xpStats then return "?", "?" end

            local xpLabel   = xpStats:FindFirstChild("XP")
            local iconFrame = xpStats:FindFirstChild("Icon")
            local iconInfo  = nil

            if iconFrame then
                for _, v in ipairs(iconFrame:GetDescendants()) do
                    if v:IsA("TextLabel") and v.Name == "Info" and tonumber(v.Text) then
                        iconInfo = v; break
                    end
                end
            end

            return xpLabel and xpLabel.Text or "?", iconInfo and iconInfo.Text or "?"
        end

        local function getMapImageFromLobbyBoard()
            local ok, img = pcall(function()
                return workspace.Lobby.GameInfo.SurfaceGui.Frame.Imgs.MapImg.Image
            end)
            if ok and img and img ~= "" then
                return img:match("rbxassetid://(%d+)") or img:match("^(%d+)$")
            end
            return nil
        end

        local function fetchImgUrl(assetId)
            if not assetId then return nil end
            local ok, raw = pcall(
                game.HttpGet, game,
                "https://thumbnails.roblox.com/v1/assets?assetIds=" .. assetId ..
                "&size=420x420&format=Png&isCircular=false"
            )
            if not ok then return nil end
            return raw:match('"imageUrl":"([^"]+)"')
        end

        local function sendWebhook(mapName, streak, xpText, level, imgUrl, rating, runXp, intensity, avatarUrl)
            if _whUrl == "" then
                Window:Notify({ title = "Webhook", content = "URL is empty!", type = "error", duration = 3 })
                return
            end
            if not reqFn then
                Window:Notify({ title = "Webhook", content = "request() not available", type = "error", duration = 4 })
                return
            end

            local displayedUser = _censorName and censorStr(lp.Name) or lp.Name
            local displayedDisp = _censorName and censorStr(lp.DisplayName) or lp.DisplayName

            local embed = {
                title  = "Survived!",
                color  = 0x57F287,
                author = {
                    name     = displayedDisp .. " (@" .. displayedUser .. ")",
                    icon_url = avatarUrl or "https://tr.rbxcdn.com/180DAY-53e89c4a9a7cdf40e4f39ea84e9f374a/150/150/Image/Webp/noFilter",
                },
                fields = {
                    { name = "📌 Map",      value = mapName,                  inline = true },
                    { name = "⭐ Rating",    value = rating  or "?",           inline = true },
                    { name = "🔥 Streak",    value = "#" .. tostring(streak),  inline = true },
                    { name = "💠 Run XP",    value = (runXp or "?") .. " XP", inline = true },
                    { name = "📈 Intensity", value = intensity or "?",         inline = true },
                    { name = "🎯 Lvl",       value = "Lv." .. tostring(level), inline = true },
                },
                footer    = { text = "Delirium" },
                timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            }
            if imgUrl then embed.thumbnail = { url = imgUrl } end

            local HS      = game:GetService("HttpService")
            local ok, err = pcall(reqFn, {
                Url     = _whUrl,
                Method  = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body    = HS:JSONEncode({ username = "Delirium FE2", embeds = { embed } }),
            })
            if ok then
                Window:Notify({ title = "Webhook", content = "✅ Sent!", type = "success", duration = 2 })
            else
                Window:Notify({ title = "Webhook", content = "❌ Failed: " .. tostring(err), type = "error", duration = 4 })
            end
        end

        local _whSurvivedThisRound = false

        -- Capture map image while the map is still active
        local function captureMapImage()
            task.delay(1.5, function()
                -- Primary: lobby board MapImg
                local lobbyId = getMapImageFromLobbyBoard()
                if lobbyId then _whMapImg = lobbyId; return end
                -- Fallback: topbar widget icon
                local pg = lp:FindFirstChild("PlayerGui")
                local okImg, img = pcall(function()
                    return pg.TopbarStandard.Holders.Left.Widget.IconButton.Menu.IconSpot.Contents.IconImage.Image
                end)
                if okImg and img and img ~= "" then
                    local id = img:match("rbxassetid://(%d+)") or img:match("^(%d+)$")
                    if id then _whMapImg = id; return end
                end
                -- Last fallback: HUD MapTest Logo
                local hudId = getMapImageIdFromHUD()
                if hudId then _whMapImg = hudId end
            end)
        end

        if remLoaded then
            remLoaded.OnClientEvent:Connect(captureMapImage)
        end

        survivedBus.Event:Connect(function()
            if _whSurvivedThisRound then return end
            _whSurvivedThisRound = true
            _whStreak += 1
            readWidgetLabel()
            if not _whAutoSend then return end
            task.wait(1.5)
            readWidgetLabel()
            local xpText, level = getXpInfo()
            local imgId  = (_whMapImg and _whMapImg ~= "") and _whMapImg
                        or getMapImageFromLobbyBoard()
                        or getMapImageIdFromHUD()
            local imgUrl = imgId and fetchImgUrl(imgId) or nil
            local avUrl  = fetchAvatarUrl(lp.UserId)
            task.spawn(sendWebhook, _whMapName, _whStreak, xpText, level, imgUrl, _whRating, _whRunXp, _whIntensity, avUrl)
        end)

        if remGameState then
            remGameState.OnClientEvent:Connect(function(gs)
                if gs == "ingame" then captureMapImage() end
                if gs == "loading" then
                    if not _whSurvivedThisRound then _whStreak = 0 end
                    _whSurvivedThisRound = false
                end
            end)
        end

        local wTab = Window:CreateTab({ name = "Webhook", icon = "lucide:webhook" })

        wTab:CreateSection({ name = "Config" })
        wTab:CreateInput({
            name        = "Discord Webhook URL",
            description = "Paste your Discord webhook URL.",
            placeholder = "https://discord.com/api/webhooks/...",
            flag        = "WebhookURL",
            value       = _whUrl,
            callback    = function(v)
                _whUrl = v
                SaveManager:ScheduleAutoSave()
            end,
        })

        wTab:CreateSection({ name = "Options" })
        wTab:CreateToggle({
            name        = "Auto Send on Survived",
            description = "Auto send log to Discord on survived.",
            flag        = "WebhookAutoSend",
            value       = false,
            callback    = function(v)
                _whAutoSend = v
                SaveManager:ScheduleAutoSave()
            end,
        })
        wTab:CreateToggle({
            name        = "Censor Username",
            flag        = "CensorName",
            value       = false,
            description = "Hide part of display name and username.",
            callback    = function(v)
                _censorName = v
                SaveManager:ScheduleAutoSave()
            end,
        })

        wTab:CreateSection({ name = "Manual" })
        wTab:CreateButton({
            name        = "Send Test Now",
            description = "Send current map log to Discord.",
            callback    = function()
                readWidgetLabel()
                local xpText, level = getXpInfo()
                local imgId  = (_whMapImg and _whMapImg ~= "") and _whMapImg
                            or getMapImageFromLobbyBoard()
                            or getMapImageIdFromHUD()
                local imgUrl = imgId and fetchImgUrl(imgId) or nil
                local avUrl  = fetchAvatarUrl(lp.UserId)
                task.spawn(sendWebhook, _whMapName, _whStreak, xpText, level, imgUrl, _whRating, _whRunXp, _whIntensity, avUrl)
            end,
        })

        wTab:CreateLabel({
            text     = "<b>Streak</b> resets when returning to lobby.",
            richText = true,
        })
    end

    SaveManager:BuildConfigTab(Window)
    SaveManager:Load()
end)

_G.DanteCleanup = function()
    if autoPlayThread then pcall(task.cancel, autoPlayThread) end
    if Window and Window.Destroy then pcall(Window.Destroy, Window) end
    if clearExitWatch then pcall(clearExitWatch) end
    if unweldHrp then pcall(unweldHrp) end
end
