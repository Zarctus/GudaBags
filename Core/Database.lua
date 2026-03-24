local addonName, ns = ...

local Database = {}
ns:RegisterModule("Database", Database)

local Constants = ns.Constants
local Events = ns:GetModule("Events")

local playerFullName

local function GetPlayerFullName()
    -- Don't use cached value if it was set incorrectly (nil name)
    if playerFullName and not playerFullName:match("^nil%-") then
        return playerFullName
    end

    local name = UnitName("player")
    local realm = GetRealmName()

    -- Don't cache if name is not available yet
    if not name or name == "" or name == "Unknown" then
        return nil
    end

    playerFullName = name .. "-" .. realm
    return playerFullName
end

local function InitializeGlobalDB()
    if not GudaBags_DB then
        GudaBags_DB = {
            version = ns.version,
            characters = {},
        }
    end

    if not GudaBags_DB.characters then
        GudaBags_DB.characters = {}
    end

    GudaBags_DB.profiles = GudaBags_DB.profiles or {}
end

local function InitializeCharDB()
    if not GudaBags_CharDB then
        GudaBags_CharDB = {
            settings = {},
            settingsVersion = 0,
        }
    end

    GudaBags_CharDB.pinnedSlots = GudaBags_CharDB.pinnedSlots or {}
    GudaBags_CharDB.lockedItems = GudaBags_CharDB.lockedItems or {}
    GudaBags_CharDB.setProtectionExceptions = GudaBags_CharDB.setProtectionExceptions or {}

    for key, default in pairs(Constants.DEFAULTS) do
        if GudaBags_CharDB.settings[key] == nil then
            GudaBags_CharDB.settings[key] = default
        end
    end

    -- Migration: v1 - update iconSpacing to account for border width
    if (GudaBags_CharDB.settingsVersion or 0) < 1 then
        GudaBags_CharDB.settings.iconSpacing = Constants.DEFAULTS.iconSpacing
        GudaBags_CharDB.settingsVersion = 1
    end

    -- Migration: v2 - convert bgAlpha from 0-1 to 0-100
    if (GudaBags_CharDB.settingsVersion or 0) < 2 then
        local oldAlpha = GudaBags_CharDB.settings.bgAlpha
        if oldAlpha and oldAlpha <= 1 then
            GudaBags_CharDB.settings.bgAlpha = math.floor(oldAlpha * 100)
        end
        GudaBags_CharDB.settingsVersion = 2
    end

    -- Migration: v3 - split showQualityBorder into equipmentBorders and otherBorders
    if (GudaBags_CharDB.settingsVersion or 0) < 3 then
        local oldSetting = GudaBags_CharDB.settings.showQualityBorder
        if oldSetting ~= nil then
            GudaBags_CharDB.settings.equipmentBorders = oldSetting
            GudaBags_CharDB.settings.otherBorders = oldSetting
            GudaBags_CharDB.settings.showQualityBorder = nil
        end
        GudaBags_CharDB.settingsVersion = 3
    end

    -- Migration: v4 - rename columns to bagColumns
    if (GudaBags_CharDB.settingsVersion or 0) < 4 then
        if GudaBags_CharDB.settings.columns ~= nil then
            GudaBags_CharDB.settings.bagColumns = GudaBags_CharDB.settings.columns
            GudaBags_CharDB.settings.columns = nil
        end
        GudaBags_CharDB.settingsVersion = 4
    end

    -- Migration: v5 - enable showTooltipCounts (cross-character inventory) by default
    if (GudaBags_CharDB.settingsVersion or 0) < 5 then
        GudaBags_CharDB.settings.showTooltipCounts = true
        GudaBags_CharDB.settingsVersion = 5
    end

    -- Migration: v6 - convert "hide" settings to "show" settings (invert values)
    if (GudaBags_CharDB.settingsVersion or 0) < 6 then
        -- hideBorders -> showBorders (invert)
        if GudaBags_CharDB.settings.hideBorders ~= nil then
            GudaBags_CharDB.settings.showBorders = not GudaBags_CharDB.settings.hideBorders
            GudaBags_CharDB.settings.hideBorders = nil
        end
        -- hideFooter -> showFooter (invert)
        if GudaBags_CharDB.settings.hideFooter ~= nil then
            GudaBags_CharDB.settings.showFooter = not GudaBags_CharDB.settings.hideFooter
            GudaBags_CharDB.settings.hideFooter = nil
        end
        -- hideCategoryCount -> showCategoryCount (invert)
        if GudaBags_CharDB.settings.hideCategoryCount ~= nil then
            GudaBags_CharDB.settings.showCategoryCount = not GudaBags_CharDB.settings.hideCategoryCount
            GudaBags_CharDB.settings.hideCategoryCount = nil
        end
        GudaBags_CharDB.settingsVersion = 6
    end
end

local function InitializeCharacterData()
    local fullName = GetPlayerFullName()
    if not fullName then
        ns:Debug("InitializeCharacterData: player name not available yet")
        return false
    end

    local _, classToken = UnitClass("player")
    local faction = UnitFactionGroup("player")

    if not GudaBags_DB.characters[fullName] then
        GudaBags_DB.characters[fullName] = {}
    end

    local charData = GudaBags_DB.characters[fullName]
    charData.name = UnitName("player")
    charData.realm = GetRealmName()
    charData.class = classToken
    charData.faction = faction
    charData.level = UnitLevel("player")
    charData.race = select(2, UnitRace("player"))
    charData.sex = UnitSex("player")
    charData.lastUpdate = time()

    if not charData.bags then
        charData.bags = {}
    end

    if not charData.bank then
        charData.bank = {}
    end

    if not charData.money then
        charData.money = GetMoney()
    end

    if not charData.mailbox then
        charData.mailbox = {}
    end

    ns:Debug("Character data initialized for", fullName)
    return true
end

function Database:Initialize()
    InitializeGlobalDB()
    InitializeCharDB()
    -- Character data init moved to PLAYER_LOGIN for reliable player name
end

function Database:InitializeCharacter()
    if not InitializeCharacterData() then
        ns:Print("Warning: Could not initialize character data")
    end
end

function Database:GetSetting(key)
    if not GudaBags_CharDB or not GudaBags_CharDB.settings then
        -- Return default if DB not initialized yet
        return Constants.DEFAULTS and Constants.DEFAULTS[key] or nil
    end
    local value = GudaBags_CharDB.settings[key]
    -- Return default if value is nil (not explicitly set)
    if value == nil and Constants.DEFAULTS then
        return Constants.DEFAULTS[key]
    end
    return value
end

function Database:SetSetting(key, value)
    GudaBags_CharDB.settings[key] = value
end

-------------------------------------------------
-- Pinned Slots (per-character, slot-based)
-------------------------------------------------

function Database:IsPinnedSlot(bagID, slot)
    if not GudaBags_CharDB or not GudaBags_CharDB.pinnedSlots then return false end
    return GudaBags_CharDB.pinnedSlots[bagID * 1000 + slot] or false
end

function Database:TogglePinnedSlot(bagID, slot)
    if not GudaBags_CharDB then return false end
    GudaBags_CharDB.pinnedSlots = GudaBags_CharDB.pinnedSlots or {}
    local key = bagID * 1000 + slot
    if GudaBags_CharDB.pinnedSlots[key] then
        GudaBags_CharDB.pinnedSlots[key] = nil
        return false
    else
        GudaBags_CharDB.pinnedSlots[key] = true
        return true
    end
end

function Database:GetPinnedSlotSet()
    if not GudaBags_CharDB or not GudaBags_CharDB.pinnedSlots then return {} end
    return GudaBags_CharDB.pinnedSlots
end

function Database:ClearPinnedSlots()
    if GudaBags_CharDB then
        GudaBags_CharDB.pinnedSlots = {}
    end
end

-------------------------------------------------
-- Locked Items (per-character, itemID-based)
-------------------------------------------------

function Database:IsItemLocked(itemID)
    if not itemID or not GudaBags_CharDB or not GudaBags_CharDB.lockedItems then return false end
    return GudaBags_CharDB.lockedItems[itemID] or false
end

function Database:ToggleItemLock(itemID)
    if not itemID or not GudaBags_CharDB then return false end
    GudaBags_CharDB.lockedItems = GudaBags_CharDB.lockedItems or {}
    if GudaBags_CharDB.lockedItems[itemID] then
        GudaBags_CharDB.lockedItems[itemID] = nil
        return false
    else
        GudaBags_CharDB.lockedItems[itemID] = true
        return true
    end
end

-------------------------------------------------
-- Set Protection Exceptions (per-character, itemID-based)
-------------------------------------------------

function Database:IsSetProtectionException(itemID)
    if not itemID or not GudaBags_CharDB or not GudaBags_CharDB.setProtectionExceptions then return false end
    return GudaBags_CharDB.setProtectionExceptions[itemID] or false
end

function Database:ToggleSetProtectionException(itemID)
    if not itemID or not GudaBags_CharDB then return false end
    GudaBags_CharDB.setProtectionExceptions = GudaBags_CharDB.setProtectionExceptions or {}
    if GudaBags_CharDB.setProtectionExceptions[itemID] then
        GudaBags_CharDB.setProtectionExceptions[itemID] = nil
        return false
    else
        GudaBags_CharDB.setProtectionExceptions[itemID] = true
        return true
    end
end

function Database:PruneSetProtectionExceptions(isInSetFunc)
    if not GudaBags_CharDB or not GudaBags_CharDB.setProtectionExceptions then return end
    for itemID in pairs(GudaBags_CharDB.setProtectionExceptions) do
        if not isInSetFunc(itemID) then
            GudaBags_CharDB.setProtectionExceptions[itemID] = nil
        end
    end
end

function Database:GetCurrentCharacter()
    local fullName = GetPlayerFullName()
    if not fullName then return nil end

    -- Auto-initialize character data if missing
    if not GudaBags_DB.characters[fullName] then
        InitializeCharacterData()
    end

    return GudaBags_DB.characters[fullName]
end

function Database:GetPlayerFullName()
    return GetPlayerFullName()
end

function Database:SaveBags(bagData)
    local charData = self:GetCurrentCharacter()
    if not charData then return end
    charData.bags = bagData
    charData.lastUpdate = time()
end

function Database:GetBags(fullName)
    fullName = fullName or GetPlayerFullName()
    local charData = GudaBags_DB.characters[fullName]
    if charData then
        return charData.bags
    end
    return nil
end

-- Normalize cached container data (SavedVariables stores numeric keys as strings)
-- Shared helper for bags and bank normalization
local function NormalizeContainerData(rawData)
    if not rawData then return nil end

    local normalized = {}
    for bagKey, bagData in pairs(rawData) do
        -- Skip non-table entries (like lastUpdate timestamps or boolean flags)
        if type(bagData) == "table" then
            local normalizedBagID = tonumber(bagKey) or bagKey
            local normalizedBag = {
                bagID = bagData.bagID,
                numSlots = bagData.numSlots,
                freeSlots = bagData.freeSlots,
                bagType = bagData.bagType,
                containerItemID = bagData.containerItemID,
                containerTexture = bagData.containerTexture,
                slots = {},
            }
            if bagData.slots then
                for slotKey, slotData in pairs(bagData.slots) do
                    normalizedBag.slots[tonumber(slotKey) or slotKey] = slotData
                end
            end
            normalized[normalizedBagID] = normalizedBag
        end
    end

    return normalized
end

function Database:GetNormalizedBags(fullName)
    return NormalizeContainerData(self:GetBags(fullName))
end

function Database:SaveBank(bankData)
    local charData = self:GetCurrentCharacter()
    if not charData then return end
    charData.bank = bankData
    charData.lastUpdate = time()
end

function Database:GetBank(fullName)
    fullName = fullName or GetPlayerFullName()
    local charData = GudaBags_DB.characters[fullName]
    if charData then
        return charData.bank
    end
    return nil
end

function Database:GetNormalizedBank(fullName)
    local bankData = self:GetBank(fullName)
    if not bankData then return nil end

    -- Check if this is the new Retail structure with tabs
    if bankData.isRetail and bankData.containers then
        return NormalizeContainerData(bankData.containers)
    end

    -- Legacy/Classic structure - just container data
    return NormalizeContainerData(bankData)
end

-- Get bank tabs for Retail (for offline viewing)
function Database:GetBankTabs(fullName)
    local bankData = self:GetBank(fullName)
    if bankData and bankData.tabs then
        return bankData.tabs
    end
    return nil
end

-- Check if bank data is from Retail (has tabs)
function Database:IsRetailBank(fullName)
    local bankData = self:GetBank(fullName)
    return bankData and bankData.isRetail == true
end

-------------------------------------------------
-- Warband Bank (Account-wide storage for Retail)
-------------------------------------------------

function Database:SaveWarbandBank(warbandData)
    if not GudaBags_DB then return end
    GudaBags_DB.warbandBank = warbandData
    GudaBags_DB.warbandBank.lastUpdate = time()
end

function Database:GetWarbandBank()
    if not GudaBags_DB then return nil end
    return GudaBags_DB.warbandBank
end

function Database:GetNormalizedWarbandBank()
    local warbandData = self:GetWarbandBank()
    if not warbandData then return nil end

    if warbandData.containers then
        return NormalizeContainerData(warbandData.containers)
    end
    return nil
end

function Database:GetWarbandBankTabs()
    local warbandData = self:GetWarbandBank()
    if warbandData and warbandData.tabs then
        return warbandData.tabs
    end
    return nil
end

-------------------------------------------------
-- Mailbox
-------------------------------------------------

function Database:SaveMailbox(mailData)
    local charData = self:GetCurrentCharacter()
    if not charData then return end
    charData.mailbox = mailData
    charData.lastUpdate = time()
end

function Database:GetMailbox(fullName)
    fullName = fullName or GetPlayerFullName()
    local charData = GudaBags_DB.characters[fullName]
    if charData then
        return charData.mailbox or {}
    end
    return {}
end

-------------------------------------------------
-- Equipment
-------------------------------------------------

function Database:ScanAndSaveEquipment()
    local charData = self:GetCurrentCharacter()
    if not charData then return end

    local equipped = {}
    for slot = 1, 19 do
        local itemID = GetInventoryItemID("player", slot)
        if itemID then
            equipped[slot] = itemID
        end
    end
    charData.equipped = equipped
end

function Database:GetEquipment(fullName)
    fullName = fullName or GetPlayerFullName()
    local charData = GudaBags_DB.characters[fullName]
    if charData then
        return charData.equipped or {}
    end
    return {}
end

-------------------------------------------------
-- Guild Bank (TBC and later)
-------------------------------------------------

function Database:SaveGuildBank(guildName, guildBankData)
    if not GudaBags_DB then return end
    if not guildName then return end

    if not GudaBags_DB.guildBanks then
        GudaBags_DB.guildBanks = {}
    end

    GudaBags_DB.guildBanks[guildName] = guildBankData
    GudaBags_DB.guildBanks[guildName].lastUpdate = time()
end

function Database:GetGuildBank(guildName)
    if not GudaBags_DB or not GudaBags_DB.guildBanks then return nil end
    if not guildName then return nil end

    return GudaBags_DB.guildBanks[guildName]
end

function Database:GetNormalizedGuildBank(guildName)
    local guildBankData = self:GetGuildBank(guildName)
    if not guildBankData then return nil end

    if not guildBankData.tabs then return nil end

    -- Normalize tab data (numeric keys may be stored as strings in SavedVariables)
    local normalized = {}
    for tabKey, tabData in pairs(guildBankData.tabs) do
        if type(tabData) == "table" then
            local normalizedTabIndex = tonumber(tabKey) or tabKey
            local normalizedTab = {
                tabIndex = tabData.tabIndex,
                name = tabData.name,
                icon = tabData.icon,
                numSlots = tabData.numSlots,
                freeSlots = tabData.freeSlots,
                slots = {},
            }
            if tabData.slots then
                for slotKey, slotData in pairs(tabData.slots) do
                    normalizedTab.slots[tonumber(slotKey) or slotKey] = slotData
                end
            end
            normalized[normalizedTabIndex] = normalizedTab
        end
    end

    return normalized
end

function Database:GetGuildBankTabInfo(guildName)
    local guildBankData = self:GetGuildBank(guildName)
    if guildBankData and guildBankData.tabInfo then
        return guildBankData.tabInfo
    end
    return nil
end

function Database:GetAllGuildBanks()
    if not GudaBags_DB or not GudaBags_DB.guildBanks then
        return {}
    end
    return GudaBags_DB.guildBanks
end

function Database:SaveMoney(copper)
    local charData = self:GetCurrentCharacter()
    if not charData then return end
    charData.money = copper
end

function Database:GetMoney(fullName)
    fullName = fullName or GetPlayerFullName()
    local charData = GudaBags_DB.characters[fullName]
    if charData then
        return charData.money or 0
    end
    return 0
end

function Database:GetAllCharacters(sameFactionOnly, sameRealmOnly)
    local characters = {}
    local currentFaction = UnitFactionGroup("player")
    local currentRealm = GetRealmName()

    for fullName, data in pairs(GudaBags_DB.characters) do
        local factionMatch = not sameFactionOnly or data.faction == currentFaction
        local realmMatch = not sameRealmOnly or data.realm == currentRealm
        if factionMatch and realmMatch then
            table.insert(characters, {
                fullName = fullName,
                name = data.name,
                realm = data.realm,
                class = data.class,
                race = data.race,
                sex = data.sex,
                faction = data.faction,
                level = data.level,
                money = data.money or 0,
                lastUpdate = data.lastUpdate,
            })
        end
    end

    table.sort(characters, function(a, b)
        return a.name < b.name
    end)

    return characters
end

function Database:GetTotalMoney(sameFactionOnly, sameRealmOnly)
    local total = 0
    local characters = self:GetAllCharacters(sameFactionOnly, sameRealmOnly)
    for _, char in ipairs(characters) do
        total = total + (char.money or 0)
    end
    return total
end

-- Count items in a container collection (bags or bank)
local function CountItemsInContainers(containers, itemID)
    local count = 0
    if containers then
        for bagKey, bagData in pairs(containers) do
            -- Skip non-table entries (like lastUpdate timestamps or boolean flags)
            if type(bagData) == "table" and bagData.slots then
                for slotKey, slotData in pairs(bagData.slots) do
                    if slotData.itemID == itemID then
                        count = count + (slotData.count or 1)
                    end
                end
            end
        end
    end
    return count
end

-- Count items by itemID across all characters (bags + bank + warband bank)
-- Returns: totalCount, characterCounts (table of {name, class, count, bagCount, bankCount, ...}), warbandCount
function Database:CountItemAcrossCharacters(itemID)
    if not itemID then return 0, {}, 0 end

    local currentFullName = GetPlayerFullName()
    local characterCounts = {}
    local totalCount = 0

    for fullName, charData in pairs(GudaBags_DB.characters) do
        local bagCount = CountItemsInContainers(charData.bags, itemID)

        -- On Retail, bank data is wrapped: {containers = {...}, tabs = {...}, isRetail = true}
        local bankContainers = charData.bank
        if bankContainers and bankContainers.isRetail then
            bankContainers = bankContainers.containers
        end
        local bankCount = CountItemsInContainers(bankContainers, itemID)

        local mailCount = 0
        if charData.mailbox then
            for _, row in ipairs(charData.mailbox) do
                if row.itemID == itemID then
                    mailCount = mailCount + (row.count or 1)
                end
            end
        end

        -- Count equipped items (live scan for current char, cached for others)
        local equippedCount = 0
        if fullName == currentFullName then
            for slot = 1, 19 do
                if GetInventoryItemID("player", slot) == itemID then
                    equippedCount = equippedCount + 1
                end
            end
        elseif charData.equipped then
            for _, equippedItemID in pairs(charData.equipped) do
                if equippedItemID == itemID then
                    equippedCount = equippedCount + 1
                end
            end
        end

        local charCount = bagCount + bankCount + mailCount + equippedCount

        if charCount > 0 then
            table.insert(characterCounts, {
                fullName = fullName,
                name = charData.name,
                class = charData.class,
                race = charData.race,
                sex = charData.sex,
                count = charCount,
                bagCount = bagCount,
                bankCount = bankCount,
                mailCount = mailCount,
                equippedCount = equippedCount,
                isCurrent = (fullName == currentFullName),
            })
            totalCount = totalCount + charCount
        end
    end

    -- Count warband bank (account-wide, not per-character)
    local warbandCount = 0
    local warbandBank = GudaBags_DB.warbandBank
    if warbandBank then
        local warbandContainers = warbandBank.containers or warbandBank
        warbandCount = CountItemsInContainers(warbandContainers, itemID)
        totalCount = totalCount + warbandCount
    end

    table.sort(characterCounts, function(a, b)
        if a.isCurrent ~= b.isCurrent then
            return a.isCurrent
        end
        return a.name < b.name
    end)

    return totalCount, characterCounts, warbandCount
end

-------------------------------------------------
-- Tracked Items
-------------------------------------------------

function Database:GetTrackedItems()
    local charData = self:GetCurrentCharacter()
    if charData then
        return charData.trackedItems or {}
    end
    return {}
end

function Database:SetTrackedItems(items)
    local charData = self:GetCurrentCharacter()
    if charData then
        charData.trackedItems = items
    end
end

-------------------------------------------------
-- Categories
-------------------------------------------------

function Database:GetCategories()
    return GudaBags_CharDB.categories
end

function Database:SetCategories(categories)
    GudaBags_CharDB.categories = categories
end

-------------------------------------------------
-- Database API Methods
-------------------------------------------------

-- Check if the database is fully initialized
function Database:IsInitialized()
    return GudaBags_DB ~= nil and GudaBags_CharDB ~= nil
end

-- Get all character data (for slash commands)
function Database:GetAllCharacterData()
    if not GudaBags_DB or not GudaBags_DB.characters then
        return {}
    end
    return GudaBags_DB.characters
end

-- Get a global setting (from GudaBags_DB.settings)
function Database:GetGlobalSetting(key)
    if not GudaBags_DB or not GudaBags_DB.settings then
        return nil
    end
    return GudaBags_DB.settings[key]
end

-- Set a global setting
function Database:SetGlobalSetting(key, value)
    if not GudaBags_DB then return end
    if not GudaBags_DB.settings then
        GudaBags_DB.settings = {}
    end
    GudaBags_DB.settings[key] = value
end

-------------------------------------------------
-- Favorites
-------------------------------------------------

function Database:ToggleFavorite(itemID)
    if not itemID or not GudaBags_CharDB then return false end
    if not GudaBags_CharDB.favoriteItems then
        GudaBags_CharDB.favoriteItems = {}
    end
    if GudaBags_CharDB.favoriteItems[itemID] then
        GudaBags_CharDB.favoriteItems[itemID] = nil
    else
        GudaBags_CharDB.favoriteItems[itemID] = true
    end
    return GudaBags_CharDB.favoriteItems[itemID] or false
end

function Database:IsFavorite(itemID)
    if not itemID or not GudaBags_CharDB or not GudaBags_CharDB.favoriteItems then return false end
    return GudaBags_CharDB.favoriteItems[itemID] or false
end

function Database:GetFavorites()
    if not GudaBags_CharDB or not GudaBags_CharDB.favoriteItems then return {} end
    return GudaBags_CharDB.favoriteItems
end

-------------------------------------------------
-- Profiles
-------------------------------------------------

local function InitializeProfiles()
    if not GudaBags_DB then return end
    if not GudaBags_DB.profiles then
        GudaBags_DB.profiles = {}
    end
end

function Database:GetProfileList()
    InitializeProfiles()
    local list = {}
    for name in pairs(GudaBags_DB.profiles) do
        table.insert(list, name)
    end
    table.sort(list)
    return list
end

function Database:GetProfile(name)
    InitializeProfiles()
    return GudaBags_DB.profiles[name]
end

function Database:SaveProfile(name, includeCategories)
    InitializeProfiles()
    if not name or name == "" then return false end

    local profile = {
        settings = {},
        savedAt = time(),
        savedBy = GetPlayerFullName(),
    }

    -- Deep copy current settings
    for key, value in pairs(GudaBags_CharDB.settings) do
        if type(value) == "table" then
            profile.settings[key] = CopyTable(value)
        else
            profile.settings[key] = value
        end
    end

    -- Optionally include categories
    if includeCategories and GudaBags_CharDB.categories then
        profile.categories = CopyTable(GudaBags_CharDB.categories)
    end

    GudaBags_DB.profiles[name] = profile
    return true
end

function Database:LoadProfile(name, includePositions)
    InitializeProfiles()
    local profile = GudaBags_DB.profiles[name]
    if not profile then return false end

    -- Copy settings from profile to current character
    if profile.settings then
        for key, value in pairs(profile.settings) do
            -- Skip per-character position settings unless explicitly requested
            local isPosition = key:match("^frame") or key:match("^bankFrame") or
                              key:match("^guildBankFrame") or key:match("^mailFrame")
            if includePositions or not isPosition then
                if type(value) == "table" then
                    GudaBags_CharDB.settings[key] = CopyTable(value)
                else
                    GudaBags_CharDB.settings[key] = value
                end
            end
        end
    end

    -- Load categories if present
    if profile.categories then
        GudaBags_CharDB.categories = CopyTable(profile.categories)
    end

    return true
end

function Database:DeleteProfile(name)
    InitializeProfiles()
    if not name or not GudaBags_DB.profiles[name] then return false end
    GudaBags_DB.profiles[name] = nil
    return true
end

-------------------------------------------------
-- Frame Position (shared by all frame types)
-------------------------------------------------

function Database:SaveFramePosition(frame, prefix)
    if not frame then return end
    local point, _, relativePoint, x, y = frame:GetPoint()
    self:SetSetting(prefix .. "Point", point)
    self:SetSetting(prefix .. "RelativePoint", relativePoint)
    self:SetSetting(prefix .. "X", x)
    self:SetSetting(prefix .. "Y", y)
end

function Database:RestoreFramePosition(frame, prefix, defaultPoint, defaultRelativePoint, defaultX, defaultY)
    if not frame then return end
    local point = self:GetSetting(prefix .. "Point")
    local relativePoint = self:GetSetting(prefix .. "RelativePoint")
    local x = self:GetSetting(prefix .. "X")
    local y = self:GetSetting(prefix .. "Y")

    if point and x and y then
        frame:ClearAllPoints()
        frame:SetPoint(point, UIParent, relativePoint, x, y)
    elseif defaultPoint then
        frame:ClearAllPoints()
        frame:SetPoint(defaultPoint, UIParent, defaultRelativePoint, defaultX, defaultY)
    end
end

-------------------------------------------------
-- Profile Import/Export
-------------------------------------------------

-- Simple serialization: converts a Lua table to a compact string
local function SerializeValue(val)
    local t = type(val)
    if t == "string" then
        return "s" .. val:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("|", "\\|")
    elseif t == "number" then
        return "n" .. tostring(val)
    elseif t == "boolean" then
        return val and "b1" or "b0"
    elseif t == "table" then
        local parts = {}
        -- Check if array
        local isArray = true
        local maxN = 0
        for k in pairs(val) do
            if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
                isArray = false
                break
            end
            if k > maxN then maxN = k end
        end
        if isArray and maxN == #val then
            -- Serialize as array
            for i = 1, #val do
                parts[i] = SerializeValue(val[i])
            end
            return "a{" .. table.concat(parts, "|") .. "}"
        else
            -- Serialize as dictionary
            for k, v in pairs(val) do
                table.insert(parts, SerializeValue(k) .. "=" .. SerializeValue(v))
            end
            return "t{" .. table.concat(parts, "|") .. "}"
        end
    end
    return "x"  -- nil/unknown
end

local function DeserializeValue(str, pos)
    if not str or pos > #str then return nil, pos end
    local tag = str:sub(pos, pos)

    if tag == "s" then
        -- String: find next unescaped | or = or } or end
        local result = {}
        local i = pos + 1
        while i <= #str do
            local c = str:sub(i, i)
            if c == "\\" then
                local next = str:sub(i + 1, i + 1)
                if next == "\\" then
                    table.insert(result, "\\")
                elseif next == "n" then
                    table.insert(result, "\n")
                elseif next == "|" then
                    table.insert(result, "|")
                else
                    table.insert(result, next)
                end
                i = i + 2
            elseif c == "|" or c == "=" or c == "}" then
                break
            else
                table.insert(result, c)
                i = i + 1
            end
        end
        return table.concat(result), i
    elseif tag == "n" then
        local i = pos + 1
        local numStr = {}
        while i <= #str do
            local c = str:sub(i, i)
            if c == "|" or c == "=" or c == "}" then break end
            table.insert(numStr, c)
            i = i + 1
        end
        return tonumber(table.concat(numStr)), i
    elseif tag == "b" then
        local val = str:sub(pos + 1, pos + 1) == "1"
        return val, pos + 2
    elseif tag == "a" or tag == "t" then
        -- Array or table
        local isArray = (tag == "a")
        if str:sub(pos + 1, pos + 1) ~= "{" then return nil, pos + 1 end
        local i = pos + 2
        local result = {}
        local idx = 1
        while i <= #str and str:sub(i, i) ~= "}" do
            if str:sub(i, i) == "|" then i = i + 1 end
            if i > #str or str:sub(i, i) == "}" then break end
            if isArray then
                local val
                val, i = DeserializeValue(str, i)
                result[idx] = val
                idx = idx + 1
            else
                local key
                key, i = DeserializeValue(str, i)
                if i <= #str and str:sub(i, i) == "=" then
                    i = i + 1
                    local val
                    val, i = DeserializeValue(str, i)
                    result[key] = val
                end
            end
        end
        if i <= #str and str:sub(i, i) == "}" then i = i + 1 end
        return result, i
    end
    return nil, pos + 1
end

function Database:ExportProfile(name)
    InitializeProfiles()
    local profile = GudaBags_DB.profiles[name]
    if not profile then return nil end

    local exportData = {
        v = 1,  -- Version for future compatibility
        name = name,
        settings = profile.settings,
    }
    if profile.categories then
        exportData.categories = profile.categories
    end

    return "GUDA1:" .. SerializeValue(exportData)
end

function Database:ImportProfile(encodedString)
    if not encodedString or encodedString == "" then return false, "empty" end

    -- Validate prefix
    if not encodedString:match("^GUDA1:") then
        return false, "invalid_format"
    end

    local dataStr = encodedString:sub(7)  -- Remove "GUDA1:" prefix
    local data = DeserializeValue(dataStr, 1)
    if not data or type(data) ~= "table" or not data.settings then
        return false, "corrupt"
    end

    local profileName = data.name or "Imported"
    InitializeProfiles()

    local profile = {
        settings = data.settings,
        savedAt = time(),
        savedBy = "imported",
    }
    if data.categories then
        profile.categories = data.categories
    end

    GudaBags_DB.profiles[profileName] = profile
    return true, profileName
end

Events:OnAddonLoaded(function()
    Database:Initialize()
end, Database)

-- Initialize character data on PLAYER_LOGIN when player name is reliable
Events:OnPlayerLogin(function()
    Database:InitializeCharacter()
    Database:ScanAndSaveEquipment()
end, Database)

-- Update cached equipment when gear changes
Events:Register("PLAYER_EQUIPMENT_CHANGED", function()
    Database:ScanAndSaveEquipment()
end, Database)
