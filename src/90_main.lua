-- @chunk 90_main  (Anime Piece: keep-alive)
local LACED_LOAD = type(_G.__lacedLoad) == "table" and _G.__lacedLoad or nil -- load marker (loader.lua)
if LACED_LOAD and type(LACED_LOAD.started) == "table" then LACED_LOAD.started["90_main"] = true end
local alive = alive

SCRIPT_LIBRARY = Library
notify("Anime Piece loaded: Auto Farm Quest and Fruits are on the Main tab", "laced.club", 4)

-- Load marker before the keep-alive loop (it does not end while loaded).
if LACED_LOAD and type(LACED_LOAD.done) == "table" then LACED_LOAD.done["90_main"] = true end
while alive() do task.wait(1) end
