-- laced.club Anime Piece menu for Matcha: chunked loader.
-- Fetches the chunks in src/ one at a time and runs them in order, so the VM
-- compiles seven chunks instead of one 2,600-line chunk.
--
-- Usage (one line):
--   loadstring(httpget("https://raw.githubusercontent.com/malachai-build/matcha-animepiece/main/loader.lua"))()
-- Override the base URL (dev/mirror) before running:
--   _G.LACED_BASE = "https://example.com/mybuild/src/"
--
-- Matcha notes: loadstring never returns nil (a syntax error only prints when
-- the chunk is called, and the call then returns normally), top-level return
-- values are dropped, a chunk that yields returns to its caller at its first
-- yield, error() only prints, and httpget/game:HttpGet return "" or an error
-- page on failure, so every body is validated first.
--
-- Failure handling (stability pass, Oct 15 2026). Chunks start loops as they
-- run, so a later chunk that failed used to leave the earlier loops running
-- with no unload hook. Now each chunk call is pcall'd, and because a syntax
-- error or a runtime error after a yield is not reported, each chunk also
-- sets its own start and end markers in _G.__lacedLoad:
--   * neither marker after the call      -> it never ran (syntax error)
--   * no end marker within CHUNK_TIMEOUT -> it failed after a yield
-- On any failure (download, compile, run, markers, or a newer load or an
-- unload taking over) the loader runs this load's own shutdownScript("loader")
-- (stops the loops, turns the toggles off, removes this run's Drawings,
-- releases the mouse, reasserts setrobloxinput(true), unloads this run's UE
-- copy). If 00_core did not get far enough to define it, the loader marks
-- this run's state unloaded, releases the mouse and unloads a UE copy this
-- load created. A previous copy of the script that is still running is never
-- touched by this cleanup. Then it raises with the chunk name (assert, since
-- error() does not raise in Matcha).

local BASE = _G.LACED_BASE or "https://raw.githubusercontent.com/malachai-build/matcha-animepiece/main/src/"
local CHUNKS = {
    "00_core", "05_uelib", "10_ui", "40_combat", "60_afq", "70_fruit", "90_main",
}
-- Anime Piece - Update 1 only; on any other place the game paths do not exist.
if game.PlaceId ~= 134039915751463 and type(warn) == "function" then
    warn("[laced.club] this is the Anime Piece build (PlaceId 134039915751463); current PlaceId " .. tostring(game.PlaceId))
end
local CHUNK_TIMEOUT = 30 -- s a chunk that yielded may take to reach its end marker
local clock = (type(os) == "table" and type(os.clock) == "function") and os.clock or tick

local function fetch(url)
    local body = ""
    if type(httpget) == "function" then
        local ok, res = pcall(httpget, url)
        if ok and type(res) == "string" then body = res end
    end
    if body == "" then
        local ok, res = pcall(function() return game:HttpGet(url) end)
        if ok and type(res) == "string" then body = res end
    end
    return body
end

-- This load's marker table. A newer load replaces _G.__lacedLoad; this one
-- then stops before its next chunk instead of running it against the newer
-- load's globals.
local LOAD = { started = {}, done = {}, failed = nil, shutdown = nil, state = nil }
_G.__lacedLoad = LOAD

-- What existed before this load, so the cleanup only touches what this load
-- created (a previous copy of the script may still be running).
local before = {
    shutdown = shutdownScript,
    state = SCRIPT_STATE,
    ue = _G.UELibrary,
}

local function cleanupThisLoad()
    -- shutdownScript is defined early in 00_core; once 00_core has run it is
    -- this load's own and does everything (idempotent).
    local own = LOAD.shutdown
    if type(own) ~= "function" and type(shutdownScript) == "function" and shutdownScript ~= before.shutdown then
        own = shutdownScript
    end
    if type(own) == "function" then
        pcall(own, "loader")
        return
    end
    local state = LOAD.state or SCRIPT_STATE
    if type(state) == "table" and state ~= before.state then state.unloaded = true end
    if type(mouse1release) == "function" then pcall(mouse1release) end
    if type(setrobloxinput) == "function" then pcall(setrobloxinput, true) end
    local ue = _G.UELibrary
    if type(ue) == "table" and ue ~= before.ue and not ue._unloaded and type(ue.Unload) == "function" then
        pcall(function() ue:Unload() end)
    end
end

local function fail(name, index, reason)
    LOAD.failed = name
    local message = "[laced.club] chunk " .. name .. " (" .. index .. "/" .. #CHUNKS .. ") failed: " .. tostring(reason)
    if type(warn) == "function" then warn(message .. " - unloading what this load started") end
    cleanupThisLoad()
    if _G.__lacedLoad == LOAD then _G.__lacedLoad = nil end
    assert(false, message)
end

local function superseded()
    return _G.__lacedLoad ~= LOAD
        or (type(LOAD.state) == "table" and LOAD.state.unloaded == true)
end

for index, name in ipairs(CHUNKS) do
    if superseded() then
        fail(name, index, "a newer load (or an unload) took over before this chunk")
    end
    local url = BASE .. name .. ".lua"
    local src = fetch(url)
    local marker = "-- @chunk " .. name
    -- Only the START of the body is checked for an error page: the chunks
    -- themselves legitimately contain the strings "<html" / "<!DOCTYPE" (the
    -- UE download validator in 10_ui), which is why a whole-body search
    -- rejected a good download.
    local head = string.sub(src, 1, 256)
    local looksHtml = string.find(head, "<html", 1, true) or string.find(head, "<!DOCTYPE", 1, true)
    if not (#src > 100 and not looksHtml and string.sub(src, 1, #marker) == marker) then
        local preview = string.gsub(string.sub(src, 1, 80), "%s+", " ")
        fail(name, index, "download from " .. url .. " was rejected (got " .. #src .. " bytes: " .. preview .. ")")
    end
    -- The end marker must be in the body too: a truncated download that kept
    -- its first line would otherwise run half a chunk.
    if not string.find(src, 'LACED_LOAD.done["' .. name .. '"]', 1, true) then
        fail(name, index, "download is truncated (no end marker)")
    end
    if superseded() then
        fail(name, index, "a newer load (or an unload) took over during the download")
    end
    local fn = loadstring(src, "laced." .. name)
    if type(fn) ~= "function" then fail(name, index, "did not compile") end
    if type(warn) == "function" and name ~= "90_main" then
        warn(("[laced.club] loading %s (%d/%d, %d bytes)"):format(name, index, #CHUNKS, #src))
    end
    LOAD.started[name] = nil
    LOAD.done[name] = nil
    -- 90_main ends with the keep-alive loop: its call returns at the first
    -- yield of that loop (or never), after its end marker is set.
    local okRun, runError = pcall(fn)
    if not okRun then fail(name, index, "runtime error: " .. tostring(runError)) end
    if not LOAD.started[name] and not LOAD.done[name] then
        fail(name, index, "never started (syntax error? see the console line printed above)")
    end
    local deadline = clock() + CHUNK_TIMEOUT
    while not LOAD.done[name] and clock() < deadline do task.wait(0.05) end
    if not LOAD.done[name] then
        fail(name, index, "did not finish within " .. CHUNK_TIMEOUT .. " s (runtime error after a yield?)")
    end
    if name == "00_core" then
        -- This load's own run: its shutdown and state, for the cleanup.
        LOAD.shutdown = shutdownScript
        LOAD.state = SCRIPT_STATE
    end
end
if _G.__lacedLoad == LOAD and type(warn) == "function" then
    warn("[laced.club] all " .. #CHUNKS .. " chunks loaded")
end
