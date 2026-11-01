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

-- Health / MaxHealth of the live character, 0 when there is none.
function AP.healthFraction()
    local fraction = 0
    pcall(function()
        local hum = LocalPlayer.Character:FindFirstChild("Humanoid")
        if hum and hum.MaxHealth > 0 then fraction = hum.Health / hum.MaxHealth end
    end)
    return fraction
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
