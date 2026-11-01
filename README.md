# matcha-animepiece

Anime Piece - Update 1 automation menu for the Matcha Luau executor (laced.club UI).
Ported from [matcha-bloxfruits](https://github.com/malachai-build/matcha-bloxfruits): same loader,
core (Matcha shims, fling-free root control, `tweenTo`, run-bound shutdown) and UE menu library;
the game features are new. Game map, remotes and the live checks behind them:
[docs/ANIME_PIECE.md](docs/ANIME_PIECE.md).

## Load (one line)

```lua
loadstring(httpget("https://raw.githubusercontent.com/malachai-build/matcha-animepiece/main/loader.lua"))()
```

Single-file fallback (same code, one chunk, no loader cleanup on failure):

```lua
loadstring(httpget("https://raw.githubusercontent.com/malachai-build/matcha-animepiece/main/dist/anime_piece.full.lua"))()
```

To load from a mirror or a dev build, set `_G.LACED_BASE = "https://.../src/"` before running the loader.
Remotes (`FireServer`) need Matcha Pro / Hybrid mode.

## Features

| Control | What it does | Live tested |
|---|---|---|
| Auto Farm Quest | Takes the highest regular kill quest for your level (001 Bandit Lv 0 ... 026 Special Student Lv 190), quits any other active quest, accepts remotely, flies to the quest area and attacks with remote M1 from Attack Height studs above the target, facing down (out of melee reach; ranged enemies will still hit, see the docs). Equips the **Weapon Slot** (1-0) hotbar key when you hold nothing; needs Roblox focused. Quests complete at N/N and the game repeats them. On a level change it re-checks the tiers: quits the old quest and takes the new one; a quest the server refuses (InQuest stays false) drops to the tier below until the next level-up. Boss quests are not included. | Yes (quest 001: a kill every ~3 s, repeats on its own) |
| Auto Farm Fruits | Flies to a spawned world fruit, stands on it and presses E. Pauses Auto Farm Quest meanwhile. | No (no fruit spawned while testing) |
| Auto Store Fruits | Stores every fruit tool in the backpack or hand. | No |
| Auto Fruit Gacha / Roll Gacha Now | Sends Luzefe's spin request whenever the game allows a roll (money and cooldown). | No (a roll spends money) |
| Settings | Fly speed (flights over 300 studs are capped at 250 studs/s), attack height (0 = stand in front), attack distance (height 0 only), swings per second. | |

## Layout

| File | Contents |
|---|---|
| `loader.lua` | Fetches and runs the chunks below in order; validates each download, pcalls each chunk, checks its load markers, cleans up on failure. |
| `src/00_core.lua` | Shared core from the Blox Fruits build (some of its Blox Fruits state remains, unused here). |
| `src/05_uelib.lua` | UE library download (3 tries) and adapter. |
| `src/10_ui.lua` | Window, unload hook, Main and Settings tabs. |
| `src/40_combat.lua` | `AP`: player data (`PlayerStats`), enemies, remote M1, flight. |
| `src/60_afq.lua` | Auto Farm Quest: quest table and loop. |
| `src/70_fruit.lua` | World fruit farm, auto store, fruit gacha. |
| `src/90_main.lua` | Keep-alive loop (must stay last). |
| `dist/anime_piece.full.lua` | The chunks concatenated (single-chunk fallback; `build.sh`). |
| `tools/matcha_mcp.py` | Minimal client for the local Matcha MCP server, for live probing. |

## Rebuild and check

```bash
bash check.sh
```

`check.sh` rebuilds `dist/anime_piece.full.lua`, runs luau-lsp on every file (0 syntax errors required)
and checks every chunk is listed in the loader and has its end marker.

## Matcha notes (this game)

`GetAttribute` on a non-empty string attribute kills the thread even inside `pcall` (read the
`PlayerStats` StringValues instead), `CFrame.lookAt` is not bound, `GuiObject.Visible` reads `nil`.
The general Matcha rules from the Blox Fruits build still apply: `error()` does not raise (use
`assert`), `task.delay`/`task.defer` never run, `task.spawn` forwards no arguments, `IsA` always returns
true (compare `ClassName`), and a CFrame write is thousands of memory writes (never per frame).
