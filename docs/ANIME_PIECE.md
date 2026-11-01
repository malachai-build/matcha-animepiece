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

## Combat and safe positioning

- **No remote hit.** The game's `ReplicatedStorage.Client.Actions["Combat Action"]` only sends
  `Combat Event:FireServer(comboStep)`. The server builds the hit box from the character's position and
  facing, and ignores extra arguments (an enemy model, root and position sent from 15 studs up did no damage).
  So unlike Blox Fruits there is no target list to send, and AFQ must stay inside the hit box.
- **A tool must be held.** With nothing equipped M1 does no damage at any distance. Moving the tool's
  `Parent` to the character from the client does not stick; pressing the hotbar key works, but only while
  Roblox is the focused window (`keypress` goes to the focused window, also after `setrobloxinput(true)`;
  there is no `EquipTool` in Matcha). The game's own equip (`Client.Services["Tool Service"]`) only fires
  `Custom Tool Event:FireServer("Equip")` after the tool is already in the character. Any tool counts,
  fruits included (they have M1). AFQ runs unfocused with whatever is held; only on an empty hand does it
  press the **Weapon Slot** key, and only while Roblox is focused.
- **Hover above, facing down** (live 2026-10-31, Higaro's bandit, Melee):

  | Root position | M1 lands | Damage taken |
  |---|---|---|
  | straight above, facing down, 15 / 10 studs | no | none |
  | straight above, facing down, 7 studs | yes (52 -> 38) | none |
  | 3 studs in front, 6 studs up | yes | yes |
  | 3 studs in front, ground level | yes | yes (23 HP in 2.4 s) |

  **Attack Height** above 0 hovers (one run hit at 7; later runs were
  after the kick below and prove nothing). The default is 0, the in-front spot: see the anti-cheat section
  for why hovering is at the kick threshold.
- **Ranged enemies (to revisit).** Hovering only keeps AFQ out of **melee** reach. Higher-level enemies with
  ranged attacks (projectiles, AoE skills) will still hit a hovering player. When AFQ reaches those tiers,
  re-measure damage taken per tier and adjust: a larger height if their hit box allows it, dodging between
  swings, or a health threshold that backs off to heal.

## Anti-cheat: "Auto Enemys Farme" kick

`ReplicatedStorage.Client["Client Anti Exploiter"]["Anti Enemy Weld"]` (client side). We were kicked by it on
2026-10-31 ("performing a suspicious action") ~2.5 s into a hovering AFQ fight. What it does, every 0.05 s
on Heartbeat:

1. `Humanoid.MoveDirection.Magnitude > 0.1` (walking by input) resets everything.
2. Takes the nearest live enemy whose root is **within 10 studs**; none resets.
3. Counts the sample when **our root moved > 0.1 stud** since the last sample, **the distance to the enemy
   changed <= 0.75**, and **our offset to the enemy changed > 0.1**.
4. Every 0.5 s: if the count is **>= 5** and the enemy has a `Stunned` child, we hold a Tool, have an `InHit`
   child, and are not `Stunned` / `Fly` attribute / `SkillMover` / `SkillMoverModify` / `Dash`: **one strike**.
5. **5 strikes** (never reset until rejoin) -> `Remotes["Kick Event"]:FireServer("Auto Enemys Farme")`.

What tripped it: the hover re-placed the root only after a 1.5 stud sag, so the root fell ~0.25 stud per
sample in between (~8 counted samples per window, a strike every window while hits landed). Unarmed tests
never counted (no Tool).

Measured with a copy of the check run beside AFQ (unarmed, so no real strike was possible):

| AFQ positioning | Max counted samples per 0.5 s (strike at 5) | In the air |
|---|---|---|
| hover, re-place after 1.5 stud sag (what got us kicked) | 10 | yes |
| hover, one write per swing, free fall between | **5** (at the threshold) | 36 % |
| ground, 3 studs in front, one write per swing | **1** | no |

What does not work around it:
- A per-frame hold: one `placeRoot` costs ~38 ms in Matcha (20 calls took 759 ms), so Heartbeat cannot keep
  the spot.
- The `Fly` exemption: Matcha's `SetAttribute` only changes existing attributes; `Fly` does not exist on the
  character, and setting it reads back `nil`.
- Standing on an enemy: only its Torso has CanCollide, and the character slid straight off (no
  player-enemy collision).

Rules AFQ follows now:
- **Default Attack Height 0** (ground, in front, one write per swing). Above 0 is kept as an option, marked risky.
- Waiting for respawns happens 25 studs above the marker: farther than 10 studs from any enemy.
- Any new movement near enemies must keep < 5 moved samples per 0.5 s (or stay > 10 studs away).
- Melee damage on the ground is still open: see the ranged-enemy note above.

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
