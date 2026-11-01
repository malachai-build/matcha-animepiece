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
-- number. Its position is the target spawn, not the giver.
function afq_areaPosition(quest)
    local pos
    pcall(function()
        local marker = Workspace.World.IgnoreList["Quest Indicator"]:FindFirstChild(tostring(quest.id))
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
    -- Fly in first, at the hover height; the swing then pins the root above
    -- (or next to) the target.
    local okPos, tpos = pcall(function() return targetRoot.Position end)
    if not okPos or not tpos then return end
    local me = AP.root()
    if me and (me.Position - tpos).Magnitude > 12 then
        AP.flyTo(tpos + Vector3.new(0, math.max(3, tonumber(S.apAttackHeight) or 0), 0), keep)
    end
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
