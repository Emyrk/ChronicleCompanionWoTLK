local T = _G.Test
local cases = {}

local function loadSettings(options)
    options = options or {}
    local widgets = {}
    local values = { position_telemetry_enabled = options.enabled ~= false,
        log_level = "info", log_window = 1 }
    local starts, stops, clears = 0, 0, 0
    local popup
    local methods = {}
    local function widget()
        local w = { scripts = {}, shown = false, enabled = true }
        setmetatable(w, { __index = function(_, key)
            return methods[key] or function() end
        end })
        widgets[#widgets + 1] = w
        return w
    end
    methods.CreateFontString = widget
    methods.SetText = function(self, text) self.text = text end
    methods.SetScript = function(self, event, fn) self.scripts[event] = fn end
    methods.SetChecked = function(self, checked) self.checked = checked end
    methods.GetChecked = function(self) return self.checked end
    methods.Enable = function(self) self.enabled = true end
    methods.Disable = function(self) self.enabled = false end
    methods.IsShown = function(self) return self.shown end
    methods.Show = function(self)
        self.shown = true
        if self.scripts.OnShow then self.scripts.OnShow(self) end
    end
    methods.Hide = function(self) self.shown = false end
    _G.StaticPopupDialogs = {}
    _G.CANCEL = "Cancel"
    _G.StaticPopup_Show = function(name) popup = name end
    _G.CreateFrame = function() return widget() end
    _G.UIParent = widget()
    _G.UISpecialFrames = {}
    _G.LoggingCombat = function() return false end
    _G.GetInstanceInfo = function() return "", "none" end
    _G.GetAddOnMetadata = function() return "test" end
    _G.GetBuildInfo = function() return "3.3.5", "12340" end
    _G.UIDropDownMenu_SetSelectedValue = function() end
    _G.UIDropDownMenu_SetWidth = function() end
    _G.UIDropDownMenu_Initialize = function() end
    _G.Chronicle = {
        ADDON_NAME = "ChronicleCompanionWoTLK",
        Logger = { SetLevel = function() end, Info = function() end },
        Config = {
            IsReady = function() return true end,
            Get = function(_, key) return values[key] end,
            Set = function(_, key, value) values[key] = value end,
            ResetAll = function() values.position_telemetry_enabled = true end,
        },
        PositionStore = {
            CanClear = function() return options.available ~= false end,
            IsReady = function() return options.available ~= false end,
        },
        PositionTelemetry = {
            ClearPositions = function() clears = clears + 1 end,
            Start = function() starts = starts + 1 end,
            Stop = function() stops = stops + 1 end,
        },
    }
    if options.noStore then Chronicle.PositionStore = nil end
    dofile("UI/SettingsUI.lua")
    Chronicle.ShowSettingsUI()
    local checkbox, reset, clearButton
    for _, w in ipairs(widgets) do
        if rawget(w, "_label") and w._label.text == "Capture positions" then checkbox = w end
        if w.text == "Reset Settings" then reset = w end
        if w.text == "Clear positions" then clearButton = w end
    end
    T.truthy(checkbox)
    return checkbox, values, function() return starts, stops end, reset, clearButton,
        function() return popup, clears end
end

cases[#cases + 1] = { name = "position checkbox reflects and updates the saved setting immediately", run = function()
    local cb, values, counts = loadSettings()
    T.truthy(cb.enabled)
    T.truthy(cb.checked)
    cb:SetChecked(false)
    cb.scripts.OnClick(cb)
    T.falsy(values.position_telemetry_enabled)
    local starts, stops = counts()
    T.equal(starts, 0)
    T.equal(stops, 1)
    cb:SetChecked(true)
    cb.scripts.OnClick(cb)
    T.truthy(values.position_telemetry_enabled)
    starts, stops = counts()
    T.equal(starts, 1)
    T.equal(stops, 1)
end }

cases[#cases + 1] = { name = "missing bridge shows a disabled unchecked position checkbox without erasing preference", run = function()
    local cb, values, counts = loadSettings({ available = false })
    T.falsy(cb.enabled)
    T.falsy(cb.checked)
    T.truthy(values.position_telemetry_enabled)
    T.contains(cb._availability.text, "Requires")
    local starts = counts()
    T.equal(starts, 0)
end }

cases[#cases + 1] = { name = "settings tolerate a missing position store", run = function()
    local cb = loadSettings({ noStore = true })
    T.falsy(cb.enabled)
    T.falsy(cb.checked)
end }

cases[#cases + 1] = { name = "saved off preference stays off with a bridge installed", run = function()
    local cb = loadSettings({ enabled = false })
    T.truthy(cb.enabled)
    T.falsy(cb.checked)
end }

cases[#cases + 1] = { name = "reset settings reconciles the position sampler and dependency state", run = function()
    local cb, _, counts, reset = loadSettings({ available = false, enabled = false })
    reset.scripts.OnClick(reset)
    local starts, stops = counts()
    T.equal(starts, 0)
    T.equal(stops, 1)
    T.falsy(cb.enabled)
    T.falsy(cb.checked)
end }

cases[#cases + 1] = { name = "clear positions button requires confirmation before deleting data", run = function()
    local _, _, _, _, button, state = loadSettings()
    T.truthy(button.enabled)
    button.scripts.OnClick(button)
    local popup, clears = state()
    T.equal(popup, "CHRONICLE_CLEAR_POSITIONS")
    T.equal(clears, 0)
    StaticPopupDialogs[popup].OnAccept()
    popup, clears = state()
    T.equal(clears, 1)
    T.truthy(StaticPopupDialogs[popup].hideOnEscape)
end }

cases[#cases + 1] = { name = "clear positions button is disabled without compatible bridge storage", run = function()
    local _, _, _, _, button = loadSettings({ available = false })
    T.falsy(button.enabled)
end }

cases[#cases + 1] = { name = "positions clear slash command opens the same confirmation dialog", run = function()
    local _, _, _, _, _, state = loadSettings()
    Chronicle.Capture = {}
    dofile("Capture/LocalScan.lua")
    Chronicle._slashHandler("positions clear")
    local popup, clears = state()
    T.equal(popup, "CHRONICLE_CLEAR_POSITIONS")
    T.equal(clears, 0)
end }

return cases
