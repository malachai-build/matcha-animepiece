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
