local addonName, ns = ...

local SlashCommands = {}
ns:RegisterModule("SlashCommands", SlashCommands)

local L = ns.L

-------------------------------------------------
-- Module Getters (lazy loading)
-------------------------------------------------

local Database = ns:GetModule("Database")

local function GetBagFrame()
    return ns:GetModule("BagFrame")
end

local function GetBankFrame()
    return ns:GetModule("BankFrame")
end

local function GetSettingsPopup()
    return ns:GetModule("SettingsPopup")
end

local function GetBagScanner()
    return ns:GetModule("BagScanner")
end

-------------------------------------------------
-- Command Handlers
-------------------------------------------------

local commandHandlers = {}

-- Default: Toggle bag frame
commandHandlers[""] = function()
    GetBagFrame():Toggle()
end

-- Settings/Config/Options
commandHandlers["settings"] = function()
    GetSettingsPopup():Toggle()
end
commandHandlers["config"] = commandHandlers["settings"]
commandHandlers["options"] = commandHandlers["settings"]

-- Sort bags
commandHandlers["sort"] = function()
    GetBagFrame():SortBags()
end

-- Toggle bank
commandHandlers["bank"] = function()
    GetBankFrame():Toggle()
end

-- Debug mode toggle
commandHandlers["debug"] = function()
    ns.debugMode = not ns.debugMode
    ns:Print(L["CMD_DEBUG_MODE"], ns.debugMode and L["CMD_ON"] or L["CMD_OFF"])
end

-- Debug item hover - print item data on hover
commandHandlers["debugitem"] = function()
    ns.debugItemMode = not ns.debugItemMode
    ns:Print("Debug item hover: " .. (ns.debugItemMode and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
end

-- Debug item button frames (for retail overlay issues)
commandHandlers["debugbutton"] = function()
    local ItemButton = ns:GetModule("ItemButton")
    ns:Print("Checking first item button structure...")

    -- Get first active button
    local firstButton = nil
    for button in ItemButton:GetActiveButtons() do
        firstButton = button
        break
    end

    if not firstButton then
        ns:Print("No active item buttons found. Open your bags first.")
        return
    end

    ns:Print("Button: " .. (firstButton:GetName() or "unnamed"))
    ns:Print("  Mouse enabled: " .. tostring(firstButton:IsMouseEnabled()))
    ns:Print("  Shown: " .. tostring(firstButton:IsShown()))
    ns:Print("  Frame level: " .. tostring(firstButton:GetFrameLevel()))

    -- List children
    local children = {firstButton:GetChildren()}
    ns:Print("  Children (" .. #children .. "):")
    for i, child in ipairs(children) do
        local childName = child:GetName() or child:GetObjectType()
        local mouseEnabled = child.IsMouseEnabled and child:IsMouseEnabled() or "N/A"
        local shown = child:IsShown()
        local level = child.GetFrameLevel and child:GetFrameLevel() or "N/A"
        ns:Print("    " .. i .. ": " .. childName .. " mouse=" .. tostring(mouseEnabled) .. " shown=" .. tostring(shown) .. " level=" .. tostring(level))
    end

    -- Check specific overlays
    local overlays = {"ItemContextOverlay", "SearchOverlay", "ExtendedSlot", "WidgetContainer", "Cooldown", "NineSlice"}
    ns:Print("  Known overlays:")
    for _, name in ipairs(overlays) do
        local overlay = firstButton[name]
        if overlay then
            local shown = overlay.IsShown and overlay:IsShown() or "N/A"
            local mouse = overlay.IsMouseEnabled and overlay:IsMouseEnabled() or "N/A"
            ns:Print("    " .. name .. ": exists, shown=" .. tostring(shown) .. " mouse=" .. tostring(mouse))
        else
            ns:Print("    " .. name .. ": not found")
        end
    end
end

-- List saved characters
commandHandlers["chars"] = function()
    ns:Print(L["CMD_SAVED_CHARACTERS"])

    local characters = Database:GetAllCharacterData()
    if characters and next(characters) then
        local currentFullName = Database:GetPlayerFullName()
        for fullName, data in pairs(characters) do
            local bagCount = 0
            local bagItemCount = 0
            local bankCount = 0
            local bankItemCount = 0

            if data.bags then
                for _, bagData in pairs(data.bags) do
                    bagCount = bagCount + 1
                    if bagData.slots then
                        for _ in pairs(bagData.slots) do
                            bagItemCount = bagItemCount + 1
                        end
                    end
                end
            end

            if data.bank then
                for _, bagData in pairs(data.bank) do
                    bankCount = bankCount + 1
                    if bagData.slots then
                        for _ in pairs(bagData.slots) do
                            bankItemCount = bankItemCount + 1
                        end
                    end
                end
            end

            local current = (fullName == currentFullName) and " " .. L["CMD_YOU"] or ""
            ns:Print("  " .. fullName .. current)
            ns:Print("    " .. L["CMD_BAGS"] .. bagCount .. L["CMD_CONTAINERS"] .. bagItemCount .. L["CMD_ITEMS"])
            ns:Print("    " .. L["CMD_BANK"] .. bankCount .. L["CMD_CONTAINERS"] .. bankItemCount .. L["CMD_ITEMS"])
        end
    else
        ns:Print("  " .. L["CMD_NO_DATA"])
    end
end

-- Force save current character
commandHandlers["save"] = function()
    local BagScanner = GetBagScanner()

    ns:Print(L["CMD_SCANNING"])
    local bags = BagScanner:ScanAllBags()

    local bagCount = 0
    local itemCount = 0
    for _, bagData in pairs(bags) do
        bagCount = bagCount + 1
        if bagData.slots then
            for _ in pairs(bagData.slots) do
                itemCount = itemCount + 1
            end
        end
    end
    ns:Print(string.format(L["CMD_SCANNED"], bagCount, itemCount))

    ns:Print(L["CMD_SAVING_TO"] .. Database:GetPlayerFullName())
    BagScanner:SaveToDatabase()
    ns:Print(L["CMD_DONE"])
end

-- Show current locale info
commandHandlers["locale"] = function()
    local testLocale = Database:GetGlobalSetting("testLocale")

    ns:Print("Current locale: " .. ns:GetCurrentLocale())
    ns:Print("Game locale: " .. GetLocale())
    if testLocale then
        ns:Print("Test override: " .. testLocale)
    else
        ns:Print("Test override: none")
    end
    ns:Print("Available: " .. table.concat(ns:GetAvailableLocales(), ", "))
end

-- Status - show expansion and feature detection info
commandHandlers["status"] = function()
    local Expansion = ns:GetModule("Expansion")
    local Constants = ns.Constants

    ns:Print("=== GudaBags Status ===")
    ns:Print("Version: " .. (ns.version or "unknown"))

    if Expansion then
        ns:Print("Interface: " .. (Expansion.InterfaceVersion or "unknown"))
        ns:Print("IsRetail: " .. tostring(Expansion.IsRetail))
        ns:Print("IsClassicEra: " .. tostring(Expansion.IsClassicEra))
        ns:Print("IsTBC: " .. tostring(Expansion.IsTBC))
        ns:Print("IsMoP: " .. tostring(Expansion.IsMoP))
    else
        ns:Print("Expansion module: NOT LOADED")
    end

    if Constants and Constants.FEATURES then
        ns:Print("Features:")
        for k, v in pairs(Constants.FEATURES) do
            ns:Print("  " .. k .. ": " .. tostring(v))
        end
    else
        ns:Print("Constants.FEATURES: NOT LOADED")
    end

    -- Check if modules are registered
    local scanner = ns:GetModule("GuildBankScanner")
    local gbFrame = ns:GetModule("GuildBankFrame")
    ns:Print("GuildBankScanner: " .. (scanner and "loaded" or "NOT LOADED"))
    ns:Print("GuildBankFrame: " .. (gbFrame and "loaded" or "NOT LOADED"))
end

-- Performance stats
commandHandlers["perf"] = function()
    local stats = ns.perfStats
    ns:Print("=== GudaBags Performance ===")
    ns:Print(string.format("Last scan: %.2f ms (%d total scans)", stats.lastScanTime, stats.scanCount))
    ns:Print(string.format("Last refresh: %.2f ms (%d total refreshes)", stats.lastRefreshTime, stats.refreshCount))

    -- Memory usage
    UpdateAddOnMemoryUsage()
    local mem = GetAddOnMemoryUsage(addonName)
    if mem then
        if mem > 1024 then
            ns:Print(string.format("Memory: %.1f MB", mem / 1024))
        else
            ns:Print(string.format("Memory: %.0f KB", mem))
        end
    end

    -- Tooltip cache size
    local ItemScanner = ns:GetModule("ItemScanner")
    if ItemScanner and ItemScanner.GetTooltipCacheSize then
        ns:Print("Tooltip cache: " .. ItemScanner:GetTooltipCacheSize() .. " entries")
    end
end

-- Profile management
commandHandlers["profiles"] = function()
    local profiles = Database:GetProfileList()
    if #profiles == 0 then
        ns:Print(L["PROFILE_NO_PROFILES"])
    else
        ns:Print(L["PROFILE_LIST"])
        for _, name in ipairs(profiles) do
            local profile = Database:GetProfile(name)
            local info = ""
            if profile and profile.savedBy then
                info = " (" .. profile.savedBy .. ")"
            end
            if profile and profile.categories then
                info = info .. " [+cat]"
            end
            ns:Print("  - " .. name .. info)
        end
    end
end

-- Help
commandHandlers["help"] = function()
    ns:Print(L["CMD_COMMANDS"])
    ns:Print("  " .. L["CMD_HELP_TOGGLE"])
    ns:Print("  " .. L["CMD_HELP_BANK"])
    ns:Print("  " .. L["CMD_HELP_SETTINGS"])
    ns:Print("  " .. L["CMD_HELP_SORT"])
    ns:Print("  " .. L["CMD_HELP_CHARS"])
    ns:Print("  " .. L["CMD_HELP_SAVE"])
    ns:Print("  " .. L["CMD_HELP_COUNT"])
    ns:Print("  " .. L["CMD_HELP_DEBUG"])
    ns:Print("  " .. L["CMD_HELP_HELP"])
    ns:Print("  /guda profiles - List saved profiles")
    ns:Print("  /guda profile save <name> - Save current settings")
    ns:Print("  /guda profile load <name> - Load profile")
    ns:Print("  /guda profile delete <name> - Delete profile")
    ns:Print("  /guda perf - Show performance stats")
    ns:Print("  /guda debugitem - Toggle item data on hover")
    ns:Print("  /guda locale [code|reset] - Test locale")
    ns:Print("  /guda status - Show expansion/feature detection")
end

-------------------------------------------------
-- Pattern-based Command Handlers
-------------------------------------------------

local patternHandlers = {}

-- Count item by ID across characters
patternHandlers["^count%s+(%d+)$"] = function(itemID)
    local total, chars = Database:CountItemAcrossCharacters(tonumber(itemID))
    ns:Print(string.format(L["CMD_ITEM_COUNT"], itemID, total))
    for _, c in ipairs(chars) do
        local current = c.isCurrent and " " .. L["CMD_YOU"] or ""
        ns:Print("  " .. c.name .. current .. ": " .. c.count)
    end
end

-- Set locale (use original case)
patternHandlers["^locale%s+(%S+)$"] = function(localeCode)
    ns:SetLocale(localeCode)
end

-- Profile save
patternHandlers["^profile%s+save%s+(.+)$"] = function(name)
    name = name:match("^%s*(.-)%s*$")
    if not name or name == "" then
        ns:Print(L["PROFILE_NAME_EMPTY"])
        return
    end
    Database:SaveProfile(name, false)
    ns:Print(string.format(L["PROFILE_SAVED"], name))
end

-- Profile load
patternHandlers["^profile%s+load%s+(.+)$"] = function(name)
    name = name:match("^%s*(.-)%s*$")
    if Database:LoadProfile(name) then
        ns:Print(string.format(L["PROFILE_LOADED"], name))
        local Events = ns:GetModule("Events")
        Events:Fire("SETTING_CHANGED", "theme", Database:GetSetting("theme"))
        Events:Fire("CATEGORIES_UPDATED")
    else
        ns:Print(string.format(L["PROFILE_NOT_FOUND"], name))
    end
end

-- Profile delete
patternHandlers["^profile%s+delete%s+(.+)$"] = function(name)
    name = name:match("^%s*(.-)%s*$")
    if Database:DeleteProfile(name) then
        ns:Print(string.format(L["PROFILE_DELETED"], name))
    else
        ns:Print(string.format(L["PROFILE_NOT_FOUND"], name))
    end
end

-------------------------------------------------
-- Main Command Dispatcher
-------------------------------------------------

local function HandleSlashCommand(msg)
    local originalMsg = msg or ""
    local cmd = string.lower(originalMsg)

    -- Try exact match first
    if commandHandlers[cmd] then
        commandHandlers[cmd]()
        return
    end

    -- Try pattern matches (use original message for case-sensitive patterns like locale)
    for pattern, handler in pairs(patternHandlers) do
        local capture = originalMsg:match(pattern)
        if capture then
            handler(capture)
            return
        end
    end

    -- Unknown command
    ns:Print(L["CMD_UNKNOWN"])
end

-------------------------------------------------
-- Registration
-------------------------------------------------

function SlashCommands:Register()
    _G["SLASH_GUDABAGS1"] = "/guda"
    _G["SLASH_GUDABAGS2"] = "/gb"
    _G.SlashCmdList["GUDABAGS"] = HandleSlashCommand
end

-- Auto-register on load
SlashCommands:Register()
