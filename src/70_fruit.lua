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
