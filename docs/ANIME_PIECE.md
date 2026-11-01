# Anime Piece - Update 1: game map for the port

PlaceId `134039915751463`. Mapped live through the Matcha MCP on 2026-10-31.

## Matcha quirks found in this game

- `Instance:GetAttribute(name)` on a **non-empty string attribute kills the whole exec**, even inside
  `pcall` (seen on the player's `ActualQuest`, `LastQuest`, `CurrentLocation`, `Title`, `ActualTool`).
  Boolean/number attributes read fine (`InQuest`, `CanGacha`, `FirstFruitSpin`). Use the
  `PlayerStats` StringValues below instead: `StringValue.Value` reads fine.
- `GuiObject.Visible` reads `nil` (unsupported). `TextLabel.Text` reads fine.
- `CFrame.lookAt` is not bound. Build facing with `CFrame.new(x,y,z) * CFrame.fromOrientation(0, math.atan2(-dx, -dz), 0)`.
- An MCP `matcha_exec` returns at the first yield; output after a `task.wait` shows up in `matcha_logs`.
- Enemies and NPCs far from the player are streamed out: the model exists but has no `HumanoidRootPart`.

## Player data

`ReplicatedStorage.Shared.PlayerStats[<player name>]`:

| Path | Type | Meaning |
|---|---|---|
| `Infos.Level` | IntValue | real level (the `Level` attribute lags) |
| `Infos.Money` | IntValue | money |
| `Quest.QuestId` | StringValue | quest id without zero padding (`"2"` for quest `002`) when set; **stayed `""` through an accept of 003 (2026-10-31)**, so not a reliable signal |
| `Quest.Progress` | IntValue | kills/items done; stayed 0 while the quest panel counted (use the panel's `(n/m)`) |
| `Build.ActualFruit` | StringValue | eaten fruit, `"None"` when none |
| `Build.ActualFightingStyle` | StringValue | e.g. `"Melee"` |
| `Unlockeds.Fruits` | Folder | stored fruits |
| `Infos.LastFruitTimeSpin` | (appears after the first spin) | gacha cooldown stamp |

Player attribute `InQuest` (bool): true after an accept the server took, false after `Quit` or a refused
accept. Quest UI: `PlayerGui.Interfaces.Screen.Quest.Current.Header.Title` and `...Current.Description`
(`"Defeat Higaro's bandits (0/5)"`); the title keeps the last quest's name after a quit.
Recommended quest for the level: `PlayerGui.Interfaces.Frames.QuestTrack.Frame.Background["Quest Name"]`
and `.LevelRecomended` (`"Level 20+"`).

**Level gate is server side**: the client dialogue modules (`ReplicatedStorage.Client.Utils.Dialogues.<NPC>`)
only send `{"Quest", "003"}`. At Lv 21 the server refused 007 (Lv 45) and 026 (Lv 190) and took 003
(InQuest unchanged on a refusal, no message).

## Remotes (`ReplicatedStorage.Remotes`)

| Remote | Call | Use |
|---|---|---|
| `Combat Event` | `FireServer(combo)` with combo 1..4 | M1 with the equipped tool. Server hit box in front of the root; standing 3 studs in front of an enemy, facing it, hits. Verified: Bandit 20 HP, 5 per hit. `Balancing Data.M1Cooldown` = 0.38 s. |
| `Dialogue Event` | `FireServer({"Quest", "001"})` | accept a quest (what the Yes button sends) |
| `Dialogue Event` | `FireServer({"SpinFruit", ""})` | fruit gacha roll (Luzefe, Foosha 250,13,-1205); needs money >= price and the cooldown over |
| `Quest Event` | `FireServer("Quit")` / `FireServer("Repeat")` | abandon / repeat the current quest |
| `Physical Fruits Event` | `FireServer("Eat"|"Drop"|"Storage", fruitName)` | act on a fruit tool you hold |
| `Fruit Notifier Event` | server -> client `(fruitName, position)` / `("Colleted")` | world fruit spawned / taken |

## World

- Enemies: `Workspace.World.Playability.Enemys`, models named `"<Name> [<level>+]"` (bosses have no tag).
- Quest areas: `Workspace.World.IgnoreList["Quest Indicator"]`, one Part per quest, named by the quest
  number without padding (`"1"`, `"13"`). Its position is the **target area**, not the giver.
- Quest givers: `Workspace.World.IgnoreList.Npcs.Interactive.<Island>.<NPC>` (streamed per island).
- World fruit spawn points: `Workspace.World.IgnoreList["Fruits Spawn"]` (19 `Point` parts).
- Fruits in the game: Copy, Kilo, Warrior, Bomb, Flame, Emperor, Scarlet, Quake, Beast, Light, Infinity, Vessel.

## Kill quests

| Id | Giver | Target model name | Level | Kind |
|---|---|---|---|---|
| 001 | Zack | Bandit [0+] | 0 | mob |
| 003 | Robe | Higaro's bandit [20+] (curly apostrophe) | 20 | mob |
| 006 | Relouneibor | Higaro | ? | boss |
| 007 | Adventurer | Warrior Monkey [45+] | 45 | mob |
| 009 | Melancio | Knight Monkey [60+] | 60 | mob |
| 010 | Adventurer Girl | King Monkey | ? | boss |
| 011 | Luna | Red Brawler [75+] | 75 | mob |
| 013 | Kairon | Robot [90+] / Robot [100+] | 90 | mob |
| 014 | Shiro | Robot King | ? | boss |
| 016 | Yoko | Robot 15, Robot 16 | ? | boss |
| 017 | Kaito | Crimson King | ? | boss |
| 019 | Naori | Frieza | ? | boss |
| 020 | Noob Player | Corrupted Player [150+] | 150 | mob |
| 021 | Master Player | Pro Player [150+] | 150 | mob |
| 024 | Novice Sorcerer | Jujutsu Student [165+] | 165 | mob |
| 026 | Yaz | Special Student [190+] | 190 | mob |
| 027 | Nando | Overtime Sorcerer | ? | boss |
| 029 | Lito | White Panda | ? | boss |

The other ids (002, 004, 005, 008, 012, 015, 018, 022, 023, 025, 028, 030) are collect/deliver quests.
