-- @chunk 05_uelib  (UE UI library loader; shared by every game build)
local LACED_LOAD = type(_G.__lacedLoad) == "table" and _G.__lacedLoad or nil -- load marker (loader.lua)
if LACED_LOAD and type(LACED_LOAD.started) == "table" then LACED_LOAD.started["05_uelib"] = true end
-- Per-execution bindings: captured at chunk load so a re-run of the script
-- cannot make this copy's loops read the new copy's state (alive is a
-- closure over this run's state since the Oct 15 stability pass).
local alive = alive
local SCRIPT_STATE = SCRIPT_STATE
local S = S
local shutdownScript = shutdownScript -- this run's (00_core), for the UE OnUnload hook
UE_URL = "https://raw.githubusercontent.com/hauntedscripts/Scripts2/refs/heads/main/matcha%20ue"

function ueEnvironments()
    local envs = {}
    local getgenvFn = _G.getgenv
    if type(getgenvFn) == "function" then
        local okGenv, genv = pcall(getgenvFn)
        if okGenv and type(genv) == "table" then table.insert(envs, genv) end
    end
    table.insert(envs, _G)
    return envs
end

-- loadstring drops top-level returns in Matcha, so the library is only
-- reachable through the UELibrary global it publishes.
function findExposedUE()
    for _, env in ipairs(ueEnvironments()) do
        local candidate = env.UELibrary
        if type(candidate) == "table" and type(candidate.CreateWindow) == "function" then return candidate end
    end
    for _, env in ipairs(ueEnvironments()) do
        local candidate = env.Library
        if type(candidate) == "table" and type(candidate.CreateWindow) == "function" and candidate.Raw == nil then
            return candidate
        end
    end
    return nil
end

function validateUESource(body)
    if type(body) ~= "string" or #body < 2000 then
        return false, "empty or truncated download (" .. tostring(type(body) == "string" and #body or 0) .. " bytes)"
    end
    local head = string.lower(string.sub(body, 1, 300))
    if string.find(head, "<!doctype", 1, true) or string.find(head, "<html", 1, true)
        or string.find(head, "404: not found", 1, true) then
        return false, "server returned an error page instead of the library"
    end
    if not string.find(body, "CreateWindow", 1, true) or not string.find(body, "UELibrary", 1, true) then
        return false, "downloaded file is not the UE library"
    end
    return true, nil
end

UE_DOWNLOAD_ATTEMPTS = 3 -- bounded retry: 1 s, then 2 s between attempts

function loadUEAdapter()
    local ueSource, valid, reason = "", false, nil
    for attempt = 1, UE_DOWNLOAD_ATTEMPTS do
        ueSource = safeHttpGet(UE_URL)
        valid, reason = validateUESource(ueSource)
        if valid or attempt == UE_DOWNLOAD_ATTEMPTS then break end
        warnThrottled("ueDownload", "[laced.club] UE download rejected (" .. tostring(reason) .. "), retrying", 5)
        task.wait(attempt)
    end
    assert(valid, "UE download rejected: " .. tostring(reason))

    local previousUE = findExposedUE()
    local ueChunk = loadstring(ueSource, "laced.club UE")
    assert(type(ueChunk) == "function", "UE compile failed")
    ueChunk()

    local UE = findExposedUE()
    -- A new UE copy that fails the checks below has already created its
    -- windows (and unloaded the previous copy): unload it, do not leave a
    -- half-built menu on screen.
    local function rejectNewUE(message)
        if type(UE) == "table" and UE ~= previousUE and type(UE.Unload) == "function" and not UE._unloaded then
            pcall(function() UE:Unload() end)
        end
        assert(false, message)
    end
    if type(UE) ~= "table" then rejectNewUE("UE did not expose UELibrary") end
    if UE == previousUE then rejectNewUE("UE chunk did not run (stale UELibrary from a previous execution)") end
    if UE._unloaded then rejectNewUE("UE library is already unloaded") end
    if type(UE.CreateWindow) ~= "function" then rejectNewUE("UE library has no CreateWindow") end

    local controls = {}

    local function roundTo(value, decimals)
        local power = 10 ^ (decimals or 0)
        return math.floor(value * power + 0.5) / power
    end

    local function roundingFor(step, explicit)
        local explicitNumber = tonumber(explicit)
        if explicitNumber then return math.max(0, math.floor(explicitNumber)) end
        step = tonumber(step) or 1
        if step >= 1 then return 0 end
        local decimals = tostring(step):match("%.(%d+)")
        return decimals and #decimals or 0
    end

    local function enhanceControl(id, control)
        if not control then return control end
        controls[id] = control
        control.Set = control.SetValue
        control.SetOptions = control.SetValues
        return control
    end

    local function makeTab(rawTab)
        local tab = { Raw = rawTab, Groups = {} }

        local function columnOf(info)
            local column = tonumber(info and info.Column) or 1
            return column == 2 and 2 or 1
        end

        local function groupFor(self, info)
            local column = columnOf(info)
            local group = self.Groups[column]
            if not group then
                if column == 2 then group = self.Raw:AddRightGroupbox("General")
                else group = self.Raw:AddLeftGroupbox("General") end
                self.Groups[column] = group
            end
            return group
        end

        function tab:AddSection(name, info)
            local column = columnOf(info)
            local group
            if column == 2 then group = self.Raw:AddRightGroupbox(name)
            else group = self.Raw:AddLeftGroupbox(name) end
            self.Groups[column] = group
            return group
        end

        function tab:AddToggle(id, info)
            info = info or {}
            local group = groupFor(self, info)
            local toggle = group:AddToggle(id, {
                Text = info.Text or id,
                Default = info.Default == true,
                Callback = info.Callback,
                Tooltip = info.Description,
                Risky = info.Risky == true,
            })
            enhanceControl(id, toggle)
            if info.Keybind == true then
                local picker = toggle:AddKeyPicker(id .. "_keybind", {
                    Text = (info.Text or id) .. " key",
                    Default = "None",
                    Mode = "Toggle",
                    SyncToggleState = true,
                })
                enhanceControl(id .. "_keybind", picker)
            end
            return toggle
        end

        function tab:AddSlider(id, info)
            info = info or {}
            -- A slider declared with Decimals but no Step must not snap to whole numbers.
            local step = tonumber(info.Step)
            if not step then
                local decimals = tonumber(info.Decimals)
                step = (decimals and decimals > 0) and (10 ^ -math.floor(decimals)) or 1
            end
            if step <= 0 then step = 1 end
            local minimum = tonumber(info.Min) or 0
            local maximum = tonumber(info.Max) or 100
            local rounding = roundingFor(step, info.Decimals)
            local callback = info.Callback
            local slider
            local function changed(value)
                value = tonumber(value) or minimum
                local snapped = minimum + math.floor(((value - minimum) / step) + 0.5) * step
                snapped = roundTo(snapped, rounding)
                if snapped < minimum then snapped = minimum end
                if snapped > maximum then snapped = maximum end
                if slider then slider.Value = snapped end
                if callback then callback(snapped) end
            end
            slider = groupFor(self, info):AddSlider(id, {
                Text = info.Text or id,
                Default = info.Default,
                Min = minimum,
                Max = maximum,
                Rounding = rounding,
                Suffix = info.Suffix or "",
                Callback = changed,
                Tooltip = info.Description,
            })
            return enhanceControl(id, slider)
        end

        function tab:AddDropdown(id, info)
            info = info or {}
            local values = info.Options or info.Values or {}
            local default = info.Default
            if default ~= nil and not info.Multi then
                local found = false
                for _, value in ipairs(values) do
                    if value == default then found = true; break end
                end
                if not found then default = values[1] end
            end
            local dropdown = groupFor(self, info):AddDropdown(id, {
                Text = info.Text or id,
                Default = default,
                Values = values,
                Multi = info.Multi == true,
                AllowNull = info.AllowNull == true,
                Callback = info.Callback,
                Tooltip = info.Description,
            })
            return enhanceControl(id, dropdown)
        end

        function tab:AddButton(id, info)
            info = info or {}
            local button = groupFor(self, info):AddButton({
                Text = info.Text or id,
                Func = info.Callback,
                Tooltip = info.Description,
                DoubleClick = info.DoubleClick == true,
            })
            return enhanceControl(id, button)
        end

        -- Read-only text line (UE GroupMethods:AddLabel(text, wraps)). UE draws
        -- the control's Text field every frame, so writing label.Text updates it.
        -- Not registered in Controls: labels have no value to save or reset.
        function tab:AddLabel(id, info)
            info = info or {}
            local label = groupFor(self, info):AddLabel(info.Text or id, info.Wrap == true)
            return label
        end

        function tab:AddPriorityList(id, info)
            info = info or {}
            local group = groupFor(self, info)
            local options = info.Options or {}
            local selected = {}
            for index, value in ipairs(info.Default or options) do selected[index] = value end
            local pickers = {}
            local changing = false

            local function emit()
                if info.Callback then
                    local order = {}
                    for index = 1, #options do order[index] = selected[index] end
                    info.Callback(order)
                end
            end

            for index = 1, #options do
                local slot = index
                local picker = group:AddDropdown(id .. "_" .. tostring(slot), {
                    Text = (info.Text or id) .. " " .. tostring(slot),
                    Default = selected[slot],
                    Values = options,
                    Callback = function(value)
                        if changing then return end
                        local previous = selected[slot]
                        local duplicate = nil
                        for other = 1, #selected do
                            if other ~= slot and selected[other] == value then duplicate = other; break end
                        end
                        selected[slot] = value
                        if duplicate then
                            selected[duplicate] = previous
                            if pickers[duplicate] then pickers[duplicate].Value = previous end
                        end
                        emit()
                    end,
                    Tooltip = info.Description,
                })
                pickers[slot] = picker
                enhanceControl(id .. "_" .. tostring(slot), picker)
            end

            local list = { Pickers = pickers, Value = selected }
            function list:SetValue(order)
                if type(order) ~= "table" then return self end
                changing = true
                for index = 1, math.min(#order, #pickers) do
                    selected[index] = order[index]
                    pickers[index].Value = order[index]
                end
                changing = false
                emit()
                return self
            end
            function list:SetValues(values)
                for _, picker in ipairs(pickers) do picker:SetValues(values or {}) end
                return self
            end
            list.SetOptions = list.SetValues
            controls[id] = list
            return list
        end

        return tab
    end

    local Adapter = { Raw = UE, Controls = controls, Windows = {} }

    local function makePopup(adapter, info)
        info = info or {}
        local wasToggled = adapter.Raw.Toggled
        local raw = adapter.Raw:CreateWindow({
            Title = info.Title or "Settings",
            Width = info.Width or 520,
            Height = info.Height or 500,
            AutoShow = false,
            Center = true,
        })
        -- CreateWindow copies the new (hidden) window's visibility into
        -- Library.Toggled, which would hide the main menu; restore it.
        adapter.Raw.Toggled = wasToggled ~= false
        local page = makeTab(raw:AddTab(info.Title or "Settings"))
        local popup = { Raw = raw }
        function popup:AddSection(...) return page:AddSection(...) end
        function popup:AddToggle(...) return page:AddToggle(...) end
        function popup:AddSlider(...) return page:AddSlider(...) end
        function popup:AddDropdown(...) return page:AddDropdown(...) end
        function popup:AddButton(...) return page:AddButton(...) end
        function popup:AddPriorityList(...) return page:AddPriorityList(...) end
        function popup:Show() raw:Show(); return self end
        function popup:Hide() raw:Hide(); return self end
        function popup:Set(id, value)
            local control = controls[id]
            if control and control.SetValue then control:SetValue(value)
            elseif control and control.Set then control:Set(value) end
            return self
        end
        return popup
    end

    -- True when the hook was installed (UE builds without OnUnload cannot stop
    -- the script from the menu's Unload button).
    function Adapter:OnUnload(callback)
        if type(self.Raw.OnUnload) == "function" then
            self.Raw:OnUnload(callback)
            return true
        end
        return false
    end

    function Adapter:CreateWindow(info)
        info = info or {}
        local accent = info.Theme and info.Theme.Colors and info.Theme.Colors.Accent
        if accent then
            -- StaticAccentColor is what the Settings tab picker, Rainbow-off and
            -- config load restore to; without it the accent snaps back to blue.
            self.Raw.AccentColor = accent
            self.Raw.StaticAccentColor = accent
        end
        if info.ConfigFile or info.SettingsFile then
            self.Raw.SettingsFile = (info.ConfigFile or info.SettingsFile) .. ".ui.json"
        end
        local raw = self.Raw:CreateWindow({
            Title = info.Title or "laced.club",
            Width = info.Width or 540,
            Height = info.Height or 430,
            AutoShow = true,
            Center = true,
        })
        local window = {
            Raw = raw,
            Tabs = {},
            Indicator = { SetVisible = function() end },
            Config = { IndicatorEnabled = false },
            _lastMenuDown = false,
        }

        local configFolder = tostring(info.ConfigFolder or "laced_club_configs")
        local selectedConfig = ""
        local function safeConfigName(name)
            name = tostring(name or ""):gsub("[^%w%._%- ]", "_"):gsub("^%s+", ""):gsub("%s+$", "")
            if name == "" then name = "default" end
            return name:sub(1, 64)
        end
        local function ensureConfigFolder()
            pcall(function()
                if not isfolder(configFolder) then makefolder(configFolder) end
            end)
        end
        local function configPathFor(name)
            return configFolder .. "/" .. safeConfigName(name) .. ".json"
        end
        local function listConfigNames()
            ensureConfigFolder()
            local names = {}
            local ok, files = pcall(listfiles, configFolder)
            if ok and type(files) == "table" then
                for _, path in ipairs(files) do
                    -- listfiles returns workspace-relative paths with backslashes.
                    local fileName = tostring(path):match("([^/\\]+)%.json$")
                    if fileName then table.insert(names, fileName) end
                end
            end
            table.sort(names)
            return names
        end
        local configPath = configPathFor("default")
        local function configValue(control)
            if not control then return nil end
            local kind = control.Type
            if kind == "Toggle" then return control.Value == true end
            if kind == "Slider" then return tonumber(control.Value) end
            if kind == "KeyPicker" then
                return type(control.Value) == "string" and control.Value or "None"
            end
            if kind == "Dropdown" then
                if control.Multi then
                    local out = {}
                    for key, value in pairs(control.Value or {}) do
                        if type(key) == "string" then out[key] = value == true end
                    end
                    return out
                end
                return type(control.Value) == "string" and control.Value or nil
            end
            return nil
        end
        local function saveFeatureConfig(name)
            name = safeConfigName(name or selectedConfig)
            ensureConfigFolder()
            local path = configPathFor(name)
            local data = { version = 4, controls = {}, name = name }
            for id, control in pairs(controls) do
                local value = configValue(control)
                if value ~= nil then data.controls[id] = value end
            end
            local ok = pcall(function()
                local http = game:GetService("HttpService")
                writefile(path, http:JSONEncode(data))
            end)
            if ok then
                selectedConfig = name
                configPath = path
                window.Config.File = path
            end
            return ok
        end
        local function loadFeatureConfig(name)
            name = safeConfigName(name or selectedConfig)
            local path = configPathFor(name)
            -- readfile raises on a missing file in Matcha.
            local okExists, exists = pcall(isfile, path)
            if not okExists or not exists then return false end
            local wasVisible = raw.Visible
            local wasToggled = self.Raw.Toggled
            local ok, data = pcall(function()
                local http = game:GetService("HttpService")
                return http:JSONDecode(readfile(path))
            end)
            if not ok or type(data) ~= "table" or data.version ~= 4 or type(data.controls) ~= "table" then
                return false
            end
            local toggleStates = {}
            for id, saved in pairs(data.controls) do
                local control = controls[id]
                local value = saved
                -- Also accept the UE Settings-tab format { type = ..., value = ... }.
                if type(saved) == "table" and saved.value ~= nil and saved.type ~= nil then value = saved.value end
                if control and control.Type == "Toggle" and type(value) == "boolean" then
                    toggleStates[id] = value
                elseif control and control.Type ~= "Button" and control.SetValue then
                    pcall(function() control:SetValue(value) end)
                end
            end
            local previous = {}
            for id, value in pairs(toggleStates) do
                local control = controls[id]
                if control then
                    previous[id] = control.Value == true
                    control.Value = value
                end
            end
            for id, value in pairs(toggleStates) do
                local control = controls[id]
                if control and previous[id] ~= value then
                    pcall(function() if control.Callback then control.Callback(value) end end)
                    pcall(function() if control.Changed then control.Changed(value) end end)
                end
            end
            for id, value in pairs(toggleStates) do
                local control = controls[id]
                if control then control.Value = value end
            end
            raw.Visible = wasVisible
            self.Raw.Toggled = wasToggled
            raw._visibilityDirty = true
            selectedConfig = name
            configPath = path
            window.Config.File = path
            return true
        end
        local function refreshConfigList(dropdown)
            local names = listConfigNames()
            if dropdown and dropdown.SetValues then
                pcall(function() dropdown:SetValues(names) end)
            end
            if selectedConfig == "" and names[1] then selectedConfig = names[1] end
            return names
        end
        window.Config = {
            IndicatorEnabled = false,
            File = configPath,
            Folder = configFolder,
            Save = function(name) return saveFeatureConfig(name) end,
            Load = function(name) return loadFeatureConfig(name) end,
            Refresh = function(dropdown) return refreshConfigList(dropdown) end,
            List = function() return listConfigNames() end,
        }

        function window:AddTab(name)
            local tab = makeTab(raw:AddTab(name))
            self.Tabs[name] = tab
            return tab
        end

        function window:Set(id, value)
            local control = controls[id]
            if control and control.SetValue then control:SetValue(value)
            elseif control and control.Set then control:Set(value) end
            return self
        end

        function window:CreatePopup(popupInfo)
            return makePopup(Adapter, popupInfo)
        end

        function window:Show() raw:Show(); return self end
        function window:Hide() raw:Hide(); return self end
        function window:SetVisible(value) if value then raw:Show() else raw:Hide() end; return self end

        function window:Step()
            return self
        end

        table.insert(Adapter.Windows, window)

        -- The UE Settings tab owns the visible config UI; point Window.Config
        -- at the same store so both paths read and write the same files.
        local ueConfigs = self.Raw.Configs
        if type(ueConfigs) == "table" then
            window.Config.Folder = ueConfigs.Folder or window.Config.Folder
            window.Config.File = tostring(window.Config.Folder) .. "/default.json"
            if type(ueConfigs.Save) == "function" then window.Config.Save = ueConfigs.Save end
            if type(ueConfigs.Load) == "function" then window.Config.Load = ueConfigs.Load end
            if type(ueConfigs.Refresh) == "function" then window.Config.Refresh = ueConfigs.Refresh end
        end
        return window
    end

    return Adapter
end

do
    local okUE, ueResult = pcall(loadUEAdapter)
    if okUE and type(ueResult) == "table" then
        Library = ueResult
        menuUE = ueResult.Raw
        SCRIPT_STATE.ue = ueResult.Raw
    else
        -- assert, not return: a plain return used to end only this chunk, so
        -- the loader ran 20_ui2 into a nil index. The loader catches this and
        -- runs this run's shutdownScript.
        warn("Failed to load UE UI: " .. tostring(ueResult))
        assert(false, "[laced.club] UE UI failed to load: " .. tostring(ueResult))
    end
end

-- Load marker: this chunk ran to the end.
if LACED_LOAD and type(LACED_LOAD.done) == "table" then LACED_LOAD.done["05_uelib"] = true end
