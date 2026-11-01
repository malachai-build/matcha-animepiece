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
S.apHealBelow    = 35    -- % HP that sends AFQ up to heal (0 = never); a death unequips the weapon
S.apHealUntil    = 90    -- % HP AFQ waits for before fighting again
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
settingsTab:AddSlider("ap_heal_below", {
    Text = "Heal Below %", Min = 0, Max = 90, Step = 5, Default = S.apHealBelow, Integer = true, Column = 1,
    Description = "AFQ leaves the fight 60 studs straight up below this HP (0 = never). A death unequips your weapon, and only a focused Roblox can equip it again",
    Callback = function(v) S.apHealBelow = math.max(0, tonumber(v) or 35) end
})
settingsTab:AddSlider("ap_heal_until", {
    Text = "Heal Until %", Min = 30, Max = 100, Step = 5, Default = S.apHealUntil, Integer = true, Column = 1,
    Description = "HP AFQ waits for up there before fighting again (gives up after 90 s)",
    Callback = function(v) S.apHealUntil = math.max(30, tonumber(v) or 90) end
})
settingsTab:AddSlider("ap_attack_rate", {
    Text = "Swings Per Second", Min = 1, Max = 2.6, Step = 0.1, Default = S.apAttackRate, Column = 1,
    Callback = function(v) S.apAttackRate = math.max(1, tonumber(v) or 2.5) end
})

-- Load marker: this chunk ran to the end.
if LACED_LOAD and type(LACED_LOAD.done) == "table" then LACED_LOAD.done["10_ui"] = true end
