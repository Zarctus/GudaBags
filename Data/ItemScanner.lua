local addonName, ns = ...

local ItemScanner = {}
ns:RegisterModule("ItemScanner", ItemScanner)

local Constants = ns.Constants
local GetItemInfo = ns:GetModule("Compatibility.API").GetItemInfo

-- Get inventory slot for bank bag (same logic as BankFooter for API consistency)
local function GetBankBagInvSlot(bankBagIndex)
    if ContainerIDToInventoryID then
        return ContainerIDToInventoryID(bankBagIndex + 4)
    elseif C_Container and C_Container.ContainerIDToInventoryID then
        return C_Container.ContainerIDToInventoryID(bankBagIndex + 4)
    else
        return BankButtonIDToInvSlotID(bankBagIndex)
    end
end

local scanningTooltip = CreateFrame("GameTooltip", "GudaBagsScanningTooltip", nil, "GameTooltipTemplate")
scanningTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")

local durabilityPattern
if DURABILITY_TEMPLATE then
    durabilityPattern = string.gsub(DURABILITY_TEMPLATE, "%%[^%s]+", "(.+)")
end

-- Local references for hot-path functions
local strfind = string.find
local strlower = string.lower
local mathabs = math.abs

-- Tooltip result caching to avoid repeated expensive scans
-- Cache by itemLink since the same item has the same properties
local tooltipCache = {}
local CACHE_MAX_SIZE = 500  -- Limit cache size to prevent memory bloat

local function GetCacheKey(itemLink, itemID)
    -- Use itemLink if available (more specific), otherwise itemID
    return itemLink or (itemID and tostring(itemID)) or nil
end

local function GetCachedTooltipResult(cacheKey)
    if cacheKey and tooltipCache[cacheKey] then
        return tooltipCache[cacheKey]
    end
    return nil
end

local function SetCachedTooltipResult(cacheKey, result)
    if not cacheKey then return end
    -- Just cache the result - no size limit needed for typical bag sizes
    -- A full bag scan is ~200 items max, well under memory concerns
    tooltipCache[cacheKey] = result
end

-- Clear tooltip cache (call when player stats change that could affect usability)
function ItemScanner:ClearTooltipCache()
    tooltipCache = {}
end

function ItemScanner:GetTooltipCacheSize()
    local count = 0
    for _ in pairs(tooltipCache) do count = count + 1 end
    return count
end

local function IsRedColor(r, g, b)
    if not r or not g or not b then return false end
    if RED_FONT_COLOR then
        local dr = mathabs(r - RED_FONT_COLOR.r)
        local dg = mathabs(g - RED_FONT_COLOR.g)
        local db = mathabs(b - RED_FONT_COLOR.b)
        if dr < 0.1 and dg < 0.1 and db < 0.1 then
            return true
        end
    end
    local threshold = Constants.COLOR_THRESHOLDS.RED
    return r > threshold.min_r and g < threshold.max_g and b < threshold.max_b
end

-- Check for green color (special effects text)
local function IsGreenColor(r, g, b)
    if not r or not g or not b then return false end
    local threshold = Constants.COLOR_THRESHOLDS.GREEN
    return g > threshold.min_g and r < threshold.max_r and b < threshold.max_b
end

-- Check for yellow/gold color (flavor text, special properties)
local function IsYellowColor(r, g, b)
    if not r or not g or not b then return false end
    local threshold = Constants.COLOR_THRESHOLDS.YELLOW
    return r > threshold.min_r and g > threshold.min_g and b < threshold.max_b
end

-- Scan tooltip once and extract all needed information
-- itemQuality: pass quality to skip hasSpecialProperties check for non-junk items
local function ScanTooltipForItem(bagID, slot, itemType, itemID, itemLink, itemQuality)
    local cacheKey = GetCacheKey(itemLink, itemID)
    local cached = GetCachedTooltipResult(cacheKey)
    if cached then
        return cached.isUsable, cached.isQuestItem, cached.isQuestStarter, cached.hasSpecialProperties, cached.hasDuration
    end

    local isUsable = true
    local isQuestItem = false
    local isQuestStarter = false
    local hasSpecialProperties = false
    local hasDuration = false

    -- Only check special properties for gray (0) or white (1) quality items
    -- These are the only ones where junk detection matters
    local needSpecialPropertiesCheck = itemQuality and (itemQuality == 0 or itemQuality == 1)


    -- Check if item is in the quest indicator ignore list
    local isQuestIgnored = itemID and Constants.QUEST_INDICATOR_IGNORE and Constants.QUEST_INDICATOR_IGNORE[itemID]

    -- Check if item is a custom quest item (force show in quest bar)
    local isCustomQuestItem = itemID and Constants.CUSTOM_QUEST_ITEMS and Constants.CUSTOM_QUEST_ITEMS[itemID]
    if isCustomQuestItem then
        isQuestItem = true
    end

    -- Mark items with itemType "Quest" as quest items (respect ignore list)
    -- Only flag poor/common quality items — green+ quality "Quest" type items
    -- are typically glyphs, enchants, or other non-quest items misclassified by WoW
    if not isQuestIgnored and itemType == "Quest" and (not itemQuality or itemQuality < 2) then
        isQuestItem = true
    end

    -- Single tooltip scan for all checks
    scanningTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanningTooltip:ClearLines()
    scanningTooltip:SetBagItem(bagID, slot)

    local numLines = scanningTooltip:NumLines()
    if numLines and numLines > 0 then
        for i = 1, numLines do
            local leftText = _G["GudaBagsScanningTooltipTextLeft" .. i]
            if leftText and leftText:IsShown() then
                local text = leftText:GetText()
                local r, g, b = leftText:GetTextColor()

                if text then
                    -- Check for red text (unusable) - skip durability lines
                    if IsRedColor(r, g, b) then
                        if not durabilityPattern or not strfind(text, durabilityPattern) then
                            isUsable = false
                        end
                    end

                    -- Check for quest item indicators (respect ignore list)
                    if not isQuestIgnored then
                        if text == ITEM_BIND_QUEST or strfind(text, "Quest Item", 1, true) then
                            isQuestItem = true
                        end
                        if text == ITEM_STARTS_QUEST or strfind(text, "This Item Begins a Quest", 1, true) then
                            isQuestStarter = true
                            isQuestItem = true
                        end
                    end

                    -- Check for item duration (e.g. "Duration: 1 hour")
                    if not hasDuration and strfind(text, "^Duration:") then
                        hasDuration = true
                    end

                    -- Check for special properties only for gray/white items (junk detection)
                    if needSpecialPropertiesCheck and not hasSpecialProperties then
                        local textLower = strlower(text)
                        -- Use: or Equip: effects
                        if strfind(textLower, "use:", 1, true) or strfind(textLower, "equip:", 1, true) then
                            hasSpecialProperties = true
                        -- Unique items
                        elseif strfind(textLower, "^unique") or strfind(textLower, "unique%-equipped") then
                            hasSpecialProperties = true
                        -- Green text (special effects)
                        elseif IsGreenColor(r, g, b) then
                            hasSpecialProperties = true
                        -- Yellow/gold text (flavor text) - skip first line (item name)
                        -- Also skip common non-special yellow text like "Crafting Reagent"
                        elseif i > 1 and IsYellowColor(r, g, b) then
                            -- Exclude common crafting/trade labels that aren't special
                            if not strfind(textLower, "crafting reagent", 1, true) and not strfind(textLower, "sell price", 1, true) then
                                hasSpecialProperties = true
                            end
                        end
                    end
                end
            end

            -- Also check right text for red color (unusable stats)
            local rightText = _G["GudaBagsScanningTooltipTextRight" .. i]
            if rightText and rightText:IsShown() then
                local text = rightText:GetText()
                local r, g, b = rightText:GetTextColor()
                if text and IsRedColor(r, g, b) then
                    if not durabilityPattern or not strfind(text, durabilityPattern) then
                        isUsable = false
                    end
                end
            end
        end
    end

    -- Cache the result
    SetCachedTooltipResult(cacheKey, {
        isUsable = isUsable,
        isQuestItem = isQuestItem,
        isQuestStarter = isQuestStarter,
        hasSpecialProperties = hasSpecialProperties,
        hasDuration = hasDuration,
    })

    return isUsable, isQuestItem, isQuestStarter, hasSpecialProperties, hasDuration
end

-- Get crafting quality tier (1-5) for Retail profession items, or nil
local function GetCraftingQuality(itemLink)
    if not itemLink or not ns.IsRetail then return nil end
    if C_TradeSkillUI then
        if C_TradeSkillUI.GetItemReagentQualityByItemInfo then
            local quality = C_TradeSkillUI.GetItemReagentQualityByItemInfo(itemLink)
            if quality then return quality end
        end
        if C_TradeSkillUI.GetItemCraftedQualityByItemInfo then
            local quality = C_TradeSkillUI.GetItemCraftedQualityByItemInfo(itemLink)
            if quality then return quality end
        end
    end
    return nil
end

-- Fast scan using cached tooltip data
-- Used when item moved slots - properties don't change, skip tooltip scan
function ItemScanner:ScanSlotFast(bagID, slot)
    local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)

    if not itemInfo then
        return nil
    end

    local itemLink = itemInfo.hyperlink
    local cacheKey = GetCacheKey(itemLink, itemInfo.itemID)
    local cached = GetCachedTooltipResult(cacheKey)

    -- If we have cached tooltip data, use it (item moved, properties unchanged)
    if cached then
        local itemName, _, itemQuality, itemLevel, itemMinLevel, itemType, itemSubType, maxStack, equipSlot, _, _, classID, subClassID, bindType, expacID = GetItemInfo(itemLink)

        return {
            slot = slot,
            bagID = bagID,
            itemID = itemInfo.itemID,
            link = itemLink,
            name = itemName or "",
            texture = itemInfo.iconFileID,
            count = itemInfo.stackCount or 1,
            quality = itemQuality or itemInfo.quality or 0,
            locked = itemInfo.isLocked or false,
            itemLevel = itemLevel or 0,
            itemMinLevel = itemMinLevel or 0,
            itemType = itemType or "",
            itemSubType = itemSubType or "",
            equipSlot = equipSlot or "",
            maxStack = maxStack or 1,
            classID = classID or 15,
            subClassID = subClassID or 0,
            expacID = expacID,
            isUsable = cached.isUsable,
            isQuestItem = cached.isQuestItem,
            isQuestStarter = cached.isQuestStarter,
            hasSpecialProperties = cached.hasSpecialProperties,
            hasDuration = cached.hasDuration,
            craftingQuality = GetCraftingQuality(itemLink),
        }
    end

    -- No cache hit - need full scan (new item)
    return nil
end

function ItemScanner:ScanSlot(bagID, slot)
    local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)

    if not itemInfo then
        return nil
    end

    local itemLink = itemInfo.hyperlink
    if not itemLink then
        return nil
    end

    local itemName, _, itemQuality, itemLevel, itemMinLevel, itemType, itemSubType, maxStack, equipSlot, itemTexture, sellPrice, classID, subClassID, bindType, expacID = GetItemInfo(itemLink)
    -- GetItemInfo can return nil if item data isn't cached yet
    if not itemName then
        -- Fallback to basic info from container API
        itemName = ""
        itemLevel = 0
        itemMinLevel = 0
        itemType = ""
        itemSubType = ""
        maxStack = 1
        equipSlot = ""
        classID = 15  -- Default to Miscellaneous
        subClassID = 0
        expacID = nil
    end

    -- Get quality from multiple sources (API differs between expansions)
    -- C_Container.GetContainerItemInfo may return quality as 'quality' or 'itemQuality'
    local quality = itemQuality or itemInfo.quality or itemInfo.itemQuality or 0

    -- Single optimized tooltip scan for all properties
    -- Pass quality so we only check hasSpecialProperties for gray/white items
    local isUsable, isQuestItem, isQuestStarter, hasSpecialProperties, hasDuration = ScanTooltipForItem(bagID, slot, itemType, itemInfo.itemID, itemLink, quality)

    return {
        slot = slot,
        bagID = bagID,
        itemID = itemInfo.itemID,
        link = itemLink,
        name = itemName or "",
        texture = itemInfo.iconFileID,
        count = itemInfo.stackCount or 1,
        quality = itemQuality or itemInfo.quality or 0,
        locked = itemInfo.isLocked or false,
        itemLevel = itemLevel or 0,
        itemMinLevel = itemMinLevel or 0,
        itemType = itemType or "",
        itemSubType = itemSubType or "",
        equipSlot = equipSlot or "",
        maxStack = maxStack or 1,
        classID = classID or 15,  -- Default to Miscellaneous
        subClassID = subClassID or 0,
        expacID = expacID,
        isUsable = isUsable,
        isQuestItem = isQuestItem,
        isQuestStarter = isQuestStarter,
        hasSpecialProperties = hasSpecialProperties,
        hasDuration = hasDuration,
        craftingQuality = GetCraftingQuality(itemLink),
    }
end

function ItemScanner:GetBagType(bagID)
    if bagID == 0 or bagID == -1 then
        return "regular"
    end

    local numFreeSlots, bagFamily = C_Container.GetContainerNumFreeSlots(bagID)
    if bagFamily and bagFamily > 0 then
        if bit.band(bagFamily, 1) ~= 0 then return "quiver" end
        if bit.band(bagFamily, 2) ~= 0 then return "ammo" end
        if bit.band(bagFamily, 4) ~= 0 then return "soul" end
        if bit.band(bagFamily, 8) ~= 0 then return "leatherworking" end
        if bit.band(bagFamily, 16) ~= 0 then return "inscription" end
        if bit.band(bagFamily, 32) ~= 0 then return "herb" end
        if bit.band(bagFamily, 64) ~= 0 then return "enchant" end
        if bit.band(bagFamily, 128) ~= 0 then return "engineering" end
        if bit.band(bagFamily, 512) ~= 0 then return "gem" end
        if bit.band(bagFamily, 1024) ~= 0 then return "mining" end
    end

    return "regular"
end

function ItemScanner:ScanContainer(bagID)
    local numSlots = C_Container.GetContainerNumSlots(bagID)
    if not numSlots or numSlots == 0 then
        return nil
    end

    local containerItemID = nil
    local containerTexture = nil
    if bagID > 0 and bagID <= 4 then
        local invSlot = C_Container.ContainerIDToInventoryID(bagID)
        if invSlot then
            containerItemID = GetInventoryItemID("player", invSlot)
            containerTexture = GetInventoryItemTexture("player", invSlot)
        end
    elseif bagID >= 5 and bagID <= 11 then
        local bankBagIndex = bagID - 4
        local invSlot = GetBankBagInvSlot(bankBagIndex)
        if invSlot then
            containerItemID = GetInventoryItemID("player", invSlot)
            containerTexture = GetInventoryItemTexture("player", invSlot)
        end
    end

    local bagData = {
        bagID = bagID,
        numSlots = numSlots,
        freeSlots = 0,
        bagType = self:GetBagType(bagID),
        containerItemID = containerItemID,
        containerTexture = containerTexture,
        slots = {},
    }

    for slot = 1, numSlots do
        local itemData = self:ScanSlot(bagID, slot)
        if itemData then
            bagData.slots[slot] = itemData
        else
            bagData.freeSlots = bagData.freeSlots + 1
        end
    end

    return bagData
end

function ItemScanner:GetScanningTooltip()
    return scanningTooltip
end

-- Clear tooltip cache when player stats change (affects usability)
local Events = ns:GetModule("Events")
if Events then
    -- Level up changes what items are usable
    Events:Register("PLAYER_LEVEL_UP", function()
        ItemScanner:ClearTooltipCache()
    end, ItemScanner)

    -- Equipment changes can affect stats and thus usability
    Events:Register("PLAYER_EQUIPMENT_CHANGED", function()
        ItemScanner:ClearTooltipCache()
    end, ItemScanner)
end
