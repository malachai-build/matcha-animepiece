-- @chunk 00_core  (lines 1-783 of the single-file build)
-- Load marker (loader.lua): proves this chunk started and, at the end of the
-- file, that it finished. Matcha's loadstring reports a syntax error only by
-- printing when the chunk is called, so the loader cannot rely on errors.
local LACED_LOAD = type(_G.__lacedLoad) == "table" and _G.__lacedLoad or nil
if LACED_LOAD and type(LACED_LOAD.started) == "table" then LACED_LOAD.started["00_core"] = true end
--[[
    laced.club core for the Matcha LuaVM, shared with the Blox Fruits build
    (github.com/malachai-build/matcha-bloxfruits): Matcha shims, root control,
    tweenTo, remote guards, run-bound shutdown. Some Blox Fruits state and data
    tables in S/AFL remain; the Anime Piece chunks do not use them.

    Fixes by category
    * Matcha compatibility
      - clock() shim (os.clock is undocumented; falls back to tick()).
      - Workspace resolved once through game:GetService (no bare `workspace`).
      - keyDown(vk): one-argument, pcall-guarded wrapper around iskeypressed.
      - UE loader: global httpget first, game:HttpGet fallback; the downloaded
        body is validated before loadstring (loadstring never returns nil in
        Matcha); aborts use assert() because error() does not raise.
      - Instance-keyed tables (visited/frozen enemies) now key by .Address.
      - FindFirstChildOfClass("BasePart") (never matches an abstract class)
        replaced by FindFirstChildWhichIsA("BasePart").
      - Drawing Text size is set through Size (FontSize does not exist).
      - Instance:IsA always returns true in Matcha; class tests use isA().
      - All FireServer/InvokeServer calls go through safeRemote(): pcall,
        throttled warning, and Remote Mode switches itself off after repeated
        failures (non-Pro builds) instead of spamming.
    * Logic bugs
      - Loops that could spin without yielding (mirage tween, boss/material/
        sea farm, mastery, level farm) now yield on every path.
      - Boat tween uses a per-run token: a new tween cancels the old one; no
        divide-by-zero when already at the target.
      - afl_setCanCollide was inverted; offset sliders snapped to integers
        despite Decimals=1; cham boxes used off-screen (0,0) corners; teleport
        ember / level farm kept running after their toggle went off;
        Legendary Sword status had no visible output.
    * UI adapter vs UE library
      - Accent colour also sets StaticAccentColor; refreshConfigList wired
        into Window.Config.Refresh; config read guarded with isfile; slider
        values rounded to their Rounding; danger-level dropdown no longer
        launches a boat flight when a config is loaded.
    * Cleanup / robustness
      - ESP caches shrink: stale entries are :Remove()d on every rebuild and
        everything is removed when a toggle turns off or the UI unloads.
      - Library unload switches every feature off and stops all loops.
      - Movement keeps the original mechanism (CFrame write for tweens,
        Position write elsewhere) but goes through guarded helpers, with a
        Position fallback when a CFrame write is rejected.
]]

-- ---------------------------------------------------------------------------
-- Compatibility shims (Matcha LuaVM)
-- ---------------------------------------------------------------------------
clock = (type(os) == "table" and type(os.clock) == "function") and os.clock or tick

-- task.wait() with no argument resumes about 2,400 times a second in Matcha
-- (measured live), not once per frame, so every bare-wait loop spun (and wrote
-- CFrame/Position) at that rate. frameWait() yields one 60 Hz frame instead.
FRAME_TIME = 1 / 60
function frameWait() task.wait(FRAME_TIME) end
-- Idle cadence for loops whose feature is off: about 30 loops used to wake at
-- 60 Hz with every toggle off (~1,800 resumes/s). idleWait(active) yields one
-- frame while the feature is on and IDLE_POLL s while it is off.
IDLE_POLL = 0.25
function idleWait(active)
    if active then task.wait(FRAME_TIME) else task.wait(IDLE_POLL) end
end
-- True unless Matcha says Roblox is not the foreground window. Synthetic keys
-- and clicks go to whatever window has focus, so every input path checks it.
function robloxFocused()
    if type(isrbxactive) ~= "function" then return true end
    local okActive, active = pcall(isrbxactive)
    return not (okActive and active == false)
end

-- Activity marks (speed restore, Oct 15 2026). Travel (tweenTo, the mastery
-- and boat tweens, the Underwater City pads) and combat (hard lock, remote M1
-- swing, farm click) stamp the time here, so a background CommF_ invoke
-- (Auto Stat AddPoint) can wait for a calm moment instead of freezing a fight
-- or a flight with its quiet window (quietInvoke below).
ACTIVITY = { travelAt = -1e9, fightAt = -1e9 }
function markTravel() ACTIVITY.travelAt = clock() end
function markFight() ACTIVITY.fightAt = clock() end
-- True when travel ("travel") or travel/combat ("any") was marked at or after t.
function activitySince(t, kind)
    if ACTIVITY.travelAt >= t then return true end
    return kind == "any" and ACTIVITY.fightAt >= t
end

Players = game:GetService("Players")
LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    repeat wait(0.1); LocalPlayer = Players.LocalPlayer until LocalPlayer
end

Workspace = nil
do
    local okService, service = pcall(function() return game:GetService("Workspace") end)
    if okService and service then
        Workspace = service
    else
        Workspace = game.Workspace
    end
end

-- Notifications are intentionally silenced (the bundled UE build disables
-- Library:Notify as well). Every call site already uses Matcha's documented
-- order notify(message, title, duration); flip NOTIFY_ENABLED to route them.
NOTIFY_ENABLED = false
if type(_G.__lacedRealNotify) ~= "function" then _G.__lacedRealNotify = _G.notify end
matchaNotify = _G.__lacedRealNotify
function notify(message, title, duration)
    if not NOTIFY_ENABLED or type(matchaNotify) ~= "function" then return end
    pcall(matchaNotify, tostring(message or ""), tostring(title or "laced.club"), tonumber(duration) or 2)
end

-- iskeypressed takes exactly one Windows VK code in Matcha.
rawIsKeyPressed = iskeypressed
function keyDown(vk)
    if type(rawIsKeyPressed) ~= "function" then return false end
    local ok, state = pcall(rawIsKeyPressed, vk)
    return ok and state == true
end

-- Matcha's Instance:IsA ignores its argument and returns true for every class
-- (confirmed live: HumanoidRootPart:IsA("Model") and :IsA("Tool") are true), so
-- class tests compare ClassName. FindFirstChildWhichIsA does honour the class
-- hierarchy and stays as is.
CLASS_FAMILIES = {
    BasePart = {
        Part = true, MeshPart = true, UnionOperation = true, IntersectOperation = true,
        NegateOperation = true, PartOperation = true, WedgePart = true, CornerWedgePart = true,
        TrussPart = true, Seat = true, VehicleSeat = true, SpawnLocation = true,
        SkateboardPlatform = true, Terrain = true,
    },
    Model = { Model = true, Actor = true, WorldModel = true },
}
function isA(instance, className)
    if instance == nil then return false end
    local okClass, actual = pcall(function() return instance.ClassName end)
    if not okClass or type(actual) ~= "string" then return false end
    if actual == className then return true end
    local family = CLASS_FAMILIES[className]
    return family ~= nil and family[actual] == true
end

-- The UE menu reads the real left mouse button, so a synthetic farm click
-- while the cursor is over the open menu presses whatever control is under it
-- (seen live: Auto Farm Nearest and Pull Enemies switched themselves on).
-- Farm/fish/repair clicks are skipped while the cursor is over a visible window.
menuMouse = nil
menuUE = nil -- the raw UE library, set once the UI has loaded
function menuUnderMouse()
    local okOver, over = pcall(function()
        local ue = menuUE
        if type(ue) ~= "table" or not ue.Toggled or ue._unloaded then return false end
        if not menuMouse then menuMouse = LocalPlayer:GetMouse() end
        local mx, my = menuMouse.X, menuMouse.Y
        for _, window in ipairs(ue.Windows or {}) do
            local position, size = window.Position, window.Size
            if window.Visible and not window.Destroyed and position and size
                and mx >= position.X - 8 and mx <= position.X + size.X + 8
                and my >= position.Y - 8 and my <= position.Y + size.Y + 8 then
                return true
            end
        end
        return false
    end)
    return okOver and over == true
end
function farmClick()
    markFight()
    if not robloxFocused() then return false end
    if menuUnderMouse() then return false end
    return (pcall(mouse1click))
end

warnTimes = {}
function warnThrottled(tag, message, interval)
    local now = clock()
    local last = warnTimes[tag]
    if last and now - last < (interval or 10) then return end
    warnTimes[tag] = now
    warn(message)
end

-- Stable table key for an Instance (Matcha documents .Address for this).
function instKey(instance)
    if instance == nil then return "nil" end
    local okAddress, address = pcall(function() return instance.Address end)
    if okAddress and address and address ~= 0 then return tostring(address) end
    return tostring(instance)
end

-- FireServer / InvokeServer are Pro (Hybrid mode) only: never let a failure
-- raise or spam the console.
RemoteFailures = {}
REMOTE_FAILURE_LIMIT = 8
function safeRemote(tag, remote, method, ...)
    if not remote then return false, nil end
    -- Serialised with CommF_ invokes (see quietInvoke): a FireServer while an
    -- invoke is pending is skipped, not counted as a failure.
    if method ~= "InvokeServer" and remoteInvokePending() then return false, "CommF_ invoke pending" end
    local count = select("#", ...)
    local args = { ... }
    local ok, result = pcall(function()
        if method == "InvokeServer" then
            return remote:InvokeServer(table.unpack(args, 1, count))
        end
        return remote:FireServer(table.unpack(args, 1, count))
    end)
    if ok then
        RemoteFailures[tag] = 0
        return true, result
    end
    RemoteFailures[tag] = (RemoteFailures[tag] or 0) + 1
    warnThrottled("remote:" .. tag, "[laced.club] " .. tag .. " remote failed: " .. tostring(result)
        .. " (FireServer/InvokeServer need Matcha Pro / Hybrid mode)", 15)
    return false, result
end
function remoteFailing(tag)
    return (RemoteFailures[tag] or 0) >= REMOTE_FAILURE_LIMIT
end

-- Movement helpers. Tweens write CFrame (as the original did) and fall back
-- to the documented BasePart.Position when the CFrame write is rejected.
function rootRotation(part)
    local rotation = nil
    pcall(function()
        local rx, ry, rz = part.CFrame:ToEulerAnglesXYZ()
        rotation = CFrame.Angles(rx, ry, rz)
    end)
    return rotation
end

-- Bridge write budget (crash mitigation, see CRASH_FINDINGS.md). Every root
-- CFrame/velocity write goes through Matcha's external memory bridge; the
-- hard-lock, holdAt and tween loops used to write 180-300 times a second.
-- AFQ_DEBUG.safeMode = true doubles every interval that uses writeInterval()
-- (halves those rates) for A/B crash testing.
-- Speed restore (Oct 15 2026): the remote quest pickup was found to be the
-- crash trigger (CHANGES.md), so the hard lock and afq_holdAt are back to one
-- write per frame (60 Hz; 30 Hz with AFQ_DEBUG.safeMode). Was 30 Hz.
ROOT_WRITE_HZ = 60
ROOT_SKIP_DIST_SQ = 0.05 * 0.05
-- WRITE_BUDGET.debug is linked to the AFQ_DEBUG table by 20_ui2 (pair P08),
-- so AFQ_DEBUG.safeMode = true switches safe mode on at runtime.
WRITE_BUDGET = { debug = nil }
function safeModeOn()
    local debug = WRITE_BUDGET.debug
    return type(debug) == "table" and debug.safeMode == true
end
function writeInterval(base)
    return safeModeOn() and base * 2 or base
end

-- Remote quiet window (stability pass, Oct 15 2026). The user reports the
-- client crashing consistently when the remote quest pickup (CommF_
-- InvokeServer "StartQuest") fires, often at the end of a long AFQ flight.
-- quietInvoke() below sets S.remoteQuiet for the duration of every CommF_
-- invoke plus AFQ_REMOTE_QUIET_BEFORE/AFTER around it; while it is set, the
-- shared write helpers (moveRoot, setPartPosition, zeroVelocity, and through
-- them tweenTo/afq_holdAt/hardLockNpcCFrame) and the loops that write parts
-- directly write nothing. S.remoteInvokeBusy serialises the remotes: no
-- FireServer (RegisterAttack/RegisterHit, auras, Magnet M1) goes out while a
-- CommF_ invoke is pending. runGate is this run's S (assigned once S exists).
local runGate = nil
function writesPaused()
    return runGate ~= nil and runGate.remoteQuiet == true
end
function remoteInvokePending()
    return runGate ~= nil and runGate.remoteInvokeBusy == true
end

function moveRoot(part, x, y, z, rotation)
    if not part then return false end
    if writesPaused() then return false end
    -- Never write to a root that left the DataModel (died, respawned, streamed
    -- out); skip the write when it already sits on the target.
    local okState, parent, current = pcall(function() return part.Parent, part.Position end)
    if not okState or parent == nil then return false end
    if current and current.X then
        local dx, dy, dz = current.X - x, current.Y - y, current.Z - z
        if dx * dx + dy * dy + dz * dz <= ROOT_SKIP_DIST_SQ then return true end
    end
    local okCFrame = pcall(function()
        local positionCF = CFrame.new(x, y, z)
        part.CFrame = rotation and (positionCF * rotation) or positionCF
    end)
    if okCFrame then return true end
    return (pcall(function() part.Position = Vector3.new(x, y, z) end))
end

function setPartPosition(part, position)
    if not part or not position then return false end
    if writesPaused() then return false end
    return (pcall(function() part.Position = position end))
end

local function nearZeroVector(v)
    return v ~= nil and v.X ~= nil and math.abs(v.X) + math.abs(v.Y) + math.abs(v.Z) < 0.01
end
function zeroVelocity(part)
    if not part then return end
    if writesPaused() then return end
    local okState, parent, velocity, assembly = pcall(function()
        return part.Parent, part.Velocity, part.AssemblyLinearVelocity
    end)
    if okState and parent == nil then return end
    if not (okState and nearZeroVector(velocity)) then
        pcall(function() part.Velocity = Vector3.new(0, 0, 0) end)
    end
    if not (okState and nearZeroVector(assembly)) then
        pcall(function() part.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end)
    end
end

-- Smooth, fling-free root control (Oct 15 2026; live symptoms after the
-- stability pass: "the camera bugs out and teleports quickly" and "tweening
-- is causing the character to be flung"). Used by tweenTo, afq_holdAt,
-- masteryTweenTo and the fight hard lock.
--
-- placeRoot writes the CFrame and then Velocity and AssemblyLinearVelocity
-- = 0 on EVERY call: no 0.05-stud skip and no "only when non-zero" read, so
-- gravity/physics cannot build up speed between two writes (the cause of the
-- launch at the end of a tween). Same guards as moveRoot: nothing while a
-- CommF_ quiet window is open, nothing on a root that left the DataModel.
function placeRoot(part, x, y, z, rotation)
    if not part then return false end
    if writesPaused() then return false end
    local okParent, parent = pcall(function() return part.Parent end)
    if not okParent or parent == nil then return false end
    local okCFrame = pcall(function()
        local positionCF = CFrame.new(x, y, z)
        part.CFrame = rotation and (positionCF * rotation) or positionCF
    end)
    if not okCFrame and not pcall(function() part.Position = Vector3.new(x, y, z) end) then return false end
    pcall(function() part.Velocity = Vector3.new(0, 0, 0) end)
    pcall(function() part.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end)
    return true
end

-- One rotation for the local root while the script keeps placing it: read
-- once, then reused by every tween / hold / hard-lock write, so the facing
-- (and the camera behind it) never changes frame to frame because physics
-- nudged the CFrame between writes. Re-read after a respawn (other root) or
-- when no placement used it for ROOT_ROTATION_TTL s (the player turned the
-- character by hand in between).
ROOT_ROTATION_TTL = 1
ROOT_ROTATION = { key = nil, rotation = nil, at = -1e9 }
function lockedRotation(part)
    local key = instKey(part)
    local now = clock()
    local cache = ROOT_ROTATION
    if cache.key ~= key or now - cache.at > ROOT_ROTATION_TTL then
        cache.key = key
        cache.rotation = rootRotation(part)
    end
    cache.at = now
    return cache.rotation
end

-- Single owner of the local root while a tween is in flight. tweenTo claims
-- a token, refreshes it every step (also while paused) and releases it when
-- it returns; a newer claim wins and the older tween stops. afq_holdAt, the
-- hard lock, Freeze Position and the void/sky pulls skip their writes while
-- rootTweenOwned() is true. The owner times out after ROOT_OWNER_TTL s
-- without a refresh, so an errored tween cannot block the root for good.
ROOT_OWNER_TTL = 0.5
ROOT_OWNER = { token = nil, at = -1e9 }
function claimRoot()
    local token = {}
    ROOT_OWNER.token = token
    ROOT_OWNER.at = clock()
    return token
end
function holdsRoot(token) return token ~= nil and ROOT_OWNER.token == token end
function refreshRoot(token) if ROOT_OWNER.token == token then ROOT_OWNER.at = clock() end end
function releaseRoot(token) if ROOT_OWNER.token == token then ROOT_OWNER.token = nil end end
function rootTweenOwned()
    return ROOT_OWNER.token ~= nil and clock() - ROOT_OWNER.at < ROOT_OWNER_TTL
end

-- Drawing helpers: every object is created, updated and removed defensively.
function setProp(object, key, value)
    if object then pcall(function() object[key] = value end) end
end

function newDrawing(kind, props)
    local okNew, object = pcall(function() return Drawing.new(kind) end)
    if not okNew or not object then return nil end
    for key, value in pairs(props or {}) do setProp(object, key, value) end
    return object
end

function newText(text, color, size, zIndex)
    local label = newDrawing("Text", {
        Text = text, Position = Vector2.new(0, 0), Color = color,
        Outline = true, Center = true, Visible = false, ZIndex = zIndex,
    })
    if label then
        -- Text size is the numeric Size property; writing FontSize raises
        -- "Unknown property FontSize" in Matcha (confirmed live).
        setProp(label, "Size", size)
        pcall(function() label.Font = Drawing.Fonts.Monospace end)
    end
    return label
end

function newLine(color, thickness, zIndex)
    return newDrawing("Line", { Color = color, Thickness = thickness, Visible = false, ZIndex = zIndex })
end

function removeDrawing(object)
    if not object then return end
    pcall(function() object.Visible = false end)
    pcall(function() object:Remove() end)
end

function destroyEspEntry(entry)
    if not entry then return end
    entry.removed = true
    removeDrawing(entry.label)
    entry.label = nil
    for _, line in pairs(entry.lines or {}) do removeDrawing(line) end
    entry.lines = {}
end

function clearEspCache(cache)
    for key, entry in pairs(cache) do
        destroyEspEntry(entry)
        cache[key] = nil
    end
end

function pruneEspCache(cache, activeKeys)
    for key, entry in pairs(cache) do
        if not activeKeys[key] then
            destroyEspEntry(entry)
            cache[key] = nil
        end
    end
end

function setEntryVisible(entry, visible)
    if not entry or entry.removed then return end
    setProp(entry.label, "Visible", visible)
    for _, line in pairs(entry.lines or {}) do setProp(line, "Visible", visible) end
end

function safeHttpGet(url)
    local body = ""
    if type(httpget) == "function" then
        local okGet, result = pcall(httpget, url)
        if okGet and type(result) == "string" then body = result end
    end
    if body == "" then
        local okGet, result = pcall(function() return game:HttpGet(url) end)
        if okGet and type(result) == "string" then body = result end
    end
    return body
end

S = {

    autoFarming     = false,
    handledChests   = {},
    fruitEsp        = false,
    chestEsp        = false,
    berryEsp        = false,
    boatEsp         = false,
    flowerEsp       = false,
    chamEsp         = false,
    autoFruits      = false,
    fruitPriorityActive = false,
    autoDinoBone    = false,
    autoFarmNearest = false,
    autoNpcFarm     = false,
    autoFarmLevel   = false,
    autoFish        = false,
    autoRepair      = false,
    dungeonEnabled  = false,
    dungeonAutoDoor = true,
    dungeonDestroyObj = true,
    dungeonUseMoves = true,
    dungeonLocalRadius = 1000,
    sanguineZBoost  = false,
    dragonTalonZBoost = false,
    yamaZBoost      = false,
    tushitaXBoost   = false,
    foxLampXBoost   = false,
    soulGuitarM1Boost = false,
    diamondM1Boost = false,
    flameFBoost     = false,
    rToX            = false,
    rToXThenZ       = false,
    bigHitbox       = false,
    flameRToC       = false,
    pullEnemies     = false,
    autoKen         = false,
    autoHaki        = false,
    freezePos       = false,
    freezePosition  = nil,
    freezeEnemies   = false,
    frozenEnemies   = {},
    teleportEmber   = false,
    tweenEmber      = false,
    teleportKitsune = false,
    buddhaPull      = false,
    autoRaid        = false,
    autoMastery     = false,
    customPull      = false,
    voidPull        = false,
    skyPull         = false,
    boatFlyEnabled  = false,
    boatTweening    = false,
    autoBoatSeat    = false,
    selectedBoatSeat = nil,
    selectedBoatSeatLabel = nil,
    remoteMode      = true,
    attackRate      = 10,  -- remote M1 swings/s (slider attack_rate; BasicM1.minInterval = 1/attackRate)
    weaponSlot      = 1,
    selectedBoss    = "The Gorilla King",
    autoBossFarm    = false,
    selectedMaterial = "Leather + Scrap Metal",
    autoMaterialFarm = false,
    statAmount      = 10,
    autoStatMelee   = false,
    autoStatDefense = false,
    autoStatSword   = false,
    autoStatGun     = false,
    autoStatFruit   = false,
    -- Auto Stat caps (level per stat, 0 = no cap) and the status label.
    statCapMelee    = 0,
    statCapDefense  = 0,
    statCapSword    = 0,
    statCapGun      = 0,
    statCapFruit    = 0,
    statStatusLabel = nil,
    -- Auto Fruit Gacha (80_misc2): one random-fruit roll per 2 h cooldown.
    autoGachaRoll   = false,
    gachaRollNow    = false, -- set by the "Roll Now" button, cleared by the loop
    gachaStoreFruit = true,  -- equip the rolled fruit by its hotbar key and store it
    gachaPaused     = false, -- every farm yields while a Gacha roll runs (flight, dialogue, spin, store)
    gachaSaveSpot   = nil,   -- set by 80_misc2: saves the Gacha stand spot for this sea
    gachaStatusLabel = nil,
    selectedSeaEvent = "Shark",
    autoSeaEvent    = false,
    mirageEsp       = false,
    mirageEspLabel  = nil,
    autoMirageTween = false,
    autoMirageGear  = false,
    autoRaceAbility = false,
    customPullX    = 0,
    customPullY    = -10,
    customPullZ    = 0,
    boatFlySpeed   = 5,
    FARM_SPEED     = 320,
    CHEST_SPEED    = 320,
    FRUIT_SPEED    = 320,
    NPC_TWEEN_SPEED = 320,
    RAID_TWEEN_SPEED = 320,
    MASTERY_TWEEN_SPEED = 320,
    BOAT_TWEEN_SPEED = 500,
    MIN_SPEED      = 50,
    MAX_SPEED      = 1000,
    SPEED_STEP     = 50,
    customOffset   = false,
    customOffsetX  = 0,
    customOffsetY  = 23,
    customOffsetZ  = 0,
    glitchSettings = {
        sanguine    = {speed=500,delay=0.1,duration=0.3},
        dragonTalon = {speed=500,delay=0.1,duration=0.3},
        yama        = {speed=500,delay=0.1,duration=0.3},
        tushita     = {speed=500,delay=0.4,duration=0.3},
        foxLamp     = {speed=500,delay=0.1,duration=0.3},
        soulGuitar  = {speed=500,delay=0.1,duration=0.3},
        diamond     = {speed=500,delay=0.1,duration=0.3},
        flame       = {speed=300,delay=0.17,duration=0.15},
    },

    chamBoxes      = {},
    espLabels      = {},
    chestEspLabels = {},
    berryEspLabels = {},
    boatEspEntries = {},
    flowerEspEntries = {},
    chestIndex     = 1,
    chestPriority  = {"Diamond","Gold","Silver"},
    selectedIsland = 1,
    espLabelCache  = {},
    chestEspLabelCache = {},
    berryEspLabelCache = {},
    boatEspCache = {},
    flowerEspCache = {},
    chamBoxCache   = {},
    currentBoat    = nil,
    boatTween      = nil,
    raidTweenActive   = false,
    raidDetected      = false,
    raidLastIslandNum = 0,
    raidLastIslandKey = nil,
    raidMapKey        = nil,
    raidMoveGeneration = 0,
    lastRaidIslandCount = 0,
    berryScanGeneration = 0,
    unloaded       = false,
    remoteQuiet    = false, -- set by quietInvoke: no part writes (see writesPaused)
    remoteInvokeBusy = false, -- set by quietInvoke: a CommF_ invoke is pending
}
runGate = S

-- Every background loop runs while alive(); unloading the UI stops them all.
-- S is a global, so a re-run replaces it. Each run's own table is bound here,
-- once: alive(), onShutdown() and shutdownScript() are closures over it, and
-- every later chunk captures them (and S) as chunk locals at load time
-- (`local alive = alive`). alive() used to read the GLOBAL SCRIPT_STATE on
-- every call, so after a re-run the old run's ~60 loops read the new run's
-- flag and could never be stopped (stability pass, Oct 15 2026). (Seen live
-- earlier: the old shutdown set the NEW S.unloaded = true.)
do
    local state = S
    local hooks = {}
    local removeDrawingFn, clearEspCacheFn = removeDrawing, clearEspCache
    SCRIPT_STATE = state
    function alive()
        return not state.unloaded
    end
    -- Cleanup hooks registered by the chunks at load time (restore heads and
    -- collisions, release held input, ...). They run once, newest first.
    function onShutdown(fn)
        if type(fn) == "function" then hooks[#hooks + 1] = fn end
    end
    local ESP_CACHES = { "espLabelCache", "chamBoxCache", "chestEspLabelCache",
        "berryEspLabelCache", "boatEspCache", "flowerEspCache" }
    local ESP_LISTS = { "espLabels", "chamBoxes", "chestEspLabels", "berryEspLabels",
        "boatEspEntries", "flowerEspEntries" }
    -- Idempotent; safe before the later chunks exist (it only touches this
    -- run's own table, its registered hooks and its own UE copy).
    -- reason: "ui" (UE OnUnload: the menu is already going away), "loader"
    -- (a later chunk failed to load; the menu is unloaded too), nil (by hand).
    function shutdownScript(reason)
        if state.shutdownStarted then return end
        state.shutdownStarted = true
        -- Toggles off through their own callbacks (each feature's normal "off"
        -- path) only while this run is the current one. During a re-run the
        -- new run is already loading; this run's loops stop on alive().
        local library = state.library
        if SCRIPT_STATE == state and type(library) == "table" and type(library.Controls) == "table" then
            for _, control in pairs(library.Controls) do
                if type(control) == "table" and control.Type == "Toggle" and control.Value == true then
                    pcall(function() control:SetValue(false) end)
                end
            end
        end
        state.unloaded = true
        state.boatTweening = false
        state.boatTween = nil
        for index = #hooks, 1, -1 do pcall(hooks[index], reason) end
        -- This run's Drawings, straight from its own caches (the global clear
        -- functions act on whichever run defined them last).
        state.berryScanGeneration = (tonumber(state.berryScanGeneration) or 0) + 1
        for _, key in ipairs(ESP_CACHES) do
            if type(state[key]) == "table" then pcall(clearEspCacheFn, state[key]) end
        end
        for _, key in ipairs(ESP_LISTS) do state[key] = {} end
        if state.mirageEspLabel then
            pcall(removeDrawingFn, state.mirageEspLabel)
            state.mirageEspLabel = nil
        end
        pcall(mouse1release)
        if type(setrobloxinput) == "function" then pcall(setrobloxinput, true) end
        if reason ~= "ui" then
            local ue = state.ue
            if type(ue) == "table" and not ue._unloaded and type(ue.Unload) == "function" then
                pcall(function() ue:Unload() end)
            end
        end
    end
end
-- This run's S for every function defined below (as in the single-file build,
-- where S was a top-level local).
local S = S

-- One CommF_ InvokeServer with the quiet window around it (see writesPaused
-- above). Every CommF_ call of the script goes through here: StartQuest,
-- AbandonQuest (Auto Farm Quest, Level Farm), AddPoint (Auto Stat), the
-- Legendary Sword Dealer check. Order: wait for any pending invoke (at most
-- 5 s), raise S.remoteInvokeBusy and S.remoteQuiet, wait
-- AFQ_REMOTE_QUIET_BEFORE s plus up to 0.5 s more for the root to stop moving
-- (no writes happen meanwhile, so a falling character keeps falling; it is
-- not held), invoke, keep the quiet window AFQ_REMOTE_QUIET_AFTER s, clear
-- both flags. AFQ_DEBUG.quietAccept = false skips the quiet window (A/B
-- test); the serialisation stays. Returns what safeRemote returns. Call it
-- from a step thread after its own hold/tween loops have returned, never
-- from inside a per-frame loop.
AFQ_REMOTE_QUIET_BEFORE = 0.3
AFQ_REMOTE_QUIET_AFTER = 0.3
local function rootSpeed()
    local okSpeed, speed = pcall(function()
        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        local v = hrp and hrp.AssemblyLinearVelocity
        return v and v.Magnitude
    end)
    return okSpeed and tonumber(speed) or 0
end
-- Deferrable invokes (speed restore, Oct 15 2026): a caller that can retry
-- later (Auto Stat) sets S.quietDefer = "travel" or "any" right before its
-- call. When travel (or travel/combat for "any") starts during the lead-in,
-- the invoke is not sent: the window is released at once (within 0.05 s) and
-- the call returns false, QUIET_POSTPONED. The caller retries at its next
-- calm moment. StartQuest/AbandonQuest never set it.
QUIET_POSTPONED = "postponed: travel or combat started"
function quietInvoke(tag, remote, ...)
    local defer = S.quietDefer
    S.quietDefer = nil
    if not remote then return false, nil end
    local count = select("#", ...)
    local args = { ... }
    local waitUntil = clock() + 5
    while S.remoteInvokeBusy and clock() < waitUntil do task.wait(0.05) end
    if S.remoteInvokeBusy then return false, "another CommF_ invoke is still pending" end
    S.remoteInvokeBusy = true
    local debug = WRITE_BUDGET.debug -- the AFQ_DEBUG table (linked by 20_ui2)
    local quiet = not (type(debug) == "table" and debug.quietAccept == false)
    local okCall, ok, result = true, false, nil
    if quiet then
        S.remoteQuiet = true
        local startedAt = clock()
        local leadEnd = startedAt + AFQ_REMOTE_QUIET_BEFORE
        local settleUntil = leadEnd + 0.5
        -- Lead-in: AFQ_REMOTE_QUIET_BEFORE s, then up to 0.5 s more while the
        -- root still moves (same as before, polled every 0.05 s).
        while clock() < settleUntil do
            if defer and activitySince(startedAt, defer) then
                S.remoteQuiet = false
                S.remoteInvokeBusy = false
                return false, QUIET_POSTPONED
            end
            if clock() >= leadEnd and rootSpeed() <= 1 then break end
            task.wait(0.05)
        end
    end
    okCall, ok, result = pcall(safeRemote, tag, remote, "InvokeServer", table.unpack(args, 1, count))
    if quiet then task.wait(AFQ_REMOTE_QUIET_AFTER) end
    S.remoteQuiet = false
    S.remoteInvokeBusy = false
    if not okCall then return false, ok end
    return ok, result
end

-- Priority features that every farm yields to (Auto Farm Quest checks this
-- itself; the other farms also yield to Auto Farm Quest, see below).
function farmPriorityFeatureActive()
    return S.fruitPriorityActive == true or S.gachaPaused == true or S.autoDinoBone == true or S.autoBossFarm == true or S.autoMaterialFarm == true
        or S.autoSeaEvent == true
        or S.dungeonEnabled == true
        or S.autoMirageTween == true or S.autoMirageGear == true
end

function farmPriorityBlocked()
    return farmPriorityFeatureActive() or S.autoFarmQuest == true
end

AFL = {
    tweenSpeed       = 320,
    selectedNpc      = nil,
    currentSea       = 1,
    lastLevel        = 0,
    npcToFarm        = "Sea1First",
    autofarmByLevel  = true,
    autoV3           = false,
    autoV4           = true,
    enableGetQuest   = true,
    useRemoteQuest   = false,  -- accept quests with CommF_ "StartQuest" (toggle afl_remote_quest, OFF by default since Oct 15 2026: the remote was found to crash the client on Matcha Hybrid); off = dialogue clicks
    usePortalTeleport = true,
    activeTweens     = {},
    lastTween        = clock(),
    tween            = nil,
    questData        = nil,
    pos = {
        sea1First              = Vector3.new(-2711.6,24.55,2105.27),
        sea1FirstWait          = Vector3.new(-2834.22,41.8,2152.38),
        jungle                 = Vector3.new(-1602.35,36.91,150.99),
        jungleWait1            = Vector3.new(-1448.19,50.91,64.35),
        jungleWait2            = Vector3.new(-1192.02,7.83,-448.82),
        pirateVillage          = Vector3.new(-1140.03,4.81,3828.47),
        pirateVillageWait1     = Vector3.new(-1233.49,115.64,3985.23),
        pirateVillageWait2     = Vector3.new(-1142.35,84.96,4297.03),
        desert                 = Vector3.new(896.93,6.5,4388.77),
        desertWait1            = Vector3.new(1054.99,52.5,4490.5),
        desertWait2            = Vector3.new(1528.99,14.51,4395.69),
        winter                 = Vector3.new(1382.2,87.34,-1294.29),
        winterWait1            = Vector3.new(1332.85,104.47,-1313.92),
        winterWait2            = Vector3.new(1200.95,144.64,-1550.89),
        marineFortress         = Vector3.new(-5036.22,28.71,4325.45),
        marineFortressWait1    = Vector3.new(-4819.73,20.71,4359.87),
        marineFortressWait2    = Vector3.new(-4950.39,71.41,4166.69),
        sky1                   = Vector3.new(-4841.94,717.73,-2623.45),
        sky1Wait1              = Vector3.new(-4959.59,365.07,-2911.46),
        sky1Wait2              = Vector3.new(-5223.22,449.34,-2397.63),
        prison                 = Vector3.new(5305.62,1.72,474.79),
        prisonWait1            = Vector3.new(5200.82,88.71,481.99),
        prisonWait2            = Vector3.new(5426.98,88.71,988.44),
        colosseum              = Vector3.new(-1578.9,7.5,-2984.3),
        colosseumWait1         = Vector3.new(-1940.03,49.12,-2894.37),
        colosseumWait2         = Vector3.new(-1300.48,7.51,-3243.32),
        magma                  = Vector3.new(-5316.38,11.38,8510.77),
        magmaWait1             = Vector3.new(-5401.39,23.07,8506.53),
        magmaWait2             = Vector3.new(-5775.68,118.91,8802.16),
        -- Underwater City (separate map, reached through the whirlpool; see
        -- UNDERWATER_CITY). Giver: 10 studs in front of King Neptune, who stands
        -- at (61406.20, 24.52, 1626.82); the old (61123.74, 18.53, 1567.43) was
        -- 289 studs away. Waits: 24 studs above the centroid of the
        -- _WorldOrigin.EnemySpawns parts (Fishman Warrior x7, Commando x6).
        underwater             = Vector3.new(61402.79,24.94,1636.15),
        underwaterWait1        = Vector3.new(60792.92,48.74,1361.48),
        underwaterWait2        = Vector3.new(61928.16,48.74,1331.06),
        -- God's Guard island moved in a map update. sky3 (Mole) is stale too:
        -- no map part within 150 studs of it (live Oct 15 2026); StartQuest
        -- is a remote and was accepted from there, so it is kept until Mole's
        -- new spot is known. sky3Wait: 24 studs above the centroid of the
        -- six God's Guard EnemySpawns parts (the old -4634.47,866.97,
        -- -1938.53 was open air ~1560 studs from them).
        sky3                   = Vector3.new(-4725.1,845.34,-1956.55),
        sky3Wait               = Vector3.new(-4240.59,1112.88,-403.66),
        sky4                   = Vector3.new(-7861.91,5545.56,-376.38),
        sky4Wait               = Vector3.new(-7688.82,5600.79,-441.55),
        sky5                   = Vector3.new(-7899.52,5636.03,-1409.42),
        sky5Wait1              = Vector3.new(-7638.64,5637.14,-1421.99),
        sky5Wait2              = Vector3.new(-7838.8,5680.52,-1793.07),
        fountain               = Vector3.new(5254.86,38.56,4049.82),
        fountainWait1          = Vector3.new(5633.07,103.08,4059.29),
        fountainWait2          = Vector3.new(5685.56,66.35,4825),
        roseKingdom            = Vector3.new(-424.07,73.14,1835.97),
        roseKingdomWait1       = Vector3.new(-713.92,39.31,2375.86),
        roseKingdomWait2       = Vector3.new(351.33,39.31,2327.74),
        roseKingdomWait3       = Vector3.new(-959.84,80.5,1691.61),
        roseKingdomWait4       = Vector3.new(-1096.17,80.65,1155.03),
        factory                = Vector3.new(634.46,73.29,919.02),
        factoryWait1           = Vector3.new(828.24,140.36,1182.37),
        factoryWait2           = Vector3.new(628.62,73.18,-5.86),
        factoryWait3           = Vector3.new(-45.62,149.66,-301.97),
        greenZone              = Vector3.new(-2442.94,73.24,-3219.45),
        greenZoneWait1         = Vector3.new(-2947.85,111.16,-2979.32),
        greenZoneWait2         = Vector3.new(-1846.47,90.45,-3207.15),
        graveyard              = Vector3.new(-5493.04,48.7,-794.38),
        graveyardWait1         = Vector3.new(-5722.79,126.26,-752.72),
        graveyardWait2         = Vector3.new(-6038.78,6.63,-1297.6),
        snow                   = Vector3.new(605.73,401.65,-5371.18),
        snowWait1              = Vector3.new(536.02,433.39,-5482.01),
        snowWait2              = Vector3.new(1269.49,454.57,-5143.11),
        coldSide               = Vector3.new(-6229.27,82.05,-4851.89),
        coldSideWait1          = Vector3.new(-5867.03,88.63,-4385.88),
        coldSideWait2          = Vector3.new(-6310.69,35.63,-5882.5),
        hotSide                = Vector3.new(-5400.93,29.39,-5376.38),
        hotSideWait1           = Vector3.new(-5700.74,135.59,-5696.33),
        hotSideWait2           = Vector3.new(-5227.32,79.8,-4910.44),
        hauntedShip1           = Vector3.new(1037.82,125.28,32909.95),
        hauntedShip1Wait1      = Vector3.new(1257.26,125.67,33093.13),
        hauntedShip1Wait2      = Vector3.new(612.15,125.28,33049.17),
        hauntedShip1Wait3      = Vector3.new(943.62,40.67,32827.61),
        hauntedShip2           = Vector3.new(971.4,125.28,33248.01),
        hauntedShip2Wait1      = Vector3.new(1212.3,125.8,33078.4),
        hauntedShip2Wait2      = Vector3.new(1201.9,181.2,33296.9),
        hauntedShip2Wait3      = Vector3.new(671.5,181.2,33291.0),
        winterCastle           = Vector3.new(5670.71,28.4,-6479.92),
        winterCastleWait1      = Vector3.new(5924.53,70.64,-6202.01),
        winterCastleWait2      = Vector3.new(5431.28,75.24,-6812.18),
        wano                   = Vector3.new(-3053.98,239.87,-10147.38),
        wanoWait1              = Vector3.new(-3044.49,29.76,-9787.32),
        wanoWait2              = Vector3.new(-3435.25,275.76,-10480.77),
        hydra1                 = Vector3.new(6737.77,127.56,-715.37),
        hydra1Wait             = Vector3.new(6744.37,115.45,-792.37),
        hydra2                 = Vector3.new(6651.94,546.71,260.22),
        hydra2Wait             = Vector3.new(6762.3,565.2,271.6),
        hydra3                 = Vector3.new(5211.85,1004.13,757.35),
        hydra3Wait             = Vector3.new(4563.77,1002.4,824.84),
        port                   = Vector3.new(-449.36,108.63,5946.07),
        portWait1a             = Vector3.new(-128.02,57.04,5759.62),
        portWait1b             = Vector3.new(-646.17,57.04,5583.4),
        portWait2a             = Vector3.new(-778.57,143.02,6048.03),
        portWait2b             = Vector3.new(-232.7,152.3,6283.1),
        greatTree              = Vector3.new(2479.55,74.3,-6786.71),
        greatTreeWait1         = Vector3.new(2613.79,131.61,-7825.64),
        greatTreeWait2         = Vector3.new(3550.92,155.81,-7354.19),
        hauntedCastle1         = Vector3.new(-9484.23,142.17,5563.99),
        hauntedCastle2         = Vector3.new(-9513.78,172.17,6077.79),
        hauntedCastleWait1     = Vector3.new(-8891,223.03,6137.75),
        hauntedCastleWait2     = Vector3.new(-10079.95,237.5,5913.72),
        hauntedCastleWait3     = Vector3.new(-9502.4,172.17,6049.03),
        hauntedCastleWait4     = Vector3.new(-9545.33,60.32,6341.16),
        iceCream               = Vector3.new(-821.24,65.88,-10963.49),
        iceCreamWait           = Vector3.new(-875.19,184.15,-11124.79),
        cakeLand1              = Vector3.new(-2021.32,37.86,-12029.23),
        cakeLand1Wait1         = Vector3.new(-2299.21,112.6,-12210.75),
        cakeLand1Wait2         = Vector3.new(-1649.28,195.72,-12314.08),
        cakeLand2              = Vector3.new(-1927.75,37.86,-12842.92),
        cakeLand2Wait1         = Vector3.new(-1738.96,143.87,-12935.42),
        cakeLand2Wait2         = Vector3.new(-2248.69,53.57,-12849.23),
        chocolate1             = Vector3.new(237.92,24.8,-12201.14),
        chocolate1Wait1        = Vector3.new(80.22,73.51,-12310.81),
        chocolate1Wait2        = Vector3.new(684.82,45.34,-12421.76),
        chocolate2             = Vector3.new(147.05,24.86,-12778.49),
        chocolate2Wait1        = Vector3.new(48.8,75.13,-12763.81),
        northPole              = Vector3.new(-1159.84,61,-14495.45),
        northPoleWait1         = Vector3.new(-1357.6,83.3,-14704.45),
        northPoleWait2         = Vector3.new(-822.36,80.32,-14390.73),
        peanut                 = Vector3.new(-2104.58,38.17,-10191.75),
        peanutWait             = Vector3.new(-2049.21,165.51,-10335.04),
        tiki1                  = Vector3.new(-16543.93,55.75,-173.82),
        tiki1Wait              = Vector3.new(-16228.02,145.37,-231.54),
        tiki1Wait2             = Vector3.new(-16753.20,126.94,-278.50),
        tiki2                  = Vector3.new(-16538.69,55.75,1051.88),
        tiki2Wait              = Vector3.new(-16498.12,131.81,1051.74),
        tiki3                  = Vector3.new(-16665.98,105.31,1576.49),
        tiki3Wait1             = Vector3.new(-16537.67,158.94,1311.88),
        tiki3Wait2             = Vector3.new(-16847.48,122.17,1727.21),
        mansion                = Vector3.new(-13231.25,332.44,-7626.68),
        mansionWait1           = Vector3.new(-13448.1,416.3,-7780.96),
        mansionWait2           = Vector3.new(-13878.98,569.46,-7089.08),
        turtleCenter           = Vector3.new(-12683.65,390.92,-9900.57),
        turtleCenterWait1      = Vector3.new(-12055.72,428.33,-10385.56),
        turtleCenterWait2      = Vector3.new(-13294.97,520.51,-9900.41),
        turtleEntrance         = Vector3.new(-10583.8,331.83,-8757.94),
        turtleEntranceWait     = Vector3.new(-10568.57,477.29,-8832.32),
    },
}

if game.PlaceId == 2753915549 then
    AFL.currentSea = 1; AFL.npcToFarm = "Sea1First"
elseif game.PlaceId == 4442272183 then
    AFL.currentSea = 2; AFL.npcToFarm = "RoseKingdom1"
elseif game.PlaceId == 7449423635 then
    AFL.currentSea = 3; AFL.npcToFarm = "Port1"
end

function afl_pick(a, b) return (math.random(1,2)==1) and a or b end

AFL.islandPositions = {
    Sea1First=AFL.pos.sea1First,
    Jungle1=AFL.pos.jungle, Jungle2=AFL.pos.jungle,
    PirateVillage1=AFL.pos.pirateVillage, PirateVillage2=AFL.pos.pirateVillage,
    DesertIsland1=AFL.pos.desert, DesertIsland2=AFL.pos.desert,
    WinterIsland1=AFL.pos.winter, WinterIsland2=AFL.pos.winter,
    MarineFortress=AFL.pos.marineFortress,
    SkyIsland1=AFL.pos.sky1, SkyIsland2=AFL.pos.sky1,
    PrisonIsland1=AFL.pos.prison, PrisonIsland2=AFL.pos.prison,
    ColosseumIsland1=AFL.pos.colosseum, ColosseumIsland2=AFL.pos.colosseum,
    MagmaIsland1=AFL.pos.magma, MagmaIsland2=AFL.pos.magma,
    UnderWaterIsland1=AFL.pos.underwater, UnderWaterIsland2=AFL.pos.underwater,
    SkyIsland3=AFL.pos.sky3, SkyIsland4=AFL.pos.sky4,
    SkyIsland5=AFL.pos.sky5, SkyIsland6=AFL.pos.sky5,
    FountainIsland1=AFL.pos.fountain, FountainIsland2=AFL.pos.fountain,
    RoseKingdom1=AFL.pos.roseKingdom, RoseKingdom2=AFL.pos.roseKingdom,
    Factory1=AFL.pos.factory, Factory2=AFL.pos.factory,
    GreenZone1=AFL.pos.greenZone, GreenZone2=AFL.pos.greenZone,
    Graveyard1=AFL.pos.graveyard, Graveyard2=AFL.pos.graveyard,
    Snow1=AFL.pos.snow, Snow2=AFL.pos.snow,
    ColdSide1=AFL.pos.coldSide, ColdSide2=AFL.pos.coldSide,
    HotSide1=AFL.pos.hotSide, HotSide2=AFL.pos.hotSide,
    HauntedShip1=AFL.pos.hauntedShip1, HauntedShip2=AFL.pos.hauntedShip1,
    HauntedShip3=AFL.pos.hauntedShip2, HauntedShip4=AFL.pos.hauntedShip2,
    WinterCastle1=AFL.pos.winterCastle, WinterCastle2=AFL.pos.winterCastle,
    Wano1=AFL.pos.wano, Wano2=AFL.pos.wano,
    Hydra1=AFL.pos.hydra1, Hydra2=AFL.pos.hydra2, Hydra3=AFL.pos.hydra3, Hydra4=AFL.pos.hydra3,
    Port1=AFL.pos.port, Port2=AFL.pos.port,
    GreatTree1=AFL.pos.greatTree, GreatTree2=AFL.pos.greatTree,
    HauntedCastle1=AFL.pos.hauntedCastle1, HauntedCastle2=AFL.pos.hauntedCastle1,
    HauntedCastle3=AFL.pos.hauntedCastle2, HauntedCastle4=AFL.pos.hauntedCastle2,
    IceCream1=AFL.pos.iceCream, IceCream2=AFL.pos.iceCream,
    CakeLand1=AFL.pos.cakeLand1, CakeLand2=AFL.pos.cakeLand1,
    CakeLand3=AFL.pos.cakeLand2, CakeLand4=AFL.pos.cakeLand2,
    Chocolate1=AFL.pos.chocolate1, Chocolate2=AFL.pos.chocolate1,
    Chocolate3=AFL.pos.chocolate2, Chocolate4=AFL.pos.chocolate2,
    NorthPole1=AFL.pos.northPole, NorthPole2=AFL.pos.northPole,
    Peanut1=AFL.pos.peanut, Peanut2=AFL.pos.peanut,
    Tiki1Quest1=AFL.pos.tiki1, Tiki1Quest2=AFL.pos.tiki1,
    Tiki2Quest1=AFL.pos.tiki2, Tiki2Quest2=AFL.pos.tiki2,
    Tiki3Quest1=AFL.pos.tiki3, Tiki3Quest2=AFL.pos.tiki3,
    Mansion1=AFL.pos.mansion, Mansion2=AFL.pos.mansion,
    TurtleCenter1=AFL.pos.turtleCenter, TurtleCenter2=AFL.pos.turtleCenter,
    TurtleEntrance1=AFL.pos.turtleEntrance, TurtleEntrance2=AFL.pos.turtleEntrance,
}

AFL.waitPositions = {
    Sea1First=AFL.pos.sea1FirstWait,
    Jungle1=AFL.pos.jungleWait1, Jungle2=AFL.pos.jungleWait2,
    PirateVillage1=AFL.pos.pirateVillageWait1, PirateVillage2=AFL.pos.pirateVillageWait2,
    DesertIsland1=AFL.pos.desertWait1, DesertIsland2=AFL.pos.desertWait2,
    WinterIsland1=AFL.pos.winterWait1, WinterIsland2=AFL.pos.winterWait2,
    MarineFortress=afl_pick(AFL.pos.marineFortressWait1, AFL.pos.marineFortressWait2),
    SkyIsland1=AFL.pos.sky1Wait1, SkyIsland2=AFL.pos.sky1Wait2,
    PrisonIsland1=AFL.pos.prisonWait1, PrisonIsland2=AFL.pos.prisonWait2,
    ColosseumIsland1=AFL.pos.colosseumWait1, ColosseumIsland2=AFL.pos.colosseumWait2,
    MagmaIsland1=AFL.pos.magmaWait1, MagmaIsland2=AFL.pos.magmaWait2,
    UnderWaterIsland1=AFL.pos.underwaterWait1, UnderWaterIsland2=AFL.pos.underwaterWait2,
    SkyIsland3=AFL.pos.sky3Wait, SkyIsland4=AFL.pos.sky4Wait,
    SkyIsland5=AFL.pos.sky5Wait1, SkyIsland6=AFL.pos.sky5Wait2,
    FountainIsland1=AFL.pos.fountainWait1, FountainIsland2=AFL.pos.fountainWait2,
    RoseKingdom1=afl_pick(AFL.pos.roseKingdomWait1, AFL.pos.roseKingdomWait2),
    RoseKingdom2=afl_pick(AFL.pos.roseKingdomWait3, AFL.pos.roseKingdomWait4),
    Factory1=AFL.pos.factoryWait1, Factory2=afl_pick(AFL.pos.factoryWait2, AFL.pos.factoryWait3),
    GreenZone1=AFL.pos.greenZoneWait1, GreenZone2=AFL.pos.greenZoneWait2,
    Graveyard1=AFL.pos.graveyardWait1, Graveyard2=AFL.pos.graveyardWait2,
    Snow1=AFL.pos.snowWait1, Snow2=AFL.pos.snowWait2,
    ColdSide1=AFL.pos.coldSideWait1, ColdSide2=AFL.pos.coldSideWait2,
    HotSide1=AFL.pos.hotSideWait1, HotSide2=AFL.pos.hotSideWait2,
    HauntedShip1=afl_pick(AFL.pos.hauntedShip1Wait1, AFL.pos.hauntedShip1Wait2),
    HauntedShip2=AFL.pos.hauntedShip1Wait3,
    HauntedShip3=AFL.pos.hauntedShip2Wait1,
    HauntedShip4=AFL.pos.hauntedShip2Wait2,
    WinterCastle1=AFL.pos.winterCastleWait1, WinterCastle2=AFL.pos.winterCastleWait2,
    Wano1=AFL.pos.wanoWait1, Wano2=AFL.pos.wanoWait2,
    Hydra1=AFL.pos.hydra1Wait, Hydra2=AFL.pos.hydra2Wait,
    Hydra3=AFL.pos.hydra3Wait, Hydra4=AFL.pos.hydra3Wait,
    Port1=afl_pick(AFL.pos.portWait1a, AFL.pos.portWait1b),
    Port2=afl_pick(AFL.pos.portWait2a, AFL.pos.portWait2b),
    GreatTree1=AFL.pos.greatTreeWait1, GreatTree2=AFL.pos.greatTreeWait2,
    HauntedCastle1=AFL.pos.hauntedCastleWait1, HauntedCastle2=AFL.pos.hauntedCastleWait2,
    HauntedCastle3=AFL.pos.hauntedCastleWait3, HauntedCastle4=AFL.pos.hauntedCastleWait4,
    IceCream1=AFL.pos.iceCreamWait, IceCream2=AFL.pos.iceCreamWait,
    CakeLand1=AFL.pos.cakeLand1Wait1, CakeLand2=AFL.pos.cakeLand1Wait2,
    CakeLand3=AFL.pos.cakeLand2Wait1, CakeLand4=AFL.pos.cakeLand2Wait2,
    Chocolate1=AFL.pos.chocolate1Wait1, Chocolate2=AFL.pos.chocolate1Wait2,
    Chocolate3=AFL.pos.chocolate2Wait1, Chocolate4=AFL.pos.chocolate2Wait1,
    NorthPole1=AFL.pos.northPoleWait1, NorthPole2=AFL.pos.northPoleWait2,
    Peanut1=AFL.pos.peanutWait, Peanut2=AFL.pos.peanutWait,
    Tiki1Quest1=AFL.pos.tiki1Wait, Tiki1Quest2=AFL.pos.tiki1Wait2,
    Tiki2Quest1=AFL.pos.tiki2Wait, Tiki2Quest2=AFL.pos.tiki2Wait,
    Tiki3Quest1=AFL.pos.tiki3Wait1, Tiki3Quest2=AFL.pos.tiki3Wait2,
    Mansion1=AFL.pos.mansionWait1, Mansion2=AFL.pos.mansionWait2,
    TurtleCenter1=AFL.pos.turtleCenterWait1, TurtleCenter2=AFL.pos.turtleCenterWait2,
    TurtleEntrance1=AFL.pos.turtleEntranceWait, TurtleEntrance2=AFL.pos.turtleEntranceWait,
}

AFL.waitRoutes={
    HauntedShip4={AFL.pos.hauntedShip2Wait2,AFL.pos.hauntedShip2Wait3},
}

AFL.waitRouteIndices={}
AFL.farmLoopRunning=false
AFL.nextNpcCache=nil
AFL.nextNpcCacheTime=0

AFL.levelFarmTable = {
    [1]={{1,10,"Sea1First"},{10,15,"Jungle1"},{15,30,"Jungle2"},{30,40,"PirateVillage1"},{40,60,"PirateVillage2"},{60,75,"DesertIsland1"},{75,90,"DesertIsland2"},{90,100,"WinterIsland1"},{100,120,"WinterIsland2"},{120,150,"MarineFortress"},{150,175,"SkyIsland1"},{175,190,"SkyIsland2"},{190,210,"PrisonIsland1"},{210,250,"PrisonIsland2"},{250,275,"ColosseumIsland1"},{275,300,"ColosseumIsland2"},{300,325,"MagmaIsland1"},{325,375,"MagmaIsland2"},{375,400,"UnderWaterIsland1"},{400,450,"UnderWaterIsland2"},{450,475,"SkyIsland3"},{475,525,"SkyIsland4"},{525,550,"SkyIsland5"},{550,625,"SkyIsland6"},{625,650,"FountainIsland1"},{650,700,"FountainIsland2"}},
    [2]={{700,725,"RoseKingdom1"},{725,775,"RoseKingdom2"},{775,800,"Factory1"},{800,875,"Factory2"},{875,900,"GreenZone1"},{900,950,"GreenZone2"},{950,975,"Graveyard1"},{975,1000,"Graveyard2"},{1000,1050,"Snow1"},{1050,1100,"Snow2"},{1100,1125,"ColdSide1"},{1125,1175,"ColdSide2"},{1175,1200,"HotSide1"},{1200,1250,"HotSide2"},{1250,1275,"HauntedShip1"},{1275,1300,"HauntedShip2"},{1300,1325,"HauntedShip3"},{1325,1350,"HauntedShip4"},{1350,1375,"WinterCastle1"},{1375,1425,"WinterCastle2"},{1425,1450,"Wano1"},{1450,1500,"Wano2"}},
    [3]={{1500,1525,"Port1"},{1525,1575,"Port2"},{1575,1600,"Hydra1"},{1600,1625,"Hydra2"},{1625,1650,"Hydra3"},{1650,1700,"Hydra4"},{1700,1725,"GreatTree1"},{1725,1775,"GreatTree2"},{1775,1800,"TurtleEntrance1"},{1800,1825,"TurtleEntrance2"},{1825,1850,"Mansion1"},{1850,1900,"Mansion2"},{1900,1925,"TurtleCenter1"},{1925,1975,"TurtleCenter2"},{1975,2000,"HauntedCastle1"},{2000,2025,"HauntedCastle2"},{2025,2050,"HauntedCastle3"},{2050,2075,"HauntedCastle4"},{2075,2100,"Peanut1"},{2100,2125,"Peanut2"},{2125,2150,"IceCream1"},{2150,2200,"IceCream2"},{2200,2225,"CakeLand1"},{2225,2250,"CakeLand2"},{2250,2275,"CakeLand3"},{2275,2300,"CakeLand4"},{2300,2325,"Chocolate1"},{2325,2350,"Chocolate2"},{2350,2375,"Chocolate3"},{2375,2400,"Chocolate4"},{2400,2425,"NorthPole1"},{2425,2450,"NorthPole2"},{2450,2475,"Tiki1Quest1"},{2475,2500,"Tiki1Quest2"},{2500,2525,"Tiki2Quest1"},{2525,2550,"Tiki2Quest2"},{2550,2575,"Tiki3Quest1"},{2575,2800,"Tiki3Quest2"}}
}

dangerLevels = {
    {name="Level 1", pos=Vector3.new(-22154,37,2735)},
    {name="Level 2", pos=Vector3.new(-26413,37,3671)},
    {name="Level 3", pos=Vector3.new(-30027,37,3921)},
    {name="Level 4", pos=Vector3.new(-33348,37,3704)},
    {name="Level 5", pos=Vector3.new(-38169,37,5121)},
    {name="Level 6", pos=Vector3.new(-43568,37,7018)},
}
dangerLevelNames = {}
for _, d in pairs(dangerLevels) do table.insert(dangerLevelNames, d.name) end

islandList = {
    {name="Tiki2",          pos=Vector3.new(-16577.81,107.2,1226.22)},
    {name="Tiki1",          pos=Vector3.new(-16546.72,55.87,-228.59)},
    {name="Port",           pos=Vector3.new(-706.75,85.98,5775.46)},
    {name="Hydra1",         pos=Vector3.new(6737.77,127.56,-715.37)},
    {name="Hydra2",         pos=Vector3.new(6651.94,546.71,260.22)},
    {name="Hydra3",         pos=Vector3.new(4563.77,1002.40,824.84)},
    {name="GreatTree1",     pos=Vector3.new(2976.45,74.41,-7919.18)},
    {name="GreatTree2",     pos=Vector3.new(3727.85,124.12,-7153.10)},
    {name="HauntedCastle",  pos=Vector3.new(-9558.96,172.28,6139.46)},
    {name="IceCream",       pos=Vector3.new(-836.01,65.99,-10973.16)},
    {name="CakeLand",       pos=Vector3.new(-2115.22,70.16,-12366.38)},
    {name="Chocolate",      pos=Vector3.new(314.05,24.97,-12480.51)},
    {name="Peanut",         pos=Vector3.new(-2093.83,38.28,-10204.63)},
    {name="Mansion",        pos=Vector3.new(-13330.71,450.81,-7441.45)},
    {name="TurtleCenter2",  pos=Vector3.new(-13274.77,391.72,-9791.60)},
    {name="TurtleCenter1",  pos=Vector3.new(-12019.83,331.91,-10562.06)},
    {name="TurtleEntrance", pos=Vector3.new(-10607.67,331.94,-8782.75)},
}

-- ---------------------------------------------------------------------------
-- Root flight (moved here from 30_esp so every game build shares it).
-- ---------------------------------------------------------------------------
local alive = alive
TWEEN_STEP_TIME=FRAME_TIME -- one CFrame write per frame (was 0.01 before the stability pass); safe mode doubles it
-- Server movement limit (measured live Oct 15 2026, Upper Skylands): a
-- 2,600-3,400 stud flight at 320 studs/s was refused after ~1.5 s (the server
-- kept the character far behind, snapped the root back to it every few frames
-- and rejected every hit meanwhile); the same flight at 250 was accepted,
-- and short hops (<= ~150 studs) at 320 always were. So a flight longer than
-- TWEEN_BURST_DIST runs at most TWEEN_SERVER_CAP studs/s, and a server
-- snap-back (root found more than TWEEN_SNAP_DIST off the last written point)
-- re-bases the flight from where the server put the root and lowers the cap
-- (x TWEEN_SNAP_SLOWDOWN, not below TWEEN_SERVER_FLOOR) for the session.
TWEEN_BURST_DIST=300
TWEEN_SERVER_CAP=250
TWEEN_SERVER_FLOOR=150
TWEEN_SNAP_DIST=60
TWEEN_SNAP_SLOWDOWN=0.85

-- Lerps the root part to targetPos at `speed` studs/s. Returns true when the
-- target was reached, false when stopped (checkFn false, part gone, unload,
-- or another tween took the root).
--
-- Speed restore + smooth flight (Oct 15 2026). Live symptoms after the
-- stability pass: "the camera bugs out and teleports quickly" and "tweening
-- is causing the character to be flung". Rules now:
--   * exactly one write per frame: CFrame, then Velocity and
--     AssemblyLinearVelocity = 0 (placeRoot, every written frame, no
--     "only when non-zero" or 0.05-stud skip), so physics cannot build up
--     speed between writes and launch the character;
--   * the position is interpolated from a fixed base point and the clock()
--     time since the base (never from the last written position), so a
--     late frame catches up on the straight line and the real speed is
--     `speed` studs/s at any frame rate;
--   * the rotation is captured once (lockedRotation: shared with
--     afq_holdAt and the hard lock while they keep running) and held for
--     the whole flight, so the camera does not turn;
--   * after a pause (CommF_ quiet window) the interpolation is re-based from
--     the root's current position and the current time: no jump on resume;
--   * the tween owns the root (claimRoot token): afq_holdAt, the hard lock,
--     Freeze Position and the void/sky pulls do not write the root while it
--     is in flight; a newer tween takes the root over and this one stops;
--   * on arrival the final CFrame is written with zero velocity for three
--     consecutive frames (the callers then restore CanCollide).
-- The local character's root is re-fetched every step and compared by key:
-- after a death or respawn the old root (possibly freed) is never touched.
function tweenTo(hrp, targetPos, speed, checkFn)
    if not hrp or not targetPos then return false end
    local okStart,startPos=pcall(function() return hrp.Position end)
    if not okStart or not startPos then return false end
    local rootKey=instKey(hrp)
    local isLocalRoot=false
    pcall(function()
        local char=LocalPlayer.Character
        local cur=char and char:FindFirstChild("HumanoidRootPart")
        isLocalRoot=cur~=nil and instKey(cur)==rootKey
    end)
    local rotationCF=isLocalRoot and lockedRotation(hrp) or rootRotation(hrp)
    local function currentPart()
        if not isLocalRoot then
            local okParent,parent=pcall(function() return hrp.Parent end)
            return (okParent and parent) and hrp or nil
        end
        -- Stop when the character left the DataModel (death/respawn) or its
        -- root is no longer the one this tween started with.
        local okCur,cur=pcall(function()
            local char=LocalPlayer.Character
            if not char or not char.Parent then return nil end
            return char:FindFirstChild("HumanoidRootPart")
        end)
        if okCur and cur and instKey(cur)==rootKey then return cur end
        return nil
    end
    local function keepGoing()
        if not alive() then return false end
        if not checkFn then return true end
        local okCheck,result=pcall(checkFn)
        return okCheck and result and true or false
    end
    local dx=targetPos.X-startPos.X; local dy=targetPos.Y-startPos.Y; local dz=targetPos.Z-startPos.Z
    local distance=math.sqrt(dx*dx+dy*dy+dz*dz)
    if distance<=1 then
        return placeRoot(hrp,targetPos.X,targetPos.Y,targetPos.Z,rotationCF)
    end
    local moveSpeed=tonumber(speed) or 320
    if moveSpeed<=0 then moveSpeed=320 end
    if isLocalRoot and distance>TWEEN_BURST_DIST then moveSpeed=math.min(moveSpeed,TWEEN_SERVER_CAP) end
    local token=isLocalRoot and claimRoot() or nil
    local function finish(result)
        if token then releaseRoot(token) end
        return result
    end
    local function ownsRoot()
        if not token then return true end
        if not holdsRoot(token) then return false end
        refreshRoot(token)
        return true
    end
    -- Interpolation base: a fixed point and the time the flight left it.
    local baseX,baseY,baseZ=startPos.X,startPos.Y,startPos.Z
    local duration=distance/moveSpeed
    local baseTime=clock()
    -- Last point written (snap-back check); nil right after a (re)base.
    local wroteX,wroteY,wroteZ=nil,nil,nil
    local function rebase()
        local part=currentPart()
        local okPos,pos=pcall(function() return part and part.Position end)
        if okPos and pos and pos.X then baseX,baseY,baseZ=pos.X,pos.Y,pos.Z end
        dx=targetPos.X-baseX; dy=targetPos.Y-baseY; dz=targetPos.Z-baseZ
        duration=math.max(math.sqrt(dx*dx+dy*dy+dz*dz)/moveSpeed,FRAME_TIME)
        baseTime=clock()
        wroteX=nil
    end
    -- True when the root is far off the point this flight last wrote: the
    -- server refused the movement and put the root back (see TWEEN_SERVER_CAP).
    local function snappedBack(part)
        if not isLocalRoot or wroteX==nil then return false end
        local okPos,pos=pcall(function() return part.Position end)
        if not okPos or not pos or not pos.X then return false end
        local ex,ey,ez=pos.X-wroteX,pos.Y-wroteY,pos.Z-wroteZ
        return ex*ex+ey*ey+ez*ez>TWEEN_SNAP_DIST*TWEEN_SNAP_DIST
    end
    local lastWrite=-1e9
    while keepGoing() do
        if not ownsRoot() then return false end -- a newer tween owns the root
        markTravel() -- a background CommF_ invoke (Auto Stat) waits until the flight is over
        local step=writeInterval(TWEEN_STEP_TIME)
        local now=clock()
        if writesPaused() then
            -- CommF_ quiet window (quietInvoke): no write. Resume from where
            -- the root is when the window closes (no jump back onto the line).
            repeat
                if not ownsRoot() then return false end
                markTravel()
                task.wait(0.05)
            until not writesPaused() or not keepGoing()
            rebase()
        elseif now-lastWrite<step-0.004 then
            -- Write floor: one write per frame (4 ms jitter slack), even when
            -- task.wait resumes early.
            task.wait(step-(now-lastWrite))
        else
            local part=currentPart()
            if not part then return finish(false) end
            if snappedBack(part) then
                -- Follow the server instead of writing on along the old line
                -- (it refuses every write that far ahead): slow down and
                -- re-base from where it put the root. A drift after a long
                -- gap since the last write (frame hitch: gravity) only
                -- re-bases; it says nothing about the server's limit.
                if now-lastWrite<0.25 then
                    moveSpeed=math.max(TWEEN_SERVER_FLOOR,moveSpeed*TWEEN_SNAP_SLOWDOWN)
                    TWEEN_SERVER_CAP=math.max(TWEEN_SERVER_FLOOR,math.min(TWEEN_SERVER_CAP,moveSpeed))
                end
                rebase()
                now=clock()
            end
            local alpha=math.min((now-baseTime)/duration,1)
            local wx,wy,wz=baseX+dx*alpha,baseY+dy*alpha,baseZ+dz*alpha
            if placeRoot(part,wx,wy,wz,rotationCF) then
                wroteX,wroteY,wroteZ=wx,wy,wz
                lastWrite=now
                if alpha>=1 then
                    -- Arrival: final CFrame with zero velocity for three
                    -- consecutive frames (this one plus two), then hand over.
                    for _=1,2 do
                        task.wait(step)
                        local last=currentPart()
                        if not last or not ownsRoot() then break end
                        placeRoot(last,targetPos.X,targetPos.Y,targetPos.Z,rotationCF)
                    end
                    return finish(true)
                end
                task.wait(step)
            elseif not writesPaused() then
                return finish(false) -- the root left the DataModel
            end
            -- else: a quiet window began between the check and the write;
            -- the pause branch above handles it on the next pass.
        end
    end
    return finish(false)
end

-- Load marker: this chunk ran to the end.
if LACED_LOAD and type(LACED_LOAD.done) == "table" then LACED_LOAD.done["00_core"] = true end
-- @chunk 05_uelib  (UE UI library loader; shared by every game build)
local LACED_LOAD = type(_G.__lacedLoad) == "table" and _G.__lacedLoad or nil -- load marker (loader.lua)
if LACED_LOAD and type(LACED_LOAD.started) == "table" then LACED_LOAD.started["05_uelib"] = true end
-- Per-execution bindings: captured at chunk load so a re-run of the script
-- cannot make this copy's loops read the new copy's state (alive is a
-- closure over this run's state since the Oct 15 stability pass).
local alive = alive
local SCRIPT_STATE = SCRIPT_STATE
local S = S
local shutdownScript = shutdownScript -- this run's (00_core), for the UE OnUnload hook
UE_URL = "https://raw.githubusercontent.com/hauntedscripts/Scripts2/refs/heads/main/matcha%20ue"

function ueEnvironments()
    local envs = {}
    local getgenvFn = _G.getgenv
    if type(getgenvFn) == "function" then
        local okGenv, genv = pcall(getgenvFn)
        if okGenv and type(genv) == "table" then table.insert(envs, genv) end
    end
    table.insert(envs, _G)
    return envs
end

-- loadstring drops top-level returns in Matcha, so the library is only
-- reachable through the UELibrary global it publishes.
function findExposedUE()
    for _, env in ipairs(ueEnvironments()) do
        local candidate = env.UELibrary
        if type(candidate) == "table" and type(candidate.CreateWindow) == "function" then return candidate end
    end
    for _, env in ipairs(ueEnvironments()) do
        local candidate = env.Library
        if type(candidate) == "table" and type(candidate.CreateWindow) == "function" and candidate.Raw == nil then
            return candidate
        end
    end
    return nil
end

function validateUESource(body)
    if type(body) ~= "string" or #body < 2000 then
        return false, "empty or truncated download (" .. tostring(type(body) == "string" and #body or 0) .. " bytes)"
    end
    local head = string.lower(string.sub(body, 1, 300))
    if string.find(head, "<!doctype", 1, true) or string.find(head, "<html", 1, true)
        or string.find(head, "404: not found", 1, true) then
        return false, "server returned an error page instead of the library"
    end
    if not string.find(body, "CreateWindow", 1, true) or not string.find(body, "UELibrary", 1, true) then
        return false, "downloaded file is not the UE library"
    end
    return true, nil
end

UE_DOWNLOAD_ATTEMPTS = 3 -- bounded retry: 1 s, then 2 s between attempts

function loadUEAdapter()
    local ueSource, valid, reason = "", false, nil
    for attempt = 1, UE_DOWNLOAD_ATTEMPTS do
        ueSource = safeHttpGet(UE_URL)
        valid, reason = validateUESource(ueSource)
        if valid or attempt == UE_DOWNLOAD_ATTEMPTS then break end
        warnThrottled("ueDownload", "[laced.club] UE download rejected (" .. tostring(reason) .. "), retrying", 5)
        task.wait(attempt)
    end
    assert(valid, "UE download rejected: " .. tostring(reason))

    local previousUE = findExposedUE()
    local ueChunk = loadstring(ueSource, "laced.club UE")
    assert(type(ueChunk) == "function", "UE compile failed")
    ueChunk()

    local UE = findExposedUE()
    -- A new UE copy that fails the checks below has already created its
    -- windows (and unloaded the previous copy): unload it, do not leave a
    -- half-built menu on screen.
    local function rejectNewUE(message)
        if type(UE) == "table" and UE ~= previousUE and type(UE.Unload) == "function" and not UE._unloaded then
            pcall(function() UE:Unload() end)
        end
        assert(false, message)
    end
    if type(UE) ~= "table" then rejectNewUE("UE did not expose UELibrary") end
    if UE == previousUE then rejectNewUE("UE chunk did not run (stale UELibrary from a previous execution)") end
    if UE._unloaded then rejectNewUE("UE library is already unloaded") end
    if type(UE.CreateWindow) ~= "function" then rejectNewUE("UE library has no CreateWindow") end

    local controls = {}

    local function roundTo(value, decimals)
        local power = 10 ^ (decimals or 0)
        return math.floor(value * power + 0.5) / power
    end

    local function roundingFor(step, explicit)
        local explicitNumber = tonumber(explicit)
        if explicitNumber then return math.max(0, math.floor(explicitNumber)) end
        step = tonumber(step) or 1
        if step >= 1 then return 0 end
        local decimals = tostring(step):match("%.(%d+)")
        return decimals and #decimals or 0
    end

    local function enhanceControl(id, control)
        if not control then return control end
        controls[id] = control
        control.Set = control.SetValue
        control.SetOptions = control.SetValues
        return control
    end

    local function makeTab(rawTab)
        local tab = { Raw = rawTab, Groups = {} }

        local function columnOf(info)
            local column = tonumber(info and info.Column) or 1
            return column == 2 and 2 or 1
        end

        local function groupFor(self, info)
            local column = columnOf(info)
            local group = self.Groups[column]
            if not group then
                if column == 2 then group = self.Raw:AddRightGroupbox("General")
                else group = self.Raw:AddLeftGroupbox("General") end
                self.Groups[column] = group
            end
            return group
        end

        function tab:AddSection(name, info)
            local column = columnOf(info)
            local group
            if column == 2 then group = self.Raw:AddRightGroupbox(name)
            else group = self.Raw:AddLeftGroupbox(name) end
            self.Groups[column] = group
            return group
        end

        function tab:AddToggle(id, info)
            info = info or {}
            local group = groupFor(self, info)
            local toggle = group:AddToggle(id, {
                Text = info.Text or id,
                Default = info.Default == true,
                Callback = info.Callback,
                Tooltip = info.Description,
                Risky = info.Risky == true,
            })
            enhanceControl(id, toggle)
            if info.Keybind == true then
                local picker = toggle:AddKeyPicker(id .. "_keybind", {
                    Text = (info.Text or id) .. " key",
                    Default = "None",
                    Mode = "Toggle",
                    SyncToggleState = true,
                })
                enhanceControl(id .. "_keybind", picker)
            end
            return toggle
        end

        function tab:AddSlider(id, info)
            info = info or {}
            -- A slider declared with Decimals but no Step must not snap to whole numbers.
            local step = tonumber(info.Step)
            if not step then
                local decimals = tonumber(info.Decimals)
                step = (decimals and decimals > 0) and (10 ^ -math.floor(decimals)) or 1
            end
            if step <= 0 then step = 1 end
            local minimum = tonumber(info.Min) or 0
            local maximum = tonumber(info.Max) or 100
            local rounding = roundingFor(step, info.Decimals)
            local callback = info.Callback
            local slider
            local function changed(value)
                value = tonumber(value) or minimum
                local snapped = minimum + math.floor(((value - minimum) / step) + 0.5) * step
                snapped = roundTo(snapped, rounding)
                if snapped < minimum then snapped = minimum end
                if snapped > maximum then snapped = maximum end
                if slider then slider.Value = snapped end
                if callback then callback(snapped) end
            end
            slider = groupFor(self, info):AddSlider(id, {
                Text = info.Text or id,
                Default = info.Default,
                Min = minimum,
                Max = maximum,
                Rounding = rounding,
                Suffix = info.Suffix or "",
                Callback = changed,
                Tooltip = info.Description,
            })
            return enhanceControl(id, slider)
        end

        function tab:AddDropdown(id, info)
            info = info or {}
            local values = info.Options or info.Values or {}
            local default = info.Default
            if default ~= nil and not info.Multi then
                local found = false
                for _, value in ipairs(values) do
                    if value == default then found = true; break end
                end
                if not found then default = values[1] end
            end
            local dropdown = groupFor(self, info):AddDropdown(id, {
                Text = info.Text or id,
                Default = default,
                Values = values,
                Multi = info.Multi == true,
                AllowNull = info.AllowNull == true,
                Callback = info.Callback,
                Tooltip = info.Description,
            })
            return enhanceControl(id, dropdown)
        end

        function tab:AddButton(id, info)
            info = info or {}
            local button = groupFor(self, info):AddButton({
                Text = info.Text or id,
                Func = info.Callback,
                Tooltip = info.Description,
                DoubleClick = info.DoubleClick == true,
            })
            return enhanceControl(id, button)
        end

        -- Text box (UE GroupMethods:AddInput). Numeric = true only takes the
        -- digit keys; UE appends each typed key to Value and calls Callback
        -- with the whole string (Finished = true: only on Enter).
        function tab:AddInput(id, info)
            info = info or {}
            local input = groupFor(self, info):AddInput(id, {
                Text = info.Text or id,
                Default = info.Default,
                Numeric = info.Numeric == true,
                Finished = info.Finished == true,
                Placeholder = info.Placeholder,
                Callback = info.Callback,
                Tooltip = info.Description,
            })
            return enhanceControl(id, input)
        end

        -- Read-only text line (UE GroupMethods:AddLabel(text, wraps)). UE draws
        -- the control's Text field every frame, so writing label.Text updates it.
        -- Not registered in Controls: labels have no value to save or reset.
        function tab:AddLabel(id, info)
            info = info or {}
            local label = groupFor(self, info):AddLabel(info.Text or id, info.Wrap == true)
            return label
        end

        function tab:AddPriorityList(id, info)
            info = info or {}
            local group = groupFor(self, info)
            local options = info.Options or {}
            local selected = {}
            for index, value in ipairs(info.Default or options) do selected[index] = value end
            local pickers = {}
            local changing = false

            local function emit()
                if info.Callback then
                    local order = {}
                    for index = 1, #options do order[index] = selected[index] end
                    info.Callback(order)
                end
            end

            for index = 1, #options do
                local slot = index
                local picker = group:AddDropdown(id .. "_" .. tostring(slot), {
                    Text = (info.Text or id) .. " " .. tostring(slot),
                    Default = selected[slot],
                    Values = options,
                    Callback = function(value)
                        if changing then return end
                        local previous = selected[slot]
                        local duplicate = nil
                        for other = 1, #selected do
                            if other ~= slot and selected[other] == value then duplicate = other; break end
                        end
                        selected[slot] = value
                        if duplicate then
                            selected[duplicate] = previous
                            if pickers[duplicate] then pickers[duplicate].Value = previous end
                        end
                        emit()
                    end,
                    Tooltip = info.Description,
                })
                pickers[slot] = picker
                enhanceControl(id .. "_" .. tostring(slot), picker)
            end

            local list = { Pickers = pickers, Value = selected }
            function list:SetValue(order)
                if type(order) ~= "table" then return self end
                changing = true
                for index = 1, math.min(#order, #pickers) do
                    selected[index] = order[index]
                    pickers[index].Value = order[index]
                end
                changing = false
                emit()
                return self
            end
            function list:SetValues(values)
                for _, picker in ipairs(pickers) do picker:SetValues(values or {}) end
                return self
            end
            list.SetOptions = list.SetValues
            controls[id] = list
            return list
        end

        return tab
    end

    local Adapter = { Raw = UE, Controls = controls, Windows = {} }

    local function makePopup(adapter, info)
        info = info or {}
        local wasToggled = adapter.Raw.Toggled
        local raw = adapter.Raw:CreateWindow({
            Title = info.Title or "Settings",
            Width = info.Width or 520,
            Height = info.Height or 500,
            AutoShow = false,
            Center = true,
        })
        -- CreateWindow copies the new (hidden) window's visibility into
        -- Library.Toggled, which would hide the main menu; restore it.
        adapter.Raw.Toggled = wasToggled ~= false
        local page = makeTab(raw:AddTab(info.Title or "Settings"))
        local popup = { Raw = raw }
        function popup:AddSection(...) return page:AddSection(...) end
        function popup:AddToggle(...) return page:AddToggle(...) end
        function popup:AddSlider(...) return page:AddSlider(...) end
        function popup:AddDropdown(...) return page:AddDropdown(...) end
        function popup:AddButton(...) return page:AddButton(...) end
        function popup:AddInput(...) return page:AddInput(...) end
        function popup:AddPriorityList(...) return page:AddPriorityList(...) end
        function popup:Show() raw:Show(); return self end
        function popup:Hide() raw:Hide(); return self end
        function popup:Set(id, value)
            local control = controls[id]
            if control and control.SetValue then control:SetValue(value)
            elseif control and control.Set then control:Set(value) end
            return self
        end
        return popup
    end

    -- True when the hook was installed (UE builds without OnUnload cannot stop
    -- the script from the menu's Unload button).
    function Adapter:OnUnload(callback)
        if type(self.Raw.OnUnload) == "function" then
            self.Raw:OnUnload(callback)
            return true
        end
        return false
    end

    function Adapter:CreateWindow(info)
        info = info or {}
        local accent = info.Theme and info.Theme.Colors and info.Theme.Colors.Accent
        if accent then
            -- StaticAccentColor is what the Settings tab picker, Rainbow-off and
            -- config load restore to; without it the accent snaps back to blue.
            self.Raw.AccentColor = accent
            self.Raw.StaticAccentColor = accent
        end
        if info.ConfigFile or info.SettingsFile then
            self.Raw.SettingsFile = (info.ConfigFile or info.SettingsFile) .. ".ui.json"
        end
        local raw = self.Raw:CreateWindow({
            Title = info.Title or "laced.club",
            Width = info.Width or 540,
            Height = info.Height or 430,
            AutoShow = true,
            Center = true,
        })
        local window = {
            Raw = raw,
            Tabs = {},
            Indicator = { SetVisible = function() end },
            Config = { IndicatorEnabled = false },
            _lastMenuDown = false,
        }

        local configFolder = tostring(info.ConfigFolder or "laced_club_configs")
        local selectedConfig = ""
        local function safeConfigName(name)
            name = tostring(name or ""):gsub("[^%w%._%- ]", "_"):gsub("^%s+", ""):gsub("%s+$", "")
            if name == "" then name = "default" end
            return name:sub(1, 64)
        end
        local function ensureConfigFolder()
            pcall(function()
                if not isfolder(configFolder) then makefolder(configFolder) end
            end)
        end
        local function configPathFor(name)
            return configFolder .. "/" .. safeConfigName(name) .. ".json"
        end
        local function listConfigNames()
            ensureConfigFolder()
            local names = {}
            local ok, files = pcall(listfiles, configFolder)
            if ok and type(files) == "table" then
                for _, path in ipairs(files) do
                    -- listfiles returns workspace-relative paths with backslashes.
                    local fileName = tostring(path):match("([^/\\]+)%.json$")
                    if fileName then table.insert(names, fileName) end
                end
            end
            table.sort(names)
            return names
        end
        local configPath = configPathFor("default")
        local function configValue(control)
            if not control then return nil end
            local kind = control.Type
            if kind == "Toggle" then return control.Value == true end
            if kind == "Slider" then return tonumber(control.Value) end
            if kind == "KeyPicker" then
                return type(control.Value) == "string" and control.Value or "None"
            end
            if kind == "Dropdown" then
                if control.Multi then
                    local out = {}
                    for key, value in pairs(control.Value or {}) do
                        if type(key) == "string" then out[key] = value == true end
                    end
                    return out
                end
                return type(control.Value) == "string" and control.Value or nil
            end
            return nil
        end
        local function saveFeatureConfig(name)
            name = safeConfigName(name or selectedConfig)
            ensureConfigFolder()
            local path = configPathFor(name)
            local data = { version = 4, controls = {}, name = name }
            for id, control in pairs(controls) do
                local value = configValue(control)
                if value ~= nil then data.controls[id] = value end
            end
            local ok = pcall(function()
                local http = game:GetService("HttpService")
                writefile(path, http:JSONEncode(data))
            end)
            if ok then
                selectedConfig = name
                configPath = path
                window.Config.File = path
            end
            return ok
        end
        local function loadFeatureConfig(name)
            name = safeConfigName(name or selectedConfig)
            local path = configPathFor(name)
            -- readfile raises on a missing file in Matcha.
            local okExists, exists = pcall(isfile, path)
            if not okExists or not exists then return false end
            local wasVisible = raw.Visible
            local wasToggled = self.Raw.Toggled
            local ok, data = pcall(function()
                local http = game:GetService("HttpService")
                return http:JSONDecode(readfile(path))
            end)
            if not ok or type(data) ~= "table" or data.version ~= 4 or type(data.controls) ~= "table" then
                return false
            end
            local toggleStates = {}
            for id, saved in pairs(data.controls) do
                local control = controls[id]
                local value = saved
                -- Also accept the UE Settings-tab format { type = ..., value = ... }.
                if type(saved) == "table" and saved.value ~= nil and saved.type ~= nil then value = saved.value end
                if control and control.Type == "Toggle" and type(value) == "boolean" then
                    toggleStates[id] = value
                elseif control and control.Type ~= "Button" and control.SetValue then
                    pcall(function() control:SetValue(value) end)
                end
            end
            local previous = {}
            for id, value in pairs(toggleStates) do
                local control = controls[id]
                if control then
                    previous[id] = control.Value == true
                    control.Value = value
                end
            end
            for id, value in pairs(toggleStates) do
                local control = controls[id]
                if control and previous[id] ~= value then
                    pcall(function() if control.Callback then control.Callback(value) end end)
                    pcall(function() if control.Changed then control.Changed(value) end end)
                end
            end
            for id, value in pairs(toggleStates) do
                local control = controls[id]
                if control then control.Value = value end
            end
            raw.Visible = wasVisible
            self.Raw.Toggled = wasToggled
            raw._visibilityDirty = true
            selectedConfig = name
            configPath = path
            window.Config.File = path
            return true
        end
        local function refreshConfigList(dropdown)
            local names = listConfigNames()
            if dropdown and dropdown.SetValues then
                pcall(function() dropdown:SetValues(names) end)
            end
            if selectedConfig == "" and names[1] then selectedConfig = names[1] end
            return names
        end
        window.Config = {
            IndicatorEnabled = false,
            File = configPath,
            Folder = configFolder,
            Save = function(name) return saveFeatureConfig(name) end,
            Load = function(name) return loadFeatureConfig(name) end,
            Refresh = function(dropdown) return refreshConfigList(dropdown) end,
            List = function() return listConfigNames() end,
        }

        function window:AddTab(name)
            local tab = makeTab(raw:AddTab(name))
            self.Tabs[name] = tab
            return tab
        end

        function window:Set(id, value)
            local control = controls[id]
            if control and control.SetValue then control:SetValue(value)
            elseif control and control.Set then control:Set(value) end
            return self
        end

        function window:CreatePopup(popupInfo)
            return makePopup(Adapter, popupInfo)
        end

        function window:Show() raw:Show(); return self end
        function window:Hide() raw:Hide(); return self end
        function window:SetVisible(value) if value then raw:Show() else raw:Hide() end; return self end

        function window:Step()
            return self
        end

        table.insert(Adapter.Windows, window)

        -- The UE Settings tab owns the visible config UI; point Window.Config
        -- at the same store so both paths read and write the same files.
        local ueConfigs = self.Raw.Configs
        if type(ueConfigs) == "table" then
            window.Config.Folder = ueConfigs.Folder or window.Config.Folder
            window.Config.File = tostring(window.Config.Folder) .. "/default.json"
            if type(ueConfigs.Save) == "function" then window.Config.Save = ueConfigs.Save end
            if type(ueConfigs.Load) == "function" then window.Config.Load = ueConfigs.Load end
            if type(ueConfigs.Refresh) == "function" then window.Config.Refresh = ueConfigs.Refresh end
        end
        return window
    end

    return Adapter
end

do
    local okUE, ueResult = pcall(loadUEAdapter)
    if okUE and type(ueResult) == "table" then
        Library = ueResult
        menuUE = ueResult.Raw
        SCRIPT_STATE.ue = ueResult.Raw
    else
        -- assert, not return: a plain return used to end only this chunk, so
        -- the loader ran 20_ui2 into a nil index. The loader catches this and
        -- runs this run's shutdownScript.
        warn("Failed to load UE UI: " .. tostring(ueResult))
        assert(false, "[laced.club] UE UI failed to load: " .. tostring(ueResult))
    end
end

-- Load marker: this chunk ran to the end.
if LACED_LOAD and type(LACED_LOAD.done) == "table" then LACED_LOAD.done["05_uelib"] = true end
-- @chunk 10_ui  (Anime Piece: window, tabs and controls)
local LACED_LOAD = type(_G.__lacedLoad) == "table" and _G.__lacedLoad or nil -- load marker (loader.lua)
if LACED_LOAD and type(LACED_LOAD.started) == "table" then LACED_LOAD.started["10_ui"] = true end
-- Per-execution bindings (see 10_ui): a re-run cannot make this copy's
-- callbacks write the new copy's state.
local SCRIPT_STATE = SCRIPT_STATE
local S = S
local shutdownScript = shutdownScript

-- Anime Piece state lives on this run's S next to the shared fields from
-- 00_core (unloaded, remoteQuiet, ...), so shutdownScript and alive() cover it.
S.apAfq          = false -- Auto Farm Quest (60_afq)
S.apFruitFarm    = false -- fly to spawned world fruits (70_fruit)
S.apFruitStore   = true  -- store any fruit tool you hold or carry
S.apGacha        = false -- roll Luzefe's fruit gacha whenever it is ready
S.apGachaNow     = false -- set by the "Roll Now" button, cleared by the loop
S.apFlySpeed     = 200   -- studs/s; tweenTo caps flights over 300 studs at 250
S.apAttackRange  = 3     -- studs in front of the target while swinging
S.apAttackRate   = 2.5   -- swings/s; the game's own M1 cooldown is 0.38 s
S.apAttackHeight = 0     -- studs above the target, facing down; 0 = spot in front (anti-cheat safe, see docs)
S.apWeaponSlot   = 1     -- hotbar key AFQ presses when nothing is held (1..9, 0 = slot 10)
S.apPaused       = false -- the fruit farm owns the root (AFQ yields)

Window = Library:CreateWindow({
    Title = "laced.club | Anime Piece",
    Columns = 2,
    Divider = true,
    ConfigFile = "laced_animepiece.json",
    BuiltInIndicatorToggle = false,
    Width = 540,
    Height = 480,
    Theme = { Colors = { Accent = Color3.fromRGB(255,111,0) } }
})

-- Unload hook right after the window exists (see 10_ui for why).
SCRIPT_STATE.library = Library
SCRIPT_LIBRARY = Library
if not Library:OnUnload(function() shutdownScript("ui") end) then
    warn("[laced.club] this UE build has no OnUnload: the menu's Unload button cannot stop the script")
end

mainTab = Window:AddTab("Main")
settingsTab = Window:AddTab("Settings")

mainTab:AddSection("Auto Farm Quest", { Column = 1 })
mainTab:AddToggle("ap_afq", {
    Text = "Auto Farm Quest",
    Description = "Takes the best kill quest for your level and farms it; switches quest on level up",
    Default = false, Column = 1,
    Callback = function(v)
        S.apAfq = v
        notify(v and "Auto Farm Quest ON!" or "Auto Farm Quest OFF!", "laced.club", 2)
    end
})
-- UE appends every typed digit to the box, so the last digit is the slot.
mainTab:AddInput("ap_weapon_slot", {
    Text = "Weapon Slot (1-0)", Default = tostring(S.apWeaponSlot), Numeric = true,
    Placeholder = "1", Column = 1,
    Description = "Hotbar key AFQ presses when your hand is empty (0 = slot 10); any tool, fruits included. The key only reaches Roblox while it is focused; once something is held AFQ runs unfocused.",
    Callback = function(v)
        local digit = tonumber(string.match(tostring(v or ""), "(%d)$"))
        if digit then S.apWeaponSlot = digit end
    end
})
S.apAfqLabel = mainTab:AddLabel("ap_afq_status", { Text = "Auto Farm Quest: off", Column = 1 })

mainTab:AddSection("Fruits", { Column = 2 })
mainTab:AddToggle("ap_fruit_farm", {
    Text = "Auto Farm Fruits",
    Description = "Flies to spawned world fruits and picks them up (pauses Auto Farm Quest meanwhile)",
    Default = false, Column = 2,
    Callback = function(v)
        S.apFruitFarm = v
        if not v then S.apPaused = false end
        notify(v and "Auto Farm Fruits ON!" or "Auto Farm Fruits OFF!", "laced.club", 2)
    end
})
mainTab:AddToggle("ap_fruit_store", {
    Text = "Auto Store Fruits",
    Description = "Stores every fruit tool in your backpack or hand",
    Default = true, Column = 2,
    Callback = function(v) S.apFruitStore = v end
})
mainTab:AddToggle("ap_gacha", {
    Text = "Auto Fruit Gacha",
    Description = "Rolls Luzefe's fruit gacha whenever the game says you can (money and cooldown)",
    Default = false, Column = 2,
    Callback = function(v)
        S.apGacha = v
        notify(v and "Auto Fruit Gacha ON!" or "Auto Fruit Gacha OFF!", "laced.club", 2)
    end
})
mainTab:AddButton("ap_gacha_now", { Text = "Roll Gacha Now", Column = 2, Callback = function() S.apGachaNow = true end })
S.apFruitLabel = mainTab:AddLabel("ap_fruit_status", { Text = "Fruits: idle", Column = 2 })

settingsTab:AddSection("Movement and combat", { Column = 1 })
settingsTab:AddSlider("ap_fly_speed", {
    Text = "Fly Speed", Min = 50, Max = 300, Step = 10, Default = S.apFlySpeed, Integer = true, Column = 1,
    Callback = function(v) S.apFlySpeed = math.max(50, tonumber(v) or 200) end
})
settingsTab:AddSlider("ap_attack_range", {
    Text = "Attack Distance", Min = 2, Max = 8, Step = 1, Default = S.apAttackRange, Integer = true, Column = 1,
    Callback = function(v) S.apAttackRange = math.max(2, tonumber(v) or 3) end
})
settingsTab:AddSlider("ap_attack_height", {
    Text = "Attack Height", Min = 0, Max = 10, Step = 1, Default = S.apAttackHeight, Integer = true, Column = 1,
    Description = "0 = stand in front (anti-cheat safe). Above 0 hovers facing down: measured at the kick threshold, risky (see docs)",
    Callback = function(v) S.apAttackHeight = math.max(0, tonumber(v) or 0) end
})
settingsTab:AddSlider("ap_attack_rate", {
    Text = "Swings Per Second", Min = 1, Max = 2.6, Step = 0.1, Default = S.apAttackRate, Column = 1,
    Callback = function(v) S.apAttackRate = math.max(1, tonumber(v) or 2.5) end
})

-- Load marker: this chunk ran to the end.
if LACED_LOAD and type(LACED_LOAD.done) == "table" then LACED_LOAD.done["10_ui"] = true end
-- @chunk 40_combat  (Anime Piece: player data, enemies, remote M1)
local LACED_LOAD = type(_G.__lacedLoad) == "table" and _G.__lacedLoad or nil -- load marker (loader.lua)
if LACED_LOAD and type(LACED_LOAD.started) == "table" then LACED_LOAD.started["40_combat"] = true end
local alive = alive
local S = S

-- Game map and the live checks behind it: docs/ANIME_PIECE.md.
--
-- Matcha in this game: GetAttribute on a non-empty STRING attribute kills
-- the whole thread (pcall does not catch it), so nothing here reads the
-- player's string attributes (ActualQuest, ActualTool, ...). The same data
-- is in ReplicatedStorage.Shared.PlayerStats[<name>] as StringValues, which
-- read fine. Boolean attributes (InQuest, CanGacha) are safe.

AP = {}
AP.FRUITS = { "Copy", "Kilo", "Warrior", "Bomb", "Flame", "Emperor",
    "Scarlet", "Quake", "Beast", "Light", "Infinity", "Vessel" }
AP.FRUIT_SET = {}
for _, name in ipairs(AP.FRUITS) do AP.FRUIT_SET[name] = true end

local ReplicatedStorage = game:GetService("ReplicatedStorage")

function AP.remote(name)
    local folder = ReplicatedStorage:FindFirstChild("Remotes")
    return folder and folder:FindFirstChild(name)
end

-- The player's stats folder (re-resolved each call: it is rebuilt on rejoin).
function AP.stats()
    local shared = ReplicatedStorage:FindFirstChild("Shared")
    local all = shared and shared:FindFirstChild("PlayerStats")
    return all and all:FindFirstChild(LocalPlayer.Name)
end

local function statValue(folderName, valueName)
    local value
    pcall(function()
        local stats = AP.stats()
        local folder = stats and stats:FindFirstChild(folderName)
        local object = folder and folder:FindFirstChild(valueName)
        if object then value = object.Value end
    end)
    return value
end

-- Infos.Level is the real level; the player's Level attribute lags behind.
function AP.level() return tonumber(statValue("Infos", "Level")) or 0 end
function AP.money() return tonumber(statValue("Infos", "Money")) or 0 end
-- Quest.QuestId as a number when the game fills it in. Live on 2026-10-31
-- it stayed "" through a whole accept of quest 003, so it is only a hint:
-- InQuest and the quest text below are what tell the state.
function AP.questId()
    local id = statValue("Quest", "QuestId")
    return tonumber(id)
end

function AP.boolAttribute(name)
    local value
    pcall(function() value = LocalPlayer:GetAttribute(name) end)
    return value == true
end

-- InQuest (bool attribute, safe to read) flips true on an accept the server
-- took and false on Quit; a rejected accept (level too low) leaves it false.
function AP.inQuest() return AP.boolAttribute("InQuest") end

-- Text of the quest panel: "Defeat Higaro's bandits (0/5)". The title keeps
-- the last quest's name after a quit, so only trust it while InQuest.
function AP.questText()
    local text
    pcall(function()
        local desc = LocalPlayer.PlayerGui.Interfaces.Screen.Quest.Current:FindFirstChild("Description")
        text = desc and desc.Text
    end)
    return type(text) == "string" and text or ""
end

-- Kills done and needed, from the "(n/m)" in the quest text (Quest.Progress
-- stays 0 while the panel counts).
function AP.questProgress()
    local done, need = string.match(AP.questText(), "%((%d+)/(%d+)%)")
    if done then return tonumber(done), tonumber(need) end
    return tonumber(statValue("Quest", "Progress")) or 0, nil
end

function AP.root()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChild("Humanoid")
    if not root or not hum then return nil end
    local okHealth, health = pcall(function() return hum.Health end)
    if not okHealth or not health or health <= 0 then return nil end
    return root
end

-- "Bandit [0+]" -> "Bandit"; bosses have no level tag.
function AP.baseName(name)
    return (string.gsub(name, "%s*%[%d+%+%]$", ""))
end

function AP.enemyFolder()
    local world = Workspace:FindFirstChild("World")
    local play = world and world:FindFirstChild("Playability")
    return play and play:FindFirstChild("Enemys")
end

-- Root part of a live enemy, nil when it is dead or streamed out (far
-- enemies keep their model but lose the HumanoidRootPart).
function AP.enemyRoot(model)
    local root, living = nil, false
    pcall(function()
        local hum = model:FindFirstChild("Humanoid")
        root = model:FindFirstChild("HumanoidRootPart")
        living = model.Parent ~= nil and hum ~= nil and hum.Health > 0
    end)
    if living and root then return root end
    return nil
end

-- Nearest live enemy whose base name is in `names` (a set), optionally only
-- within `radius` of `center`.
function AP.nearestEnemy(names, center, radius)
    local folder = AP.enemyFolder()
    local me = AP.root()
    if not folder or not me then return nil end
    local from = me.Position
    local best, bestRoot, bestDist = nil, nil, math.huge
    for _, model in ipairs(folder:GetChildren()) do
        if model.ClassName == "Model" and names[AP.baseName(model.Name)] then
            local root = AP.enemyRoot(model)
            if root then
                local pos = root.Position
                if not center or (pos - center).Magnitude <= radius then
                    local dist = (pos - from).Magnitude
                    if dist < bestDist then best, bestRoot, bestDist = model, root, dist end
                end
            end
        end
    end
    return best, bestRoot
end

-- Facing rotation (CFrame.lookAt is not bound in Matcha).
function AP.facing(fromPos, toPos)
    local d = toPos - fromPos
    if math.abs(d.X) + math.abs(d.Z) < 0.01 then return CFrame.fromOrientation(0, 0, 0) end
    return CFrame.fromOrientation(0, math.atan2(-d.X, -d.Z), 0)
end

-- True when the character holds any Tool (the server's M1 uses it; fruits
-- have M1 too, so they count).
function AP.holdsTool()
    local char = LocalPlayer.Character
    if not char then return false end
    for _, child in ipairs(char:GetChildren()) do
        if child.ClassName == "Tool" then return true end
    end
    return false
end

-- Whatever the player holds is their weapon; only an empty hand is acted on
-- (without a tool Combat Event does no damage). Then the Weapon Slot key
-- (1..9, 0 = slot 10) is pressed, whatever that slot holds. Matcha cannot
-- equip a tool without input: a client Parent write does not stick, there
-- is no EquipTool, and keypress (even after setrobloxinput(true)) only
-- reaches Roblox while it is the focused window, so the key is only sent
-- then (unfocused it would type into the other window). Returns false and
-- a hint when the hand is still empty; callers keep going either way.
VK_DIGIT0 = 0x30
EQUIP_RETRY = 2 -- s between slot key presses while the hand stays empty
local lastEquip = -1e9

function AP.equipWeapon()
    if AP.holdsTool() then return true end
    local slot = math.floor(tonumber(S.apWeaponSlot) or 1) % 10
    if not robloxFocused() then
        return false, ("nothing held: equip slot %d (or focus Roblox once)"):format(slot)
    end
    local now = clock()
    if now - lastEquip >= EQUIP_RETRY then
        lastEquip = now
        pcall(keypress, VK_DIGIT0 + slot)
        task.wait(0.1)
        pcall(keyrelease, VK_DIGIT0 + slot)
        task.wait(0.3)
    end
    if AP.holdsTool() then return true end
    return false, ("nothing held: pressed slot %d"):format(slot)
end

-- Remote M1, the game's own path (Combat Action): Combat Event:FireServer(n)
-- with the combo step 1..4 and the equipped tool. The client sends only the
-- combo step (no target list, extra args ignored): the server hit box comes
-- from the root's position and facing. So the root goes S.apAttackHeight
-- studs straight above the target facing down, where M1 still lands (live:
-- 7 studs hit, 10 and 15 did not) and the enemies' melee does not (standing
-- in front lost 23 HP in 2.4 s, overhead lost none). Height 0 keeps the old
-- spot AP.range studs in front, facing it.
--
-- One write per swing, never more, and the hover is NOT held between swings
-- (the root falls): the game's client check (Client Anti Exploiter["Anti
-- Enemy Weld"], docs) samples every 0.05 s and, with an enemy within 10
-- studs, counts a sample when the root moved > 0.1, the distance changed
-- <= 0.75 and the offset changed > 0.1; 5+ in 0.5 s while hitting is a
-- strike, 5 strikes a kick. Re-placing after every 1.5 stud sag counted ~8
-- per window and got us kicked in ~2.5 s. A free fall only counts its first
-- ~2 samples (after that it drops > 0.75 per sample), so one write per
-- swing stays under 5. A per-frame hold is not possible: one placeRoot
-- costs ~38 ms in Matcha.
--
-- Armed, even the ground spot trips it: hits knock both bodies around
-- every sample (mirror: 3-5 per window in 2.5 s; InHit and Stunned are set
-- by the server during real hits). But a sample with NO enemy within 10
-- studs resets the window, and a strike is only judged once a window fills
-- 0.5 s. So HIT_DWELL s after each swing the root steps RETREAT_DIST studs
-- out from the target along the ground (out of the 10 stud radius, no fall)
-- and comes back for the next swing: ~4 samples in range per swing, the
-- window never fills, and half of the time is out of melee reach. Two
-- writes per swing. (Popping 20 studs up instead lost writes: the server
-- put the root back, ~100 studs/s of teleports.)
local FACE_DOWN = CFrame.fromOrientation(-math.pi / 2, 0, 0)
HIT_DWELL = 0.2     -- s next to the target after a swing (the server's hit needs it)
RETREAT_DIST = 12   -- studs from the target between swings (radius 10 + margin)
RETREAT_UP = 20     -- studs above the target where AFQ arrives (outside the radius)
local combo = { step = 0, at = -1e9, retreated = true }

-- Of 8 ground spots RETREAT_DIST studs around the target, the one farthest
-- from every live enemy: mobs stand in groups, and a spot 12 studs from the
-- target can be within 10 of its neighbour.
local RETREAT_DIRS = {}
for i = 0, 7 do
    local angle = i * math.pi / 4
    RETREAT_DIRS[#RETREAT_DIRS + 1] = Vector3.new(math.cos(angle), 0, math.sin(angle))
end
function AP.retreatSpot(tpos)
    local roots = {}
    pcall(function()
        for _, model in ipairs(AP.enemyFolder():GetChildren()) do
            local root = AP.enemyRoot(model)
            if root then
                local pos = root.Position
                if (pos - tpos).Magnitude < RETREAT_DIST + 12 then roots[#roots + 1] = pos end
            end
        end
    end)
    local best, bestClear = tpos + RETREAT_DIRS[1] * RETREAT_DIST, -1
    for _, dir in ipairs(RETREAT_DIRS) do
        local spot = tpos + dir * RETREAT_DIST
        local clear = math.huge
        for _, pos in ipairs(roots) do
            local d = (pos - spot).Magnitude
            if d < clear then clear = d end
        end
        if clear > bestClear then best, bestClear = spot, clear end
    end
    return best
end
function AP.swing(targetRoot)
    local me = AP.root()
    if not me or not targetRoot then return false end
    local now = clock()
    local interval = 1 / math.max(1, tonumber(S.apAttackRate) or 2.5)
    local height = tonumber(S.apAttackHeight) or 0
    if now - combo.at < interval then
        if not combo.retreated and now - combo.at >= HIT_DWELL and not rootTweenOwned() then
            combo.retreated = true
            local okPos, tpos = pcall(function() return targetRoot.Position end)
            if okPos and tpos then
                local spot = AP.retreatSpot(tpos)
                placeRoot(me, spot.X, tpos.Y, spot.Z, AP.facing(spot, tpos))
            end
        end
        return true
    end
    local okPos, tpos, look = pcall(function() return targetRoot.Position, targetRoot.CFrame.LookVector end)
    if not okPos or not tpos then return false end
    if not rootTweenOwned() then
        if height > 0 then
            placeRoot(me, tpos.X, tpos.Y + height, tpos.Z, FACE_DOWN)
        else
            local range = tonumber(S.apAttackRange) or 3
            local spot = tpos + Vector3.new(look.X, 0, look.Z) * range
            placeRoot(me, spot.X, tpos.Y, spot.Z, AP.facing(spot, tpos))
        end
    end
    -- The game resets the combo after a 1 s gap or the 4th hit.
    if now - combo.at > 1 or combo.step >= 4 then combo.step = 0 end
    combo.step = combo.step + 1
    combo.at = now
    combo.retreated = false
    markFight()
    return safeRemote("Combat Event", AP.remote("Combat Event"), "FireServer", combo.step)
end

-- Fly next to a target with the shared tweenTo (fling-free, server speed cap).
function AP.flyTo(pos, checkFn)
    local me = AP.root()
    if not me then return false end
    markTravel()
    return tweenTo(me, pos, S.apFlySpeed, checkFn)
end

function AP.setLabel(label, text)
    if label then pcall(function() label.Text = text end) end
end

-- Load marker: this chunk ran to the end.
if LACED_LOAD and type(LACED_LOAD.done) == "table" then LACED_LOAD.done["40_combat"] = true end
-- @chunk 60_afq  (Anime Piece: Auto Farm Quest)
local LACED_LOAD = type(_G.__lacedLoad) == "table" and _G.__lacedLoad or nil -- load marker (loader.lua)
if LACED_LOAD and type(LACED_LOAD.started) == "table" then LACED_LOAD.started["60_afq"] = true end
local alive = alive
local S = S
local AP = AP

-- Kill quests with a regular (respawning) target, by level. The quest level
-- is the target's level tag (the game's own tracker shows "Level 10+" for the
-- [10+] tier). Boss quests (006 Higaro, 010 King Monkey, 014 Robot King, 016
-- Robot 15/16, 017 Crimson King, 019 Frieza, 027 Overtime Sorcerer, 029 White
-- Panda) are left out: their level gate is server side and unknown, and a
-- boss that is down leaves the quest stuck until it respawns.
-- Collect/deliver quests (002, 004, 005, ...) are not farmable this way.
AP_QUESTS = {
    { id = 1,  level = 0,   targets = { "Bandit" } },
    { id = 3,  level = 20,  targets = { "Higaro\226\128\153s bandit" } }, -- curly apostrophe, as in the game
    { id = 7,  level = 45,  targets = { "Warrior Monkey" } },
    { id = 9,  level = 60,  targets = { "Knight Monkey" } },
    { id = 11, level = 75,  targets = { "Red Brawler" } },
    { id = 13, level = 90,  targets = { "Robot" } },
    { id = 20, level = 150, targets = { "Corrupted Player" } },
    { id = 21, level = 150, targets = { "Pro Player" } },
    { id = 24, level = 165, targets = { "Jujutsu Student" } },
    { id = 26, level = 190, targets = { "Special Student" } },
}
local QUEST_BY_ID = {}
for _, quest in ipairs(AP_QUESTS) do
    quest.targetSet = {}
    for _, name in ipairs(quest.targets) do quest.targetSet[name] = true end
    QUEST_BY_ID[quest.id] = quest
end

AFQ_AREA_RADIUS = 700   -- studs around the quest's area marker that count as its spawn
AFQ_ACCEPT_WAIT = 3     -- s for InQuest to flip after an accept or a quit
AFQ_LOCK_TIME = 120     -- s a refused quest is skipped (a level-up clears it sooner)
AFQ_TARGET_TIMEOUT = 25 -- s on one enemy before trying another (stuck / unreachable)
AFQ_AREA_HEIGHT = 25    -- studs above the marker while waiting for respawns

-- Boss quests whose text contains a mob target ("Defeat Robot King" holds
-- "Robot"): never read them as that mob's quest.
local BOSS_TEXT = { "robot king", "robot 15", "robot 16" }

-- tracked: id of the quest AFQ accepted, kept while InQuest stays true.
-- locked[id] = clock() when the server refused it (the level gate is server
-- side: live, Lv 21 was refused 007 and 026 and took 003).
AFQ = { tracked = nil, locked = {}, level = nil }

-- Highest quest the level allows that the server has not just refused. The
-- table levels are the enemies' tags; a refusal drops to the tier below
-- until the next level-up, so a wrong tag costs one accept, not the farm.
function afq_bestQuest(level)
    local now = clock()
    local best
    for _, quest in ipairs(AP_QUESTS) do
        local lockedAt = AFQ.locked[quest.id]
        if quest.level <= level and not (lockedAt and now - lockedAt < AFQ_LOCK_TIME) then
            best = quest
        end
    end
    return best
end

-- The active quest: nil when none, false when it is not one of AP_QUESTS
-- (a boss, collect or hand-picked quest AFQ cannot tell apart).
function afq_activeQuest()
    if not AP.inQuest() then AFQ.tracked = nil return nil end
    if AFQ.tracked then return QUEST_BY_ID[AFQ.tracked] end
    local byId = QUEST_BY_ID[AP.questId() or -1]
    if byId then AFQ.tracked = byId.id return byId end
    -- Taken before AFQ started: match the quest text against the targets.
    local text = string.lower(AP.questText())
    for _, boss in ipairs(BOSS_TEXT) do
        if string.find(text, boss, 1, true) then return false end
    end
    local found, foundLen = false, 0
    for _, quest in ipairs(AP_QUESTS) do
        for _, name in ipairs(quest.targets) do
            if #name > foundLen and string.find(text, string.lower(name), 1, true) then
                found, foundLen = quest, #name
            end
        end
    end
    -- Track it: afq_fight only keeps going for the tracked quest.
    if found then AFQ.tracked = found.id end
    return found
end

-- Quest area: the Part in IgnoreList["Quest Indicator"] named by the quest
-- number. Its position is the target spawn, not the giver. Named "003" since
-- 2026-10-31 (was "3"), so both spellings are tried.
function afq_areaPosition(quest)
    local pos
    pcall(function()
        local folder = Workspace.World.IgnoreList["Quest Indicator"]
        local marker = folder:FindFirstChild(string.format("%03d", quest.id)) or folder:FindFirstChild(tostring(quest.id))
        if marker then pos = marker.Position end
    end)
    return pos
end

local function setStatus(text) AP.setLabel(S.apAfqLabel, "Auto Farm Quest: " .. text) end

-- The quest Yes button sends Dialogue Event {"Quest", "001"}. The server
-- accepts it from anywhere (verified 282 studs from the giver), so there is
-- no flight to the NPC and no dialogue click.
-- Returns "accepted", "refused" (InQuest stayed false: level too low) or
-- "unsent" (the remote failed; not the quest's fault, so no lock).
function afq_accept(quest)
    local id = string.format("%03d", quest.id)
    if not safeRemote("Dialogue Event", AP.remote("Dialogue Event"), "FireServer", { "Quest", id }) then
        return "unsent"
    end
    local deadline = clock() + AFQ_ACCEPT_WAIT
    while alive() and clock() < deadline do
        if AP.inQuest() then AFQ.tracked = quest.id return "accepted" end
        task.wait(0.2)
    end
    if AP.inQuest() then AFQ.tracked = quest.id return "accepted" end
    return "refused"
end

-- Another quest is active (an older tier after a level-up, or one the
-- player took by hand): quit it so the best one can be taken. The game
-- keeps one quest at a time.
function afq_quit()
    safeRemote("Quest Event", AP.remote("Quest Event"), "FireServer", "Quit")
    local deadline = clock() + AFQ_ACCEPT_WAIT
    while alive() and clock() < deadline do
        if not AP.inQuest() then AFQ.tracked = nil return true end
        task.wait(0.2)
    end
    return not AP.inQuest()
end

-- Fight one enemy until it dies, the quest ends, the level changes (a new
-- tier may be open), AFQ is switched off or the fruit farm takes over.
function afq_fight(quest, model, targetRoot)
    local started = clock()
    local level = AFQ.level
    local function keep()
        return alive() and S.apAfq and not S.apPaused and AFQ.tracked == quest.id
            and AP.inQuest() and AP.level() == level
    end
    -- Fly in to the retreat spot RETREAT_UP studs above the target, outside
    -- the anti-cheat's 10 stud radius (see AP.swing); each swing then drops
    -- in next to the target and pops back up.
    local okPos, tpos = pcall(function() return targetRoot.Position end)
    if not okPos or not tpos then return end
    local me = AP.root()
    if me and (me.Position - tpos).Magnitude > RETREAT_UP + 2 then
        AP.flyTo(tpos + Vector3.new(0, RETREAT_UP, 0), keep)
    end
    -- AP.swing writes the root once per swing only (anti-cheat, see there).
    while keep() and clock() - started < AFQ_TARGET_TIMEOUT do
        local root = AP.enemyRoot(model)
        if not root then return end
        AP.swing(root)
        frameWait()
    end
end

task.spawn(function()
    local wasOn = false
    while alive() do
        if not S.apAfq then
            if wasOn then setStatus("off") wasOn = false end
            task.wait(0.5)
        elseif S.apPaused then
            wasOn = true
            setStatus("paused (fruit farm)")
            task.wait(0.5)
        elseif not AP.root() then
            wasOn = true
            setStatus("waiting for character")
            task.wait(1)
        else
            wasOn = true
            local ok, err = pcall(function()
                if not AP.stats() then setStatus("waiting for player data") task.wait(1) return end
                local level = AP.level()
                if AFQ.level ~= level then
                    -- Level changed: tiers the server refused may be open now.
                    if AFQ.level then setStatus(("level %d -> %d, checking quests"):format(AFQ.level, level)) end
                    AFQ.level = level
                    AFQ.locked = {}
                end
                local quest = afq_bestQuest(level)
                if not quest then setStatus("no kill quest the server takes at Lv " .. level) task.wait(2) return end
                local current = afq_activeQuest()
                if current ~= quest then
                    if current ~= nil then
                        setStatus(current and ("quitting quest %03d for %03d"):format(current.id, quest.id)
                            or ("quitting other quest for %03d"):format(quest.id))
                        afq_quit()
                        return
                    end
                    setStatus(("accepting quest %03d (Lv %d)"):format(quest.id, quest.level))
                    local result = afq_accept(quest)
                    if result == "refused" then
                        AFQ.locked[quest.id] = clock()
                        warnThrottled("afq-refused", ("[laced.club] Auto Farm Quest: quest %03d refused at Lv %d, using a lower tier"):format(quest.id, level), 30)
                    elseif result == "unsent" then
                        task.wait(1)
                    end
                    return
                end
                local area = afq_areaPosition(quest)
                local model, root = AP.nearestEnemy(quest.targetSet, area, AFQ_AREA_RADIUS)
                if not model then
                    -- Targets far away are streamed out; flying to the area
                    -- streams them in. Wait above the marker for respawns.
                    local me = AP.root()
                    if area and me and (me.Position - area).Magnitude > 60 then
                        setStatus(("flying to quest %03d area"):format(quest.id))
                        AP.flyTo(area + Vector3.new(0, AFQ_AREA_HEIGHT, 0), function()
                            return S.apAfq and not S.apPaused
                        end)
                    else
                        setStatus(("waiting for %s to spawn"):format(quest.targets[1]))
                        task.wait(0.5)
                    end
                    return
                end
                local armed, why = AP.equipWeapon()
                local done, need = AP.questProgress()
                setStatus(("%03d %s (%d/%s)%s"):format(quest.id, model.Name, done, need and tostring(need) or "?",
                    armed and "" or (" - " .. why)))
                afq_fight(quest, model, root)
            end)
            if not ok then
                warnThrottled("afq", "[laced.club] Auto Farm Quest step failed: " .. tostring(err), 15)
                task.wait(1)
            end
            frameWait()
        end
    end
end)

-- Load marker: this chunk ran to the end.
if LACED_LOAD and type(LACED_LOAD.done) == "table" then LACED_LOAD.done["60_afq"] = true end
-- @chunk 70_fruit  (Anime Piece: world fruit farm, auto store, fruit gacha)
local LACED_LOAD = type(_G.__lacedLoad) == "table" and _G.__lacedLoad or nil -- load marker (loader.lua)
if LACED_LOAD and type(LACED_LOAD.started) == "table" then LACED_LOAD.started["70_fruit"] = true end
local alive = alive
local S = S
local AP = AP
local onShutdown = onShutdown

FRUIT_SCAN_INTERVAL = 1.5 -- s between world scans (GetChildren on a few folders, never GetDescendants)
FRUIT_PICKUP_HOLD = 2     -- s standing on a fruit for the touch pickup
FRUIT_STORE_RETRY = 3     -- s before storing the same fruit name again
GACHA_RETRY = 60          -- s between gacha attempts while Auto Fruit Gacha is on
GACHA_SPIN_WAIT = 6       -- s the spin animation takes before the fruit lands in the backpack
VK_E = 0x45

local fruitStatus = "idle"
local function setStatus(text)
    fruitStatus = text
    AP.setLabel(S.apFruitLabel, "Fruits: " .. text)
end

-- "Flame", "Flame Fruit", "Flame Fruit [Spawned]" -> "Flame" when it is a
-- fruit of this game, nil otherwise.
local function fruitName(name)
    if AP.FRUIT_SET[name] then return name end
    local first = string.match(name, "^(%a+)%s+[Ff]ruit")
    if first and AP.FRUIT_SET[first] then return first end
    return nil
end

local function partOf(object)
    if object.ClassName == "Part" or object.ClassName == "MeshPart" then return object end
    local handle = object:FindFirstChild("Handle")
    if handle then return handle end
    return object:FindFirstChildWhichIsA("BasePart")
end

-- Spawned fruits. Not seen live yet (none had spawned while the game was
-- mapped), so every place one can plausibly appear is checked: the Workspace
-- root (dropped tools), World.Playability.DroppedTools, and the fruit spawn
-- points in IgnoreList["Fruits Spawn"] (a fruit parented to its point).
function fruit_scan()
    local found = {}
    local function check(object)
        local name = fruitName(object.Name)
        if not name then return end
        if object.ClassName ~= "Tool" and object.ClassName ~= "Model" and object.ClassName ~= "Part"
            and object.ClassName ~= "MeshPart" then return end
        local part = partOf(object)
        if part then found[#found + 1] = { object = object, part = part, name = name } end
    end
    pcall(function() for _, child in ipairs(Workspace:GetChildren()) do check(child) end end)
    pcall(function()
        local world = Workspace:FindFirstChild("World")
        local dropped = world and world.Playability:FindFirstChild("DroppedTools")
        if dropped then for _, child in ipairs(dropped:GetChildren()) do check(child) end end
        local points = world and world.IgnoreList:FindFirstChild("Fruits Spawn")
        if points then
            for _, point in ipairs(points:GetChildren()) do
                for _, child in ipairs(point:GetChildren()) do check(child) end
            end
        end
    end)
    return found
end

local function nearestFruit()
    local me = AP.root()
    if not me then return nil end
    local best, bestDist = nil, math.huge
    for _, entry in ipairs(fruit_scan()) do
        local okPos, pos = pcall(function() return entry.part.Position end)
        if okPos and pos then
            local dist = (pos - me.Position).Magnitude
            if dist < bestDist then best, bestDist = entry, dist end
        end
    end
    return best
end

-- Touch pickup: stand on the fruit for a moment. If the game uses a prompt
-- instead, E is pressed too (only while Roblox is focused: keypress goes to
-- the focused window).
function fruit_pickup(entry)
    local function keep()
        return alive() and S.apFruitFarm and entry.object.Parent ~= nil
    end
    local okPos, pos = pcall(function() return entry.part.Position end)
    if not okPos or not pos then return false end
    setStatus("flying to " .. entry.name)
    if not AP.flyTo(pos, keep) then return false end
    setStatus("picking up " .. entry.name)
    local deadline = clock() + FRUIT_PICKUP_HOLD
    local pressed = false
    while keep() and clock() < deadline do
        local me = AP.root()
        local okNow, now = pcall(function() return entry.part.Position end)
        if me and okNow and now then placeRoot(me, now.X, now.Y, now.Z, lockedRotation(me)) end
        if not pressed and robloxFocused() then
            pcall(keypress, VK_E)
            task.wait(0.1)
            pcall(keyrelease, VK_E)
            pressed = true
        end
        task.wait(0.25)
    end
    return entry.object.Parent == nil
end

-- Every fruit tool in the backpack or hand goes to storage (the Physical
-- Fruits menu's Storage button sends exactly this). The eaten fruit's power
-- is also a Tool named after the fruit, but empty (seen live: "Bomb" with no
-- children while Build.ActualFruit = "Bomb"), so a tool with the eaten
-- fruit's name and no Handle is skipped.
local lastStore = {}
function fruit_storeAll()
    local stored = 0
    local eaten
    pcall(function() eaten = AP.stats().Build.ActualFruit.Value end)
    local containers = { LocalPlayer:FindFirstChild("Backpack"), LocalPlayer.Character }
    for _, container in ipairs(containers) do
        if container then
            for _, tool in ipairs(container:GetChildren()) do
                local name = tool.ClassName == "Tool" and AP.FRUIT_SET[tool.Name] and tool.Name
                if name == eaten and not tool:FindFirstChild("Handle") then name = nil end
                if name and clock() - (lastStore[name] or -1e9) > FRUIT_STORE_RETRY then
                    lastStore[name] = clock()
                    safeRemote("Physical Fruits Event", AP.remote("Physical Fruits Event"), "FireServer", "Storage", name)
                    stored = stored + 1
                end
            end
        end
    end
    return stored
end

-- Luzefe's dialogue sends Dialogue Event {"SpinFruit", ""} when you have the
-- money and the cooldown is over; the server re-checks both, so a roll that
-- is not ready does nothing. The CanGacha attribute (boolean, safe to read)
-- is false while the game knows you cannot roll.
local lastGacha = -1e9
local function gachaReady()
    local value
    pcall(function() value = LocalPlayer:GetAttribute("CanGacha") end)
    return value ~= false
end
function fruit_roll()
    lastGacha = clock()
    if not gachaReady() then setStatus("gacha not ready (cooldown or money)") return false end
    setStatus("rolling gacha")
    safeRemote("Dialogue Event", AP.remote("Dialogue Event"), "FireServer", { "SpinFruit", "" })
    local deadline = clock() + GACHA_SPIN_WAIT
    while alive() and clock() < deadline do task.wait(0.25) end
    return true
end

onShutdown(function() S.apPaused = false end)

task.spawn(function()
    local nextScan = 0
    while alive() do
        local ok, err = pcall(function()
            if S.apGachaNow or (S.apGacha and clock() - lastGacha > GACHA_RETRY) then
                S.apGachaNow = false
                fruit_roll()
            end
            if S.apFruitStore and fruit_storeAll() > 0 then setStatus("stored a fruit") end
            if S.apFruitFarm and AP.root() and clock() >= nextScan then
                nextScan = clock() + FRUIT_SCAN_INTERVAL
                local entry = nearestFruit()
                if entry then
                    S.apPaused = true -- AFQ yields the root while the fruit is fetched
                    local got = fruit_pickup(entry)
                    S.apPaused = false
                    setStatus(got and ("picked up " .. entry.name) or (entry.name .. " pickup failed"))
                    if got and S.apFruitStore then task.wait(0.5) fruit_storeAll() end
                elseif fruitStatus == "idle" or string.find(fruitStatus, "flying", 1, true) then
                    setStatus("no fruit spawned")
                end
            end
        end)
        if not ok then
            S.apPaused = false
            warnThrottled("fruit", "[laced.club] fruit loop step failed: " .. tostring(err), 15)
        end
        task.wait(0.5)
    end
end)

-- Load marker: this chunk ran to the end.
if LACED_LOAD and type(LACED_LOAD.done) == "table" then LACED_LOAD.done["70_fruit"] = true end
-- @chunk 90_main  (Anime Piece: keep-alive)
local LACED_LOAD = type(_G.__lacedLoad) == "table" and _G.__lacedLoad or nil -- load marker (loader.lua)
if LACED_LOAD and type(LACED_LOAD.started) == "table" then LACED_LOAD.started["90_main"] = true end
local alive = alive

SCRIPT_LIBRARY = Library
notify("Anime Piece loaded: Auto Farm Quest and Fruits are on the Main tab", "laced.club", 4)

-- Load marker before the keep-alive loop (it does not end while loaded).
if LACED_LOAD and type(LACED_LOAD.done) == "table" then LACED_LOAD.done["90_main"] = true end
while alive() do task.wait(1) end
