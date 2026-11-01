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
-- Current quest as a number (Quest.QuestId is "001", "2" or "None"), nil
-- when there is none or it is not a numbered quest.
function AP.questId()
    local id = statValue("Quest", "QuestId")
    return tonumber(id)
end
function AP.questProgress() return tonumber(statValue("Quest", "Progress")) or 0 end

function AP.boolAttribute(name)
    local value
    pcall(function() value = LocalPlayer:GetAttribute(name) end)
    return value == true
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

-- True when the character holds a Tool (the server's M1 uses it).
function AP.holdsTool()
    local char = LocalPlayer.Character
    if not char then return false end
    for _, child in ipairs(char:GetChildren()) do
        if child.ClassName == "Tool" and not AP.FRUIT_SET[child.Name] then return true end
    end
    return false
end

-- Remote M1, the game's own path (Combat Action): Combat Event:FireServer(n)
-- with the combo step 1..4 and the equipped tool. The server hit box sits in
-- front of the root, so the root is placed AP.range studs in front of the
-- target, facing it, once per swing (a per-frame CFrame write is thousands of
-- memory writes in Matcha). Verified live: Bandit 20 HP -> 0 in 4 swings.
local combo = { step = 0, at = -1e9 }
function AP.swing(targetRoot)
    local me = AP.root()
    if not me or not targetRoot then return false end
    local now = clock()
    local interval = 1 / math.max(1, tonumber(S.apAttackRate) or 2.5)
    if now - combo.at < interval then return true end
    local okPos, tpos, look = pcall(function() return targetRoot.Position, targetRoot.CFrame.LookVector end)
    if not okPos or not tpos then return false end
    local range = tonumber(S.apAttackRange) or 3
    local spot = tpos + Vector3.new(look.X, 0, look.Z) * range
    if not rootTweenOwned() then
        placeRoot(me, spot.X, tpos.Y, spot.Z, AP.facing(spot, tpos))
    end
    -- The game resets the combo after a 1 s gap or the 4th hit.
    if now - combo.at > 1 or combo.step >= 4 then combo.step = 0 end
    combo.step = combo.step + 1
    combo.at = now
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
