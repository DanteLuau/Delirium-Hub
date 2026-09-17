--[[
  ╔══════════════════════════════════════════════════════════════╗
  ║   INDO VOICE — Mega Suite (Delirium · API.md compliant)      ║
  ║   Fishing · Mining · Refining · Auto Claim · Anti-AFK        ║
  ║   Misc · Auto Sell · Hotspot ESP/Chams · Auto Fav Fish       ║
  ╚══════════════════════════════════════════════════════════════╝
]]

repeat task.wait() until game:IsLoaded()

do
    local _prevUnload = getgenv and getgenv().IndoVoice_Unload
    if type(_prevUnload) == "function" then
        pcall(_prevUnload)
        task.wait(0.2)
    end
end

-- ─── Load Delirium (dist/library.lua per API.md §1) ──────────────
local Delirium = (getgenv and getgenv().Delirium) or (type(Delirium) == "table" and Delirium or nil)
if not (Delirium and type(Delirium) == "table" and Delirium.CreateWindow) then
    local GITHUB_URL = "https://raw.githubusercontent.com/DanteLuau/Delirium/refs/heads/main/test.lua?t="
                       .. tostring(tick())
    local success, result = pcall(function()
        return loadstring(game:HttpGet(GITHUB_URL))()
    end)
    if success and result and result.CreateWindow then
        Delirium = result
        if getgenv then getgenv().Delirium = Delirium end
    else
        error("[Delirium] Failed to load library: " .. tostring(result))
    end
end
assert(Delirium and Delirium.CreateWindow, "[Indo Voice] Delirium.CreateWindow missing")

-- ─── Forward-declared Notify shim (routes to Window once available) ─
local ActiveWindow
local function Notify(props)
    if not ActiveWindow then return end
    local nt = tostring(props.Type or props.type or "info"):lower()
    if nt ~= "success" and nt ~= "warning" and nt ~= "error" and nt ~= "info" then
        nt = "info"
    end
    pcall(function()
        ActiveWindow:Notify({
            title    = props.Title    or props.title    or "Indo Voice",
            content  = props.Message  or props.content  or "",
            type     = nt,
            duration = props.Duration or props.duration or 3,
        })
    end)
end

-- ─── Services ────────────────────────────────────────────────────
local Players              = game:GetService("Players")
local RunService           = game:GetService("RunService")
local UserInputService     = game:GetService("UserInputService")
local VirtualInputManager  = game:GetService("VirtualInputManager")
local PathfindingService   = game:GetService("PathfindingService")
local ReplicatedStorage    = game:GetService("ReplicatedStorage")
local LocalPlayer          = Players.LocalPlayer
local PlayerGui            = LocalPlayer:WaitForChild("PlayerGui")

-- ─── Config / Runtime ────────────────────────────────────────────
local Settings = {
    Fishing = {
        Enabled           = false,
        AutoEquipRod      = true,
        CastMethod        = "Legit",
        CatchMethod       = "Legit",
        CastHoldDuration  = 2.0,
        BlatantCatchDelay = 3.8,
        ClickSpeedCPS     = 10,
        ClickInterval     = 1 / 15,
        CastDelay         = 0,
        BaitTimeout       = 25,
        TotalFishCaught   = 0,
        FilterByRarity    = false,
        MinRarity         = "Rare",
        AllowUnspecified  = true,
    },
    Mining = {
        Enabled           = false,
        FullyAuto         = false,
        TargetFilter      = "Hotspot Only",
        UndergroundDepth  = 12.5,
        AutoEquipPickaxe  = true,
        AutoWalk          = false,
        AutoWalkReachDist = 12,
        FakeHitAnimation  = false,
        FakeHitRepeatCount= 3,
        SearchRadius      = 40,
        SafeZonePercent   = 1,
        LoopDelay         = 0.15,
        HitGap            = 0.12,
        WatchdogTimeout   = 3.0,
        MineMethod        = "Legit",
        BlatantHitDelay   = 5.5,
        TotalMined        = 0,
        TotalFailed       = 0,
    }
}

local Runtime = {
    Fishing = {
        Thread = nil, ActiveRod = nil, CastToken = nil, LastUsedToken = nil,
        IsCasting = false, BaitLanded = false, IsBusy = false,
        IsInternalReEquip = false, ActiveCatchThread = nil,
        LastCastTime = 0, LastBaitLandedTime = 0,
        FacingLockConn = nil, Connections = {},
    },
    Mining = {
        Thread = nil, IsBusy = false, SessionToken = nil, HookedPickaxe = nil,
        CurrentTargetStone = nil, ActiveHitThread = nil, IsInternalReEquip = false,
        Connections = {}, FloatMover = nil, FloatGyro = nil, FloatConn = nil,
        TargetFloatCF = nil, IsFloating = false,
    },
    GlobalConnections = {},
}

-- ─── Utils ───────────────────────────────────────────────────────
local Utils = {}

function Utils.AddConnection(list, conn) table.insert(list, conn) return conn end
function Utils.ClearConnections(list)
    for _, c in ipairs(list) do pcall(function() c:Disconnect() end) end
    table.clear(list)
end
function Utils.GetCharacter() return LocalPlayer.Character end
function Utils.GetHumanoid()
    local c = LocalPlayer.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end
function Utils.GetHumanoidRootPart()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end
function Utils.GetCharacterPosition()
    local h = Utils.GetHumanoidRootPart()
    return h and h.Position or Vector3.zero
end

local IsMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

function Utils.SendClick(x, y)
    if IsMobile then
        VirtualInputManager:SendTouchEvent(0, Vector2.new(x, y), Enum.UserInputState.Begin, game)
        task.wait(0.01)
        VirtualInputManager:SendTouchEvent(0, Vector2.new(x, y), Enum.UserInputState.End, game)
    else
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 1)
        task.wait(0.01)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 1)
    end
end

-- Simple safety teleport used by Hotspot ESP
function SafeTeleportTo(pos)
    local hrp = Utils.GetHumanoidRootPart()
    if not hrp then return end
    hrp.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
end

-- ══════════════════════════════════════════════════════════════════
-- FISHING SYSTEM
-- ══════════════════════════════════════════════════════════════════
local FishingSystem = {}

function FishingSystem.GetEquippedRod()
    local c = Utils.GetCharacter() if not c then return nil end
    for _, item in ipairs(c:GetChildren()) do
        if item:IsA("Tool") and string.find(string.lower(item.Name), "rod") then return item end
    end
    return nil
end

function FishingSystem.GetBackpackRod()
    local bp = LocalPlayer:FindFirstChildOfClass("Backpack") if not bp then return nil end
    for _, item in ipairs(bp:GetChildren()) do
        if item:IsA("Tool") and string.find(string.lower(item.Name), "rod") then return item end
    end
    return nil
end

function FishingSystem.EnsureRodEquipped()
    local eq = FishingSystem.GetEquippedRod() if eq then return eq end
    if not Settings.Fishing.AutoEquipRod then return nil end
    local bpRod = FishingSystem.GetBackpackRod()
    local hum = Utils.GetHumanoid()
    if bpRod and hum then
        hum:EquipTool(bpRod)
        task.wait(0.3)
        return FishingSystem.GetEquippedRod()
    end
    return nil
end

function FishingSystem.FindActiveBobber()
    local c = Utils.GetCharacter()
    if c and c:FindFirstChild("Bobber") then return c:FindFirstChild("Bobber") end
    local lpName = string.lower(LocalPlayer.Name)
    for _, obj in ipairs(workspace:GetChildren()) do
        local n = string.lower(obj.Name)
        if (string.find(n, lpName) and string.find(n, "bobber")) or obj.Name == "Bobber" then
            return obj
        end
    end
    return nil
end

function FishingSystem.GetFishingGui()
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui") if not pg then return nil end
    for _, g in ipairs(pg:GetChildren()) do
        if g.Name == "FishingUI" or g:FindFirstChild("FishingHolder") or g:FindFirstChild("PreFishingHolder") then
            return g
        end
    end
    return nil
end

function FishingSystem.CheckSuspension()
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local msg = pg and pg:FindFirstChild("Message")
    local lbl = msg and msg:FindFirstChild("MessageHolder")
        and msg.MessageHolder:FindFirstChild("MessageLabel")
    if lbl and lbl.Visible and lbl.Text and lbl.Text:find("temporarily disabled") then
        local secs = tonumber(lbl.Text:match("(%d+)%s+seconds"))
        return true, secs or 5
    end
    return false, 0
end

function FishingSystem.SolvePreFishingDrag(pre)
    if not pre or not pre.Visible then return end
    local dragBtn = pre:WaitForChild("DragButton", 2)
    local target = pre:WaitForChild("TargetFrame", 2)
    if not dragBtn or not target then return end
    local det = dragBtn:WaitForChild("UIDragDetector", 2)
    if not det then return end
    local t0 = os.clock()
    while pre.Visible and (os.clock() - t0) < 5 do
        pcall(function()
            dragBtn.Position = target.Position
            task.wait(0.03)
            if firesignal then
                firesignal(det.DragStart) task.wait(0.02)
                firesignal(det.DragContinue) task.wait(0.02)
                firesignal(det.DragEnd)
            elseif IsMobile then
                -- proper swipe drag: Begin at dragBtn → interpolate Change → End at target
                local bap = dragBtn.AbsolutePosition
                local bas = dragBtn.AbsoluteSize
                local bx0 = math.floor(bap.X + bas.X * 0.5)
                local by0 = math.floor(bap.Y + bas.Y * 0.5)
                local tap, tas = target.AbsolutePosition, target.AbsoluteSize
                local tx = math.floor(tap.X + tas.X * 0.5)
                local ty = math.floor(tap.Y + tas.Y * 0.5)
                VirtualInputManager:SendTouchEvent(0, Vector2.new(bx0, by0), Enum.UserInputState.Begin, game)
                task.wait(0.04)
                for si = 1, 5 do
                    local t = si / 5
                    local ix = math.floor(bx0 + (tx - bx0) * t)
                    local iy = math.floor(by0 + (ty - by0) * t)
                    VirtualInputManager:SendTouchEvent(0, Vector2.new(ix, iy), Enum.UserInputState.Change, game)
                    task.wait(0.025)
                end
                VirtualInputManager:SendTouchEvent(0, Vector2.new(tx, ty), Enum.UserInputState.End, game)
            end
        end)
        task.wait(0.2)
    end
end

function FishingSystem.ProcessBarMinigame(holder)
    if not holder or not holder.Visible then return end
    local frame = holder:FindFirstChild("FishingFrame") if not frame then return end
    local info = frame:FindFirstChild("InfoLabel") if not info then return end
    local txt = info.Text
    if txt == "Click/tap to raise the bar!" then
        -- game listens globally to any screen tap — no specific button needed
        local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(800, 600)
        local tapX = math.floor(vp.X * 0.5)
        local tapY = math.floor(vp.Y * 0.75) -- lower half, below bar UI
        pcall(function() Utils.SendClick(tapX, tapY) end)
        if firesignal then
            -- fire on FishingFrame itself as fallback
            pcall(function() firesignal(frame.InputBegan, {UserInputType = Enum.UserInputType.Touch}) end)
        end
        task.wait(Settings.Fishing.ClickInterval)
    else
        task.wait(0.05)
    end
end

function FishingSystem.GetFishingZone()
    local main = workspace:FindFirstChild("Main")
    if main and main:FindFirstChild("FishingZone") then return main.FishingZone end
    local rs_main = ReplicatedStorage:FindFirstChild("Main")
    return rs_main and rs_main:FindFirstChild("FishingZone")
end

function FishingSystem.IsHotspotActive(part)
    if not part then return false end
    local att = part:FindFirstChildOfClass("Attachment")
    local emitter = att and att:FindFirstChild("GroundFlasg")
    if emitter and emitter.Enabled == true then return true end
    return part:GetAttribute("IsActive") == true
end

function FishingSystem.ResetSession()
    if Runtime.Fishing.ActiveCatchThread then
        pcall(task.cancel, Runtime.Fishing.ActiveCatchThread)
        Runtime.Fishing.ActiveCatchThread = nil
    end
    Runtime.Fishing.CastToken = nil
    Runtime.Fishing.LastUsedToken = nil
    Runtime.Fishing.BaitLanded = false
    Runtime.Fishing.IsBusy = false
    Runtime.Fishing.IsCasting = false
    if Runtime.Fishing.FacingLockConn then
        Runtime.Fishing.FacingLockConn:Disconnect()
        Runtime.Fishing.FacingLockConn = nil
    end
    local h = Utils.GetHumanoid() if h then h.AutoRotate = true end
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if pg then
        for _, g in ipairs(pg:GetChildren()) do
            if g.Name == "FishingUI" or g:FindFirstChild("FishingHolder") or g:FindFirstChild("PreFishingHolder") then
                pcall(function() g:Destroy() end)
            end
        end
    end
end

function FishingSystem.UnhookRodEvents()
    Runtime.Fishing.ActiveRod = nil
    Runtime.Fishing.CastToken = nil
    Runtime.Fishing.LastUsedToken = nil
    Runtime.Fishing.BaitLanded = false
    Runtime.Fishing.IsBusy = false
    Runtime.Fishing.IsCasting = false
    Utils.ClearConnections(Runtime.Fishing.Connections)
end

function FishingSystem.HookRodEvents(tool)
    if not tool then return end
    if Runtime.Fishing.ActiveRod == tool and tool:GetAttribute("_IVRodHooked") then return end
    FishingSystem.UnhookRodEvents()
    Runtime.Fishing.ActiveRod = tool
    tool:SetAttribute("_IVRodHooked", true)

    Utils.AddConnection(Runtime.Fishing.Connections, tool.Unequipped:Connect(function()
        if Runtime.Fishing.IsInternalReEquip then return end
        FishingSystem.ResetSession()
        Runtime.Fishing.CastToken = nil
    end))

    local toolReady    = tool:WaitForChild("ToolReady", 4)
    local baitLanded   = tool:WaitForChild("BaitLanded", 4)
    local canceled     = tool:WaitForChild("FishingCanceled", 4)
    local startMinigame= tool:FindFirstChild("StartMinigame")

    if toolReady and toolReady:IsA("RemoteEvent") then
        Utils.AddConnection(Runtime.Fishing.Connections, toolReady.OnClientEvent:Connect(function(token)
            Runtime.Fishing.CastToken = token
            Runtime.Fishing.IsCasting = false
        end))
    end

    if baitLanded and baitLanded:IsA("RemoteEvent") then
        Utils.AddConnection(Runtime.Fishing.Connections, baitLanded.OnClientEvent:Connect(function(_, ...)
            Runtime.Fishing.BaitLanded = true
            Runtime.Fishing.IsCasting = false
            Runtime.Fishing.LastBaitLandedTime = os.clock()
            if Settings.Fishing.CastMethod == "Blatant" or Settings.Fishing.CatchMethod == "Blatant" then
                task.spawn(function()
                    task.wait(0.06)
                    local char = Utils.GetCharacter()
                    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
                    local hum  = char and char:FindFirstChildOfClass("Humanoid")
                    if not hrp or not hum then return end
                    local savedLook = hrp.CFrame.LookVector
                    hum.AutoRotate = true
                    if Runtime.Fishing.FacingLockConn then
                        Runtime.Fishing.FacingLockConn:Disconnect()
                        Runtime.Fishing.FacingLockConn = nil
                    end
                    Runtime.Fishing.FacingLockConn = RunService.PreRender:Connect(function()
                        if not Runtime.Fishing.BaitLanded or not hrp or not hrp.Parent then
                            if Runtime.Fishing.FacingLockConn then
                                Runtime.Fishing.FacingLockConn:Disconnect()
                                Runtime.Fishing.FacingLockConn = nil
                            end
                            hum.AutoRotate = true
                            return
                        end
                        hrp.CFrame    = CFrame.lookAt(hrp.Position, hrp.Position + savedLook)
                        hum.AutoRotate = true
                    end)
                end)
            end
        end))
    end

    if canceled and canceled:IsA("RemoteEvent") then
        Utils.AddConnection(Runtime.Fishing.Connections, canceled.OnClientEvent:Connect(function()
            FishingSystem.ResetSession()
        end))
    end

    if startMinigame and startMinigame:IsA("RemoteEvent") then
        Utils.AddConnection(Runtime.Fishing.Connections, startMinigame.OnClientEvent:Connect(function(arg1, arg2, arg3, ...)
            if Settings.Fishing.CatchMethod ~= "Blatant" then return end
            local catchRemote = tool:FindFirstChild("Catch")
            if not catchRemote or not catchRemote:IsA("RemoteEvent") then return end
            if Runtime.Fishing.IsBusy then return end
            Runtime.Fishing.IsBusy = true
            if Runtime.Fishing.ActiveCatchThread then pcall(task.cancel, Runtime.Fishing.ActiveCatchThread) end
            local eventArgs = { arg1, arg2, arg3, ... }

            Runtime.Fishing.ActiveCatchThread = task.spawn(function()
                -- ─── Fish Rarity Filter Check (plan.txt item 6 & 7) ───────────
                if Settings.Fishing.FilterByRarity then
                    local targetRarity = nil
                    for _, a in ipairs(eventArgs) do
                        if type(a) == "table" then
                            targetRarity = a.Rarity or a.FishRarity or (a.Fish and a.Fish.Rarity)
                            if targetRarity then break end
                        elseif type(a) == "string" and RARITY_ORDER[a] then
                            targetRarity = a
                            break
                        end
                    end

                    local RARITIES = {
                        Common = 1, Uncommon = 2, Rare = 3, Epic = 4,
                        Legend = 5, Mythic = 6, Ancient = 7,
                    }
                    local minRank = RARITIES[Settings.Fishing.MinRarity] or 3

                    if targetRarity then
                        local fishRank = RARITIES[targetRarity] or 1
                        if fishRank < minRank then
                            -- Skip catch! Cancel by unequipping rod and re-casting
                            Runtime.Fishing.BaitLanded = false
                            FishingSystem.FastReEquipRod(tool)
                            Runtime.Fishing.IsBusy = false
                            Runtime.Fishing.ActiveCatchThread = nil
                            return
                        end
                    elseif not Settings.Fishing.AllowUnspecified then
                        -- Rarity not determined from remote args, user chose to skip unspecified
                        Runtime.Fishing.BaitLanded = false
                        FishingSystem.FastReEquipRod(tool)
                        Runtime.Fishing.IsBusy = false
                        Runtime.Fishing.ActiveCatchThread = nil
                        return
                    end
                end

                task.wait(math.max(Settings.Fishing.BlatantCatchDelay or 0.8, 0.6))
                if not Settings.Fishing.Enabled or Settings.Fishing.CatchMethod ~= "Blatant" then
                    Runtime.Fishing.IsBusy = false
                    return
                end
                local char = Utils.GetCharacter()
                if not char or tool.Parent ~= char then FishingSystem.ResetSession() return end
                Runtime.Fishing.BaitLanded = false
                pcall(function() catchRemote:FireServer(true) end)
                local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
                if pg then
                    for _, g in ipairs(pg:GetChildren()) do
                        if g.Name == "FishingUI" or g:FindFirstChild("FishingHolder") or g:FindFirstChild("PreFishingHolder") then
                            pcall(function() g:Destroy() end)
                        end
                    end
                end
                task.wait(0.5)
                if Settings.Fishing.Enabled and Settings.Fishing.CatchMethod == "Blatant" then
                    local after = Utils.GetCharacter()
                    if after and tool.Parent == after then
                        FishingSystem.FastReEquipRod(tool)
                        local dl = os.clock() + 2.5
                        while os.clock() < dl do
                            local ct = Runtime.Fishing.CastToken or FishingSystem.ExtractToken(tool)
                            if ct and ct ~= Runtime.Fishing.LastUsedToken then
                                Runtime.Fishing.CastToken = ct
                                break
                            end
                            task.wait(0.05)
                        end
                    end
                end
                Runtime.Fishing.IsBusy = false
                Runtime.Fishing.ActiveCatchThread = nil
            end)
        end))
    end
end

function FishingSystem.ExtractToken(tool)
    if not tool then return nil end
    local toolReady = tool:FindFirstChild("ToolReady")
    if not toolReady then return nil end
    if getconnections and getupvalues then
        local conns = getconnections(toolReady.OnClientEvent)
        for _, c in ipairs(conns) do
            if c.Function then
                local ups = getupvalues(c.Function)
                for _, val in pairs(ups) do
                    if type(val) == "number" and val > 1000000000 then
                        if val ~= Runtime.Fishing.LastUsedToken then return val end
                    end
                end
            end
        end
    end
    return nil
end

function FishingSystem.EnsureCastToken()
    if Runtime.Fishing.CastToken and Runtime.Fishing.CastToken ~= Runtime.Fishing.LastUsedToken then
        return Runtime.Fishing.CastToken
    end
    local rod = FishingSystem.EnsureRodEquipped()
    if not rod then return nil end
    FishingSystem.HookRodEvents(rod)
    local token = FishingSystem.ExtractToken(rod)
    if token and token ~= Runtime.Fishing.LastUsedToken then
        Runtime.Fishing.CastToken = token
        return token
    end
    local dl = os.clock() + 1.0
    while (not Runtime.Fishing.CastToken or Runtime.Fishing.CastToken == Runtime.Fishing.LastUsedToken)
        and os.clock() < dl do
        task.wait(0.05)
    end
    if Runtime.Fishing.CastToken ~= Runtime.Fishing.LastUsedToken then
        return Runtime.Fishing.CastToken
    end
    return nil
end

function FishingSystem.FastReEquipRod(tool)
    local hum = Utils.GetHumanoid()
    local target = tool or Runtime.Fishing.ActiveRod or FishingSystem.GetEquippedRod()
    if not hum or not target then return end
    Runtime.Fishing.IsInternalReEquip = true
    Runtime.Fishing.CastToken = nil
    if Runtime.Fishing.FacingLockConn then
        Runtime.Fishing.FacingLockConn:Disconnect()
        Runtime.Fishing.FacingLockConn = nil
    end
    local h = Utils.GetHumanoid() if h then h.AutoRotate = true end
    hum:UnequipTools() task.wait(0.15) hum:EquipTool(target)
    FishingSystem.HookRodEvents(target) task.wait(0.05)
    Runtime.Fishing.IsInternalReEquip = false
end

function FishingSystem.RunBlatantCycle()
    if Runtime.Fishing.IsBusy or Runtime.Fishing.IsCasting then task.wait(0.1) return end
    local sus, waitSecs = FishingSystem.CheckSuspension()
    if sus then task.wait(math.clamp(waitSecs, 1, 5)) return end
    local rod = FishingSystem.EnsureRodEquipped()
    if not rod then task.wait(0.5) return end
    FishingSystem.HookRodEvents(rod)
    local castRemote = rod:FindFirstChild("Cast")

    local fishingGui = FishingSystem.GetFishingGui()
    if fishingGui then
        local pre = fishingGui:FindFirstChild("PreFishingHolder")
        local hol = fishingGui:FindFirstChild("FishingHolder")
        if (pre and pre.Visible) or (hol and hol.Visible) then task.wait(0.1) return end
    end

    local bobber = FishingSystem.FindActiveBobber()
    if Runtime.Fishing.BaitLanded or bobber then
        if Runtime.Fishing.LastBaitLandedTime
            and (os.clock() - Runtime.Fishing.LastBaitLandedTime) > Settings.Fishing.BaitTimeout then
            Runtime.Fishing.BaitLanded = false
            Runtime.Fishing.CastToken = nil
        end
        task.wait(0.2) return
    end

    local castDelay = Settings.Fishing.CastDelay or 0.5
    if (os.clock() - Runtime.Fishing.LastCastTime) < castDelay then task.wait(0.1) return end

    local token = FishingSystem.EnsureCastToken()
    if not token or token == Runtime.Fishing.LastUsedToken then task.wait(0.3) return end

    if castRemote and castRemote:IsA("RemoteFunction") then
        Runtime.Fishing.IsCasting = true
        Runtime.Fishing.IsBusy = true
        Runtime.Fishing.LastUsedToken = token
        Runtime.Fishing.CastToken = nil
        Runtime.Fishing.LastCastTime = os.clock()
        local power = Settings.Fishing.CastHoldDuration or 1.0
        pcall(function() return castRemote:InvokeServer(power, token) end)
        local dl = os.clock() + 3.5
        while Runtime.Fishing.IsCasting and os.clock() < dl do
            if Runtime.Fishing.BaitLanded or not Settings.Fishing.Enabled then break end
            task.wait(0.05)
        end
        Runtime.Fishing.IsCasting = false
        Runtime.Fishing.IsBusy = false
    else
        task.wait(0.3)
    end
end

function FishingSystem.RunLegitCycle()
    if Runtime.Fishing.IsBusy then task.wait(0.1) return end
    local sus, waitSecs = FishingSystem.CheckSuspension()
    if sus then task.wait(math.clamp(waitSecs, 1, 5)) return end
    local char = Utils.GetCharacter()
    local hum  = Utils.GetHumanoid()
    if not char or not hum or hum.Health <= 0 then task.wait(0.5) return end
    local rod = FishingSystem.EnsureRodEquipped()
    if not rod then task.wait(0.5) return end
    FishingSystem.HookRodEvents(rod)

    local gui = FishingSystem.GetFishingGui()
    local bobber = FishingSystem.FindActiveBobber()

    if gui then
        local pre = gui:FindFirstChild("PreFishingHolder")
        local hol = gui:FindFirstChild("FishingHolder")
        if pre and pre.Visible then
            if Settings.Fishing.CatchMethod == "Legit" then
                FishingSystem.SolvePreFishingDrag(pre)
            else task.wait(0.1) end
        elseif hol and hol.Visible then
            if Settings.Fishing.CatchMethod ~= "Blatant" then
                FishingSystem.ProcessBarMinigame(hol)
            else task.wait(0.1) end
        else task.wait(0.05) end
        return
    end

    if Runtime.Fishing.BaitLanded or bobber then
        if Runtime.Fishing.LastBaitLandedTime
            and (os.clock() - Runtime.Fishing.LastBaitLandedTime) > Settings.Fishing.BaitTimeout then
            Runtime.Fishing.BaitLanded = false
        end
        task.wait(0.3) return
    end

    local castDelay = Settings.Fishing.CastDelay or 0.5
    if (os.clock() - Runtime.Fishing.LastCastTime) < castDelay then task.wait(0.2) return end

    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(800, 600)
    local cx, cy = math.floor(vp.X * 0.5), math.floor(vp.Y * 0.5)

    if IsMobile then
        VirtualInputManager:SendTouchEvent(0, Vector2.new(cx, cy), Enum.UserInputState.Begin, game)
        task.wait(0.05)
        pcall(function() rod:Activate() end)  -- mobile tool activation
        task.wait(Settings.Fishing.CastHoldDuration)
        VirtualInputManager:SendTouchEvent(0, Vector2.new(cx, cy), Enum.UserInputState.End, game)
    else
        VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
        task.wait(0.05)
        rod:Activate()
        task.wait(0.05)
        VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, true, game, 1)
        task.wait(Settings.Fishing.CastHoldDuration)
        VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
    end
    Runtime.Fishing.LastCastTime = os.clock()
    task.wait(1.0)
end

function FishingSystem.Start()
    if Runtime.Fishing.Thread then return end
    Runtime.Fishing.Thread = task.spawn(function()
        while Settings.Fishing.Enabled do
            if Settings.Fishing.CastMethod == "Blatant" then
                FishingSystem.RunBlatantCycle()
            else
                FishingSystem.RunLegitCycle()
            end
            task.wait(0.01)
        end
        Runtime.Fishing.Thread = nil
    end)
end

function FishingSystem.Stop()
    Settings.Fishing.Enabled = false
    FishingSystem.ResetSession()
    FishingSystem.UnhookRodEvents()
    if Runtime.Fishing.Thread then
        task.cancel(Runtime.Fishing.Thread)
        Runtime.Fishing.Thread = nil
    end
end

-- ══════════════════════════════════════════════════════════════════
-- MINING SYSTEM
-- ══════════════════════════════════════════════════════════════════
local MiningSystem = {}

function MiningSystem.GetMiningContainer()
    do
        local _genv = getgenv and getgenv()
        local _idvMap = _genv and _genv.IDV_Map
        if _idvMap and _idvMap.GetMiningContainer then
            local c = _idvMap.GetMiningContainer()
            if c then return c end
        end
    end
    local main = workspace:FindFirstChild("Main")
    if main and main:FindFirstChild("ActiveMiningStones") then return main.ActiveMiningStones end
    local rs_main = ReplicatedStorage:FindFirstChild("Main")
    if rs_main and rs_main:FindFirstChild("ActiveMiningStones") then return rs_main.ActiveMiningStones end
    return nil
end

function MiningSystem.GetOrePosition(o)
    if o:IsA("Model") then return o:GetBoundingBox().Position end
    if o:IsA("BasePart") then return o.Position end
    return nil
end

function MiningSystem.IsHotspot(s)
    if not s then return false end
    local a = s:GetAttribute("IsHotspot")
    if a ~= nil then return a == true end
    local n = s.Name:lower()
    return n:find("hotspot") ~= nil or n:find("hot") ~= nil
end

function MiningSystem.IsAllowed(s)
    if not s then return false end
    return s:IsA("BasePart") or s:IsA("Model")
end

function MiningSystem.FindNearestOre(radius)
    local hrp = Utils.GetHumanoidRootPart()
    local cont = MiningSystem.GetMiningContainer()
    if not hrp or not cont then return nil, nil end
    local bestD, bestS = radius, nil
    for _, s in ipairs(cont:GetChildren()) do
        if MiningSystem.IsAllowed(s) then
            local pos = MiningSystem.GetOrePosition(s)
            if pos then
                local d = (hrp.Position - pos).Magnitude
                if d < bestD then bestD, bestS = d, s end
            end
        end
    end
    return bestS, bestD
end

function MiningSystem.GetNextTargetStone()
    local hrp = Utils.GetHumanoidRootPart()
    local cont = MiningSystem.GetMiningContainer()
    if not hrp or not cont then return nil, nil end
    local filter = Settings.Mining.TargetFilter or "Hotspot Only"
    local bestD, bestS = math.huge, nil
    for _, s in ipairs(cont:GetChildren()) do
        if MiningSystem.IsAllowed(s) and s.Parent then
            local isHot = MiningSystem.IsHotspot(s)
            local allowed = true
            if filter == "Hotspot Only" and not isHot then allowed = false end
            local slot = s:GetAttribute("AvailableSlot")
            if slot ~= nil and slot <= 0 then allowed = false end
            if allowed then
                local pos = MiningSystem.GetOrePosition(s)
                if pos then
                    local d = (hrp.Position - pos).Magnitude
                    if d < bestD then bestD, bestS = d, s end
                end
            end
        end
    end
    return bestS, bestD
end

function MiningSystem.EnableUndergroundFloat(targetCF)
    local hrp = Utils.GetHumanoidRootPart()
    local char = Utils.GetCharacter()
    local hum = Utils.GetHumanoid()
    if not hrp or not char then return end
    Runtime.Mining.IsFloating = true
    Runtime.Mining.TargetFloatCF = targetCF
    if hum then
        pcall(function()
            hum:ChangeState(Enum.HumanoidStateType.Physics)
            hum.AutoRotate = false
        end)
    end
    for _, p in ipairs(char:GetDescendants()) do
        if p:IsA("BasePart") then
            p.CanCollide = false
            p.AssemblyLinearVelocity = Vector3.zero
            p.AssemblyAngularVelocity = Vector3.zero
        end
    end
    hrp.CFrame = targetCF
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero

    if not Runtime.Mining.FloatMover or not Runtime.Mining.FloatMover.Parent then
        local bv = Instance.new("BodyVelocity")
        bv.Name = "Delirium_UndergroundMover"
        bv.Velocity = Vector3.zero
        bv.MaxForce = Vector3.new(1e7, 1e7, 1e7)
        bv.P = 1e5
        bv.Parent = hrp
        Runtime.Mining.FloatMover = bv
    else
        Runtime.Mining.FloatMover.Velocity = Vector3.zero
    end

    if not Runtime.Mining.FloatGyro or not Runtime.Mining.FloatGyro.Parent then
        local bg = Instance.new("BodyGyro")
        bg.Name = "Delirium_UndergroundGyro"
        bg.CFrame = targetCF
        bg.MaxTorque = Vector3.new(1e7, 1e7, 1e7)
        bg.P = 1e5 bg.D = 500
        bg.Parent = hrp
        Runtime.Mining.FloatGyro = bg
    else
        Runtime.Mining.FloatGyro.CFrame = targetCF
    end

    if not Runtime.Mining.FloatConn then
        Runtime.Mining.FloatConn = RunService.Stepped:Connect(function()
            if not Runtime.Mining.IsFloating then return end
            local c = Utils.GetCharacter()
            local root = Utils.GetHumanoidRootPart()
            local tCF = Runtime.Mining.TargetFloatCF
            if c and root then
                for _, part in ipairs(c:GetDescendants()) do
                    if part:IsA("BasePart") then
                        if part.CanCollide then part.CanCollide = false end
                    end
                end
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
                if tCF then root.CFrame = tCF end
            end
        end)
    end
end

function MiningSystem.DisableUndergroundFloat()
    local wasFloating = Runtime.Mining.IsFloating
    Runtime.Mining.IsFloating = false
    Runtime.Mining.TargetFloatCF = nil
    if Runtime.Mining.FloatConn then
        pcall(function() Runtime.Mining.FloatConn:Disconnect() end)
        Runtime.Mining.FloatConn = nil
    end
    if Runtime.Mining.FloatMover then
        pcall(function() Runtime.Mining.FloatMover:Destroy() end)
        Runtime.Mining.FloatMover = nil
    end
    if Runtime.Mining.FloatGyro then
        pcall(function() Runtime.Mining.FloatGyro:Destroy() end)
        Runtime.Mining.FloatGyro = nil
    end
    local hum = Utils.GetHumanoid()
    if hum then
        pcall(function()
            hum.AutoRotate = true
            hum:ChangeState(Enum.HumanoidStateType.GettingUp)
        end)
    end
    local hrp = Utils.GetHumanoidRootPart()
    if hrp then
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        if wasFloating then
            local stone = Runtime.Mining.CurrentTargetStone
            local stonePos = stone and stone.Parent and MiningSystem.GetOrePosition(stone)
            if stonePos then
                hrp.CFrame = CFrame.new(stonePos + Vector3.new(0, 4.0, 0))
            else
                local depth = Settings.Mining.UndergroundDepth or 15.0
                hrp.CFrame = CFrame.new(hrp.Position + Vector3.new(0, depth + 5.0, 0))
            end
            hrp.AssemblyLinearVelocity = Vector3.zero
        end
    end
    pcall(function()
        local isNoclip = (typeof(MiscSettings) == "table" and MiscSettings.Noclip == true)
        if not isNoclip then
            local c = Utils.GetCharacter()
            if c then
                for _, part in ipairs(c:GetDescendants()) do
                    if part:IsA("BasePart") then part.CanCollide = true end
                end
            end
        end
    end)
end

function MiningSystem.FindPickaxe()
    local char = Utils.GetCharacter()
    local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
    local function check(parent)
        if not parent then return nil end
        for _, item in ipairs(parent:GetChildren()) do
            if item:IsA("Tool") and (item:FindFirstChild("Mine") or item:GetAttribute("IsPickaxe")) then
                return item
            end
        end
        return nil
    end
    return check(char) or check(bp)
end

function MiningSystem.EnsurePickaxeEquipped()
    local px = MiningSystem.FindPickaxe() if not px then return nil end
    if Runtime.Mining.HookedPickaxe ~= px then
        Runtime.Mining.SessionToken = nil
        MiningSystem.HookPickaxeEvents(px)
        Runtime.Mining.HookedPickaxe = px
    end
    local char = Utils.GetCharacter()
    if Settings.Mining.AutoEquipPickaxe and char and px.Parent ~= char then
        local hum = Utils.GetHumanoid()
        if hum then
            hum:EquipTool(px)
            local dl = os.clock() + 2.0
            while not Runtime.Mining.SessionToken and os.clock() < dl do task.wait(0.05) end
        end
    end
    return px
end

function MiningSystem.PlayFakeHit(stone, pickaxe)
    local hum = Utils.GetHumanoid()
    local animator = hum and hum:FindFirstChildWhichIsA("Animator")
    local tool = pickaxe or MiningSystem.FindPickaxe()
    local count = math.max(1, Settings.Mining.FakeHitRepeatCount or 1)
    local target = stone or Runtime.Mining.CurrentTargetStone
    local swings = {}
    if animator and tool then
        local af = tool:FindFirstChild("Animation")
        if af then
            for _, name in ipairs({"Swing1", "Swing2", "Swing3"}) do
                local a = af:FindFirstChild(name)
                if a and a:IsA("Animation") then table.insert(swings, a) end
            end
        end
    end
    local sounds = {}
    if tool then
        local ui = tool:FindFirstChild("MiningUI")
        if ui then
            for _, name in ipairs({"Mining1", "Mining2", "Mining3"}) do
                local s = ui:FindFirstChild(name)
                if s and s:IsA("Sound") then table.insert(sounds, s) end
            end
        end
    end
    for i = 1, count do
        if #swings > 0 then
            pcall(function()
                local t = animator:LoadAnimation(swings[math.random(1, #swings)])
                t.Priority = Enum.AnimationPriority.Action
                t:Play(0.05)
            end)
        end
        if #sounds > 0 then
            pcall(function() sounds[math.random(1, #sounds)]:Play() end)
        end
        if target then
            pcall(function()
                local pos = MiningSystem.GetOrePosition(target)
                if pos then
                    local pm = ReplicatedStorage:FindFirstChild("Lib")
                    pm = pm and pm:FindFirstChild("Particle")
                    if pm then
                        local P = require(pm)
                        if P and P.PlayClientEmitter then P.PlayClientEmitter("MiningEffect", pos) end
                    end
                end
            end)
        end
        if i < count then task.wait(0.25 + math.random() * 0.30) end
    end
end

function MiningSystem.PlayFakeHitTimed(stone, pickaxe, duration)
    local hum = Utils.GetHumanoid()
    local animator = hum and hum:FindFirstChildWhichIsA("Animator")
    local tool = pickaxe or MiningSystem.FindPickaxe()
    local target = stone or Runtime.Mining.CurrentTargetStone
    local dl = os.clock() + duration
    local swings, sounds = {}, {}
    if animator and tool then
        local af = tool:FindFirstChild("Animation")
        if af then
            for _, name in ipairs({"Swing1", "Swing2", "Swing3"}) do
                local a = af:FindFirstChild(name)
                if a and a:IsA("Animation") then table.insert(swings, a) end
            end
        end
    end
    if tool then
        local ui = tool:FindFirstChild("MiningUI")
        if ui then
            for _, name in ipairs({"Mining1", "Mining2", "Mining3"}) do
                local s = ui:FindFirstChild(name)
                if s and s:IsA("Sound") then table.insert(sounds, s) end
            end
        end
    end
    while os.clock() < dl do
        if #swings > 0 then
            pcall(function()
                local t = animator:LoadAnimation(swings[math.random(1, #swings)])
                t.Priority = Enum.AnimationPriority.Action
                t:Play(0.05)
            end)
        end
        if #sounds > 0 then
            pcall(function() sounds[math.random(1, #sounds)]:Play() end)
        end
        if target then
            pcall(function()
                local pos = MiningSystem.GetOrePosition(target)
                if pos then
                    local pm = ReplicatedStorage:FindFirstChild("Lib")
                    pm = pm and pm:FindFirstChild("Particle")
                    if pm then
                        local P = require(pm)
                        if P and P.PlayClientEmitter then P.PlayClientEmitter("MiningEffect", pos) end
                    end
                end
            end)
        end
        local rem = dl - os.clock()
        local jeda = 0.30 + math.random() * 0.35
        if rem <= jeda + 0.05 then break end
        task.wait(jeda)
    end
end

function MiningSystem.ResetSession()
    if Runtime.Mining.ActiveHitThread then
        pcall(task.cancel, Runtime.Mining.ActiveHitThread)
        Runtime.Mining.ActiveHitThread = nil
    end
    Runtime.Mining.SessionToken = nil
    Runtime.Mining.IsBusy = false
    Runtime.Mining.CurrentTargetStone = nil
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if pg then
        for _, g in ipairs(pg:GetChildren()) do
            if g:FindFirstChild("PreMiningHolder") or g.Name == "MiningUI" then
                pcall(function() g:Destroy() end)
            end
        end
    end
end

function MiningSystem.FastReEquipPickaxe(px)
    local hum = Utils.GetHumanoid() if not hum then return end
    local target = px or MiningSystem.FindPickaxe() if not target then return end
    Runtime.Mining.IsInternalReEquip = true
    Runtime.Mining.SessionToken = nil
    hum:UnequipTools() task.wait(0.15) hum:EquipTool(target)
    MiningSystem.HookPickaxeEvents(target) task.wait(0.05)
    Runtime.Mining.IsInternalReEquip = false
end

function MiningSystem.UnhookPickaxeEvents()
    Utils.ClearConnections(Runtime.Mining.Connections)
    Runtime.Mining.HookedPickaxe = nil
end

function MiningSystem.HookPickaxeEvents(px)
    if not px then return end
    MiningSystem.UnhookPickaxeEvents()
    Runtime.Mining.HookedPickaxe = px
    Utils.AddConnection(Runtime.Mining.Connections, px.Unequipped:Connect(function()
        if not Runtime.Mining.IsInternalReEquip then MiningSystem.ResetSession() end
    end))
    local cancelRemote = px:FindFirstChild("MiningCancel")
    if cancelRemote then
        Utils.AddConnection(Runtime.Mining.Connections, cancelRemote.OnClientEvent:Connect(function()
            MiningSystem.ResetSession()
        end))
    end
    local toolReady = px:FindFirstChild("ToolReady")
    if toolReady then
        Utils.AddConnection(Runtime.Mining.Connections, toolReady.OnClientEvent:Connect(function(token)
            Runtime.Mining.SessionToken = token
        end))
    end
    local mineResult = px:FindFirstChild("MineResult")
    if mineResult then
        Utils.AddConnection(Runtime.Mining.Connections, mineResult.OnClientEvent:Connect(function(result)
            local success = (type(result) == "table" and result.CanMine == true)
            if success then
                Settings.Mining.TotalMined = Settings.Mining.TotalMined + 1
            else
                Settings.Mining.TotalFailed = Settings.Mining.TotalFailed + 1
            end
            if MiningSystem.OnStatsUpdated then
                MiningSystem.OnStatsUpdated(Settings.Mining.TotalMined, Settings.Mining.TotalFailed)
            end
        end))
    end
    local startMini = px:FindFirstChild("StartMinigame")
    if startMini then
        Utils.AddConnection(Runtime.Mining.Connections, startMini.OnClientEvent:Connect(function(_, arg3)
            if Settings.Mining.MineMethod ~= "Blatant" or not Settings.Mining.Enabled then return end
            local char = Utils.GetCharacter()
            if not char or px.Parent ~= char then MiningSystem.ResetSession() return end
            local mr = px:FindFirstChild("MineResult")
            if not mr then Runtime.Mining.IsBusy = false return end
            if Runtime.Mining.ActiveHitThread then
                pcall(task.cancel, Runtime.Mining.ActiveHitThread)
                Runtime.Mining.ActiveHitThread = nil
            end
            local boulder = (type(arg3) == "table" and arg3.boulder) or Runtime.Mining.CurrentTargetStone
            Runtime.Mining.ActiveHitThread = task.spawn(function()
                if Settings.Mining.FakeHitAnimation then
                    MiningSystem.PlayFakeHitTimed(boulder, px, Settings.Mining.BlatantHitDelay - 0.20)
                else
                    task.wait(Settings.Mining.BlatantHitDelay)
                end
                local cur = Utils.GetCharacter()
                if not Settings.Mining.Enabled
                    or Settings.Mining.MineMethod ~= "Blatant"
                    or not cur or px.Parent ~= cur then
                    MiningSystem.ResetSession() return
                end
                if Settings.Mining.FakeHitAnimation then
                    MiningSystem.PlayFakeHit(boulder, px)
                end
                pcall(function() mr:FireServer(true) end)
                local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
                if pg then
                    for _, g in ipairs(pg:GetChildren()) do
                        if g:FindFirstChild("PreMiningHolder") or g.Name == "MiningUI" then
                            pcall(function() g:Destroy() end)
                        end
                    end
                end
                task.wait(0.25)
                local after = Utils.GetCharacter()
                if not Settings.Mining.Enabled or not after or px.Parent ~= after then
                    MiningSystem.ResetSession() return
                end
                MiningSystem.FastReEquipPickaxe(px)
                local dl = os.clock() + 2.5
                while not Runtime.Mining.SessionToken and os.clock() < dl do task.wait(0.05) end
                task.wait(0.08)
                Runtime.Mining.ActiveHitThread = nil
                Runtime.Mining.IsBusy = false
            end)
        end))
    end
end

function MiningSystem.HookMiningGui(gui)
    local pre = gui:FindFirstChild("PreMiningHolder")
    local mineH = gui:FindFirstChild("MiningHolder")
    if not (pre and mineH) then return end
    local dragBtn = pre:FindFirstChild("DragButton")
    local targetF = pre:FindFirstChild("TargetFrame")
    local dragDet = dragBtn and dragBtn:FindFirstChild("UIDragDetector")
    local mineF = mineH:FindFirstChild("MiningFrame")
    local barC = mineF and mineF:FindFirstChild("BarContainer")
    local bar  = barC and barC:FindFirstChild("Bar")
    local point= barC and barC:FindFirstChild("Point")
    if not (dragBtn and targetF and dragDet and bar and point) then return end

    local hitDebounce = false
    local function executeHit()
        if hitDebounce then return end
        hitDebounce = true
        task.delay(Settings.Mining.HitGap or 0.12, function() hitDebounce = false end)
        local hitDone = false
        if keypress and keyrelease then
            pcall(function()
                keypress(0x20) task.wait(0.02) keyrelease(0x20)
                hitDone = true
            end)
        end
        if not hitDone then
            pcall(function()
                -- on mobile hit the bar's actual center, not hardcoded (10,10)
                if IsMobile and bar and bar.Parent then
                    local bap3 = bar.AbsolutePosition
                    local bas3 = bar.AbsoluteSize
                    local hitX = math.floor(bap3.X + bas3.X * 0.5)
                    local hitY = math.floor(bap3.Y + bas3.Y * 0.5)
                    Utils.SendClick(hitX, hitY)
                else
                    Utils.SendClick(10, 10)
                end
            end)
        end
    end

    local px = MiningSystem.FindPickaxe()
    if px and Runtime.Mining.SessionToken then
        local op = px:FindFirstChild("MinigameOpened")
        if op then task.spawn(function() pcall(function() op:FireServer(Runtime.Mining.SessionToken) end) end) end
    end

    local stepConn, roundConn
    stepConn = RunService.Heartbeat:Connect(function()
        if not Settings.Mining.Enabled or not gui.Parent then
            stepConn:Disconnect()
            if roundConn then roundConn:Disconnect() end
            Runtime.Mining.IsBusy = false
            return
        end
        if Settings.Mining.MineMethod ~= "Legit" then return end
        if pre.Visible and dragDet.Enabled then
            task.spawn(function()
                dragBtn.Position = UDim2.new(
                    targetF.Position.X.Scale, targetF.Position.X.Offset,
                    targetF.Position.Y.Scale, targetF.Position.Y.Offset)
                RunService.Heartbeat:Wait()
                if firesignal then
                    pcall(firesignal, dragDet.DragStart) task.wait(0.02)
                    pcall(firesignal, dragDet.DragContinue)
                elseif IsMobile then
                    -- proper swipe: Begin at dragBtn center → interpolate → End at targetF center
                    local bap2 = dragBtn.AbsolutePosition
                    local bas2 = dragBtn.AbsoluteSize
                    local bx0m = math.floor(bap2.X + bas2.X * 0.5)
                    local by0m = math.floor(bap2.Y + bas2.Y * 0.5)
                    local tap2, tas2 = targetF.AbsolutePosition, targetF.AbsoluteSize
                    local txm = math.floor(tap2.X + tas2.X * 0.5)
                    local tym = math.floor(tap2.Y + tas2.Y * 0.5)
                    pcall(function()
                        VirtualInputManager:SendTouchEvent(0, Vector2.new(bx0m, by0m), Enum.UserInputState.Begin, game)
                        task.wait(0.04)
                        for si2 = 1, 5 do
                            local t2 = si2 / 5
                            local ix2 = math.floor(bx0m + (txm - bx0m) * t2)
                            local iy2 = math.floor(by0m + (tym - by0m) * t2)
                            VirtualInputManager:SendTouchEvent(0, Vector2.new(ix2, iy2), Enum.UserInputState.Change, game)
                            task.wait(0.025)
                        end
                        VirtualInputManager:SendTouchEvent(0, Vector2.new(txm, tym), Enum.UserInputState.End, game)
                    end)
                end
                repeat task.wait()
                until not gui.Parent or mineH.Visible or not pre.Visible
            end)
        elseif mineH.Visible then
            local mp = point.Position.X.Scale
            local cp = bar.Position.X.Scale
            local hw = bar.Size.X.Scale / 2
            local pct = Settings.Mining.SafeZonePercent or 0.5
            if pct > 1 then pct = pct / 100 end
            pct = math.clamp(pct, 0.1, 1.0)
            local r = hw * pct
            if mp >= (cp - r) and mp <= (cp + r) then executeHit() end
        end
    end)

    roundConn = gui:GetAttributeChangedSignal("CurrentRound"):Connect(function()
        if Settings.Mining.MineMethod ~= "Legit" then return end
        local cur = MiningSystem.FindPickaxe()
        if cur and Runtime.Mining.SessionToken then
            local ref = cur:FindFirstChild("RefreshMultipliers")
            if ref then pcall(function() ref:FireServer(Runtime.Mining.SessionToken) end) end
        end
    end)

    gui.Destroying:Connect(function()
        stepConn:Disconnect()
        if roundConn then roundConn:Disconnect() end
        task.wait(0.2)
        Runtime.Mining.IsBusy = false
    end)
end

function MiningSystem.MineOre(stone)
    local px = MiningSystem.EnsurePickaxeEquipped()
    if not px then Runtime.Mining.IsBusy = false return end
    local mr = px:FindFirstChild("Mine")
    if not mr then Runtime.Mining.IsBusy = false return end
    local hrp = Utils.GetHumanoidRootPart()
    local orePos = MiningSystem.GetOrePosition(stone)
    if hrp and orePos and not Runtime.Mining.IsFloating then
        local look = Vector3.new(orePos.X, hrp.Position.Y, orePos.Z)
        if (look - hrp.Position).Magnitude > 0.05 then
            hrp.CFrame = CFrame.lookAt(hrp.Position, look)
        end
    end
    if not Runtime.Mining.SessionToken then
        MiningSystem.FastReEquipPickaxe(px)
        local to = os.clock() + 2.0
        while not Runtime.Mining.SessionToken and os.clock() < to do task.wait(0.05) end
        if not Runtime.Mining.SessionToken then Runtime.Mining.IsBusy = false return end
    end
    local token = Runtime.Mining.SessionToken
    Runtime.Mining.SessionToken = nil
    task.spawn(function()
        local ok, success = pcall(function() return mr:InvokeServer(token) end)
        if not ok or success == false then
            task.delay(0.2, function()
                MiningSystem.FastReEquipPickaxe(px)
                Runtime.Mining.IsBusy = false
            end)
        end
    end)
    task.delay(Settings.Mining.WatchdogTimeout, function()
        if not Runtime.Mining.IsBusy then return end
        local hasGui = false
        local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if pg then
            for _, g in ipairs(pg:GetChildren()) do
                if g:FindFirstChild("PreMiningHolder") or g.Name == "MiningUI" then
                    hasGui = true break
                end
            end
        end
        if not hasGui then Runtime.Mining.IsBusy = false end
    end)
end

function MiningSystem.WalkToOre(stone)
    local PARAMS = { AgentRadius = 2, AgentHeight = 6, AgentCanJump = true, AgentCanClimb = true }
    local WP_REACH = 3
    local WP_TIMEOUT = 4.0
    local MAX_REPATH = 4
    local reachDist = Settings.Mining.AutoWalkReachDist or 12
    local function shouldAbort()
        return not Settings.Mining.Enabled or not Settings.Mining.AutoWalk or not stone.Parent
    end
    local hrp = Utils.GetHumanoidRootPart()
    local hum = Utils.GetHumanoid()
    if not hrp or not hum then return false end
    local orePos = MiningSystem.GetOrePosition(stone) if not orePos then return false end
    if (hrp.Position - orePos).Magnitude <= reachDist then return true end
    for _ = 1, MAX_REPATH do
        if shouldAbort() then return false end
        orePos = MiningSystem.GetOrePosition(stone) if not orePos then return false end
        hrp = Utils.GetHumanoidRootPart() hum = Utils.GetHumanoid()
        if not hrp or not hum then return false end
        local path = PathfindingService:CreatePath(PARAMS)
        local ok = pcall(function() path:ComputeAsync(hrp.Position, orePos) end)
        if not ok or path.Status ~= Enum.PathStatus.Success then task.wait(0.3) continue end
        local wps = path:GetWaypoints()
        if #wps == 0 then return false end
        for _, wp in ipairs(wps) do
            if shouldAbort() then return false end
            hrp = Utils.GetHumanoidRootPart() hum = Utils.GetHumanoid()
            if not hrp or not hum then return false end
            if (hrp.Position - orePos).Magnitude <= reachDist then return true end
            if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
            hum:MoveTo(wp.Position)
            local t0 = os.clock()
            repeat
                task.wait(0.05)
                hrp = Utils.GetHumanoidRootPart()
                if not hrp then return false end
            until shouldAbort()
                or (hrp.Position - wp.Position).Magnitude <= WP_REACH
                or (os.clock() - t0) >= WP_TIMEOUT
            if shouldAbort() then return false end
        end
        hrp = Utils.GetHumanoidRootPart()
        if hrp and (hrp.Position - orePos).Magnitude <= reachDist then return true end
        task.wait(0.1)
    end
    hrp = Utils.GetHumanoidRootPart()
    return hrp ~= nil and (hrp.Position - orePos).Magnitude <= reachDist
end

function MiningSystem.Start()
    if Runtime.Mining.Thread then return end
    Runtime.Mining.Thread = task.spawn(function()
        while Settings.Mining.Enabled do
            task.wait(Settings.Mining.LoopDelay)
            if not Settings.Mining.Enabled then break end
            if Runtime.Mining.IsBusy then continue end
            local px = MiningSystem.EnsurePickaxeEquipped()
            if not px then continue end
            if Settings.Mining.FullyAuto then
                local cur = Runtime.Mining.CurrentTargetStone
                local valid = cur and cur.Parent and MiningSystem.IsAllowed(cur)
                    and (cur:GetAttribute("AvailableSlot") == nil or cur:GetAttribute("AvailableSlot") > 0)
                if not valid then
                    local next = MiningSystem.GetNextTargetStone()
                    if next then Runtime.Mining.CurrentTargetStone = next cur = next
                    else task.wait(0.5) continue end
                end
                if cur and cur.Parent then
                    local orePos = MiningSystem.GetOrePosition(cur)
                    if orePos then
                        local depth = math.clamp(Settings.Mining.UndergroundDepth or 15.0, 3, 40)
                        local under = orePos - Vector3.new(0, depth, 0)
                        local targetCF = CFrame.lookAt(under, orePos)
                        MiningSystem.EnableUndergroundFloat(targetCF)
                        Runtime.Mining.IsBusy = true
                        MiningSystem.MineOre(cur)
                    end
                end
            else
                if Runtime.Mining.IsFloating then MiningSystem.DisableUndergroundFloat() end
                local target = MiningSystem.FindNearestOre(Settings.Mining.SearchRadius)
                if target then
                    Runtime.Mining.CurrentTargetStone = target
                    Runtime.Mining.IsBusy = true
                    if Settings.Mining.AutoWalk then
                        if not MiningSystem.WalkToOre(target) then
                            Runtime.Mining.IsBusy = false
                            continue
                        end
                    end
                    MiningSystem.MineOre(target)
                end
            end
        end
        Runtime.Mining.Thread = nil
    end)
end

function MiningSystem.Stop()
    Settings.Mining.Enabled = false
    if Runtime.Mining.Thread then
        task.cancel(Runtime.Mining.Thread)
        Runtime.Mining.Thread = nil
    end
    MiningSystem.DisableUndergroundFloat()
    MiningSystem.ResetSession()
    MiningSystem.UnhookPickaxeEvents()
end

-- ─── Global listeners ────────────────────────────────────────────
Utils.AddConnection(Runtime.GlobalConnections, PlayerGui.ChildAdded:Connect(function(child)
    RunService.Heartbeat:Wait()
    if child:FindFirstChild("PreMiningHolder") then
        if Settings.Mining.MineMethod == "Legit" then
            Runtime.Mining.IsBusy = true
            MiningSystem.HookMiningGui(child)
        end
    end
end))
for _, g in ipairs(PlayerGui:GetChildren()) do
    if g:FindFirstChild("PreMiningHolder") and Settings.Mining.MineMethod == "Legit" then
        Runtime.Mining.IsBusy = true
        MiningSystem.HookMiningGui(g)
    end
end

Utils.AddConnection(Runtime.GlobalConnections, LocalPlayer.CharacterAdded:Connect(function()
    Runtime.Mining.SessionToken = nil
    Runtime.Mining.HookedPickaxe = nil
    Runtime.Fishing.CastToken = nil
    Runtime.Fishing.BaitLanded = false
    task.wait(1)
    if Settings.Mining.Enabled then MiningSystem.EnsurePickaxeEquipped() end
    if Settings.Fishing.Enabled then FishingSystem.EnsureRodEquipped() end
end))

task.spawn(function()
    local gre = ReplicatedStorage:FindFirstChild("GameRemoteEvents")
                or ReplicatedStorage:WaitForChild("GameRemoteEvents", 6)
    if gre then
        local re = gre:FindFirstChild("CreateFishRewardInfoEvent")
                  or gre:WaitForChild("CreateFishRewardInfoEvent", 6)
        if re and re:IsA("RemoteEvent") then
            Utils.AddConnection(Runtime.GlobalConnections, re.OnClientEvent:Connect(function(_)
                Runtime.Fishing.BaitLanded = false
                Settings.Fishing.TotalFishCaught = Settings.Fishing.TotalFishCaught + 1
                if FishingSystem.OnFishCaught then
                    FishingSystem.OnFishCaught(Settings.Fishing.TotalFishCaught)
                end
            end))
        end
    end
end)

-- ══════════════════════════════════════════════════════════════════
-- AUTO CLAIM
-- ══════════════════════════════════════════════════════════════════
local AutoClaim = {}
local ClaimSettings = { AutoClaimDaily = true, AutoClaimSession = true }
local ClaimRuntime  = { Thread = nil }

local function GetClaimRemotes()
    local fns = ReplicatedStorage:FindFirstChild("GameRemoteFunctions")
    if not fns then return nil, nil end
    return fns:FindFirstChild("CollectDailyRewardFunction"),
           fns:FindFirstChild("CollectSessionRewardFunction")
end

local function TryClaimDaily()
    local dailyFn = GetClaimRemotes()
    if not dailyFn then return false end
    local ok, result = pcall(function() return dailyFn:InvokeServer() end)
    if ok and result then
        local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local rGui = pg and pg:FindFirstChild("Reward")
        if rGui then
            local cb = rGui:FindFirstChild("Holder")
                and rGui.Holder:FindFirstChild("Frame")
                and rGui.Holder.Frame:FindFirstChild("Body")
                and rGui.Holder.Frame.Body:FindFirstChild("Daily")
                and rGui.Holder.Frame.Body.Daily:FindFirstChild("ClaimFrame")
                and rGui.Holder.Frame.Body.Daily.ClaimFrame:FindFirstChild("ClaimButton")
            if cb and cb.Visible then pcall(function() cb:activate() end) end
        end
        return true
    end
    return false
end

local function TryClaimSession()
    local _, sessionFn = GetClaimRemotes()
    if not sessionFn then return false end
    local claimedAny = false
    for i = 1, 12 do
        local ok, res = pcall(function() return sessionFn:InvokeServer(i) end)
        if ok and res == true then claimedAny = true end
        task.wait(0.08)
    end
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local rGui = pg and pg:FindFirstChild("Reward")
    if rGui then
        local inner = rGui:FindFirstChild("Holder")
            and rGui.Holder:FindFirstChild("Frame")
            and rGui.Holder.Frame:FindFirstChild("Body")
            and rGui.Holder.Frame.Body:FindFirstChild("Session")
            and rGui.Holder.Frame.Body.Session:FindFirstChild("SessionFrame")
        if inner then
            for _, slot in ipairs(inner:GetChildren()) do
                if slot:IsA("Frame") then
                    local c = slot:FindFirstChild("Claimed", true)
                    if not (c and c.Visible) then
                        local b = slot:FindFirstChild("ClaimButton", true)
                        if b and b.Visible then pcall(function() b:activate() end) end
                    end
                end
            end
        end
    end
    return claimedAny
end

local function RunClaimLoop()
    while ClaimSettings.AutoClaimDaily or ClaimSettings.AutoClaimSession do
        if ClaimSettings.AutoClaimDaily then
            if TryClaimDaily() then
                Notify({ Title = "Auto Claim", Message = "Daily reward claimed!",
                    Type = "success", Duration = 4 })
            end
        end
        if ClaimSettings.AutoClaimSession then
            if TryClaimSession() then
                Notify({ Title = "Auto Claim", Message = "Session reward claimed!",
                    Type = "success", Duration = 4 })
            end
        end
        task.wait(30)
    end
end

function AutoClaim.Start()
    if ClaimRuntime.Thread then task.cancel(ClaimRuntime.Thread) end
    ClaimRuntime.Thread = task.spawn(RunClaimLoop)
end
function AutoClaim.Stop()
    if ClaimRuntime.Thread then
        task.cancel(ClaimRuntime.Thread)
        ClaimRuntime.Thread = nil
    end
end
local function UpdateClaimLoop()
    if ClaimSettings.AutoClaimDaily or ClaimSettings.AutoClaimSession then
        AutoClaim.Start()
    else
        AutoClaim.Stop()
    end
end

task.spawn(function()
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui") if not pg then return end
    local rGui = pg:WaitForChild("Reward", 10) if not rGui then return end
    Utils.AddConnection(Runtime.GlobalConnections, rGui:GetPropertyChangedSignal("Enabled"):Connect(function()
        if not rGui.Enabled then return end
        task.wait(0.5)
        if ClaimSettings.AutoClaimDaily then TryClaimDaily() end
        if ClaimSettings.AutoClaimSession then TryClaimSession() end
    end))
end)

-- ══════════════════════════════════════════════════════════════════
-- ANTI-AFK
-- ══════════════════════════════════════════════════════════════════
local AntiAFK = {}
local AntiAFKSettings = { Enabled = true }
local AntiAFKRuntime  = {
    Thread = nil, PopupConn = nil, AFKFrameConn = nil,
    ConfirmConn = nil, AFKCheckConn = nil,
}

local _afkDecision = nil
local function GetAFKDecisionEvent()
    if _afkDecision and _afkDecision.Parent then return _afkDecision end
    local ge = ReplicatedStorage:FindFirstChild("GameRemoteEvents")
    if ge then _afkDecision = ge:FindFirstChild("AFKCheckDecisionEvent") end
    return _afkDecision
end
local function FireAFKDecision()
    local ev = GetAFKDecisionEvent()
    if ev then pcall(function() ev:FireServer() end) end
end

local function HasDismissOption(gui)
    if not gui then return false end
    for _, d in ipairs(gui:GetDescendants()) do
        if d:IsA("TextLabel") or d:IsA("TextButton") then
            local t = string.lower(d.Text or "")
            if string.find(t, "dismiss") then return true end
        end
    end
    return false
end

local function HasAFKContent(pop)
    if not pop then return false end
    local ctrl = pop:FindFirstChild("PopUpNotificationUIController")
    local cfg  = ctrl and ctrl:FindFirstChild("ObjectConfig")
    local mv   = cfg and cfg:FindFirstChild("MessageLabel")
    local mb   = mv and mv.Value
    local txt  = string.lower((mb and mb.Text) or "")
    if string.find(txt, "afk") or string.find(txt, "idle") or string.find(txt, "moved to") then
        return true
    end
    for _, d in ipairs(pop:GetDescendants()) do
        if d:IsA("TextLabel") then
            local t = string.lower(d.Text or "")
            if string.find(t, "afk") or string.find(t, "idle") or string.find(t, "moved to") then
                return true
            end
        end
    end
    return false
end

local function DismissConfirmation(timeout)
    if not AntiAFKSettings.Enabled then return end
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui") if not pg then return end
    local conf = pg:FindFirstChild("Confirmation")
    if not conf or not conf.Enabled then return end
    if not HasDismissOption(conf) then return end
    local ctrl = conf:FindFirstChild("ConfirmationUIController")
    local cfg  = ctrl and ctrl:FindFirstChild("ObjectConfig")
    local cbV  = cfg and cfg:FindFirstChild("CloseButton")
    local cb   = cbV and cbV.Value
    local dl = os.clock() + (timeout or 35)
    if cb then
        while not cb.Active and os.clock() < dl do
            if not HasDismissOption(conf) then return end
            task.wait(0.5)
        end
        if cb.Active and HasDismissOption(conf) then
            pcall(function() cb:Activate() end)
            if firesignal then
                pcall(function() firesignal(cb.Activated) end)
                pcall(function() firesignal(cb.MouseButton1Click) end)
            end
        end
    end
    FireAFKDecision()
end

local function DismissAFKFrame()
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local hud = pg and pg:FindFirstChild("HUD") if not hud then return end
    local f = hud:FindFirstChild("AFKFrame")
    if not (f and f.Visible) then return end
    for _, o in ipairs(f:GetDescendants()) do
        if (o:IsA("TextButton") or o:IsA("ImageButton")) and o.Visible then
            pcall(function() o:Activate() end)
            if firesignal then
                pcall(function() firesignal(o.Activated) end)
                pcall(function() firesignal(o.MouseButton1Click) end)
            end
        end
    end
end

local function DismissPopUpNotification()
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local pop = pg and pg:FindFirstChild("PopUpNotification")
    if not pop or not pop.Enabled then return end
    if not HasAFKContent(pop) then return end
    local ctrl = pop:FindFirstChild("PopUpNotificationUIController")
    local hideFn = ctrl and ctrl:FindFirstChild("HideFunction")
    local cfg  = ctrl and ctrl:FindFirstChild("ObjectConfig")
    local cbV  = cfg and cfg:FindFirstChild("CloseButton")
    local cb   = cbV and cbV.Value
    if not cb then
        local h = pop:FindFirstChild("Holder")
        local f = h and h:FindFirstChild("Frame")
        local b = f and f:FindFirstChild("Body")
        cb = b and b:FindFirstChild("CloseButton")
    end
    if cb then
        local dl = os.clock() + 35
        while not cb.Active and os.clock() < dl do
            if not pop.Enabled then return end
            task.wait(0.5)
        end
        if cb.Active then
            pcall(function() cb:Activate() end)
            if firesignal then
                pcall(function() firesignal(cb.Activated) end)
                pcall(function() firesignal(cb.MouseButton1Click) end)
            end
        end
    end
    if hideFn then pcall(function() hideFn:Invoke() end) end
    FireAFKDecision()
end

local function RunAntiAFKLoop()
    while AntiAFKSettings.Enabled do
        pcall(function()
            VirtualInputManager:SendMouseMoveEvent(1, 0, game)
            task.wait(0.03)
            VirtualInputManager:SendMouseMoveEvent(-1, 0, game)
        end)
        DismissAFKFrame()
        task.wait(15)
    end
end

function AntiAFK.Start()
    AntiAFKSettings.Enabled = true
    if AntiAFKRuntime.Thread then task.cancel(AntiAFKRuntime.Thread) end
    AntiAFKRuntime.Thread = task.spawn(RunAntiAFKLoop)

    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui") if not pg then return end

    local ge = ReplicatedStorage:FindFirstChild("GameRemoteEvents")
    local ce = ge and ge:FindFirstChild("AFKCheckEvent")
    if ce then
        if AntiAFKRuntime.AFKCheckConn then AntiAFKRuntime.AFKCheckConn:Disconnect() end
        AntiAFKRuntime.AFKCheckConn = ce.OnClientEvent:Connect(function(deadline)
            if not AntiAFKSettings.Enabled then return end
            task.spawn(function()
                task.wait(0.5)
                DismissConfirmation(deadline or 35)
            end)
        end)
    end

    local conf = pg:FindFirstChild("Confirmation")
    if conf then
        if AntiAFKRuntime.ConfirmConn then AntiAFKRuntime.ConfirmConn:Disconnect() end
        AntiAFKRuntime.ConfirmConn = conf:GetPropertyChangedSignal("Enabled"):Connect(function()
            if conf.Enabled and AntiAFKSettings.Enabled then
                task.spawn(function()
                    task.wait(0.3)
                    if HasDismissOption(conf) then DismissConfirmation(35) end
                end)
            end
        end)
    end

    local pop = pg:FindFirstChild("PopUpNotification")
    if pop then
        if AntiAFKRuntime.PopupConn then AntiAFKRuntime.PopupConn:Disconnect() end
        AntiAFKRuntime.PopupConn = pop:GetPropertyChangedSignal("Enabled"):Connect(function()
            if pop.Enabled and AntiAFKSettings.Enabled then
                task.spawn(function()
                    task.wait(0.3)
                    if HasAFKContent(pop) then DismissPopUpNotification() end
                end)
            end
        end)
    end

    local hud = pg:FindFirstChild("HUD")
    local f = hud and hud:FindFirstChild("AFKFrame")
    if f then
        if AntiAFKRuntime.AFKFrameConn then AntiAFKRuntime.AFKFrameConn:Disconnect() end
        AntiAFKRuntime.AFKFrameConn = f:GetPropertyChangedSignal("Visible"):Connect(function()
            if f.Visible and AntiAFKSettings.Enabled then
                task.wait(0.2)
                DismissAFKFrame()
            end
        end)
    end
end

function AntiAFK.Stop()
    AntiAFKSettings.Enabled = false
    if AntiAFKRuntime.Thread then
        task.cancel(AntiAFKRuntime.Thread)
        AntiAFKRuntime.Thread = nil
    end
    for _, k in ipairs({"PopupConn","AFKFrameConn","ConfirmConn","AFKCheckConn"}) do
        if AntiAFKRuntime[k] then
            AntiAFKRuntime[k]:Disconnect()
            AntiAFKRuntime[k] = nil
        end
    end
end

-- ══════════════════════════════════════════════════════════════════
-- PLAYER TELEPORT BYPASS
-- ══════════════════════════════════════════════════════════════════
local PlayerTPBypass = {}
local TPBypassSettings = { BypassInGameMenu = true }

local function GetPlayerFromDetail(header, tpBtn)
    if getconnections and tpBtn then
        local ok, conns = pcall(getconnections, tpBtn.Activated)
        if ok and conns then
            for _, c in ipairs(conns) do
                local ok2, ups = pcall(debug.getupvalues, c.Function)
                if ok2 and type(ups) == "table" then
                    for _, v in pairs(ups) do
                        if typeof(v) == "Instance" and v:IsA("Player") and v ~= LocalPlayer then
                            return v
                        end
                    end
                end
            end
        end
    end
    if header then
        local ul = header:FindFirstChild("UsernameLabel")
        local nl = header:FindFirstChild("NameLabel")
        local ru = ul and ul.Text or ""
        local rn = nl and nl.Text or ""
        local cu = string.lower(string.gsub(ru, "[@%s]", ""))
        local cn = string.lower(string.gsub(rn, "^%s*(.-)%s*$", "%1"))
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer then
                if cu ~= "" and string.lower(p.Name) == cu then return p end
                if cn ~= "" and (string.lower(p.DisplayName) == cn or string.lower(p.Name) == cn) then return p end
            end
        end
    end
    return nil
end

function PlayerTPBypass.TeleportToPlayer(target)
    if not target or target == LocalPlayer then return false end
    local fns = ReplicatedStorage:FindFirstChild("GameRemoteFunctions")
    local fn = fns and fns:FindFirstChild("TeleportPlayerFunction")
    if not fn then return false end
    local ok, res = pcall(function() return fn:InvokeServer(target) end)
    return ok and res == true
end

task.spawn(function()
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui") if not pg then return end
    local pd = pg:WaitForChild("PlayerDetail", 10) if not pd then return end
    local h = pd:WaitForChild("Holder", 5)
    local frame = h and h:WaitForChild("Frame", 5)
    local hd = frame and frame:WaitForChild("Header", 5)
    local bd = frame and frame:WaitForChild("Body", 5)
    local bf = bd and bd:WaitForChild("ButtonFrame", 5)
    local tb = bf and bf:WaitForChild("TeleportButton", 5)
    if tb then
        local function forceUnlock()
            if TPBypassSettings.BypassInGameMenu then tb.Visible = true end
        end
        Utils.AddConnection(Runtime.GlobalConnections, tb:GetPropertyChangedSignal("Visible"):Connect(function()
            if not tb.Visible and TPBypassSettings.BypassInGameMenu then
                task.wait(0.02) tb.Visible = true
            end
        end))
        Utils.AddConnection(Runtime.GlobalConnections, pd:GetPropertyChangedSignal("Enabled"):Connect(function()
            if pd.Enabled then task.wait(0.05) forceUnlock() end
        end))
        local last = 0
        local function click()
            if not TPBypassSettings.BypassInGameMenu then return end
            if os.clock() - last < 1.0 then return end
            last = os.clock()
            local target = GetPlayerFromDetail(hd, tb)
            if target then
                if PlayerTPBypass.TeleportToPlayer(target) then
                    Notify({ Title = "Teleport",
                        Message = "Teleporting to @" .. target.Name .. " (" .. target.DisplayName .. ")",
                        Type = "success", Duration = 3 })
                    local cb = hd and hd:FindFirstChild("CloseButton")
                    if cb then pcall(function() cb:activate() end) end
                else
                    Notify({ Title = "Teleport", Message = "Teleport failed or blocked by server.",
                        Type = "warning", Duration = 3 })
                end
            else
                Notify({ Title = "Teleport", Message = "Could not resolve target player.",
                    Type = "warning", Duration = 2 })
            end
        end
        Utils.AddConnection(Runtime.GlobalConnections, tb.Activated:Connect(click))
        Utils.AddConnection(Runtime.GlobalConnections, tb.MouseButton1Click:Connect(click))
        forceUnlock()
    end
end)

-- ══════════════════════════════════════════════════════════════════
-- ORE REFINEMENT
-- ══════════════════════════════════════════════════════════════════
local RefiningSystem = {}
local RefiningSettings = {
    AutoClaim = false, AutoRefine = false,
    PriorityMode = "Highest Density",
    ExcludedOres = {}, CheckInterval = 3.0,
    TotalClaimed = 0, TotalStarted = 0,
    RefineTiers = {"Ancient","Mythic","Legend","Epic","Rare","Uncommon","Common"},
}
local RefiningRuntime = {
    Thread = nil, IsBusy = false,
    ClaimFunction = nil, StartFunction = nil,
    RefiningConfig = nil, ReplicaManager = nil, OreContent = nil,
}

function RefiningSystem.Init()
    pcall(function()
        local fns = ReplicatedStorage:WaitForChild("GameRemoteFunctions", 5)
        if fns then
            RefiningRuntime.ClaimFunction = fns:FindFirstChild("RefineClaimFunction")
            RefiningRuntime.StartFunction = fns:FindFirstChild("RefineStartFunction")
        end
    end)
    pcall(function()
        local cfg = ReplicatedStorage:WaitForChild("Configuration", 5)
        if cfg and cfg:FindFirstChild("RefiningConfig") then
            RefiningRuntime.RefiningConfig = require(cfg.RefiningConfig)
        end
    end)
    pcall(function()
        local rf = game:GetService("ReplicatedFirst")
        local mgr = rf:WaitForChild("Manager", 5)
        if mgr and mgr:FindFirstChild("ReplicaManager") then
            RefiningRuntime.ReplicaManager = require(mgr.ReplicaManager)
        end
    end)
    pcall(function()
        local c = ReplicatedStorage:WaitForChild("Content", 5)
        if c and c:FindFirstChild("Ore") then RefiningRuntime.OreContent = require(c.Ore) end
    end)
end

function RefiningSystem.GetProfileData()
    if not RefiningRuntime.ReplicaManager then pcall(RefiningSystem.Init) end
    if not RefiningRuntime.ReplicaManager then return nil end
    local ok, pd = pcall(function()
        local r = RefiningRuntime.ReplicaManager:GetPlayerData(LocalPlayer)
        return r and r.ProfileReplica and r.ProfileReplica.Data
    end)
    return ok and pd or nil
end

function RefiningSystem.GetMaxUnlockedSlots(pd)
    if not pd then return 1 end
    local cfg = RefiningRuntime.RefiningConfig
    local loy = pd.Loyalty or 0
    local base = cfg and cfg.BASE_SLOT or 1
    local per  = cfg and cfg.LOYALTY_PER_SLOT or 100
    local max  = cfg and cfg.MAX_SLOT or 10
    return math.clamp(base + math.floor(loy / per), base, max)
end

function RefiningSystem.GetAvailableOresByType(pd)
    local cfg = RefiningRuntime.RefiningConfig
    local idMap = cfg and cfg.REFINED_ID or {}
    -- build tier lookup set from RefineTiers
    local tierSet = {}
    for _, t in ipairs(RefiningSettings.RefineTiers) do tierSet[t] = true end
    local oreData = RefiningRuntime.OreContent or {}
    local byType = {}
    local all = pd and pd.Ore or {}
    for k, v in pairs(all) do
        local oreRarity = oreData[v.OreId] and oreData[v.OreId].Rarity
        if typeof(v) == "table"
            and not v.IsRefined and not v.Favorite and not v.IsEquip
            and idMap[v.OreId] and not RefiningSettings.ExcludedOres[v.OreId]
            and (not oreRarity or tierSet[oreRarity]) then
            local list = byType[v.OreId] or {}
            byType[v.OreId] = list
            table.insert(list, { UniqueId = k, Density = v.Density or 0, OreId = v.OreId })
        end
    end
    for _, list in pairs(byType) do
        if RefiningSettings.PriorityMode == "Highest Density" then
            table.sort(list, function(a, b) return a.Density > b.Density end)
        elseif RefiningSettings.PriorityMode == "Lowest Density" then
            table.sort(list, function(a, b) return a.Density < b.Density end)
        else
            for i = #list, 2, -1 do
                local j = math.random(1, i)
                list[i], list[j] = list[j], list[i]
            end
        end
    end
    local copy = {}
    for id, list in pairs(byType) do
        local c = {}
        for _, v in ipairs(list) do table.insert(c, v) end
        copy[id] = c
    end
    local pairs_ = {}
    for id, pool in pairs(copy) do
        while #pool >= 2 do
            local a = table.remove(pool, 1)
            local b = table.remove(pool, 1)
            table.insert(pairs_, { OreId = id, OreA = a, OreB = b, Score = (a.Density + b.Density) / 2 })
        end
    end
    if RefiningSettings.PriorityMode == "Highest Density" then
        table.sort(pairs_, function(a, b) return a.Score > b.Score end)
    elseif RefiningSettings.PriorityMode == "Lowest Density" then
        table.sort(pairs_, function(a, b) return a.Score < b.Score end)
    end
    return byType, pairs_
end

function RefiningSystem.ProcessCycle()
    if RefiningRuntime.IsBusy then return end
    RefiningRuntime.IsBusy = true
    local pd = RefiningSystem.GetProfileData()
    if not pd then RefiningRuntime.IsBusy = false return end
    local serverNow = workspace:GetServerTimeNow()
    local slots = pd.Refining or {}
    local max = RefiningSystem.GetMaxUnlockedSlots(pd)
    local fns = ReplicatedStorage:FindFirstChild("GameRemoteFunctions")
    local claimFn = RefiningRuntime.ClaimFunction
                     or (fns and fns:FindFirstChild("RefineClaimFunction"))
    local startFn = RefiningRuntime.StartFunction
                     or (fns and fns:FindFirstChild("RefineStartFunction"))

    if RefiningSettings.AutoClaim and claimFn then
        for i = 1, max do
            local slotKey = tostring(i)
            local sd = slots[slotKey]
            if sd and (sd.OreId or sd.StartedAt or sd.EndTime) then
                local endT = sd.EndTime or ((sd.StartedAt or 0) + (sd.Duration or 0))
                if serverNow >= endT then
                    local ok, res = pcall(function() return claimFn:InvokeServer(slotKey) end)
                    if ok and res then
                        RefiningSettings.TotalClaimed = RefiningSettings.TotalClaimed + 1
                        if RefiningSystem.OnStatsUpdated then RefiningSystem.OnStatsUpdated() end
                        Notify({ Title = "Refining",
                            Message = string.format("Slot %s collected! Total: %d", slotKey, RefiningSettings.TotalClaimed),
                            Type = "success", Duration = 2.5 })
                        task.wait(0.35)
                    end
                end
            end
        end
    end

    pd = RefiningSystem.GetProfileData()
    if not pd then RefiningRuntime.IsBusy = false return end
    slots = pd.Refining or {}

    if RefiningSettings.AutoRefine and startFn then
        local empty = 0
        for i = 1, max do
            local sd = slots[tostring(i)]
            if not sd or (not sd.OreId and not sd.StartedAt and not sd.EndTime) then
                empty = empty + 1
            end
        end
        if empty > 0 then
            local _, list = RefiningSystem.GetAvailableOresByType(pd)
            for _, p in ipairs(list) do
                if empty <= 0 then break end
                local ok, res = pcall(function() return startFn:InvokeServer(p.OreA.UniqueId, p.OreB.UniqueId) end)
                if ok and res then
                    empty = empty - 1
                    RefiningSettings.TotalStarted = RefiningSettings.TotalStarted + 1
                    if RefiningSystem.OnStatsUpdated then RefiningSystem.OnStatsUpdated() end
                    local name = string.gsub(p.OreId, "^Ore_", "")
                    Notify({ Title = "Refining",
                        Message = string.format("Refining: %s (D: %.1f + %.1f, avg %.1f)",
                            name, p.OreA.Density, p.OreB.Density, p.Score),
                        Type = "info", Duration = 2.5 })
                    task.wait(0.35)
                end
            end
        end
    end
    RefiningRuntime.IsBusy = false
end

function RefiningSystem.Start()
    if RefiningRuntime.Thread then return end
    RefiningSystem.Init()
    RefiningRuntime.Thread = task.spawn(function()
        while RefiningSettings.AutoClaim or RefiningSettings.AutoRefine do
            pcall(RefiningSystem.ProcessCycle)
            task.wait(RefiningSettings.CheckInterval)
        end
        RefiningRuntime.Thread = nil
    end)
end

function RefiningSystem.Stop()
    if RefiningRuntime.Thread then
        task.cancel(RefiningRuntime.Thread)
        RefiningRuntime.Thread = nil
    end
    RefiningRuntime.IsBusy = false
end

function RefiningSystem.CheckActive()
    if RefiningSettings.AutoClaim or RefiningSettings.AutoRefine then
        RefiningSystem.Start()
    else
        RefiningSystem.Stop()
    end
end

-- ══════════════════════════════════════════════════════════════════
-- MISC SYSTEM
-- ══════════════════════════════════════════════════════════════════
local MiscSystem = {}
local MiscSettings = {
    AutoRun = false, SpeedEnabled = false, WalkSpeed = 16,
    JumpEnabled = false, JumpPower = 50, InfiniteJump = false,
    Noclip = false, AutoLikeLoop = false,
    FPSBooster = false,
}
local MiscRuntime = {
    NoclipConn = nil, InfJumpConn = nil,
    AutoLikeThread = nil, AutoLikePlayerConn = nil, MovementThread = nil,
    FPSBoosterConn = nil, FPSBoosterSaved = {},
}

-- ══════════════════════════════════════════════════════════════════
-- TELEPORT MANAGER (Named Waypoints & Custom Positions)
-- ══════════════════════════════════════════════════════════════════
local TeleportManager = {
    Waypoints = {},
    OnUpdated = nil,
}

function TeleportManager.SaveWaypoint(name, cf)
    if not name or name == "" then return false end
    local hrp = Utils.GetHumanoidRootPart()
    local targetCF = cf or (hrp and hrp.CFrame)
    if not targetCF then return false end
    TeleportManager.Waypoints[name] = targetCF
    if TeleportManager.OnUpdated then pcall(TeleportManager.OnUpdated) end
    return true
end

function TeleportManager.DeleteWaypoint(name)
    if not name or not TeleportManager.Waypoints[name] then return false end
    TeleportManager.Waypoints[name] = nil
    if TeleportManager.OnUpdated then pcall(TeleportManager.OnUpdated) end
    return true
end

function TeleportManager.TeleportTo(name)
    local cf = TeleportManager.Waypoints[name]
    if not cf then return false end
    local hrp = Utils.GetHumanoidRootPart()
    if not hrp then return false end
    hrp.CFrame = cf
    return true
end

function TeleportManager.GetNames()
    local names = {}
    for n, _ in pairs(TeleportManager.Waypoints) do
        table.insert(names, n)
    end
    table.sort(names)
    return names
end

function MiscSystem.GetLovedPlayers()
    local set = {}
    pcall(function()
        local rf = game:GetService("ReplicatedFirst")
        local mgr = rf:FindFirstChild("Manager")
        local pl = mgr and mgr:FindFirstChild("PlayerListManager")
        local upd = pl and pl:FindFirstChild("PlayerListUpdater")
        if upd then
            local u = require(upd)
            if u then
                if u.UpdateLove then u.UpdateLove() end
                if u.GetLoveState then
                    for _, p in ipairs(Players:GetPlayers()) do
                        if p ~= LocalPlayer and u.GetLoveState(p.Name) == 1 then
                            set[p.Name] = true
                        end
                    end
                end
            end
        end
    end)
    pcall(function()
        local rf = game:GetService("ReplicatedFirst")
        local mgr = rf:FindFirstChild("Manager")
        local rm  = mgr and mgr:FindFirstChild("ReplicaManager")
        if rm then
            local R = require(rm)
            local pd = R:GetPlayerData(LocalPlayer)
            pd = pd and pd.ProfileReplica and pd.ProfileReplica.Data
            if pd and typeof(pd.DailyLoving) == "table" then
                local lib = ReplicatedStorage:FindFirstChild("Lib")
                lib = lib and lib:FindFirstChild("Misc")
                if lib then
                    local M = require(lib)
                    local key = M.GetDailyKey(workspace:GetServerTimeNow())
                    local today = pd.DailyLoving[key]
                    if typeof(today) == "table" then
                        for _, n in pairs(today) do set[tostring(n)] = true end
                    end
                end
            end
        end
    end)
    return set
end

function MiscSystem.GiveLoveToAll(notify)
    local fns = ReplicatedStorage:FindFirstChild("GameRemoteFunctions")
    local fn = fns and fns:FindFirstChild("GiveLoveFunction")
    if not fn then
        if notify then Notify({ Title = "Give Love",
            Message = "GiveLoveFunction remote not found",
            Type = "error", Duration = 3 }) end
        return 0, 0, "Remote not found"
    end
    local loved = MiscSystem.GetLovedPlayers()
    local liked, alreadyLiked = 0, 0
    local ageMsg = nil
    local targets = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            if loved[p.Name] then alreadyLiked = alreadyLiked + 1
            else table.insert(targets, p) end
        end
    end
    if #targets == 0 then
        if notify then Notify({ Title = "Give Love",
            Message = string.format("All %d player(s) already liked!", alreadyLiked),
            Type = "info", Duration = 3 }) end
        return 0, alreadyLiked, nil
    end
    if notify then Notify({ Title = "Give Love",
        Message = string.format("Liking %d unliked player(s)...", #targets),
        Type = "info", Duration = 2.5 }) end
    for i, p in ipairs(targets) do
        local ok, res, msg = pcall(function() return fn:InvokeServer(p) end)
        if ok and res == true then
            liked = liked + 1
            loved[p.Name] = true
            pcall(function()
                local rf = game:GetService("ReplicatedFirst")
                local u = require(rf.Manager.PlayerListManager.PlayerListUpdater)
                if u and u.PatchLoveState then u.PatchLoveState(p.Name, 1) end
            end)
        elseif ok and res == false then
            local s = tostring(msg or "")
            if s:find("under 30 days") then ageMsg = s break
            elseif s:find("already") or s:find("once per day") then
                loved[p.Name] = true
            elseif s:find("wait a moment") then
                task.wait(1.0)
                local ok2, res2 = pcall(function() return fn:InvokeServer(p) end)
                if ok2 and res2 == true then
                    liked = liked + 1 loved[p.Name] = true
                end
            end
        end
        if i < #targets then task.wait(1.02) end
    end
    if notify then
        if ageMsg then
            Notify({ Title = "Give Love Restricted", Message = ageMsg,
                Type = "warning", Duration = 4 })
        elseif liked > 0 then
            Notify({ Title = "Give Love",
                Message = string.format("Finished! Liked %d player(s). (%d already liked)", liked, alreadyLiked),
                Type = "success", Duration = 3.5 })
        end
    end
    return liked, alreadyLiked, ageMsg
end

function MiscSystem.StartAutoLikeLoop()
    if MiscRuntime.AutoLikeThread then return end
    task.spawn(function() MiscSystem.GiveLoveToAll(true) end)
    if not MiscRuntime.AutoLikePlayerConn then
        MiscRuntime.AutoLikePlayerConn = Players.PlayerAdded:Connect(function(p)
            if not MiscSettings.AutoLikeLoop then return end
            if p == LocalPlayer then return end
            task.wait(2.5)
            local loved = MiscSystem.GetLovedPlayers()
            if not loved[p.Name] then
                local fns = ReplicatedStorage:FindFirstChild("GameRemoteFunctions")
                local fn = fns and fns:FindFirstChild("GiveLoveFunction")
                if fn then pcall(function() return fn:InvokeServer(p) end) end
            end
        end)
    end
    MiscRuntime.AutoLikeThread = task.spawn(function()
        while MiscSettings.AutoLikeLoop do
            for _ = 1, 30 do
                if not MiscSettings.AutoLikeLoop then break end
                task.wait(1)
            end
            if not MiscSettings.AutoLikeLoop then break end
            MiscSystem.GiveLoveToAll(false)
        end
        MiscRuntime.AutoLikeThread = nil
    end)
end

function MiscSystem.StopAutoLikeLoop()
    if MiscRuntime.AutoLikeThread then
        pcall(task.cancel, MiscRuntime.AutoLikeThread)
        MiscRuntime.AutoLikeThread = nil
    end
    if MiscRuntime.AutoLikePlayerConn then
        pcall(function() MiscRuntime.AutoLikePlayerConn:Disconnect() end)
        MiscRuntime.AutoLikePlayerConn = nil
    end
end

function MiscSystem.RedeemCode(code)
    if not code or code == "" then return false end
    local fns = ReplicatedStorage:FindFirstChild("GameRemoteFunctions")
    local fn = fns and fns:FindFirstChild("CodeRedeemFunction")
    if not fn then return false end
    local ok, res = pcall(function() return fn:InvokeServer(code) end)
    return ok and res == true
end

function MiscSystem.RedeemAllKnownCodes()
    local codes = {"INDOVOICE","UPDATE","RELEASE","FISH","MINE","FREE","VOICE","NEW","100K","50K"}
    local n = 0
    for _, c in ipairs(codes) do
        if MiscSystem.RedeemCode(c) then n = n + 1 end
        task.wait(0.12)
    end
    return n
end

function MiscSystem.SetInfiniteJump(enabled)
    MiscSettings.InfiniteJump = enabled
    if MiscRuntime.InfJumpConn then
        MiscRuntime.InfJumpConn:Disconnect()
        MiscRuntime.InfJumpConn = nil
    end
    if enabled then
        MiscRuntime.InfJumpConn = UserInputService.JumpRequest:Connect(function()
            if MiscSettings.InfiniteJump then
                local h = Utils.GetHumanoid()
                if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
            end
        end)
    end
end

function MiscSystem.SetNoclip(enabled)
    MiscSettings.Noclip = enabled
    if MiscRuntime.NoclipConn then
        MiscRuntime.NoclipConn:Disconnect()
        MiscRuntime.NoclipConn = nil
    end
    if enabled then
        MiscRuntime.NoclipConn = RunService.Stepped:Connect(function()
            if not MiscSettings.Noclip then return end
            local c = LocalPlayer.Character
            if c then
                for _, p in ipairs(c:GetDescendants()) do
                    if p:IsA("BasePart") and p.CanCollide then p.CanCollide = false end
                end
            end
        end)
    else
        local c = LocalPlayer.Character
        if c then
            for _, p in ipairs(c:GetDescendants()) do
                if p:IsA("BasePart") then p.CanCollide = true end
            end
        end
    end
end

function MiscSystem.SetFPSBooster(enabled)
    MiscSettings.FPSBooster = enabled
    if MiscRuntime.FPSBoosterConn then
        MiscRuntime.FPSBoosterConn:Disconnect()
        MiscRuntime.FPSBoosterConn = nil
    end

    local lighting = game:GetService("Lighting")

    if enabled then
        -- 1. Save original lighting properties
        MiscRuntime.FPSBoosterSaved = {
            GlobalShadows = lighting.GlobalShadows,
            FogEnd = lighting.FogEnd,
            Brightness = lighting.Brightness,
        }
        lighting.GlobalShadows = false
        lighting.FogEnd = 9e9

        -- 2. Optimize existing visual effects and particle emitters
        for _, obj in ipairs(workspace:GetDescendants()) do
            if obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Smoke") or obj:IsA("Fire") or obj:IsA("Sparkles") then
                obj.Enabled = false
            elseif obj:IsA("PostEffect") then
                obj.Enabled = false
            end
        end

        -- 3. Intercept newly added particles/effects
        MiscRuntime.FPSBoosterConn = workspace.DescendantAdded:Connect(function(obj)
            if not MiscSettings.FPSBooster then return end
            if obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Smoke") or obj:IsA("Fire") or obj:IsA("Sparkles") then
                pcall(function() obj.Enabled = false end)
            elseif obj:IsA("PostEffect") then
                pcall(function() obj.Enabled = false end)
            end
        end)
    else
        -- Restore saved lighting
        if MiscRuntime.FPSBoosterSaved then
            if MiscRuntime.FPSBoosterSaved.GlobalShadows ~= nil then
                lighting.GlobalShadows = MiscRuntime.FPSBoosterSaved.GlobalShadows
            end
            if MiscRuntime.FPSBoosterSaved.FogEnd ~= nil then
                lighting.FogEnd = MiscRuntime.FPSBoosterSaved.FogEnd
            end
        end
        for _, obj in ipairs(workspace:GetDescendants()) do
            if obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Smoke") or obj:IsA("Fire") or obj:IsA("Sparkles") then
                obj.Enabled = true
            elseif obj:IsA("PostEffect") then
                obj.Enabled = true
            end
        end
        MiscRuntime.FPSBoosterSaved = {}
    end
end

function MiscSystem.Stop()
    MiscSettings.SpeedEnabled = false
    MiscSettings.JumpEnabled  = false
    MiscSettings.AutoRun      = false
    MiscSettings.InfiniteJump = false
    MiscSettings.Noclip       = false
    MiscSettings.AutoLikeLoop = false
    MiscSettings.FPSBooster   = false
    if MiscRuntime.MovementThread then
        pcall(task.cancel, MiscRuntime.MovementThread)
        MiscRuntime.MovementThread = nil
    end
    MiscSystem.SetNoclip(false)
    MiscSystem.SetInfiniteJump(false)
    MiscSystem.SetFPSBooster(false)
    MiscSystem.StopAutoLikeLoop()
    local h = Utils.GetHumanoid()
    if h then
        pcall(function()
            h.WalkSpeed = 16
            h.UseJumpPower = false
            h.JumpPower = 50
        end)
    end
end

MiscRuntime.MovementThread = task.spawn(function()
    while true do
        local h = Utils.GetHumanoid()
        if h then
            if MiscSettings.SpeedEnabled then
                local target = MiscSettings.WalkSpeed
                if MiscSettings.AutoRun and h.MoveDirection.Magnitude > 0 then
                    target = math.max(target, 26)
                end
                if h.WalkSpeed ~= target then h.WalkSpeed = target end
            end
            if MiscSettings.JumpEnabled then
                h.UseJumpPower = true
                h.JumpPower = MiscSettings.JumpPower
            end
        end
        task.wait(0.1)
    end
end)

-- ══════════════════════════════════════════════════════════════════
-- AUTO SELL
-- ══════════════════════════════════════════════════════════════════
local AutoSell = {}
local SELL_TIERS_ALL = {"Ancient","Mythic","Legend","Epic","Rare","Uncommon","Common"}
local AutoSellSettings = {
    FishEnabled = false, OreEnabled = false,
    FishShopType = "FishShop", FishTrigger = 50,
    OreTrigger = 30, OreFilterMode = "All", ReturnAfterSell = true,
    FishSellTiers = {"Ancient","Mythic","Legend","Epic","Rare","Uncommon","Common"},
    OreSellTiers  = {"Ancient","Mythic","Legend","Epic","Rare","Uncommon","Common"},
    MaxRetry = 5, RetryDelay = 1.5,
}
local AutoSellRuntime = {
    IsBusy = false, FishThread = nil, OreThread = nil,
    FishCountSnap = 0, OreCountSnap = 0, ReplicaManager = nil,
}
local SHOP_POSITIONS = {
    FishShop   = Vector3.new(-259.418, 24.233, -5048.189),
    FishBroker = Vector3.new(265.043, 39.033, -4872.701),
    OreShop    = Vector3.new(309.462, 15.941, -4996.720),
}
local SELL_APPROACH = 7

local function AutoSell_TP(shopKey)
    local hrp = Utils.GetHumanoidRootPart() if not hrp then return false end
    local pos = SHOP_POSITIONS[shopKey] if not pos then return false end
    if shopKey == "OreShop" then
        local under = pos - Vector3.new(0, 7.5, 0)
        MiningSystem.EnableUndergroundFloat(CFrame.lookAt(under, pos))
    else
        hrp.CFrame = CFrame.new(pos + Vector3.new(0, 0, SELL_APPROACH))
    end
    task.wait(0.35)
    return true
end

local function AutoSell_Fish()
    local fns = ReplicatedStorage:FindFirstChild("GameRemoteFunctions") if not fns then return false end
    local rem = fns:FindFirstChild("SellAllFishFunction") if not rem then return false end
    local tiers = (#AutoSellSettings.FishSellTiers > 0)
        and AutoSellSettings.FishSellTiers or SELL_TIERS_ALL
    local ok, r = pcall(function() return rem:InvokeServer(tiers) end)
    return ok and r ~= false and r ~= nil
end

local function AutoSell_GetOres()
    if not AutoSellRuntime.ReplicaManager then
        pcall(function()
            local rf = game:GetService("ReplicatedFirst")
            local mgr = rf:WaitForChild("Manager", 5)
            if mgr and mgr:FindFirstChild("ReplicaManager") then
                AutoSellRuntime.ReplicaManager = require(mgr.ReplicaManager)
            end
        end)
    end
    if not AutoSellRuntime.ReplicaManager then return nil end
    local ok, d = pcall(function()
        local r = AutoSellRuntime.ReplicaManager:GetPlayerData(LocalPlayer)
        return r and r.ProfileReplica and r.ProfileReplica.Data
    end)
    return ok and d and d.Ore or nil
end

local function AutoSell_CountFish()
    if not AutoSellRuntime.ReplicaManager then
        pcall(function()
            local rf = game:GetService("ReplicatedFirst")
            local mgr = rf:WaitForChild("Manager", 5)
            if mgr and mgr:FindFirstChild("ReplicaManager") then
                AutoSellRuntime.ReplicaManager = require(mgr.ReplicaManager)
            end
        end)
    end
    if not AutoSellRuntime.ReplicaManager then return nil end
    local ok, d = pcall(function()
        local r = AutoSellRuntime.ReplicaManager:GetPlayerData(LocalPlayer)
        return r and r.ProfileReplica and r.ProfileReplica.Data
    end)
    if not ok or not d or not d.Fish then return nil end
    local tierSet = {}
    for _, t in ipairs(AutoSellSettings.FishSellTiers) do tierSet[t] = true end
    local RARITY_LIST = {"Ancient","Mythic","Legend","Epic","Rare","Uncommon","Common"}
    local n = 0
    for _, fd in pairs(d.Fish) do
        if type(fd) == "table" and not fd.Favorite and not fd.IsEquip then
            local rarity = fd.Rarity
            if not rarity and type(fd.FishId) == "string" then
                local low = string.lower(fd.FishId)
                for _, rv in ipairs(RARITY_LIST) do
                    if string.find(low, string.lower(rv), 1, true) then
                        rarity = rv break
                    end
                end
            end
            if not rarity or tierSet[rarity] then
                n = n + 1
            end
        end
    end
    return n
end

local function AutoSell_CountOre()
    local ores = AutoSell_GetOres()
    if not ores then return nil end
    local mode = AutoSellSettings.OreFilterMode
    local n = 0
    for uid, od in pairs(ores) do
        if typeof(od) == "table" and not od.Favorite then
            if mode == "All" then
                n = n + 1
            else
                local isRef = (od.IsRefined == true)
                    or (typeof(od.OreId) == "string" and string.find(od.OreId, "Refined") ~= nil)
                    or (typeof(uid) == "string" and string.find(uid, "Refined") ~= nil)
                if mode == "Refined Only" and isRef then n = n + 1
                elseif mode == "Raw Only" and not isRef then n = n + 1 end
            end
        end
    end
    return n
end

local function AutoSell_Ore()
    local fns = ReplicatedStorage:FindFirstChild("GameRemoteFunctions") if not fns then return false end
    local mode = AutoSellSettings.OreFilterMode
    local oreTiers = (#AutoSellSettings.OreSellTiers > 0)
        and AutoSellSettings.OreSellTiers or SELL_TIERS_ALL
    if mode == "All" then
        local rem = fns:FindFirstChild("SellAllOreFunction") if not rem then return false end
        local ok, r = pcall(function() return rem:InvokeServer(oreTiers) end)
        return ok and r ~= false and r ~= nil
    end
    local sellRem = fns:FindFirstChild("SellOreFunction")
    if not sellRem then
        local rem = fns:FindFirstChild("SellAllOreFunction") if not rem then return false end
        local ok, r = pcall(function() return rem:InvokeServer(oreTiers) end)
        return ok and r ~= false and r ~= nil
    end
    local ores = AutoSell_GetOres() if not ores then return false end
    local wantRef = (mode == "Refined Only")
    local list = {}
    for uid, od in pairs(ores) do
        if typeof(od) == "table" and not od.Favorite then
            local isRef = (od.IsRefined == true)
                or (typeof(od.OreId) == "string" and string.find(od.OreId, "Refined") ~= nil)
                or (typeof(uid) == "string" and string.find(uid, "Refined") ~= nil)
            if isRef == wantRef then table.insert(list, uid) end
        end
    end
    if #list == 0 then
        Notify({ Title = "Auto Sell Ore",
            Message = string.format("Tidak ada %s yang bisa dijual.", wantRef and "Refined Ore" or "Raw Ore"),
            Type = "info", Duration = 2.5 })
        return false
    end
    local n = 0
    for _, uid in ipairs(list) do
        local ok, r = pcall(function() return sellRem:InvokeServer(uid) end)
        if ok and r ~= false and r ~= nil then n = n + 1 end
        task.wait(0.08)
    end
    return n > 0
end

local function AutoSell_DoFish()
    if AutoSellRuntime.IsBusy then return false end
    AutoSellRuntime.IsBusy = true
    local hrp = Utils.GetHumanoidRootPart()
    local savedCF = (hrp and hrp.CFrame) or CFrame.new()
    local shop = AutoSellSettings.FishShopType or "FishShop"
    if not AutoSell_TP(shop) then AutoSellRuntime.IsBusy = false return false end

    local maxRetry  = AutoSellSettings.MaxRetry or 5
    local retryDelay = AutoSellSettings.RetryDelay or 1.5
    local sold = false

    for attempt = 1, maxRetry do
        local countBefore = AutoSell_CountFish()

        -- tas kosong, ga perlu jual
        if countBefore and countBefore == 0 then break end

        AutoSell_Fish()
        task.wait(0.8) -- tunggu server proses

        local countAfter = AutoSell_CountFish()

        if countBefore and countAfter then
            if countAfter < countBefore then
                sold = true
                break
            end
            -- count sama = sell gagal, retry
            if attempt < maxRetry then
                Notify({ Title = "Auto Sell",
                    Message = string.format("Sell ikan gagal, retry %d/%d...", attempt, maxRetry),
                    Type = "warning", Duration = 1.5 })
                task.wait(retryDelay)
                AutoSell_TP(shop) -- re-TP biar dipastiin di shop
            end
        else
            -- ReplicaManager ga bisa dibaca, trust server response aja
            sold = true
            break
        end
    end

    task.wait(0.25)
    if AutoSellSettings.ReturnAfterSell then
        local h = Utils.GetHumanoidRootPart()
        if h then h.CFrame = savedCF task.wait(0.2) end
    end
    AutoSellRuntime.FishCountSnap = Settings.Fishing.TotalFishCaught
    AutoSellRuntime.IsBusy = false
    if sold then
        Notify({ Title = "Auto Sell", Message = "Ikan terjual!", Type = "success", Duration = 2 })
    else
        Notify({ Title = "Auto Sell", Message = "Ga ada ikan / sell tetap gagal.", Type = "warning", Duration = 2 })
    end
    return sold
end

local function AutoSell_DoOre()
    if AutoSellRuntime.IsBusy then return false end
    AutoSellRuntime.IsBusy = true
    local hrp = Utils.GetHumanoidRootPart()
    local savedCF = (hrp and hrp.CFrame) or CFrame.new()
    if not AutoSell_TP("OreShop") then AutoSellRuntime.IsBusy = false return false end
    local wasFloating = Runtime.Mining.IsFloating

    local maxRetry   = AutoSellSettings.MaxRetry or 5
    local retryDelay = AutoSellSettings.RetryDelay or 1.5
    local sold = false

    for attempt = 1, maxRetry do
        local countBefore = AutoSell_CountOre()

        -- tas ore kosong
        if countBefore and countBefore == 0 then break end

        AutoSell_Ore()
        task.wait(0.8) -- tunggu server proses

        local countAfter = AutoSell_CountOre()

        if countBefore and countAfter then
            if countAfter < countBefore then
                sold = true
                break
            end
            -- count sama = sell gagal, retry
            if attempt < maxRetry then
                Notify({ Title = "Auto Sell Ore",
                    Message = string.format("Sell ore gagal, retry %d/%d...", attempt, maxRetry),
                    Type = "warning", Duration = 1.5 })
                task.wait(retryDelay)
                AutoSell_TP("OreShop") -- re-TP ke shop
            end
        else
            -- ReplicaManager ga bisa dibaca, trust server response
            sold = true
            break
        end
    end

    task.wait(0.25)
    if AutoSellSettings.ReturnAfterSell then
        local h = Utils.GetHumanoidRootPart()
        if h then
            if wasFloating then
                MiningSystem.EnableUndergroundFloat(savedCF)
            else
                MiningSystem.DisableUndergroundFloat()
                h.CFrame = savedCF
            end
            task.wait(0.2)
        end
    else
        MiningSystem.DisableUndergroundFloat()
    end
    AutoSellRuntime.OreCountSnap = Settings.Mining.TotalMined
    AutoSellRuntime.IsBusy = false
    if sold then
        Notify({ Title = "Auto Sell Ore",
            Message = string.format("Ore terjual! (%s)", AutoSellSettings.OreFilterMode),
            Type = "success", Duration = 2 })
    else
        Notify({ Title = "Auto Sell Ore",
            Message = string.format("Ga ada ore / sell tetap gagal. (%s)", AutoSellSettings.OreFilterMode),
            Type = "warning", Duration = 2 })
    end
    return sold
end

function AutoSell.StartFishLoop()
    if AutoSellRuntime.FishThread then return end
    AutoSellRuntime.FishCountSnap = Settings.Fishing.TotalFishCaught
    AutoSellRuntime.FishThread = task.spawn(function()
        while AutoSellSettings.FishEnabled do
            task.wait(4)
            if not AutoSellSettings.FishEnabled then break end
            local caught = Settings.Fishing.TotalFishCaught - AutoSellRuntime.FishCountSnap
            if caught >= AutoSellSettings.FishTrigger then
                local was = Settings.Fishing.Enabled
                if was then Settings.Fishing.Enabled = false task.wait(1.5) end
                AutoSell_DoFish()
                if was and AutoSellSettings.FishEnabled then
                    Settings.Fishing.Enabled = true
                    task.spawn(FishingSystem.Start)
                end
            end
        end
        AutoSellRuntime.FishThread = nil
    end)
end

function AutoSell.StopFishLoop()
    AutoSellSettings.FishEnabled = false
    if AutoSellRuntime.FishThread then
        pcall(function() task.cancel(AutoSellRuntime.FishThread) end)
        AutoSellRuntime.FishThread = nil
    end
end

function AutoSell.StartOreLoop()
    if AutoSellRuntime.OreThread then return end
    AutoSellRuntime.OreThread = task.spawn(function()
        while AutoSellSettings.OreEnabled do
            local mined = Settings.Mining.TotalMined - AutoSellRuntime.OreCountSnap
            if mined >= AutoSellSettings.OreTrigger then
                local was = Settings.Mining.Enabled
                if was then Settings.Mining.Enabled = false task.wait(1.5) end
                AutoSell_DoOre()
                if was and AutoSellSettings.OreEnabled then
                    Settings.Mining.Enabled = true
                    task.spawn(MiningSystem.Start)
                end
            end
            task.wait(4)
            if not AutoSellSettings.OreEnabled then break end
        end
        AutoSellRuntime.OreThread = nil
    end)
end

function AutoSell.StopOreLoop()
    AutoSellSettings.OreEnabled = false
    if AutoSellRuntime.OreThread then
        pcall(function() task.cancel(AutoSellRuntime.OreThread) end)
        AutoSellRuntime.OreThread = nil
    end
end

-- ══════════════════════════════════════════════════════════════════
-- HOTSPOT ESP & CHAMS
-- ══════════════════════════════════════════════════════════════════
local HotspotESP = {}
local HotspotSettings = {
    FishingEnabled = false, FishingESP = false, FishingTracer = true, FishingChams = false,
    FishingOnlyHotspot = false, FishingMaxDist = 500,
    MiningEnabled = false, MiningESP = false, MiningTracer = true, MiningChams = false,
    MiningOnlyHotspot = false, MiningMaxDist = 10000,
}
local HotspotRuntime = {
    FishingDrawings = {}, MiningDrawings = {}, Highlights = {},
    HiddenBBs = {}, ChamsFolder = nil, Thread = nil,
}

local COLOR_HOTSPOT_GOLD   = Color3.fromRGB(255, 215, 0)
local COLOR_HOTSPOT_GREEN  = Color3.fromRGB(40, 255, 130)
local COLOR_NORMAL_ORE     = Color3.fromRGB(120, 205, 255)
local COLOR_NORMAL_FISHING = Color3.fromRGB(140, 185, 215)

local function EnsureChamsFolder()
    if not HotspotRuntime.ChamsFolder or not HotspotRuntime.ChamsFolder.Parent then
        local f = Instance.new("Folder")
        f.Name = "Delirium_Hotspot_Chams"
        f.Parent = workspace
        HotspotRuntime.ChamsFolder = f
    end
    return HotspotRuntime.ChamsFolder
end

local function NewTracerLine(color, thickness)
    -- Simple Drawing-based fallback: not available in all executors,
    -- but preserved from source. If Drawing is nil the label alone still works.
    if not Drawing then return nil end
    local line = Drawing.new("Line")
    line.Color = color or Color3.new(1,1,1)
    line.Thickness = thickness or 2
    line.Visible = false
    line.ZIndex = 10
    return line
end
local function UpdateTracerLine(t, from, to, color, thickness)
    if not t then return end
    t.From = from t.To = to t.Color = color
    t.Thickness = thickness or 2 t.Visible = true
end
local function SetTracerVisible(t, v) if t then t.Visible = v end end
local function DestroyTracerLine(t) if t then pcall(function() t:Remove() end) end end

local function CreateESPChams(adornee, text, color, isHotspot)
    if not adornee or not adornee.Parent then return end
    local container = EnsureChamsFolder()
    local existing = HotspotRuntime.Highlights[adornee]
    if existing then
        pcall(function()
            if existing.hl then existing.hl:Destroy() end
            if existing.bb then existing.bb:Destroy() end
        end)
        HotspotRuntime.Highlights[adornee] = nil
    end
    local function hideBB(inst)
        if inst:IsA("BillboardGui") and not inst:GetAttribute("DX8_IV_ESP") then
            table.insert(HotspotRuntime.HiddenBBs, { bb = inst, vis = inst.Enabled })
            inst.Enabled = false
        end
    end
    for _, c in ipairs(adornee:GetChildren()) do hideBB(c) end
    if adornee:IsA("Model") then
        for _, d in ipairs(adornee:GetDescendants()) do hideBB(d) end
    end
    local hl = Instance.new("Highlight")
    hl.Name = "IV_HL_" .. tostring(adornee.Name)
    hl.Adornee = adornee
    hl.FillColor = color
    hl.FillTransparency = isHotspot and 0.45 or 0.70
    hl.OutlineColor = isHotspot and COLOR_HOTSPOT_GOLD or Color3.fromRGB(255,255,255)
    hl.OutlineTransparency = 0.15
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = container

    local bb = Instance.new("BillboardGui")
    bb.Name = "IV_BB_" .. tostring(adornee.Name)
    bb.Adornee = adornee
    bb.Size = UDim2.new(0, 180, 0, 32)
    bb.StudsOffset = Vector3.new(0, isHotspot and 5 or 3.5, 0)
    bb.AlwaysOnTop = true bb.MaxDistance = 0 bb.LightInfluence = 0
    bb:SetAttribute("DX8_IV_ESP", true)
    bb.Parent = container

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = text
    lbl.TextColor3 = color
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = isHotspot and 14 or 12
    lbl.TextStrokeColor3 = Color3.new(0,0,0)
    lbl.TextStrokeTransparency = 0.2
    lbl.Parent = bb

    HotspotRuntime.Highlights[adornee] = { hl = hl, bb = bb }
end

local function RemoveESPChams(adornee)
    local d = HotspotRuntime.Highlights[adornee]
    if d then
        pcall(function() if d.hl then d.hl:Destroy() end end)
        pcall(function() if d.bb then d.bb:Destroy() end end)
        HotspotRuntime.Highlights[adornee] = nil
    end
end

local function ClearDrawingsTable(tbl)
    for k, d in pairs(tbl) do
        if d.line then DestroyTracerLine(d.line) end
        if d.label then pcall(function() d.label:Remove() end) end
        tbl[k] = nil
    end
end

local function ClearAllHighlights()
    for _, e in ipairs(HotspotRuntime.HiddenBBs) do
        pcall(function() e.bb.Enabled = e.vis end)
    end
    HotspotRuntime.HiddenBBs = {}
    for inst, d in pairs(HotspotRuntime.Highlights) do
        pcall(function()
            if type(d) == "table" then
                if d.hl then d.hl:Destroy() end
                if d.bb then d.bb:Destroy() end
            else d:Destroy() end
        end)
        HotspotRuntime.Highlights[inst] = nil
    end
    if HotspotRuntime.ChamsFolder then
        pcall(function() HotspotRuntime.ChamsFolder:Destroy() end)
        HotspotRuntime.ChamsFolder = nil
    end
end

local function GetFishingZones()
    local out = {}
    local main = workspace:FindFirstChild("Main")
    local fz = main and main:FindFirstChild("FishingZone")
    if not fz then
        local rs_main = ReplicatedStorage:FindFirstChild("Main")
        fz = rs_main and rs_main:FindFirstChild("FishingZone")
    end
    if fz then
        for i, c in ipairs(fz:GetChildren()) do
            local part = c:IsA("BasePart") and c
                       or (c:IsA("Model") and (c.PrimaryPart or c:FindFirstChildWhichIsA("BasePart")))
            if part then
                local isActive = c:GetAttribute("IsActive") == true
                    or c:FindFirstChild("DX8_Active") ~= nil
                    or part:GetAttribute("IsActive") == true
                table.insert(out, { index = i, instance = c, part = part, isActive = isActive })
            end
        end
    end
    return out
end

local function GetMiningStones()
    local out = {}
    local container = MiningSystem.GetMiningContainer()
        or (workspace:FindFirstChild("Main")
            and workspace:FindFirstChild("Main"):FindFirstChild("ActiveMiningStones"))
    if container then
        for i, c in ipairs(container:GetChildren()) do
            local part = c:IsA("BasePart") and c
                       or (c:IsA("Model") and (c.PrimaryPart or c:FindFirstChildWhichIsA("BasePart")))
            if part then
                local isHot = c:GetAttribute("IsHotspot") == true or c:FindFirstChild("Hotspot") ~= nil
                local slot  = c:GetAttribute("AvailableSlot") or 0
                local maxS  = c:GetAttribute("MaxSlot") or 0
                table.insert(out, {
                    index = i, instance = c, part = part,
                    isHotspot = isHot, availableSlot = slot, maxSlot = maxS,
                })
            end
        end
    end
    return out
end

function HotspotESP.TeleportToNearestFishing(onlyActive)
    local zones = GetFishingZones()
    local myPos = Utils.GetCharacterPosition()
    local near, nd = nil, math.huge
    for _, z in ipairs(zones) do
        if not onlyActive or z.isActive then
            local d = (z.part.Position - myPos).Magnitude
            if d < nd then nd, near = d, z end
        end
    end
    if near then
        SafeTeleportTo(near.part.Position)
        local tag = near.isActive and "ACTIVE HOTSPOT" or ("Spot #" .. near.index)
        Notify({ Title = "Fishing Spot",
            Message = "Teleported to " .. tag .. " (" .. math.floor(nd) .. "m)",
            Type = "success", Duration = 2 })
    else
        Notify({ Title = "Fishing Spot",
            Message = onlyActive and "No active fishing hotspot found." or "No fishing zones found.",
            Type = "warning", Duration = 2 })
    end
end

function HotspotESP.TeleportToNearestMining(onlyHotspot)
    local stones = GetMiningStones()
    local myPos = Utils.GetCharacterPosition()
    local near, nd = nil, math.huge
    for _, s in ipairs(stones) do
        if not onlyHotspot or s.isHotspot then
            local d = (s.part.Position - myPos).Magnitude
            if d < nd then nd, near = d, s end
        end
    end
    if near then
        SafeTeleportTo(near.part.Position)
        local tag = near.isHotspot and "HOTSPOT ORE" or near.instance.Name
        Notify({ Title = "Mining Stone",
            Message = "Teleported to " .. tag .. " (" .. math.floor(nd) .. "m)",
            Type = "success", Duration = 2 })
    else
        Notify({ Title = "Mining Stone",
            Message = onlyHotspot and "No active hotspot ore on map." or "No mining stones found.",
            Type = "warning", Duration = 2 })
    end
end

local function UpdateHotspotESP()
    local cam = workspace.CurrentCamera if not cam then return end
    local myPos = Utils.GetCharacterPosition()
    local vp = cam.ViewportSize
    local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local hrpScreen = hrp and cam:WorldToViewportPoint(hrp.Position)
    local origin = (hrpScreen and hrpScreen.Z > 0)
        and Vector2.new(hrpScreen.X, hrpScreen.Y)
        or  Vector2.new(vp.X / 2, vp.Y)

    if HotspotSettings.FishingEnabled then
        local zones = GetFishingZones()
        local seen = {}
        for _, z in ipairs(zones) do
            local distVal = (z.part.Position - myPos).Magnitude
            if distVal <= HotspotSettings.FishingMaxDist then
                if not HotspotSettings.FishingOnlyHotspot or z.isActive then
                    seen[z.instance] = true
                    local d = HotspotRuntime.FishingDrawings[z.instance]
                    local color = z.isActive and COLOR_HOTSPOT_GREEN or COLOR_NORMAL_FISHING
                    local dist = math.floor(distVal)
                    if not d then
                        local line = NewTracerLine(color, z.isActive and 2 or 1.5)
                        local label
                        if Drawing then
                            label = Drawing.new("Text")
                            label.Color = color
                            label.Size = z.isActive and 14 or 12
                            label.Center = true
                            label.Outline = true
                            label.OutlineColor = Color3.fromRGB(0,0,0)
                            label.Font = Drawing.Fonts.UI
                            label.ZIndex = 11
                            label.Visible = false
                        end
                        d = { line = line, label = label, part = z.part }
                        HotspotRuntime.FishingDrawings[z.instance] = d
                    else
                        if d.line then d.line.Color = color end
                        if d.label then d.label.Color = color end
                    end
                    local screenPos, onScreen = cam:WorldToViewportPoint(z.part.Position)
                    if screenPos.Z > 0 then
                        if HotspotSettings.FishingTracer then
                            UpdateTracerLine(d.line, origin, Vector2.new(screenPos.X, screenPos.Y), color,
                                z.isActive and 2 or 1.5)
                        else
                            SetTracerVisible(d.line, false)
                        end
                    else
                        SetTracerVisible(d.line, false)
                    end
                    if d.label then
                        if onScreen and screenPos.Z > 0 and not HotspotSettings.FishingChams then
                            d.label.Position = Vector2.new(screenPos.X, screenPos.Y - 14)
                            d.label.Text = z.isActive
                                and string.format("ACTIVE HOTSPOT #%d (%dm)", z.index, dist)
                                or  string.format("Fishing Spot #%d (%dm)", z.index, dist)
                            d.label.Visible = true
                        else
                            d.label.Visible = false
                        end
                    end
                    if HotspotSettings.FishingChams then
                        local title = z.isActive
                            and string.format(" ACTIVE HOTSPOT #%d (%dm)", z.index, dist)
                            or  string.format(" Fishing Spot #%d (%dm)", z.index, dist)
                        local ex = HotspotRuntime.Highlights[z.instance]
                        if not ex or not ex.hl or not ex.hl.Parent then
                            CreateESPChams(z.instance, title, color, z.isActive)
                        else
                            pcall(function()
                                local lbl = ex.bb:FindFirstChildWhichIsA("TextLabel")
                                if lbl then lbl.Text = title end
                            end)
                        end
                    end
                end
            end
        end
        for inst, d in pairs(HotspotRuntime.FishingDrawings) do
            if not seen[inst] then
                if d.line then DestroyTracerLine(d.line) end
                if d.label then pcall(function() d.label:Remove() end) end
                RemoveESPChams(inst)
                HotspotRuntime.FishingDrawings[inst] = nil
            end
        end
    else
        ClearDrawingsTable(HotspotRuntime.FishingDrawings)
    end

    if HotspotSettings.MiningEnabled then
        local stones = GetMiningStones()
        local seen = {}
        for _, s in ipairs(stones) do
            local wp = (s.instance:IsA("Model") and s.instance:GetPivot().Position) or s.part.Position
            local distVal = (wp - myPos).Magnitude
            if distVal <= HotspotSettings.MiningMaxDist then
                if not HotspotSettings.MiningOnlyHotspot or s.isHotspot then
                    seen[s.instance] = true
                    local d = HotspotRuntime.MiningDrawings[s.instance]
                    local color = s.isHotspot and COLOR_HOTSPOT_GOLD or COLOR_NORMAL_ORE
                    local dist = math.floor(distVal)
                    local slotStr = (s.maxSlot > 0) and string.format("[%d/%d]", s.availableSlot, s.maxSlot) or ""
                    if not d then
                        local line = NewTracerLine(color, s.isHotspot and 2 or 1.5)
                        local label
                        if Drawing then
                            label = Drawing.new("Text")
                            label.Color = color
                            label.Size = s.isHotspot and 14 or 12
                            label.Center = true
                            label.Outline = true
                            label.OutlineColor = Color3.fromRGB(0,0,0)
                            label.Font = Drawing.Fonts.UI
                            label.ZIndex = 11
                            label.Visible = false
                        end
                        d = { line = line, label = label, part = s.part }
                        HotspotRuntime.MiningDrawings[s.instance] = d
                    else
                        if d.line then d.line.Color = color end
                        if d.label then d.label.Color = color end
                    end
                    local screenPos, onScreen = cam:WorldToViewportPoint(wp)
                    if screenPos.Z > 0 then
                        if HotspotSettings.MiningTracer then
                            UpdateTracerLine(d.line, origin, Vector2.new(screenPos.X, screenPos.Y), color,
                                s.isHotspot and 2 or 1.5)
                        else
                            SetTracerVisible(d.line, false)
                        end
                    else
                        SetTracerVisible(d.line, false)
                    end
                    if d.label then
                        if onScreen and screenPos.Z > 0 and not HotspotSettings.MiningChams then
                            d.label.Position = Vector2.new(screenPos.X, screenPos.Y - 14)
                            d.label.Text = s.isHotspot
                                and string.format("HOTSPOT ORE %s (%dm)", slotStr, dist)
                                or  string.format("%s %s (%dm)", s.instance.Name, slotStr, dist)
                            d.label.Visible = true
                        else
                            d.label.Visible = false
                        end
                    end
                    if HotspotSettings.MiningChams then
                        local title = s.isHotspot
                            and string.format("HOTSPOT %s (%dm)", slotStr, dist)
                            or  string.format("%s %s (%dm)", s.instance.Name, slotStr, dist)
                        local ex = HotspotRuntime.Highlights[s.instance]
                        if not ex or not ex.hl or not ex.hl.Parent then
                            CreateESPChams(s.instance, title, color, s.isHotspot)
                        else
                            pcall(function()
                                local lbl = ex.bb:FindFirstChildWhichIsA("TextLabel")
                                if lbl then lbl.Text = title end
                            end)
                        end
                    end
                end
            end
        end
        for inst, d in pairs(HotspotRuntime.MiningDrawings) do
            if not seen[inst] then
                if d.line then DestroyTracerLine(d.line) end
                if d.label then pcall(function() d.label:Remove() end) end
                RemoveESPChams(inst)
                HotspotRuntime.MiningDrawings[inst] = nil
            end
        end
    else
        ClearDrawingsTable(HotspotRuntime.MiningDrawings)
    end
end

function HotspotESP.Start()
    if HotspotRuntime.Thread then return end
    HotspotRuntime.Thread = task.spawn(function()
        while HotspotSettings.FishingEnabled or HotspotSettings.MiningEnabled do
            pcall(UpdateHotspotESP)
            RunService.RenderStepped:Wait()
        end
        ClearDrawingsTable(HotspotRuntime.FishingDrawings)
        ClearDrawingsTable(HotspotRuntime.MiningDrawings)
        ClearAllHighlights()
        HotspotRuntime.Thread = nil
    end)
end

function HotspotESP.Stop()
    HotspotSettings.FishingEnabled = false
    HotspotSettings.FishingChams   = false
    HotspotSettings.MiningEnabled  = false
    HotspotSettings.MiningChams    = false
    if HotspotRuntime.Thread then
        task.cancel(HotspotRuntime.Thread)
        HotspotRuntime.Thread = nil
    end
    ClearDrawingsTable(HotspotRuntime.FishingDrawings)
    ClearDrawingsTable(HotspotRuntime.MiningDrawings)
    ClearAllHighlights()
    for _, item in ipairs(HotspotRuntime.HiddenBBs) do
        pcall(function()
            if item.bb and item.bb.Parent then item.bb.Enabled = item.vis end
        end)
    end
    table.clear(HotspotRuntime.HiddenBBs)
    if HotspotRuntime.ChamsFolder and HotspotRuntime.ChamsFolder.Parent then
        pcall(function() HotspotRuntime.ChamsFolder:Destroy() end)
        HotspotRuntime.ChamsFolder = nil
    end
    local cf = workspace:FindFirstChild("Delirium_Hotspot_Chams")
    if cf then pcall(function() cf:Destroy() end) end
end

function HotspotESP.CheckActive()
    if HotspotSettings.FishingEnabled or HotspotSettings.MiningEnabled then HotspotESP.Start()
    else HotspotESP.Stop() end
end

-- ══════════════════════════════════════════════════════════════════
-- AUTO FAVORITE FISH
-- ══════════════════════════════════════════════════════════════════
local AutoFavFish = {}
local AutoFavFishSettings = {
    Mode = "By Rarity", MinRarity = "Rare",
    MinPrice = 100000, MinWeight = 50,
    UnfavoriteNonMatching = false,
    BatchSize = 4, BatchDelay = 0.12,
    RetryFailed = true, RetryDelay = 0.6,
}
local AutoFavFishRuntime = {
    IsBusy = false, ReplicaManager = nil, FavRemote = nil,
    FishContent = nil, StatusLabel = nil,
}
local RARITY_ORDER = {
    Common = 1, Uncommon = 2, Rare = 3, Epic = 4,
    Legend = 5, Mythic = 6, Ancient = 7,
}

local function AutoFavFish_Init()
    pcall(function()
        local rf = game:GetService("ReplicatedFirst")
        local mgr = rf:WaitForChild("Manager", 5)
        if mgr and mgr:FindFirstChild("ReplicaManager") then
            AutoFavFishRuntime.ReplicaManager = require(mgr.ReplicaManager)
        end
    end)
    pcall(function()
        AutoFavFishRuntime.FishContent = require(
            ReplicatedStorage:WaitForChild("Content", 5):WaitForChild("Fish", 5))
    end)
    pcall(function()
        local fns = ReplicatedStorage:FindFirstChild("GameRemoteFunctions")
        AutoFavFishRuntime.FavRemote = fns and fns:FindFirstChild("InventoryFishFavoriteFunction")
    end)
end

local function AutoFavFish_GetProfileFish()
    if not AutoFavFishRuntime.ReplicaManager then return nil end
    local ok, d = pcall(function()
        local r = AutoFavFishRuntime.ReplicaManager:GetPlayerData(LocalPlayer)
        return r and r.ProfileReplica and r.ProfileReplica.Data
    end)
    if not ok or not d then return nil end
    return d.Fish
end

local function AutoFavFish_GetRarity(fd)
    if fd.Rarity and type(fd.Rarity) == "string" then return fd.Rarity end
    local c = AutoFavFishRuntime.FishContent
    if not c or not fd.FishId then return "Common" end
    local info = c[fd.FishId]
    if info and info.Rarity then return info.Rarity end
    local low = string.lower(fd.FishId)
    for k, v in pairs(c) do
        if string.lower(tostring(k)) == low then
            if v and v.Rarity then return v.Rarity end
            break
        end
    end
    if string.find(low, "ancient")  then return "Ancient"  end
    if string.find(low, "mythic")   then return "Mythic"   end
    if string.find(low, "legend")   then return "Legend"   end
    if string.find(low, "epic")     then return "Epic"     end
    if string.find(low, "rare")     then return "Rare"     end
    if string.find(low, "uncommon") then return "Uncommon" end
    return "Common"
end

local function AutoFavFish_Matches(fd)
    if AutoFavFishSettings.Mode == "All" then return true end
    if AutoFavFishSettings.Mode == "By Rarity" then
        local r = AutoFavFish_GetRarity(fd)
        local mo = RARITY_ORDER[AutoFavFishSettings.MinRarity] or 1
        local fo = RARITY_ORDER[r] or 1
        return fo >= mo
    end
    if AutoFavFishSettings.Mode == "By Price" then
        return (fd.Price or 0) >= AutoFavFishSettings.MinPrice
    end
    if AutoFavFishSettings.Mode == "By Weight" then
        return (fd.Weight or 0) >= AutoFavFishSettings.MinWeight
    end
    return false
end

local function AutoFavFish_SetStatus(msg)
    local lbl = AutoFavFishRuntime.StatusLabel
    if not lbl then return end
    pcall(function() lbl:Set(msg) end)
end

local function AutoFavFish_FireBatch(uids)
    local results, finished, total = {}, 0, #uids
    for _, uid in ipairs(uids) do
        task.spawn(function()
            local ok, res = pcall(function() return AutoFavFishRuntime.FavRemote:InvokeServer(uid) end)
            results[uid] = ok and res == true
            finished += 1
        end)
    end
    local dl = os.clock() + 8
    while finished < total and os.clock() < dl do task.wait(0.02) end
    return results
end

function AutoFavFish.Run(unfavoriteAll)
    if AutoFavFishRuntime.IsBusy then
        Notify({ Title = "Auto Favorite", Message = "Already running, wait for it to finish.",
            Type = "warning", Duration = 3 })
        return
    end
    AutoFavFishRuntime.IsBusy = true
    AutoFavFish_SetStatus("Status: scanning...")
    task.spawn(function()
        if not AutoFavFishRuntime.ReplicaManager or not AutoFavFishRuntime.FavRemote then
            AutoFavFish_Init()
        end
        if not AutoFavFishRuntime.FavRemote then
            AutoFavFish_SetStatus("Status: remote not found")
            Notify({ Title = "Auto Favorite", Message = "InventoryFishFavoriteFunction not found.",
                Type = "error", Duration = 4 })
            AutoFavFishRuntime.IsBusy = false
            return
        end
        local table_ = AutoFavFish_GetProfileFish()
        if not table_ then
            AutoFavFish_SetStatus("Status: no profile data")
            Notify({ Title = "Auto Favorite", Message = "Could not read fish inventory.",
                Type = "error", Duration = 4 })
            AutoFavFishRuntime.IsBusy = false
            return
        end
        local toToggle = {}
        for uid, fd in pairs(table_) do
            if typeof(fd) == "table" and fd.FishId then
                local should
                if unfavoriteAll then should = false else should = AutoFavFish_Matches(fd) end
                local isFav = fd.Favorite == true
                if should ~= isFav then
                    if should then table.insert(toToggle, uid)
                    elseif unfavoriteAll or AutoFavFishSettings.UnfavoriteNonMatching then table.insert(toToggle, uid) end
                end
            end
        end
        if #toToggle == 0 then
            AutoFavFish_SetStatus("Status: nothing to change")
            Notify({ Title = "Auto Favorite", Message = "All fish already match the target state.",
                Type = "success", Duration = 3 })
            AutoFavFishRuntime.IsBusy = false
            return
        end
        Notify({ Title = "Auto Favorite",
            Message = string.format("Processing %d fish (batch %d)...", #toToggle, AutoFavFishSettings.BatchSize),
            Type = "info", Duration = 3 })
        local done, failed = 0, {}
        local bs = math.max(1, AutoFavFishSettings.BatchSize)
        local bd = AutoFavFishSettings.BatchDelay
        local total = #toToggle
        local bn = 0
        for bs_ = 1, total, bs do
            bn += 1
            local be = math.min(bs_ + bs - 1, total)
            local bu = {}
            for i = bs_, be do table.insert(bu, toToggle[i]) end
            AutoFavFish_SetStatus(string.format("Status: batch %d — %d / %d done", bn, math.min(bs_ - 1, total), total))
            local res = AutoFavFish_FireBatch(bu)
            for _, uid in ipairs(bu) do
                if res[uid] then done += 1 else table.insert(failed, uid) end
            end
            if bs_ + bs <= total then task.wait(bd) end
        end
        if AutoFavFishSettings.RetryFailed and #failed > 0 then
            AutoFavFish_SetStatus(string.format("Status: retrying %d failed...", #failed))
            task.wait(AutoFavFishSettings.RetryDelay)
            local still = 0
            for _, uid in ipairs(failed) do
                local ok, res = pcall(function() return AutoFavFishRuntime.FavRemote:InvokeServer(uid) end)
                if ok and res then done += 1 else still += 1 end
                task.wait(0.15)
            end
            failed = {}
            for _ = 1, still do table.insert(failed, true) end
        end
        local action = unfavoriteAll and "Unfavorited" or "Favorited"
        local msg = string.format("%s %d / %d fish. Failed: %d", action, done, total, #failed)
        AutoFavFish_SetStatus("Status: done — " .. msg)
        Notify({ Title = "Auto Favorite", Message = msg,
            Type = #failed > 0 and "warning" or "success", Duration = 5 })
        AutoFavFishRuntime.IsBusy = false
    end)
end

-- ══════════════════════════════════════════════════════════════════
-- AUTO FAVORITE ORE
-- ══════════════════════════════════════════════════════════════════
local AutoFavOre = {}
local AutoFavOreSettings = {
    Mode = "By Rarity",        -- "All" | "By Rarity" | "By Density"
    MinRarity = "Rare",        -- minimum rarity to favorite
    MinDensity = 50,           -- minimum density to favorite (when Mode == "By Density")
    UnfavoriteNonMatching = false,
    BatchSize = 4,
    BatchDelay = 0.12,
    RetryFailed = true,
    RetryDelay = 0.6,
}
local AutoFavOreRuntime = {
    IsBusy = false, ReplicaManager = nil, FavRemote = nil,
    OreContent = nil, StatusLabel = nil,
}
local ORE_RARITY_ORDER = {
    Common = 1, Uncommon = 2, Rare = 3, Epic = 4,
    Legend = 5, Mythic = 6, Ancient = 7,
}

local function AutoFavOre_Init()
    pcall(function()
        local rf = game:GetService("ReplicatedFirst")
        local mgr = rf:WaitForChild("Manager", 5)
        if mgr and mgr:FindFirstChild("ReplicaManager") then
            AutoFavOreRuntime.ReplicaManager = require(mgr.ReplicaManager)
        end
    end)
    pcall(function()
        local cont = ReplicatedStorage:FindFirstChild("Content")
        if cont and cont:FindFirstChild("Ore") then
            AutoFavOreRuntime.OreContent = require(cont.Ore)
        end
    end)
    pcall(function()
        local fns = ReplicatedStorage:FindFirstChild("GameRemoteFunctions")
        AutoFavOreRuntime.FavRemote = fns and fns:FindFirstChild("InventoryOreFavoriteFunction")
    end)
end

local function AutoFavOre_GetProfileOres()
    if not AutoFavOreRuntime.ReplicaManager then return nil end
    local ok, d = pcall(function()
        local r = AutoFavOreRuntime.ReplicaManager:GetPlayerData(LocalPlayer)
        return r and r.ProfileReplica and r.ProfileReplica.Data
    end)
    if not ok or not d then return nil end
    return d.Ore
end

local function AutoFavOre_GetRarity(od)
    if od.Rarity and type(od.Rarity) == "string" then return od.Rarity end
    local c = AutoFavOreRuntime.OreContent
    if not c or not od.OreId then return "Common" end
    local info = c[od.OreId]
    if info and info.Rarity then return info.Rarity end
    local low = string.lower(tostring(od.OreId))
    if string.find(low, "ancient")  then return "Ancient"  end
    if string.find(low, "mythic")   then return "Mythic"   end
    if string.find(low, "legend")   then return "Legend"   end
    if string.find(low, "epic")     then return "Epic"     end
    if string.find(low, "rare")     then return "Rare"     end
    if string.find(low, "uncommon") then return "Uncommon" end
    return "Common"
end

local function AutoFavOre_Matches(od)
    if AutoFavOreSettings.Mode == "All" then return true end
    if AutoFavOreSettings.Mode == "By Rarity" then
        local r = AutoFavOre_GetRarity(od)
        local mo = ORE_RARITY_ORDER[AutoFavOreSettings.MinRarity] or 1
        local fo = ORE_RARITY_ORDER[r] or 1
        return fo >= mo
    end
    if AutoFavOreSettings.Mode == "By Density" then
        return (od.Density or 0) >= AutoFavOreSettings.MinDensity
    end
    return false
end

local function AutoFavOre_SetStatus(msg)
    local lbl = AutoFavOreRuntime.StatusLabel
    if lbl then pcall(function() lbl:Set(msg) end) end
end

local function AutoFavOre_FireBatch(uids)
    local results = {}
    for _, uid in ipairs(uids) do
        local fav = results[uid]  -- placeholder
        local ok, res = pcall(function()
            return AutoFavOreRuntime.FavRemote:InvokeServer(uid)
        end)
        results[uid] = { ok = ok, res = res }
        task.wait(0.04)
    end
    return results
end

function AutoFavOre.Run(unfavoriteAll)
    if AutoFavOreRuntime.IsBusy then
        AutoFavOre_SetStatus("Status: masih berjalan...")
        return
    end
    AutoFavOreRuntime.IsBusy = true
    AutoFavOre_SetStatus("Status: scanning...")

    if not AutoFavOreRuntime.ReplicaManager or not AutoFavOreRuntime.FavRemote then
        AutoFavOre_Init()
    end
    if not AutoFavOreRuntime.FavRemote then
        AutoFavOre_SetStatus("Status: remote tidak ditemukan")
        AutoFavOreRuntime.IsBusy = false
        return
    end

    local ores = AutoFavOre_GetProfileOres()
    if not ores then
        AutoFavOre_SetStatus("Status: data profil tidak ada")
        AutoFavOreRuntime.IsBusy = false
        return
    end

    local toFav, toUnfav = {}, {}
    for uid, od in pairs(ores) do
        if typeof(od) == "table" then
            local should = unfavoriteAll and false or AutoFavOre_Matches(od)
            if should and not od.Favorite then
                table.insert(toFav, uid)
            elseif not should and od.Favorite
                and (unfavoriteAll or AutoFavOreSettings.UnfavoriteNonMatching) then
                table.insert(toUnfav, uid)
            end
        end
    end

    local toToggle = {}
    for _, uid in ipairs(toFav)   do table.insert(toToggle, uid) end
    for _, uid in ipairs(toUnfav) do table.insert(toToggle, uid) end

    if #toToggle == 0 then
        AutoFavOre_SetStatus("Status: tidak ada yang perlu diubah")
        AutoFavOreRuntime.IsBusy = false
        return
    end

    AutoFavOre_SetStatus(string.format("Status: memproses %d ore...", #toToggle))
    local bs = math.max(1, AutoFavOreSettings.BatchSize)
    local bd = AutoFavOreSettings.BatchDelay
    local failed, bn = {}, 0

    for i = 1, #toToggle, bs do
        bn = bn + 1
        local batch = {}
        for j = i, math.min(i + bs - 1, #toToggle) do
            table.insert(batch, toToggle[j])
        end
        AutoFavOre_SetStatus(string.format("Status: batch %d — %d / %d selesai",
            bn, math.min(i + bs - 1, #toToggle), #toToggle))
        local res = AutoFavOre_FireBatch(batch)
        for uid, r in pairs(res) do
            if not r.ok or r.res == false then table.insert(failed, uid) end
        end
        task.wait(bd)
    end

    if AutoFavOreSettings.RetryFailed and #failed > 0 then
        AutoFavOre_SetStatus(string.format("Status: retry %d gagal...", #failed))
        task.wait(AutoFavOreSettings.RetryDelay)
        for _, uid in ipairs(failed) do
            pcall(function() AutoFavOreRuntime.FavRemote:InvokeServer(uid) end)
            task.wait(0.05)
        end
    end

    local msg = string.format("%d diubah", #toToggle - #failed)
    if #failed > 0 then msg = msg .. string.format(", %d gagal", #failed) end
    AutoFavOre_SetStatus("Status: selesai — " .. msg)
    Notify({ Title = "Auto Favorite Ore", Message = msg,
        Type = #failed > 0 and "warning" or "success", Duration = 4 })
    AutoFavOreRuntime.IsBusy = false
end

task.defer(AutoFavOre_Init)

-- ══════════════════════════════════════════════════════════════════
-- SAVEMANAGER BOOT (mirror example.client.luau)
-- ══════════════════════════════════════════════════════════════════
local SaveManager = Delirium.SaveManager
assert(SaveManager, "[Indo Voice] Delirium.SaveManager missing")

-- SetFolder + Load BEFORE CreateWindow so persisted values apply
-- via _pendingLoad when Register() fires on each widget below.
SaveManager:SetFolder("IndoVoice")
SaveManager:Load()

-- ══════════════════════════════════════════════════════════════════
-- WINDOW (Delirium API.md)
-- ══════════════════════════════════════════════════════════════════
local Window = Delirium:CreateWindow({
    name     = "Indo Voice",
    subtitle = "Delirium Team v1.0",
    theme    = "Default",
})
ActiveWindow = Window

local TabMain     = Window:CreateTab({ name = "Main",     columns = 2, icon = "lucide:home" })
local TabFishing  = Window:CreateTab({ name = "Fishing",  columns = 2, icon = "lucide:fish" })
local TabMining   = Window:CreateTab({ name = "Mining",   columns = 2, icon = "lucide:pickaxe" })
local TabRefining = Window:CreateTab({ name = "Refining", columns = 2, icon = "lucide:flame" })
local TabMisc     = Window:CreateTab({ name = "Misc",     columns = 2, icon = "lucide:settings" })
local TabSystem   = Window:CreateTab({ name = "System",   columns = 2, icon = "lucide:cog" })

-- ══════════════════════════════════════════════════════════════════
-- MAIN TAB
-- ══════════════════════════════════════════════════════════════════
TabMain.Left:CreateSection({ name = "Auto Claim" })

local IV_ClaimDaily = TabMain.Left:CreateToggle({
    name = "Auto Claim Daily", value = true, flag = "iv_claim_daily",
    callback = function(v)
        ClaimSettings.AutoClaimDaily = v
        UpdateClaimLoop()
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_claim_daily", function(v) IV_ClaimDaily:Set(v, true) end)

local IV_ClaimSession = TabMain.Left:CreateToggle({
    name = "Auto Claim Session", value = true, flag = "iv_claim_session",
    callback = function(v)
        ClaimSettings.AutoClaimSession = v
        UpdateClaimLoop()
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_claim_session", function(v) IV_ClaimSession:Set(v, true) end)

TabMain.Left:CreateSection({ name = "" })
TabMain.Left:CreateButton({
    name = "Claim All Now",
    callback = function()
        local any = false
        if TryClaimDaily() then
            any = true
            Notify({ Title = "Claimed", Message = "Daily reward claimed!", Type = "success", Duration = 3 })
        end
        if TryClaimSession() then
            any = true
            Notify({ Title = "Claimed", Message = "Session reward claimed!", Type = "success", Duration = 3 })
        end
        if not any then
            Notify({ Title = "Auto Claim", Message = "Nothing to claim right now.", Type = "warning", Duration = 3 })
        end
    end,
})

TabMain.Right:CreateSection({ name = "Anti-AFK & Bypass" })

local IV_AntiAFK = TabMain.Right:CreateToggle({
    name = "Anti-AFK", value = true, flag = "iv_anti_afk",
    callback = function(v)
        if v then AntiAFK.Start() else AntiAFK.Stop() end
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_anti_afk", function(v) IV_AntiAFK:Set(v, true) end)

local IV_TPBypass = TabMain.Right:CreateToggle({
    name = "Bypass Ingame TP", value = true, flag = "iv_tp_bypass",
    callback = function(v)
        TPBypassSettings.BypassInGameMenu = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_tp_bypass", function(v) IV_TPBypass:Set(v, true) end)

TabMain.Right:CreateLabel({
    text = "<b>Teleport Bypass</b>\nBypasses friend lock. Clicking 'Teleport' on ANY player in-game will work.",
})

-- ══════════════════════════════════════════════════════════════════
-- FISHING TAB
-- ══════════════════════════════════════════════════════════════════
local NoclipToggle
local function AutoNoclip_Sync()
    local should = Settings.Fishing.Enabled or Settings.Mining.Enabled
    MiscSystem.SetNoclip(should)
    if NoclipToggle then pcall(function() NoclipToggle:Set(should) end) end
end

TabFishing.Left:CreateSection({ name = "Automation" })

local IV_FishingEnabled = TabFishing.Left:CreateToggle({
    name = "Auto Fishing", value = false, flag = "iv_fishing_enabled",
    callback = function(v)
        Settings.Fishing.Enabled = v
        if v then FishingSystem.Start() else FishingSystem.Stop() end
        AutoNoclip_Sync()
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_fishing_enabled", function(v) IV_FishingEnabled:Set(v, true) end)

local IV_FishingAutoEquip = TabFishing.Left:CreateToggle({
    name = "Auto Equip Rod", value = Settings.Fishing.AutoEquipRod, flag = "iv_fishing_autoequip",
    callback = function(v)
        Settings.Fishing.AutoEquipRod = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_fishing_autoequip", function(v) IV_FishingAutoEquip:Set(v, true) end)

TabFishing.Left:CreateSection({ name = "" })
local FishCaughtLabel = TabFishing.Left:CreateLabel({ text = "Fish Caught: 0" })
FishingSystem.OnFishCaught = function(count)
    if FishCaughtLabel then pcall(function() FishCaughtLabel:Set("Fish Caught: " .. tostring(count)) end) end
end
TabFishing.Left:CreateButton({
    name = "Reset Stats",
    callback = function()
        Settings.Fishing.TotalFishCaught = 0
        if FishingSystem.OnFishCaught then FishingSystem.OnFishCaught(0) end
    end,
})

TabFishing.Left:CreateSection({ name = "ESP" })

local IV_FishingESP = TabFishing.Left:CreateToggle({
    name = "Fishing ESP", value = false, flag = "iv_fishing_esp_enabled",
    callback = function(v)
        HotspotSettings.FishingEnabled = v
        if v then HotspotESP.Start()
        else
            ClearDrawingsTable(HotspotRuntime.FishingDrawings)
            for _, z in ipairs(GetFishingZones()) do RemoveESPChams(z.instance) end
            if HotspotRuntime.Thread and not HotspotSettings.MiningEnabled then
                task.cancel(HotspotRuntime.Thread)
                HotspotRuntime.Thread = nil
            end
        end
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_fishing_esp_enabled", function(v) IV_FishingESP:Set(v, true) end)

local IV_FishingTracer = TabFishing.Left:CreateToggle({
    name = "  Tracer", value = true, flag = "iv_fishing_tracer",
    callback = function(v)
        HotspotSettings.FishingTracer = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_fishing_tracer", function(v) IV_FishingTracer:Set(v, true) end)

local IV_FishingChams = TabFishing.Left:CreateToggle({
    name = "  Chams", value = false, flag = "iv_fishing_chams",
    callback = function(v)
        local prev = HotspotSettings.FishingChams
        HotspotSettings.FishingChams = v
        if prev and not v then
            for _, z in ipairs(GetFishingZones()) do RemoveESPChams(z.instance) end
        end
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_fishing_chams", function(v) IV_FishingChams:Set(v, true) end)

local IV_FishingOnlyHotspots = TabFishing.Left:CreateToggle({
    name = "  Only Hotspots", value = false, flag = "iv_fishing_only_hotspots",
    callback = function(v)
        HotspotSettings.FishingOnlyHotspot = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_fishing_only_hotspots", function(v) IV_FishingOnlyHotspots:Set(v, true) end)

local IV_FishingESPMaxDist = TabFishing.Left:CreateSlider({
    name = "Max Distance (ESP)", min = 505, max = 4000, step = 50,
    value = 2000, flag = "iv_fishing_esp_max_dist",
    callback = function(v)
        HotspotSettings.FishingMaxDist = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_fishing_esp_max_dist", function(v) IV_FishingESPMaxDist:Set(v, true) end)

TabFishing.Left:CreateButton({
    name = "TP to Nearest Fishing Spot",
    callback = function() HotspotESP.TeleportToNearestFishing(false) end,
})
TabFishing.Left:CreateButton({
    name = "TP to Active Hotspot",
    callback = function() HotspotESP.TeleportToNearestFishing(true) end,
})

TabFishing.Right:CreateSection({ name = "Configuration" })

local IV_FishingCastMethod = TabFishing.Right:CreateDropdown({
    name = "Cast Method", flag = "iv_fishing_cast_method",
    options = { { Label = "Legit", Value = "Legit" }, { Label = "Blatant", Value = "Blatant" } },
    value = "Legit",
    callback = function(v)
        Settings.Fishing.CastMethod = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_fishing_cast_method", function(v) IV_FishingCastMethod:Set(v, true) end)

local IV_FishingCatchMethod = TabFishing.Right:CreateDropdown({
    name = "Catch Method", flag = "iv_fishing_catch_method",
    options = { { Label = "Legit", Value = "Legit" }, { Label = "Blatant", Value = "Blatant" } },
    value = "Legit",
    callback = function(v)
        Settings.Fishing.CatchMethod = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_fishing_catch_method", function(v) IV_FishingCatchMethod:Set(v, true) end)

local IV_FishingHoldDuration = TabFishing.Right:CreateSlider({
    name = "Cast Hold", min = 0.1, max = 2.0, step = 0.1,
    value = Settings.Fishing.CastHoldDuration, flag = "iv_fishing_hold_duration",
    callback = function(v)
        Settings.Fishing.CastHoldDuration = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_fishing_hold_duration", function(v) IV_FishingHoldDuration:Set(v, true) end)

local IV_FishingBlatantDelay = TabFishing.Right:CreateSlider({
    name = "Blatant Catch Delay (s)", min = 3.8, max = 10.0, step = 0.1,
    value = Settings.Fishing.BlatantCatchDelay, flag = "iv_fishing_blatant_catch_delay",
    callback = function(v)
        Settings.Fishing.BlatantCatchDelay = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_fishing_blatant_catch_delay", function(v) IV_FishingBlatantDelay:Set(v, true) end)

local IV_FishingCastDelay = TabFishing.Right:CreateSlider({
    name = "Cast Delay After Catch (s)", min = 0, max = 3.0, step = 0.1,
    value = Settings.Fishing.CastDelay, flag = "iv_fishing_cast_delay",
    callback = function(v)
        Settings.Fishing.CastDelay = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_fishing_cast_delay", function(v) IV_FishingCastDelay:Set(v, true) end)

local IV_FishingCPS = TabFishing.Right:CreateSlider({
    name = "Click per Second", min = 1, max = 12, step = 1,
    value = Settings.Fishing.ClickSpeedCPS, flag = "iv_fishing_cps",
    callback = function(v)
        Settings.Fishing.ClickSpeedCPS = v
        Settings.Fishing.ClickInterval = 1 / math.max(v, 1)
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_fishing_cps", function(v) IV_FishingCPS:Set(v, true) end)

TabFishing.Right:CreateLabel({
    text = "<b>Information</b>\nCast Hold slider affects Blatant cast power — max it when using Blatant cast.",
})

-- Auto Favorite Fish section (right column)
TabFishing.Right:CreateSection({ name = "Auto Favorite Fish (BETA)" })

local IV_AutoFavMode = TabFishing.Right:CreateDropdown({
    name = "Mode", flag = "iv_autofav_mode",
    options = {
        { Label = "All Fish",   Value = "All" },
        { Label = "By Rarity",  Value = "By Rarity" },
        { Label = "By Price",   Value = "By Price" },
        { Label = "By Weight",  Value = "By Weight" },
    },
    value = "By Rarity",
    callback = function(v)
        AutoFavFishSettings.Mode = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_autofav_mode", function(v) IV_AutoFavMode:Set(v, true) end)

local IV_AutoFavMinRarity = TabFishing.Right:CreateDropdown({
    name = "Min Rarity", flag = "iv_autofav_min_rarity",
    options = {"Common","Uncommon","Rare","Epic","Legend","Mythic","Ancient"},
    value = "Rare",
    callback = function(v)
        AutoFavFishSettings.MinRarity = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_autofav_min_rarity", function(v) IV_AutoFavMinRarity:Set(v, true) end)

local IV_AutoFavMinPrice = TabFishing.Right:CreateSlider({
    name = "Min Price (x1000 RP)", min = 0, max = 5000, step = 10,
    value = 100, flag = "iv_autofav_min_price",
    callback = function(v)
        AutoFavFishSettings.MinPrice = v * 1000
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_autofav_min_price", function(v) IV_AutoFavMinPrice:Set(v, true) end)

local IV_AutoFavMinWeight = TabFishing.Right:CreateSlider({
    name = "Min Weight (kg)", min = 0, max = 500, step = 5,
    value = 50, flag = "iv_autofav_min_weight",
    callback = function(v)
        AutoFavFishSettings.MinWeight = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_autofav_min_weight", function(v) IV_AutoFavMinWeight:Set(v, true) end)

local IV_AutoFavUnfav = TabFishing.Right:CreateToggle({
    name = "Unfavorite Non-Matching", value = false, flag = "iv_autofav_unfav_nonmatch",
    callback = function(v)
        AutoFavFishSettings.UnfavoriteNonMatching = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_autofav_unfav_nonmatch", function(v) IV_AutoFavUnfav:Set(v, true) end)

AutoFavFishRuntime.StatusLabel = TabFishing.Right:CreateLabel({ text = "Status: idle" })
TabFishing.Right:CreateButton({
    name = "Apply Favorite Now",
    callback = function() AutoFavFish.Run(false) end,
})
TabFishing.Right:CreateButton({
    name = "Unfavorite All Fish",
    callback = function() AutoFavFish.Run(true) end,
})
task.defer(AutoFavFish_Init)

-- Fish Rarity Filter section (right column, Blatant-mode only)
TabFishing.Right:CreateSection({ name = "Filter Rarity Ikan (Blatant)" })

local IV_FishFilterRarity = TabFishing.Right:CreateToggle({
    name = "Filter by Rarity", value = false, flag = "iv_fish_filter_rarity",
    callback = function(v)
        Settings.Fishing.FilterByRarity = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_fish_filter_rarity", function(v) IV_FishFilterRarity:Set(v, true) end)

local IV_FishFilterMinRarity = TabFishing.Right:CreateDropdown({
    name = "Min Rarity", flag = "iv_fish_filter_min_rarity",
    options = {"Common","Uncommon","Rare","Epic","Legend","Mythic","Ancient"},
    value = "Rare",
    callback = function(v)
        Settings.Fishing.MinRarity = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_fish_filter_min_rarity", function(v) IV_FishFilterMinRarity:Set(v, true) end)

local IV_FishFilterUnspecified = TabFishing.Right:CreateToggle({
    name = "Izinkan Rarity Tidak Diketahui", value = true, flag = "iv_fish_filter_allow_unspecified",
    callback = function(v)
        Settings.Fishing.AllowUnspecified = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_fish_filter_allow_unspecified", function(v) IV_FishFilterUnspecified:Set(v, true) end)

TabFishing.Right:CreateLabel({
    text = "<b>Filter Rarity Ikan</b>\nHanya aktif di Blatant mode. Ikan di bawah min rarity langsung di-skip tanpa fire remote Catch.",
})

-- Auto Sell Fish section (left column add-on)
TabFishing.Left:CreateSection({ name = "Auto Sell Fish" })

local IV_AutoSellFish = TabFishing.Left:CreateToggle({
    name = "Auto Sell Fish", value = false, flag = "iv_autosell_fish",
    callback = function(v)
        AutoSellSettings.FishEnabled = v
        if v then AutoSell.StartFishLoop() else AutoSell.StopFishLoop() end
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_autosell_fish", function(v) IV_AutoSellFish:Set(v, true) end)

local IV_AutoSellFishShop = TabFishing.Left:CreateDropdown({
    name = "Shop", flag = "iv_autosell_fish_shop",
    options = {"FishShop", "FishBroker"},
    value = "FishShop",
    callback = function(v)
        AutoSellSettings.FishShopType = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_autosell_fish_shop", function(v) IV_AutoSellFishShop:Set(v, true) end)

local IV_AutoSellFishTiers = TabFishing.Left:CreateDropdown({
    name = "Tier yang Dijual (Fish)", flag = "iv_autosell_fish_tiers",
    options = {"Ancient","Mythic","Legend","Epic","Rare","Uncommon","Common"},
    value = {"Ancient","Mythic","Legend","Epic","Rare","Uncommon","Common"},
    multiSelect = true,
    callback = function(v)
        AutoSellSettings.FishSellTiers = (type(v) == "table" and #v > 0) and v or SELL_TIERS_ALL
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_autosell_fish_tiers", function(v) IV_AutoSellFishTiers:Set(v, true) end)

local IV_AutoSellFishTrigger = TabFishing.Left:CreateSlider({
    name = "Trigger (ikan)", min = 0, max = 1200, step = 10,
    value = AutoSellSettings.FishTrigger, flag = "iv_autosell_fish_trigger",
    callback = function(v)
        AutoSellSettings.FishTrigger = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_autosell_fish_trigger", function(v) IV_AutoSellFishTrigger:Set(v, true) end)

local IV_AutoSellFishReturn = TabFishing.Left:CreateToggle({
    name = "Balik ke spot setelah sell", value = true, flag = "iv_autosell_fish_return",
    callback = function(v)
        AutoSellSettings.ReturnAfterSell = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_autosell_fish_return", function(v) IV_AutoSellFishReturn:Set(v, true) end)

TabFishing.Left:CreateButton({
    name = "Sell Fish Sekarang",
    callback = function() task.spawn(AutoSell_DoFish) end,
})

-- ══════════════════════════════════════════════════════════════════
-- MINING TAB
-- ══════════════════════════════════════════════════════════════════
TabMining.Left:CreateSection({ name = "Automation" })

local IV_MiningEnabled = TabMining.Left:CreateToggle({
    name = "Auto Mining", value = false, flag = "iv_mining_enabled",
    callback = function(v)
        Settings.Mining.Enabled = v
        if v then MiningSystem.Start() else MiningSystem.Stop() end
        AutoNoclip_Sync()
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_mining_enabled", function(v) IV_MiningEnabled:Set(v, true) end)

local IV_MiningFullyAuto = TabMining.Left:CreateToggle({
    name = "Fully Auto (Underground Loop)", value = false, flag = "iv_mining_fully_auto",
    callback = function(v)
        Settings.Mining.FullyAuto = v
        if not v and Runtime.Mining.IsFloating then MiningSystem.DisableUndergroundFloat() end
        AutoNoclip_Sync()
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_mining_fully_auto", function(v) IV_MiningFullyAuto:Set(v, true) end)

local IV_MiningTargetFilter = TabMining.Left:CreateDropdown({
    name = "Target Stone Mode", flag = "iv_mining_target_filter",
    options = {
        { Label = "Hotspot Only", Value = "Hotspot Only" },
        { Label = "All Stones",   Value = "All Stones" },
    },
    value = "Hotspot Only",
    callback = function(v)
        Settings.Mining.TargetFilter = v
        Runtime.Mining.CurrentTargetStone = nil
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_mining_target_filter", function(v) IV_MiningTargetFilter:Set(v, true) end)

local IV_MiningUGDepth = TabMining.Left:CreateSlider({
    name = "Underground Depth (studs)", min = 5, max = 35, step = 0.5,
    value = 15, flag = "iv_mining_ug_depth",
    callback = function(v)
        Settings.Mining.UndergroundDepth = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_mining_ug_depth", function(v) IV_MiningUGDepth:Set(v, true) end)

local IV_MiningAutoEquip = TabMining.Left:CreateToggle({
    name = "Auto Equip Pickaxe", value = Settings.Mining.AutoEquipPickaxe, flag = "iv_mining_autoequip",
    callback = function(v)
        Settings.Mining.AutoEquipPickaxe = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_mining_autoequip", function(v) IV_MiningAutoEquip:Set(v, true) end)

local IV_MiningFakeHitAnim = TabMining.Left:CreateToggle({
    name = "Fake Hit Animation", value = Settings.Mining.FakeHitAnimation, flag = "iv_mining_fake_hit_anim",
    callback = function(v)
        Settings.Mining.FakeHitAnimation = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_mining_fake_hit_anim", function(v) IV_MiningFakeHitAnim:Set(v, true) end)

local IV_MiningFakeHitCount = TabMining.Left:CreateSlider({
    name = "Repeat Count", min = 1, max = 10, step = 1, value = 1,
    enabled = false, flag = "iv_mining_fake_hit_count",
    callback = function(v)
        Settings.Mining.FakeHitRepeatCount = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_mining_fake_hit_count", function(v) IV_MiningFakeHitCount:Set(v, true) end)

local IV_MiningAutoWalk = TabMining.Left:CreateToggle({
    name = "Auto Walk ke Ore", value = false, flag = "iv_mining_auto_walk",
    callback = function(v)
        Settings.Mining.AutoWalk = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_mining_auto_walk", function(v) IV_MiningAutoWalk:Set(v, true) end)

TabMining.Left:CreateSection({ name = "" })
local MiningStatsLabel = TabMining.Left:CreateLabel({ text = "Mined: 0 | Failed: 0" })
MiningSystem.OnStatsUpdated = function(mined, failed)
    local str = string.format("Mined: %d | Failed: %d", mined, failed)
    if MiningStatsLabel then pcall(function() MiningStatsLabel:Set(str) end) end
end
TabMining.Left:CreateButton({
    name = "Reset Stats",
    callback = function()
        Settings.Mining.TotalMined = 0
        Settings.Mining.TotalFailed = 0
        if MiningSystem.OnStatsUpdated then MiningSystem.OnStatsUpdated(0, 0) end
    end,
})

TabMining.Left:CreateSection({ name = "Mining ESP" })

local IV_MiningESP = TabMining.Left:CreateToggle({
    name = "Mining Stone ESP", value = false, flag = "iv_mining_esp_enabled",
    callback = function(v)
        HotspotSettings.MiningEnabled = v
        if v then HotspotESP.Start()
        else
            ClearDrawingsTable(HotspotRuntime.MiningDrawings)
            for _, s in ipairs(GetMiningStones()) do RemoveESPChams(s.instance) end
            if HotspotRuntime.Thread and not HotspotSettings.FishingEnabled then
                task.cancel(HotspotRuntime.Thread)
                HotspotRuntime.Thread = nil
            end
        end
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_mining_esp_enabled", function(v) IV_MiningESP:Set(v, true) end)

local IV_MiningTracer = TabMining.Left:CreateToggle({
    name = "  Tracer", value = true, flag = "iv_mining_tracer",
    callback = function(v)
        HotspotSettings.MiningTracer = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_mining_tracer", function(v) IV_MiningTracer:Set(v, true) end)

local IV_MiningChams = TabMining.Left:CreateToggle({
    name = "  Chams", value = false, flag = "iv_mining_chams",
    callback = function(v)
        local prev = HotspotSettings.MiningChams
        HotspotSettings.MiningChams = v
        if prev and not v then
            for _, s in ipairs(GetMiningStones()) do RemoveESPChams(s.instance) end
        end
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_mining_chams", function(v) IV_MiningChams:Set(v, true) end)

local IV_MiningOnlyHotspots = TabMining.Left:CreateToggle({
    name = "  Only Hotspot Ores", value = false, flag = "iv_mining_only_hotspots",
    callback = function(v)
        HotspotSettings.MiningOnlyHotspot = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_mining_only_hotspots", function(v) IV_MiningOnlyHotspots:Set(v, true) end)

local IV_MiningESPMaxDist = TabMining.Left:CreateSlider({
    name = "Max Distance (ESP)", min = 500, max = 4000, step = 50,
    value = 2000, flag = "iv_mining_esp_max_dist",
    callback = function(v)
        HotspotSettings.MiningMaxDist = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_mining_esp_max_dist", function(v) IV_MiningESPMaxDist:Set(v, true) end)

TabMining.Left:CreateButton({
    name = "TP to Nearest Ore",
    callback = function() HotspotESP.TeleportToNearestMining(false) end,
})
TabMining.Left:CreateButton({
    name = "TP to Hotspot Ore",
    callback = function() HotspotESP.TeleportToNearestMining(true) end,
})
TabMining.Left:CreateButton({
    name = "TP to Underground Middle",
    callback = function()
        local hrp = Utils.GetHumanoidRootPart()
        if not hrp then return end
        local midCF = CFrame.new(570, -30, -5020)
        MiningSystem.EnableUndergroundFloat(midCF)
        Notify({ Title = "Teleport", Message = "Teleported to underground middle cave.", Type = "info", Duration = 2 })
    end,
})

TabMining.Right:CreateSection({ name = "Configuration" })

local IV_MiningBlatantHitDelay = TabMining.Right:CreateSlider({
    name = "Blatant Hit Delay (s)", min = 4, max = 10, step = 0.1,
    value = Settings.Mining.BlatantHitDelay, flag = "iv_mining_blatant_hit_delay",
    callback = function(v)
        Settings.Mining.BlatantHitDelay = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_mining_blatant_hit_delay", function(v) IV_MiningBlatantHitDelay:Set(v, true) end)

local IV_MiningMethod = TabMining.Right:CreateDropdown({
    name = "Mine Method", flag = "iv_mining_method",
    options = { { Label = "Legit", Value = "Legit" }, { Label = "Blatant", Value = "Blatant" } },
    value = "Legit",
    callback = function(v)
        Settings.Mining.MineMethod = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_mining_method", function(v) IV_MiningMethod:Set(v, true) end)

local IV_MiningRadius = TabMining.Right:CreateSlider({
    name = "Radius", min = 5, max = 100, step = 1,
    value = Settings.Mining.SearchRadius, flag = "iv_mining_radius",
    callback = function(v)
        Settings.Mining.SearchRadius = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_mining_radius", function(v) IV_MiningRadius:Set(v, true) end)

local IV_MiningSafeZone = TabMining.Right:CreateSlider({
    name = "Click Zone", min = 1, max = 100, step = 10, value = 50, flag = "iv_mining_safezone",
    callback = function(v)
        Settings.Mining.SafeZonePercent = v / 100
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_mining_safezone", function(v) IV_MiningSafeZone:Set(v, true) end)

local IV_MiningLoopDelay = TabMining.Right:CreateSlider({
    name = "Loop Delay", min = 0, max = 5.0, step = 0.1,
    value = Settings.Mining.LoopDelay, flag = "iv_mining_loop_delay",
    callback = function(v)
        Settings.Mining.LoopDelay = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_mining_loop_delay", function(v) IV_MiningLoopDelay:Set(v, true) end)

TabMining.Right:CreateLabel({
    text = "<b>Mining Methods</b>\nLegit: auto drag & click.\nBlatant: bypasses everything, faster but riskier.",
})

-- Auto Sell Ore section
TabMining.Right:CreateSection({ name = "Auto Sell Ore" })

local IV_AutoSellOre = TabMining.Right:CreateToggle({
    name = "Auto Sell Ore", value = false, flag = "iv_autosell_ore",
    callback = function(v)
        AutoSellSettings.OreEnabled = v
        if v then AutoSell.StartOreLoop() else AutoSell.StopOreLoop() end
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_autosell_ore", function(v) IV_AutoSellOre:Set(v, true) end)

local IV_AutoSellOreTrigger = TabMining.Right:CreateSlider({
    name = "Trigger (ore)", min = 0, max = 1500, step = 10,
    value = AutoSellSettings.OreTrigger, flag = "iv_autosell_ore_trigger",
    callback = function(v)
        AutoSellSettings.OreTrigger = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_autosell_ore_trigger", function(v) IV_AutoSellOreTrigger:Set(v, true) end)

local IV_AutoSellOreFilter = TabMining.Right:CreateDropdown({
    name = "Sell Mode", flag = "iv_autosell_ore_filter",
    options = {
        { Label = "All Ore",       Value = "All" },
        { Label = "Refined Only",  Value = "Refined Only" },
        { Label = "Raw Only",      Value = "Raw Only" },
    },
    value = "All",
    callback = function(v)
        AutoSellSettings.OreFilterMode = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_autosell_ore_filter", function(v) IV_AutoSellOreFilter:Set(v, true) end)

local IV_AutoSellOreTiers = TabMining.Right:CreateDropdown({
    name = "Tier yang Dijual (Ore)", flag = "iv_autosell_ore_tiers",
    options = {"Ancient","Mythic","Legend","Epic","Rare","Uncommon","Common"},
    value = {"Ancient","Mythic","Legend","Epic","Rare","Uncommon","Common"},
    multiSelect = true,
    callback = function(v)
        AutoSellSettings.OreSellTiers = (type(v) == "table" and #v > 0) and v or SELL_TIERS_ALL
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_autosell_ore_tiers", function(v) IV_AutoSellOreTiers:Set(v, true) end)

TabMining.Right:CreateLabel({
    text = "<b>Auto Sell Ore</b>\nTP ke OreShop underground, jual ore (kecuali favorit), lalu kembali.",
})
TabMining.Right:CreateButton({
    name = "Sell Ore Sekarang",
    callback = function() task.spawn(AutoSell_DoOre) end,
})

-- Auto Favorite Ore section
TabMining.Right:CreateSection({ name = "Auto Favorite Ore" })

local IV_AutoFavOreMode = TabMining.Right:CreateDropdown({
    name = "Mode", flag = "iv_autofav_ore_mode",
    options = {
        { Label = "Semua Ore",    Value = "All" },
        { Label = "By Rarity",   Value = "By Rarity" },
        { Label = "By Density",  Value = "By Density" },
    },
    value = "By Rarity",
    callback = function(v)
        AutoFavOreSettings.Mode = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_autofav_ore_mode", function(v) IV_AutoFavOreMode:Set(v, true) end)

local IV_AutoFavOreMinRarity = TabMining.Right:CreateDropdown({
    name = "Min Rarity", flag = "iv_autofav_ore_min_rarity",
    options = {"Common","Uncommon","Rare","Epic","Legend","Mythic","Ancient"},
    value = "Rare",
    callback = function(v)
        AutoFavOreSettings.MinRarity = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_autofav_ore_min_rarity", function(v) IV_AutoFavOreMinRarity:Set(v, true) end)

local IV_AutoFavOreMinDensity = TabMining.Right:CreateSlider({
    name = "Min Density", min = 0, max = 500, step = 10,
    value = 50, flag = "iv_autofav_ore_min_density",
    callback = function(v)
        AutoFavOreSettings.MinDensity = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_autofav_ore_min_density", function(v) IV_AutoFavOreMinDensity:Set(v, true) end)

local IV_AutoFavOreUnfav = TabMining.Right:CreateToggle({
    name = "Unfavorite Non-Matching", value = false, flag = "iv_autofav_ore_unfav_nonmatch",
    callback = function(v)
        AutoFavOreSettings.UnfavoriteNonMatching = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_autofav_ore_unfav_nonmatch", function(v) IV_AutoFavOreUnfav:Set(v, true) end)

AutoFavOreRuntime.StatusLabel = TabMining.Right:CreateLabel({ text = "Status: idle" })
TabMining.Right:CreateButton({
    name = "Apply Favorite Sekarang",
    callback = function() task.spawn(function() AutoFavOre.Run(false) end) end,
})
TabMining.Right:CreateButton({
    name = "Unfavorite Semua Ore",
    callback = function() task.spawn(function() AutoFavOre.Run(true) end) end,
})

-- ══════════════════════════════════════════════════════════════════
-- REFINING TAB
-- ══════════════════════════════════════════════════════════════════
TabRefining.Left:CreateSection({ name = "Automation" })

local IV_RefiningAutoClaim = TabRefining.Left:CreateToggle({
    name = "Auto Collect Refined Ore", value = false, flag = "iv_refining_auto_claim",
    callback = function(v)
        RefiningSettings.AutoClaim = v
        RefiningSystem.CheckActive()
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_refining_auto_claim", function(v) IV_RefiningAutoClaim:Set(v, true) end)

local IV_RefiningAutoRefine = TabRefining.Left:CreateToggle({
    name = "Auto Start Refining", value = false, flag = "iv_refining_auto_refine",
    callback = function(v)
        RefiningSettings.AutoRefine = v
        RefiningSystem.CheckActive()
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_refining_auto_refine", function(v) IV_RefiningAutoRefine:Set(v, true) end)

TabRefining.Left:CreateSection({ name = "" })
local RefineStatsLabel = TabRefining.Left:CreateLabel({
    text = "Collected: 0 | Started: 0",
})
RefiningSystem.OnStatsUpdated = function()
    local str = string.format("Collected: %d | Started: %d",
        RefiningSettings.TotalClaimed, RefiningSettings.TotalStarted)
    if RefineStatsLabel then pcall(function() RefineStatsLabel:Set(str) end) end
end
TabRefining.Left:CreateButton({
    name = "Refine & Claim Now",
    callback = function()
        task.spawn(function()
            Notify({ Title = "Refining", Message = "Processing refinement cycle...",
                Type = "info", Duration = 2 })
            RefiningSystem.Init()
            RefiningSystem.ProcessCycle()
        end)
    end,
})
TabRefining.Left:CreateButton({
    name = "Reset Stats",
    callback = function()
        RefiningSettings.TotalClaimed = 0
        RefiningSettings.TotalStarted = 0
        if RefiningSystem.OnStatsUpdated then RefiningSystem.OnStatsUpdated() end
    end,
})
TabRefining.Left:CreateButton({
    name = "Open Refinement UI",
    callback = function()
        local g = LocalPlayer.PlayerGui:FindFirstChild("Refining")
        local fn = g and g:FindFirstChild("ShowFunction", true)
        if fn and fn:IsA("BindableFunction") then
            pcall(function() fn:Invoke() end)
        else
            Notify({ Title = "Refining", Message = "Refining UI not loaded yet",
                Type = "warning", Duration = 2 })
        end
    end,
})

TabRefining.Right:CreateSection({ name = "Configuration" })

local IV_RefiningPriority = TabRefining.Right:CreateDropdown({
    name = "Ore Priority Mode", flag = "iv_refining_priority",
    options = {
        { Label = "Highest Density (Best Stats)", Value = "Highest Density" },
        { Label = "Lowest Density (Cheap First)", Value = "Lowest Density" },
        { Label = "Random",                       Value = "Random" },
    },
    value = "Highest Density",
    callback = function(v)
        RefiningSettings.PriorityMode = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_refining_priority", function(v) IV_RefiningPriority:Set(v, true) end)

local IV_RefiningTiers = TabRefining.Right:CreateDropdown({
    name = "Tier yang Di-Refine", flag = "iv_refining_tiers",
    options = {"Ancient","Mythic","Legend","Epic","Rare","Uncommon","Common"},
    value = {"Ancient","Mythic","Legend","Epic","Rare","Uncommon","Common"},
    multiSelect = true,
    callback = function(v)
        RefiningSettings.RefineTiers = (type(v) == "table" and #v > 0)
            and v or {"Ancient","Mythic","Legend","Epic","Rare","Uncommon","Common"}
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_refining_tiers", function(v) IV_RefiningTiers:Set(v, true) end)

local IV_RefiningInterval = TabRefining.Right:CreateSlider({
    name = "Check Interval (s)", min = 1, max = 30, step = 1,
    value = 3, flag = "iv_refining_interval",
    callback = function(v)
        RefiningSettings.CheckInterval = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_refining_interval", function(v) IV_RefiningInterval:Set(v, true) end)

TabRefining.Right:CreateLabel({
    text = "<b>How Auto Refine Works</b>\nChecks unlocked refining slots, pairs 2 unrefined ores of identical type, starts refining. Auto-claims when ready.",
})

-- ══════════════════════════════════════════════════════════════════
-- MISC TAB
-- ══════════════════════════════════════════════════════════════════
TabMisc.Left:CreateSection({ name = "Social & Codes" })
TabMisc.Left:CreateButton({
    name = "Love All (Once)",
    callback = function() MiscSystem.GiveLoveToAll(true) end,
})

local IV_AutoLikeLoop = TabMisc.Left:CreateToggle({
    name = "Auto Love", value = false, flag = "iv_auto_like_loop",
    callback = function(v)
        MiscSettings.AutoLikeLoop = v
        if v then MiscSystem.StartAutoLikeLoop() else MiscSystem.StopAutoLikeLoop() end
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_auto_like_loop", function(v) IV_AutoLikeLoop:Set(v, true) end)

TabMisc.Left:CreateSection({ name = "" })
local enteredCode = ""
local IV_PromoCodeInput = TabMisc.Left:CreateInput({
    name = "Promo Code", placeholder = "Enter code...", value = "", flag = "iv_promo_code_input",
    callback = function(v)
        enteredCode = tostring(v or "")
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_promo_code_input", function(v) IV_PromoCodeInput:Set(v, true) end)

TabMisc.Left:CreateButton({
    name = "Redeem Code",
    callback = function()
        if enteredCode == "" then
            Notify({ Title = "Codes", Message = "Please enter a code first.",
                Type = "warning", Duration = 2 })
            return
        end
        if MiscSystem.RedeemCode(enteredCode) then
            Notify({ Title = "Codes", Message = "Code '" .. enteredCode .. "' redeemed!",
                Type = "success", Duration = 3 })
        else
            Notify({ Title = "Codes", Message = "Code '" .. enteredCode .. "' is invalid or used.",
                Type = "warning", Duration = 3 })
        end
    end,
})
TabMisc.Left:CreateButton({
    name = "Redeem All Known Codes",
    callback = function()
        Notify({ Title = "Codes", Message = "Redeeming all known codes...",
            Type = "info", Duration = 2 })
        local n = MiscSystem.RedeemAllKnownCodes()
        Notify({ Title = "Codes", Message = "Finished! Redeemed " .. n .. " codes.",
            Type = "success", Duration = 3 })
    end,
})

TabMisc.Right:CreateSection({ name = "Movement & Character" })

local IV_WalkSpeed = TabMisc.Right:CreateSlider({
    name = "Walk Speed", min = 16, max = 100, step = 1,
    value = 16, flag = "iv_walk_speed",
    callback = function(v)
        MiscSettings.WalkSpeed = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_walk_speed", function(v) IV_WalkSpeed:Set(v, true) end)

local IV_SpeedEnabled = TabMisc.Right:CreateToggle({
    name = "Speed Walk", value = false, flag = "iv_speed_enabled",
    callback = function(v)
        MiscSettings.SpeedEnabled = v
        if not v then
            local h = Utils.GetHumanoid()
            if h then h.WalkSpeed = 16 end
        end
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_speed_enabled", function(v) IV_SpeedEnabled:Set(v, true) end)

local IV_AutoRun = TabMisc.Right:CreateToggle({
    name = "Auto Run (Sprint)", value = false, flag = "iv_auto_run",
    callback = function(v)
        MiscSettings.AutoRun = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_auto_run", function(v) IV_AutoRun:Set(v, true) end)

TabMisc.Right:CreateSection({ name = "" })
local IV_JumpPower = TabMisc.Right:CreateSlider({
    name = "Jump Power", min = 50, max = 250, step = 5,
    value = 50, flag = "iv_jump_power",
    callback = function(v)
        MiscSettings.JumpPower = v
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_jump_power", function(v) IV_JumpPower:Set(v, true) end)

local IV_JumpEnabled = TabMisc.Right:CreateToggle({
    name = "Enable Jump Power", value = false, flag = "iv_jump_enabled",
    callback = function(v)
        MiscSettings.JumpEnabled = v
        if not v then
            local h = Utils.GetHumanoid()
            if h then h.UseJumpPower = false h.JumpPower = 50 end
        end
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_jump_enabled", function(v) IV_JumpEnabled:Set(v, true) end)

TabMisc.Right:CreateSection({ name = "" })
local IV_InfiniteJump = TabMisc.Right:CreateToggle({
    name = "Infinite Jump", value = false, flag = "iv_infinite_jump",
    callback = function(v)
        MiscSystem.SetInfiniteJump(v)
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_infinite_jump", function(v) IV_InfiniteJump:Set(v, true) end)

NoclipToggle = TabMisc.Right:CreateToggle({
    name = "Noclip", value = false, flag = "iv_noclip",
    callback = function(v)
        MiscSystem.SetNoclip(v)
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_noclip", function(v) NoclipToggle:Set(v, true) end)

TabMisc.Right:CreateSection({ name = "Performa" })

local IV_FPSBooster = TabMisc.Right:CreateToggle({
    name = "FPS Booster", value = false, flag = "iv_fps_booster",
    callback = function(v)
        MiscSystem.SetFPSBooster(v)
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_fps_booster", function(v) IV_FPSBooster:Set(v, true) end)

TabMisc.Right:CreateLabel({
    text = "<b>FPS Booster</b>\nMatikan shadow, fog, particles, dan post-effect. Otomatis restore saat dimatikan.",
})

-- Teleport Manager (left column, under Social & Codes)
TabMisc.Left:CreateSection({ name = "Teleport Manager" })
local TM_InputName = ""
local IV_TPWaypointName = TabMisc.Left:CreateInput({
    name = "Nama Waypoint", placeholder = "Ketik nama waypoint...",
    value = "", flag = "iv_tp_waypoint_name",
    callback = function(v)
        TM_InputName = tostring(v or "")
        SaveManager:_scheduleAutoSave()
    end,
})
SaveManager:Register("iv_tp_waypoint_name", function(v) IV_TPWaypointName:Set(v, true) end)

TabMisc.Left:CreateButton({
    name = "Simpan Posisi Sekarang",
    callback = function()
        if TM_InputName == "" then
            Notify({ Title = "Teleport Manager", Message = "Nama waypoint tidak boleh kosong.", Type = "warning", Duration = 2 })
            return
        end
        if TeleportManager.SaveWaypoint(TM_InputName) then
            Notify({ Title = "Teleport Manager",
                Message = "Waypoint '" .. TM_InputName .. "' disimpan.",
                Type = "success", Duration = 2 })
        end
    end,
})
TabMisc.Left:CreateButton({
    name = "TP ke Waypoint",
    callback = function()
        if TM_InputName == "" then
            Notify({ Title = "Teleport Manager", Message = "Masukkan nama waypoint terlebih dahulu.", Type = "warning", Duration = 2 })
            return
        end
        if TeleportManager.TeleportTo(TM_InputName) then
            Notify({ Title = "Teleport Manager",
                Message = "Teleported ke '" .. TM_InputName .. "'.",
                Type = "success", Duration = 2 })
        else
            Notify({ Title = "Teleport Manager",
                Message = "Waypoint '" .. TM_InputName .. "' tidak ditemukan.",
                Type = "error", Duration = 2 })
        end
    end,
})
TabMisc.Left:CreateButton({
    name = "Hapus Waypoint",
    callback = function()
        if TM_InputName == "" then
            Notify({ Title = "Teleport Manager", Message = "Masukkan nama waypoint terlebih dahulu.", Type = "warning", Duration = 2 })
            return
        end
        if TeleportManager.DeleteWaypoint(TM_InputName) then
            Notify({ Title = "Teleport Manager",
                Message = "Waypoint '" .. TM_InputName .. "' dihapus.",
                Type = "info", Duration = 2 })
        else
            Notify({ Title = "Teleport Manager",
                Message = "Waypoint '" .. TM_InputName .. "' tidak ditemukan.",
                Type = "error", Duration = 2 })
        end
    end,
})
TabMisc.Left:CreateButton({
    name = "Lihat Daftar Waypoint",
    callback = function()
        local names = TeleportManager.GetNames()
        if #names == 0 then
            Notify({ Title = "Teleport Manager", Message = "Belum ada waypoint tersimpan.", Type = "info", Duration = 3 })
        else
            Notify({ Title = "Teleport Manager (" .. #names .. " waypoint)",
                Message = table.concat(names, ", "),
                Type = "info", Duration = 5 })
        end
    end,
})

-- ══════════════════════════════════════════════════════════════════
-- SYSTEM TAB
-- ══════════════════════════════════════════════════════════════════
TabSystem.Left:CreateSection({ name = "Configuration" })
TabSystem.Left:CreateLabel({
    text = "<b>Indo Voice</b>\nScript made by Delirium Team v1.0\n\n"
        .. "Save, load, delete and auto-save profiles via the "
        .. "<b>Config</b> tab (built by SaveManager).",
})

TabSystem.Right:CreateSection({ name = "Unload" })
TabSystem.Right:CreateLabel({
    text = "Stops all automations, disconnects events, resets character mods, and closes the UI.",
})

local function IndoVoice_Unload()
    pcall(function()
        Settings.Fishing.Enabled = false
        FishingSystem.Stop()
        FishingSystem.ResetSession()
        FishingSystem.UnhookRodEvents()
        if Runtime.Fishing.ActiveRod then
            pcall(function() Runtime.Fishing.ActiveRod:SetAttribute("_IVRodHooked", nil) end)
            Runtime.Fishing.ActiveRod = nil
        end
    end)
    pcall(function()
        Settings.Mining.Enabled = false
        Settings.Mining.FullyAuto = false
        MiningSystem.Stop()
        MiningSystem.DisableUndergroundFloat()
        MiningSystem.ResetSession()
        MiningSystem.UnhookPickaxeEvents()
        Runtime.Mining.HookedPickaxe = nil
    end)
    pcall(function()
        RefiningSettings.AutoClaim = false
        RefiningSettings.AutoRefine = false
        RefiningSystem.Stop()
    end)
    pcall(function() HotspotESP.Stop() end)
    pcall(function() MiscSystem.Stop() end)
    pcall(function() AntiAFK.Stop() end)
    pcall(function() AutoClaim.Stop() end)
    pcall(function()
        AutoSell.StopFishLoop()
        AutoSell.StopOreLoop()
    end)
    pcall(function()
        Utils.ClearConnections(Runtime.GlobalConnections)
        Utils.ClearConnections(Runtime.Fishing.Connections)
        Utils.ClearConnections(Runtime.Mining.Connections)
    end)
    pcall(function()
        local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if pg then
            for _, name in ipairs({"FishingUI", "MiningUI"}) do
                local g = pg:FindFirstChild(name)
                if g then pcall(function() g:Destroy() end) end
            end
        end
    end)
    pcall(function()
        if Window and Window.Unload then Window:Unload() end
    end)
    ActiveWindow = nil
    if getgenv then getgenv().IndoVoice_Unload = nil end
end

TabSystem.Right:CreateButton({
    name = "Unload Script",
    callback = function()
        IndoVoice_Unload()
        Notify({ Title = "Unloaded", Message = "Indo Voice script unloaded successfully.",
            Type = "info", Duration = 3 })
    end,
})

if getgenv then getgenv().IndoVoice_Unload = IndoVoice_Unload end

-- ─── Config tab (SaveManager built-in profile UI) ────────────────
SaveManager:BuildConfigTab(Window)

-- ─── Post-init: sync runtime to defaults ─────────────────────────
-- Delirium ga fire callback waktu CreateToggle, jadi kita paksa sync manual.
do
    UpdateClaimLoop()
    if AntiAFKSettings.Enabled then AntiAFK.Start() end
end

Window:Notify({
    title = "Indo Voice",
    content = "Script loaded.",
    type = "info",
    duration = 3,
})

print("[Indo Voice] loaded — Delirium API.md compliant")