-- GudaBags Sort Engine
-- Multi-phase sorting algorithm for Classic expansions

local addonName, ns = ...

local SortEngine = {}
ns:RegisterModule("SortEngine", SortEngine)

local Constants = ns.Constants
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")
local Expansion = ns:GetModule("Expansion")

-- Cached globals
local InCombatLockdown = InCombatLockdown
local ClearCursor = ClearCursor
local C_Container_GetContainerItemInfo = C_Container.GetContainerItemInfo
local C_Container_GetContainerNumSlots = C_Container.GetContainerNumSlots
local C_Container_GetContainerNumFreeSlots = C_Container.GetContainerNumFreeSlots
local C_Container_PickupContainerItem = C_Container.PickupContainerItem
local C_Container_SplitContainerItem = C_Container.SplitContainerItem
local C_Item_GetItemFamily = C_Item.GetItemFamily
local GetItemInfo = GetItemInfo
local bit_band = bit.band
local table_sort = table.sort
local string_find = string.find
local string_lower = string.lower
local tostring = tostring
local tonumber = tonumber
local math_min = math.min
local ipairs = ipairs
local pairs = pairs
local wipe = wipe
local debugprofilestop = debugprofilestop
local GetTime = GetTime
local coroutine_yield = coroutine.yield
local coroutine_create = coroutine.create
local coroutine_resume = coroutine.resume
local coroutine_status = coroutine.status

-- Frame budget for coroutine-based sorting (microseconds)
local FRAME_BUDGET_US = 4000      -- 4ms for player bags
local FRAME_BUDGET_BANK_US = 6000 -- 6ms for bank (more lenient)
local frameStartTime = 0
local currentFrameBudget = FRAME_BUDGET_US

local function StartFrameTimer()
    frameStartTime = debugprofilestop()
end

local function IsFrameBudgetExceeded()
    return (debugprofilestop() - frameStartTime) > currentFrameBudget
end

-- Sorting state
local sortInProgress = false
local sortCoroutine = nil
local currentPass = 0
local maxPasses = 10  -- Increased from 6 to ensure sort completes
local soundsMuted = false

-- Performance: Caches to avoid repeated expensive operations
local specialPropertiesCache = {}  -- Cache HasSpecialProperties results by itemID
local sortKeyCache = {}            -- Cache computed sort keys by itemID

-- Performance tracking (debug)
local perfStats = {
    tooltipScans = 0,
    tooltipCacheHits = 0,
    sortKeyComputes = 0,
    sortKeyCacheHits = 0,
}

-- Use pickup sound IDs from Constants
local function MutePickupSounds()
    for _, soundID in ipairs(Constants.PICKUP_SOUND_IDS) do
        MuteSoundFile(soundID)
    end
end

local function UnmutePickupSounds()
    for _, soundID in ipairs(Constants.PICKUP_SOUND_IDS) do
        UnmuteSoundFile(soundID)
    end
end

--===========================================================================
-- SORT KEY DEFINITIONS
--===========================================================================

-- Priority items (Hearthstone always first)
local PRIORITY_ITEMS = {
    [6948] = 1, -- Hearthstone
}

-- Item class ordering (maps WoW item classID to sort order)
local CLASS_ORDER = {
    [0] = 2,   -- Consumable
    [1] = 12,  -- Container (Bags)
    [2] = 5,   -- Weapon
    [3] = 8,   -- Gem
    [4] = 6,   -- Armor
    [5] = 3,   -- Reagent
    [6] = 4,   -- Projectile
    [7] = 10,  -- Trade Goods
    [8] = 9,   -- Item Enhancement (not in TBC but for future)
    [9] = 11,  -- Recipe
    [10] = 16, -- Money (obsolete)
    [11] = 7,  -- Quiver
    [12] = 13, -- Quest
    [13] = 14, -- Key
    [14] = 17, -- Permanent (obsolete)
    [15] = 15, -- Miscellaneous
    [16] = 18, -- Glyph (not in TBC)
    [17] = 19, -- Battle Pet (not in TBC)
    [18] = 1,  -- WoW Token (not in TBC)
}

-- Weapon subclass ordering
local WEAPON_SUBCLASS_ORDER = {
    [0] = 1,   -- One-Handed Axes
    [1] = 10,  -- Two-Handed Axes
    [2] = 2,   -- Bows
    [3] = 13,  -- Guns
    [4] = 3,   -- One-Handed Maces
    [5] = 11,  -- Two-Handed Maces
    [6] = 12,  -- Polearms
    [7] = 4,   -- One-Handed Swords
    [8] = 14,  -- Two-Handed Swords
    [9] = 20,  -- Obsolete
    [10] = 15, -- Staves
    [11] = 20, -- One-Handed Exotics
    [12] = 20, -- Two-Handed Exotics
    [13] = 16, -- Fist Weapons
    [14] = 17, -- Miscellaneous (wands in classic)
    [15] = 5,  -- Daggers
    [16] = 18, -- Thrown
    [17] = 19, -- Spears
    [18] = 6,  -- Crossbows
    [19] = 7,  -- Wands
    [20] = 8,  -- Fishing Poles
}

-- Armor subclass ordering
local ARMOR_SUBCLASS_ORDER = {
    [0] = 10,  -- Miscellaneous
    [1] = 4,   -- Cloth
    [2] = 3,   -- Leather
    [3] = 2,   -- Mail
    [4] = 1,   -- Plate
    [5] = 11,  -- Cosmetic
    [6] = 5,   -- Shields
    [7] = 6,   -- Librams
    [8] = 7,   -- Idols
    [9] = 8,   -- Totems
    [10] = 9,  -- Sigils
}

-- Equipment slot ordering
local EQUIP_SLOT_ORDER = {
    ["INVTYPE_WEAPONMAINHAND"] = 1,
    ["INVTYPE_WEAPON"] = 2,
    ["INVTYPE_2HWEAPON"] = 3,
    ["INVTYPE_WEAPONOFFHAND"] = 4,
    ["INVTYPE_SHIELD"] = 5,
    ["INVTYPE_HOLDABLE"] = 6,
    ["INVTYPE_RANGED"] = 7,
    ["INVTYPE_RANGEDRIGHT"] = 8,
    ["INVTYPE_THROWN"] = 9,
    ["INVTYPE_HEAD"] = 10,
    ["INVTYPE_NECK"] = 11,
    ["INVTYPE_SHOULDER"] = 12,
    ["INVTYPE_CLOAK"] = 13,
    ["INVTYPE_CHEST"] = 14,
    ["INVTYPE_ROBE"] = 14,
    ["INVTYPE_BODY"] = 15,
    ["INVTYPE_TABARD"] = 16,
    ["INVTYPE_WRIST"] = 17,
    ["INVTYPE_HAND"] = 18,
    ["INVTYPE_WAIST"] = 19,
    ["INVTYPE_LEGS"] = 20,
    ["INVTYPE_FEET"] = 21,
    ["INVTYPE_FINGER"] = 22,
    ["INVTYPE_TRINKET"] = 23,
    ["INVTYPE_RELIC"] = 24,
    ["INVTYPE_BAG"] = 25,
    ["INVTYPE_QUIVER"] = 26,
    ["INVTYPE_AMMO"] = 27,
}

-- Trade Goods subclass ordering (TBC)
local TRADE_GOODS_SUBCLASS_ORDER = {
    [1] = 1,   -- Parts
    [2] = 2,   -- Explosives
    [3] = 3,   -- Devices
    [4] = 4,   -- Jewelcrafting
    [5] = 5,   -- Cloth
    [6] = 6,   -- Leather
    [7] = 7,   -- Metal & Stone
    [8] = 8,   -- Meat
    [9] = 9,   -- Herb
    [10] = 10, -- Elemental
    [11] = 11, -- Other
    [12] = 12, -- Enchanting
    [14] = 13, -- Inscription (not TBC)
}

-- Consumable subclass ordering
local CONSUMABLE_SUBCLASS_ORDER = {
    [0] = 1,   -- Consumable (generic)
    [1] = 2,   -- Potion
    [2] = 3,   -- Elixir
    [3] = 4,   -- Flask
    [4] = 5,   -- Scroll
    [5] = 6,   -- Food & Drink
    [6] = 7,   -- Item Enhancement
    [7] = 8,   -- Bandage
    [8] = 9,   -- Other
}

--===========================================================================
-- UTILITY FUNCTIONS
--===========================================================================

-- Tooltip for scanning item properties
local scanTooltip = CreateFrame("GameTooltip", "GudaBags_SortScanTooltip", nil, "GameTooltipTemplate")
scanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")

function SortEngine:ClearCache()
    -- Log performance stats before clearing (if any work was done)
    if perfStats.tooltipScans > 0 or perfStats.sortKeyComputes > 0 then
        local tooltipHitRate = perfStats.tooltipScans > 0 and (perfStats.tooltipCacheHits / (perfStats.tooltipScans + perfStats.tooltipCacheHits) * 100) or 0
        local sortKeyHitRate = perfStats.sortKeyComputes > 0 and (perfStats.sortKeyCacheHits / (perfStats.sortKeyComputes + perfStats.sortKeyCacheHits) * 100) or 0
        ns:Debug(string.format("Sort cache stats - Tooltip: %d scans, %d hits (%.0f%%) | SortKeys: %d computes, %d hits (%.0f%%)",
            perfStats.tooltipScans,
            perfStats.tooltipCacheHits,
            tooltipHitRate,
            perfStats.sortKeyComputes,
            perfStats.sortKeyCacheHits,
            sortKeyHitRate
        ))
    end
    -- Clear performance caches
    wipe(specialPropertiesCache)
    wipe(sortKeyCache)
    -- Reset stats
    perfStats.tooltipScans = 0
    perfStats.tooltipCacheHits = 0
    perfStats.sortKeyComputes = 0
    perfStats.sortKeyCacheHits = 0
end

-------------------------------------------------
-- Check if item has special properties (cached by itemID)
-------------------------------------------------
local function HasSpecialProperties(bagID, slot, itemID)
    if not bagID or not slot then return false end

    -- Check cache first (keyed by itemID since properties are inherent to item)
    if itemID and specialPropertiesCache[itemID] ~= nil then
        perfStats.tooltipCacheHits = perfStats.tooltipCacheHits + 1
        return specialPropertiesCache[itemID]
    end

    perfStats.tooltipScans = perfStats.tooltipScans + 1

    scanTooltip:ClearLines()
    scanTooltip:SetBagItem(bagID, slot)

    local numLines = scanTooltip:NumLines()
    if not numLines or numLines == 0 then
        if itemID then specialPropertiesCache[itemID] = false end
        return false
    end

    local hasSpecial = false
    for i = 1, numLines do
        local line = _G["GudaBags_SortScanTooltipTextLeft" .. i]
        if line then
            local text = line:GetText()
            if text then
                local textLower = string_lower(text)
                if string_find(textLower, "use:") or string_find(textLower, "equip:") then
                    hasSpecial = true
                    break
                end
                if string_find(textLower, "^unique") or string_find(textLower, "unique%-equipped") then
                    hasSpecial = true
                    break
                end
            end

            local r, g, b = line:GetTextColor()
            if r and g and b then
                if g > 0.9 and r < 0.2 and b < 0.2 then
                    hasSpecial = true
                    break
                end
                if r > 0.9 and g > 0.7 and b < 0.2 and text and i > 1 then
                    hasSpecial = true
                    break
                end
            end
        end
    end

    -- Cache the result
    if itemID then
        specialPropertiesCache[itemID] = hasSpecial
    end

    return hasSpecial
end

-------------------------------------------------
-- Check if item is a tool
-------------------------------------------------
local function IsTool(itemType, itemSubType, itemName)
    if not itemType then return false end

    local typeLower = string_lower(itemType)
    local subLower = itemSubType and string_lower(itemSubType) or ""
    local nameLower = itemName and string_lower(itemName) or ""

    if typeLower == "tools" or typeLower == "tool" then return true end
    if string_find(subLower, "fishing") then return true end
    if string_find(subLower, "mining") then return true end
    if string_find(nameLower, "mining pick") then return true end
    if string_find(nameLower, "fishing pole") then return true end
    if string_find(nameLower, "fishing rod") then return true end
    if string_find(nameLower, "skinning knife") then return true end
    if string_find(nameLower, "blacksmith hammer") then return true end
    if string_find(nameLower, "arclight spanner") then return true end

    return false
end

-------------------------------------------------
-- Bag family utilities
-------------------------------------------------
local function GetBagFamily(bagID)
    if bagID == 0 then return 0 end
    local numFreeSlots, bagFamily = C_Container_GetContainerNumFreeSlots(bagID)
    return bagFamily or 0
end

local function CanItemGoInBag(itemID, bagFamily)
    if bagFamily == 0 then return true end
    if not itemID then return false end
    local itemFamily = C_Item_GetItemFamily(itemID)
    if not itemFamily then return false end
    return bit_band(itemFamily, bagFamily) ~= 0
end

local function GetBagTypeFromFamily(bagFamily)
    if bagFamily == 0 then return nil end

    -- TBC-specific bag types (quiver/ammo only exist in TBC)
    if Expansion.IsTBC then
        if bit_band(bagFamily, 1) ~= 0 then return "quiver" end
        if bit_band(bagFamily, 2) ~= 0 then return "ammo" end
    end

    -- Common bag types (all Classic expansions)
    if bit_band(bagFamily, 4) ~= 0 then return "soul" end
    if bit_band(bagFamily, 8) ~= 0 then return "leatherworking" end
    if bit_band(bagFamily, 32) ~= 0 then return "herb" end
    if bit_band(bagFamily, 64) ~= 0 then return "enchant" end
    if bit_band(bagFamily, 128) ~= 0 then return "engineering" end
    if bit_band(bagFamily, 1024) ~= 0 then return "mining" end

    -- MoP-specific bag types
    if Expansion.IsMoP then
        if bit_band(bagFamily, 16) ~= 0 then return "inscription" end
        if bit_band(bagFamily, 512) ~= 0 then return "gem" end
    end

    return "specialized"
end

local function GetItemPreferredContainer(itemID)
    if not itemID then return nil end
    local itemFamily = C_Item_GetItemFamily(itemID)
    if not itemFamily or itemFamily == 0 then return nil end
    return GetBagTypeFromFamily(itemFamily)
end

--===========================================================================
-- SORT KEY COMPUTATION
--===========================================================================

local function GetSortedClassID(classID)
    return CLASS_ORDER[classID] or 99
end

local function GetSortedSubClassID(classID, subClassID)
    if classID == 2 then -- Weapon
        return WEAPON_SUBCLASS_ORDER[subClassID] or 99
    elseif classID == 4 then -- Armor
        return ARMOR_SUBCLASS_ORDER[subClassID] or 99
    elseif classID == 7 then -- Trade Goods
        return TRADE_GOODS_SUBCLASS_ORDER[subClassID] or 99
    elseif classID == 0 then -- Consumable
        return CONSUMABLE_SUBCLASS_ORDER[subClassID] or 99
    end
    return subClassID or 99
end

local function GetEquipSlotOrder(equipLoc)
    return EQUIP_SLOT_ORDER[equipLoc] or 99
end

-- Numeric key for swap deduplication (avoids string concatenation garbage)
-- Offset bagIDs by 10 to handle negatives (-2..12 → 8..22), slots are 1-36
local function SlotPairKey(bag1, slot1, bag2, slot2)
    return ((bag1 + 10) * 100 + slot1) * 10000 + (bag2 + 10) * 100 + slot2
end

--===========================================================================
-- PHASE 1: Classify Bags
--===========================================================================

local function ClassifyBags(bagIDs)
    -- Build container types based on expansion
    local containers = {
        -- Common bag types (all Classic expansions)
        soul = {}, herb = {}, enchant = {},
        engineering = {}, mining = {}, leatherworking = {},
        specialized = {}, regular = {}
    }

    -- TBC-specific bag types
    if Expansion.IsTBC then
        containers.quiver = {}
        containers.ammo = {}
    end

    -- MoP-specific bag types
    if Expansion.IsMoP then
        containers.gem = {}
        containers.inscription = {}
    end

    local bagFamilies = {}

    for _, bagID in ipairs(bagIDs) do
        local family = GetBagFamily(bagID)
        bagFamilies[bagID] = family

        local bagType = GetBagTypeFromFamily(family)
        if bagType and containers[bagType] then
            local ct = containers[bagType]
            ct[#ct + 1] = bagID
        elseif bagType then
            containers.specialized[#containers.specialized + 1] = bagID
        else
            containers.regular[#containers.regular + 1] = bagID
        end
    end

    return containers, bagFamilies
end

--===========================================================================
-- PHASE 2: Route Specialized Items
--===========================================================================

local function RouteSpecializedItems(bagIDs, containers, bagFamilies)
    local routingPlan = {}

    for _, bagID in ipairs(bagIDs) do
        local numSlots = C_Container_GetContainerNumSlots(bagID)
        for slot = 1, numSlots do
            local itemInfo = C_Container_GetContainerItemInfo(bagID, slot)
            if itemInfo and itemInfo.itemID then
                local preferredType = GetItemPreferredContainer(itemInfo.itemID)
                local currentBagType = GetBagTypeFromFamily(bagFamilies[bagID] or 0)

                if preferredType and currentBagType ~= preferredType then
                    local targetBags = containers[preferredType]
                    if targetBags and #targetBags > 0 then
                        local foundSlot = false
                        for _, targetBagID in ipairs(targetBags) do
                            if not foundSlot then
                                -- Verify item can actually go in target bag before routing
                                local targetBagFamily = bagFamilies[targetBagID] or 0
                                if CanItemGoInBag(itemInfo.itemID, targetBagFamily) then
                                    local targetSlots = C_Container_GetContainerNumSlots(targetBagID)
                                    for targetSlot = 1, targetSlots do
                                        local targetInfo = C_Container_GetContainerItemInfo(targetBagID, targetSlot)
                                        if not targetInfo then
                                            routingPlan[#routingPlan + 1] = {
                                                fromBag = bagID, fromSlot = slot,
                                                toBag = targetBagID, toSlot = targetSlot
                                            }
                                            foundSlot = true
                                            break
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    ClearCursor()
    for _, move in ipairs(routingPlan) do
        local sourceInfo = C_Container_GetContainerItemInfo(move.fromBag, move.fromSlot)
        if sourceInfo and not sourceInfo.isLocked then
            C_Container_PickupContainerItem(move.fromBag, move.fromSlot)
            C_Container_PickupContainerItem(move.toBag, move.toSlot)
            ClearCursor()
        end
    end

    return #routingPlan
end

--===========================================================================
-- PHASE 3: Stack Consolidation
--===========================================================================

local function ConsolidateStacks(bagIDs, bagFamilies)
    local itemGroups = {}

    for _, bagID in ipairs(bagIDs) do
        local numSlots = C_Container_GetContainerNumSlots(bagID)
        for slot = 1, numSlots do
            local itemInfo = C_Container_GetContainerItemInfo(bagID, slot)
            if itemInfo and itemInfo.itemID then
                local groupKey = itemInfo.itemID
                if not itemGroups[groupKey] then
                    itemGroups[groupKey] = { itemID = itemInfo.itemID, stacks = {} }
                end
                local stacks = itemGroups[groupKey].stacks
                stacks[#stacks + 1] = {
                    bagID = bagID, slot = slot,
                    count = tonumber(itemInfo.stackCount) or 1
                }
            end
        end
    end

    local consolidationMoves = 0
    for _, group in pairs(itemGroups) do
        if #group.stacks > 1 then
            -- GetItemInfo returns: name, link, quality, ilvl, minLevel, type, subType, stackCount, equipLoc, texture, sellPrice
            -- Can return nil if item data isn't cached
            local itemInfoResults = {GetItemInfo(group.itemID)}
            local stackSize = itemInfoResults[8]
            local maxStack = tonumber(stackSize) or 1

            if maxStack > 1 then
                table_sort(group.stacks, function(a, b)
                    return (tonumber(a.count) or 0) > (tonumber(b.count) or 0)
                end)

                for i = 1, #group.stacks do
                    local source = group.stacks[i]
                    if source.count < maxStack and source.count > 0 then
                        for j = i + 1, #group.stacks do
                            local target = group.stacks[j]
                            if target.count > 0 then
                                local spaceAvailable = maxStack - source.count
                                local amountToMove = math_min(spaceAvailable, target.count)

                                if amountToMove > 0 then
                                    local sourceInfo = C_Container_GetContainerItemInfo(source.bagID, source.slot)
                                    local targetInfo = C_Container_GetContainerItemInfo(target.bagID, target.slot)

                                    if sourceInfo and targetInfo and not sourceInfo.isLocked and not targetInfo.isLocked then
                                        if amountToMove < target.count then
                                            C_Container_SplitContainerItem(target.bagID, target.slot, amountToMove)
                                            C_Container_PickupContainerItem(source.bagID, source.slot)
                                        else
                                            C_Container_PickupContainerItem(target.bagID, target.slot)
                                            C_Container_PickupContainerItem(source.bagID, source.slot)
                                        end
                                        ClearCursor()

                                        source.count = source.count + amountToMove
                                        target.count = target.count - amountToMove
                                        consolidationMoves = consolidationMoves + 1

                                        if source.count >= maxStack then break end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return consolidationMoves
end

--===========================================================================
-- PHASE 4: Collect and Sort Items
--===========================================================================

local function CollectItems(bagIDs)
    local items = {}
    local sequence = 0

    for _, bagID in ipairs(bagIDs) do
        local numSlots = C_Container_GetContainerNumSlots(bagID)
        for slot = 1, numSlots do
            local itemInfo = C_Container_GetContainerItemInfo(bagID, slot)
            if itemInfo then
                local itemLink = itemInfo.hyperlink
                local itemName, _, itemQuality, itemLevel, _, itemType, itemSubType, _, itemEquipLoc, _, _, classID, subClassID = GetItemInfo(itemLink)
                -- GetItemInfo can return nil if item data isn't cached yet
                itemName = itemName or ""
                itemQuality = itemQuality or itemInfo.quality or 0
                itemLevel = itemLevel or 0
                itemType = itemType or "Miscellaneous"
                itemSubType = itemSubType or ""
                itemEquipLoc = itemEquipLoc or ""
                classID = classID or 15
                subClassID = subClassID or 0

                sequence = sequence + 1
                items[#items + 1] = {
                    bagID = bagID,
                    slot = slot,
                    sequence = sequence,
                    itemID = itemInfo.itemID,
                    itemLink = itemLink,
                    itemName = itemName,
                    quality = tonumber(itemQuality) or 0,
                    itemLevel = tonumber(itemLevel) or 0,
                    itemType = itemType,
                    itemSubType = itemSubType,
                    equipLoc = itemEquipLoc,
                    stackCount = tonumber(itemInfo.stackCount) or 1,
                    isLocked = itemInfo.isLocked,
                    itemFamily = C_Item_GetItemFamily(itemInfo.itemID) or 0,
                    classID = classID,
                    subClassID = subClassID,
                }
            end
        end
    end

    return items
end

local function AddSortKeys(items)
    -- Check if white items should be treated as junk (setting) - read once
    local whiteItemsJunk = Database:GetSetting("whiteItemsJunk") or false

    for _, item in ipairs(items) do
        local itemID = item.itemID

        -- Check if we have cached sort keys for this itemID
        local cached = sortKeyCache[itemID]
        if cached then
            perfStats.sortKeyCacheHits = perfStats.sortKeyCacheHits + 1
            -- Reuse cached sort keys
            item.priority = cached.priority
            item.sortedClassID = cached.sortedClassID
            item.sortedSubClassID = cached.sortedSubClassID
            item.sortedEquipSlot = cached.sortedEquipSlot
            item.isEquippable = cached.isEquippable
            item.isJunk = cached.isJunk
            item.invertedQuality = cached.invertedQuality
            item.invertedItemLevel = cached.invertedItemLevel
            item.invertedItemID = cached.invertedItemID
            -- Note: invertedCount is stack-specific, compute fresh
            item.invertedCount = -item.stackCount
        else
            perfStats.sortKeyComputes = perfStats.sortKeyComputes + 1
            -- Compute sort keys fresh
            -- Priority (hearthstone always first)
            item.priority = PRIORITY_ITEMS[itemID] or 1000

            -- Sorted class and subclass IDs
            item.sortedClassID = GetSortedClassID(item.classID)
            item.sortedSubClassID = GetSortedSubClassID(item.classID, item.subClassID)
            item.sortedEquipSlot = GetEquipSlotOrder(item.equipLoc)

            -- Check if equippable
            local isEquippable = (item.classID == 2 or item.classID == 4) and
                                item.equipLoc ~= "" and item.equipLoc ~= "INVTYPE_BAG"
            item.isEquippable = isEquippable

            -- Check for tools and special properties (cached by itemID)
            local isTool = IsTool(item.itemType, item.itemSubType, item.itemName)
            local hasSpecial = HasSpecialProperties(item.bagID, item.slot, itemID)

            -- Junk detection
            local isGrayItem = item.quality == 0
            local isWhiteEquip = (item.quality == 1) and isEquippable
            local shouldBeJunk = false

            -- Check if this equip slot is valuable (never junk)
            local isValuableSlot = Constants.VALUABLE_EQUIP_SLOTS and Constants.VALUABLE_EQUIP_SLOTS[item.equipLoc]

            if isGrayItem then
                -- Gray items are always junk (unless profession tools)
                shouldBeJunk = not isTool
            elseif isWhiteEquip and whiteItemsJunk then
                -- Only treat white equippable as junk if setting is enabled
                -- Valuable slots (trinket, ring, neck, shirt, tabard) are never junk
                if isValuableSlot then
                    shouldBeJunk = false
                else
                    shouldBeJunk = not isTool and not hasSpecial
                end
            end

            item.isJunk = shouldBeJunk

            -- Override class for junk items (sort to end)
            if shouldBeJunk then
                item.sortedClassID = 100
            end

            -- Inverted values for descending sorts
            item.invertedQuality = -item.quality
            item.invertedItemLevel = -item.itemLevel
            item.invertedCount = -item.stackCount
            item.invertedItemID = -itemID

            -- Cache the computed sort keys for this itemID
            sortKeyCache[itemID] = {
                priority = item.priority,
                sortedClassID = item.sortedClassID,
                sortedSubClassID = item.sortedSubClassID,
                sortedEquipSlot = item.sortedEquipSlot,
                isEquippable = item.isEquippable,
                isJunk = item.isJunk,
                invertedQuality = item.invertedQuality,
                invertedItemLevel = item.invertedItemLevel,
                invertedItemID = item.invertedItemID,
            }
        end
    end
end

-- Module-level sort comparator (avoids closure allocation per SortItems call)
local currentReverseStackSort = false

local function SortComparator(a, b)
    if a.priority ~= b.priority then return a.priority < b.priority end
    if a.sortedClassID ~= b.sortedClassID then return a.sortedClassID < b.sortedClassID end
    if a.isEquippable and b.isEquippable then
        if a.sortedEquipSlot ~= b.sortedEquipSlot then return a.sortedEquipSlot < b.sortedEquipSlot end
    end
    if a.sortedSubClassID ~= b.sortedSubClassID then return a.sortedSubClassID < b.sortedSubClassID end
    if a.invertedItemLevel ~= b.invertedItemLevel then return a.invertedItemLevel < b.invertedItemLevel end
    if a.invertedQuality ~= b.invertedQuality then return a.invertedQuality < b.invertedQuality end
    if a.itemName ~= b.itemName then return a.itemName < b.itemName end
    if a.invertedItemID ~= b.invertedItemID then return a.invertedItemID < b.invertedItemID end
    if a.invertedCount ~= b.invertedCount then
        if currentReverseStackSort then return a.stackCount < b.stackCount
        else return a.invertedCount < b.invertedCount end
    end
    return a.sequence < b.sequence
end

local function SortItems(items)
    AddSortKeys(items)
    currentReverseStackSort = Database:GetSetting("reverseStackSort")
    table_sort(items, SortComparator)
    return items
end

--===========================================================================
-- PHASE 5: Build Target Positions and Apply Sort
--===========================================================================

local function BuildTargetPositions(bagIDs, itemCount)
    local positions = {}
    local index = 1
    local rightToLeft = Database:GetSetting("sortRightToLeft")

    local bagOrder = {}
    for _, bagID in ipairs(bagIDs) do
        bagOrder[#bagOrder + 1] = bagID
    end

    if rightToLeft then
        local reversed = {}
        for i = #bagOrder, 1, -1 do
            reversed[#reversed + 1] = bagOrder[i]
        end
        bagOrder = reversed
    end

    for _, bagID in ipairs(bagOrder) do
        local numSlots = C_Container_GetContainerNumSlots(bagID)

        if rightToLeft then
            for slot = numSlots, 1, -1 do
                if index <= itemCount then
                    positions[index] = { bagID = bagID, slot = slot }
                    index = index + 1
                end
            end
        else
            for slot = 1, numSlots do
                if index <= itemCount then
                    positions[index] = { bagID = bagID, slot = slot }
                    index = index + 1
                end
            end
        end
    end

    return positions
end

local function BuildTailPositions(bagIDs, junkCount)
    local positions = {}
    if junkCount <= 0 then return positions end

    local rightToLeft = Database:GetSetting("sortRightToLeft")

    local bagOrder = {}
    for _, bagID in ipairs(bagIDs) do
        local numSlots = C_Container_GetContainerNumSlots(bagID)
        if numSlots > 0 then
            bagOrder[#bagOrder + 1] = { bagID = bagID, numSlots = numSlots }
        end
    end

    local tailSlots = {}

    if rightToLeft then
        for i = 1, #bagOrder do
            local info = bagOrder[i]
            for slot = 1, info.numSlots do
                if #tailSlots < junkCount then
                    tailSlots[#tailSlots + 1] = { bagID = info.bagID, slot = slot }
                else
                    break
                end
            end
            if #tailSlots >= junkCount then break end
        end
    else
        for i = #bagOrder, 1, -1 do
            local info = bagOrder[i]
            for slot = info.numSlots, 1, -1 do
                if #tailSlots < junkCount then
                    tailSlots[#tailSlots + 1] = { bagID = info.bagID, slot = slot }
                else
                    break
                end
            end
            if #tailSlots >= junkCount then break end
        end
    end

    table_sort(tailSlots, function(a, b)
        if a.bagID ~= b.bagID then return a.bagID < b.bagID end
        return a.slot < b.slot
    end)

    return tailSlots
end

local function SplitJunkItems(items)
    local nonJunk, junk = {}, {}
    for _, item in ipairs(items) do
        if item.isJunk then
            junk[#junk + 1] = item
        else
            nonJunk[#nonJunk + 1] = item
        end
    end
    return nonJunk, junk
end

local function ApplySort(items, targetPositions, bagFamilies)
    ClearCursor()

    local moveToEmpty = {}
    local swapOccupied = {}
    local swappedSlots = {} -- Track queued swap pairs to prevent double-swaps

    for i, item in ipairs(items) do
        local target = targetPositions[i]
        if target then
            local targetFamily = bagFamilies[target.bagID] or 0
            local canGoInBag = (targetFamily == 0) or CanItemGoInBag(item.itemID, targetFamily)

            if canGoInBag and (item.bagID ~= target.bagID or item.slot ~= target.slot) then
                local targetInfo = C_Container_GetContainerItemInfo(target.bagID, target.slot)
                if not targetInfo then
                    moveToEmpty[#moveToEmpty + 1] = {
                        sourceBag = item.bagID, sourceSlot = item.slot,
                        targetBag = target.bagID, targetSlot = target.slot,
                    }
                else
                    -- Skip swaps between functionally identical items (same itemID + stackCount).
                    -- Without this, identical items oscillate between passes because their
                    -- sequence numbers change when they move to new positions.
                    if item.itemID == targetInfo.itemID and item.stackCount == (targetInfo.stackCount or 1) then
                        -- Items are interchangeable, swap is a no-op
                    else
                        local sourceFamily = bagFamilies[item.bagID] or 0
                        local targetCanGoInSource = (sourceFamily == 0) or CanItemGoInBag(targetInfo.itemID, sourceFamily)

                        if targetCanGoInSource then
                            -- Deduplicate: if target→source was already queued, this swap
                            -- would undo it (A↔B then B↔A = no progress). Skip the reverse.
                            local reverseKey = SlotPairKey(target.bagID, target.slot, item.bagID, item.slot)
                            if not swappedSlots[reverseKey] then
                                local forwardKey = SlotPairKey(item.bagID, item.slot, target.bagID, target.slot)
                                swappedSlots[forwardKey] = true
                                swapOccupied[#swapOccupied + 1] = {
                                    sourceBag = item.bagID, sourceSlot = item.slot,
                                    targetBag = target.bagID, targetSlot = target.slot,
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    local moveCount = 0

    for _, move in ipairs(moveToEmpty) do
        local sourceInfo = C_Container_GetContainerItemInfo(move.sourceBag, move.sourceSlot)
        if sourceInfo and not sourceInfo.isLocked then
            C_Container_PickupContainerItem(move.sourceBag, move.sourceSlot)
            C_Container_PickupContainerItem(move.targetBag, move.targetSlot)
            ClearCursor()
            moveCount = moveCount + 1
            if not soundsMuted then
                MutePickupSounds()
                soundsMuted = true
            end
        end
    end

    for _, move in ipairs(swapOccupied) do
        local sourceInfo = C_Container_GetContainerItemInfo(move.sourceBag, move.sourceSlot)
        local targetInfo = C_Container_GetContainerItemInfo(move.targetBag, move.targetSlot)

        if sourceInfo and targetInfo and not sourceInfo.isLocked and not targetInfo.isLocked then
            C_Container_PickupContainerItem(move.sourceBag, move.sourceSlot)
            C_Container_PickupContainerItem(move.targetBag, move.targetSlot)
            ClearCursor()
            moveCount = moveCount + 1
            if not soundsMuted then
                MutePickupSounds()
                soundsMuted = true
            end
        end
    end

    return moveCount
end

-- Yielding version of ApplySort for coroutine-based sorting
-- Same logic but yields every 5 moves when frame budget is exceeded
local function ApplySort_Yielding(items, targetPositions, bagFamilies)
    ClearCursor()

    local moveToEmpty = {}
    local swapOccupied = {}
    local swappedSlots = {} -- Track queued swap pairs to prevent double-swaps

    -- Build move lists (fast, no yielding needed)
    for i, item in ipairs(items) do
        local target = targetPositions[i]
        if target then
            local targetFamily = bagFamilies[target.bagID] or 0
            local canGoInBag = (targetFamily == 0) or CanItemGoInBag(item.itemID, targetFamily)

            if canGoInBag and (item.bagID ~= target.bagID or item.slot ~= target.slot) then
                local targetInfo = C_Container_GetContainerItemInfo(target.bagID, target.slot)
                if not targetInfo then
                    moveToEmpty[#moveToEmpty + 1] = {
                        sourceBag = item.bagID, sourceSlot = item.slot,
                        targetBag = target.bagID, targetSlot = target.slot,
                    }
                else
                    -- Skip swaps between functionally identical items (same itemID + stackCount).
                    -- Without this, identical items oscillate between passes because their
                    -- sequence numbers change when they move to new positions.
                    if item.itemID == targetInfo.itemID and item.stackCount == (targetInfo.stackCount or 1) then
                        -- Items are interchangeable, swap is a no-op
                    else
                        local sourceFamily = bagFamilies[item.bagID] or 0
                        local targetCanGoInSource = (sourceFamily == 0) or CanItemGoInBag(targetInfo.itemID, sourceFamily)

                        if targetCanGoInSource then
                            -- Deduplicate: if target→source was already queued, this swap
                            -- would undo it (A↔B then B↔A = no progress). Skip the reverse.
                            local reverseKey = SlotPairKey(target.bagID, target.slot, item.bagID, item.slot)
                            if not swappedSlots[reverseKey] then
                                local forwardKey = SlotPairKey(item.bagID, item.slot, target.bagID, target.slot)
                                swappedSlots[forwardKey] = true
                                swapOccupied[#swapOccupied + 1] = {
                                    sourceBag = item.bagID, sourceSlot = item.slot,
                                    targetBag = target.bagID, targetSlot = target.slot,
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    local moveCount = 0

    for idx, move in ipairs(moveToEmpty) do
        local sourceInfo = C_Container_GetContainerItemInfo(move.sourceBag, move.sourceSlot)
        if sourceInfo and not sourceInfo.isLocked then
            C_Container_PickupContainerItem(move.sourceBag, move.sourceSlot)
            C_Container_PickupContainerItem(move.targetBag, move.targetSlot)
            ClearCursor()
            moveCount = moveCount + 1
            if not soundsMuted then
                MutePickupSounds()
                soundsMuted = true
            end
            if idx % 5 == 0 and IsFrameBudgetExceeded() then
                coroutine_yield("budget")
                StartFrameTimer()
            end
        end
    end

    for idx, move in ipairs(swapOccupied) do
        local sourceInfo = C_Container_GetContainerItemInfo(move.sourceBag, move.sourceSlot)
        local targetInfo = C_Container_GetContainerItemInfo(move.targetBag, move.targetSlot)

        if sourceInfo and targetInfo and not sourceInfo.isLocked and not targetInfo.isLocked then
            C_Container_PickupContainerItem(move.sourceBag, move.sourceSlot)
            C_Container_PickupContainerItem(move.targetBag, move.targetSlot)
            ClearCursor()
            moveCount = moveCount + 1
            if not soundsMuted then
                MutePickupSounds()
                soundsMuted = true
            end
            if idx % 5 == 0 and IsFrameBudgetExceeded() then
                coroutine_yield("budget")
                StartFrameTimer()
            end
        end
    end

    return moveCount
end

--===========================================================================
-- PHASE 6: Verify Sort Completeness
--===========================================================================

-- Check how many items are out of position (without moving them)
local function CountOutOfPlaceItems(bagIDs)
    local containers, bagFamilies = ClassifyBags(bagIDs)
    local outOfPlace = 0

    -- Check regular bags
    local regularBags = containers.regular
    if #regularBags > 0 then
        local allItems = CollectItems(regularBags)
        if #allItems > 0 then
            allItems = SortItems(allItems)
            local nonJunk, junk = SplitJunkItems(allItems)

            -- Check non-junk items against front positions
            if #nonJunk > 0 then
                local frontPositions = BuildTargetPositions(regularBags, #nonJunk)
                for i, item in ipairs(nonJunk) do
                    local target = frontPositions[i]
                    if target and (item.bagID ~= target.bagID or item.slot ~= target.slot) then
                        -- Check if the item at target is functionally identical (interchangeable)
                        local targetInfo = C_Container_GetContainerItemInfo(target.bagID, target.slot)
                        if not targetInfo or targetInfo.itemID ~= item.itemID or (targetInfo.stackCount or 1) ~= item.stackCount then
                            outOfPlace = outOfPlace + 1
                        end
                    end
                end
            end
        end
    end

    return outOfPlace
end

-- Cached specialized bag type list (initialized once on first use)
local cachedSpecializedTypes = nil
local function GetSpecializedTypes()
    if not cachedSpecializedTypes then
        cachedSpecializedTypes = {"soul", "herb", "enchant", "engineering", "mining", "leatherworking"}
        if Expansion.IsTBC then
            cachedSpecializedTypes[#cachedSpecializedTypes + 1] = "quiver"
            cachedSpecializedTypes[#cachedSpecializedTypes + 1] = "ammo"
        end
        if Expansion.IsMoP then
            cachedSpecializedTypes[#cachedSpecializedTypes + 1] = "gem"
            cachedSpecializedTypes[#cachedSpecializedTypes + 1] = "inscription"
        end
    end
    return cachedSpecializedTypes
end

-- Full sort completeness check: returns true if all items are already in their sorted positions.
-- Checks specialized bags, regular bags (non-junk + junk), so a redundant sort is skipped entirely.
local function IsSortComplete(bagIDs)
    local containers, bagFamilies = ClassifyBags(bagIDs)

    -- Check specialized bags
    local specializedTypes = GetSpecializedTypes()
    for _, bagType in ipairs(specializedTypes) do
        local specialBags = containers[bagType]
        if specialBags then
            for _, bagID in ipairs(specialBags) do
                local items = CollectItems({bagID})
                if #items > 0 then
                    items = SortItems(items)
                    local targets = BuildTargetPositions({bagID}, #items)
                    for i, item in ipairs(items) do
                        local target = targets[i]
                        if target and (item.bagID ~= target.bagID or item.slot ~= target.slot) then
                            -- Check if the item at target is functionally identical
                            local targetInfo = C_Container_GetContainerItemInfo(target.bagID, target.slot)
                            if not targetInfo or targetInfo.itemID ~= item.itemID or (targetInfo.stackCount or 1) ~= item.stackCount then
                                return false
                            end
                        end
                    end
                end
            end
        end
    end

    -- Check regular bags (non-junk front positions + junk tail positions)
    local regularBags = containers.regular
    if #regularBags > 0 then
        local allItems = CollectItems(regularBags)
        if #allItems > 0 then
            allItems = SortItems(allItems)
            local nonJunk, junk = SplitJunkItems(allItems)

            if #nonJunk > 0 then
                local frontPositions = BuildTargetPositions(regularBags, #nonJunk)
                for i, item in ipairs(nonJunk) do
                    local target = frontPositions[i]
                    if target and (item.bagID ~= target.bagID or item.slot ~= target.slot) then
                        local targetInfo = C_Container_GetContainerItemInfo(target.bagID, target.slot)
                        if not targetInfo or targetInfo.itemID ~= item.itemID or (targetInfo.stackCount or 1) ~= item.stackCount then
                            return false
                        end
                    end
                end
            end

            if #junk > 0 then
                local tailPositions = BuildTailPositions(regularBags, #junk)
                for i, item in ipairs(junk) do
                    local target = tailPositions[i]
                    if target and (item.bagID ~= target.bagID or item.slot ~= target.slot) then
                        local targetInfo = C_Container_GetContainerItemInfo(target.bagID, target.slot)
                        if not targetInfo or targetInfo.itemID ~= item.itemID or (targetInfo.stackCount or 1) ~= item.stackCount then
                            return false
                        end
                    end
                end
            end
        end
    end

    return true
end

--===========================================================================
-- PHASE 7: Coroutine Sort Pass
-- Yields between phases and during move execution to stay within frame budget.
-- Yield values: "wait_locks" (wait for item locks), "budget" (frame budget exceeded)
-- Return value: totalMoves (when coroutine completes)
--===========================================================================

local function SortCoroutineBody(bagIDs)
    local containers, bagFamilies = ClassifyBags(bagIDs)
    local totalMoves = 0

    -- Phase 2: Route specialized items
    local routeMoves = RouteSpecializedItems(bagIDs, containers, bagFamilies)
    totalMoves = totalMoves + routeMoves
    if routeMoves > 0 then
        coroutine_yield("wait_locks")
        StartFrameTimer()
    end

    -- Phase 3: Consolidate stacks
    local consolidateMoves = ConsolidateStacks(bagIDs, bagFamilies)
    totalMoves = totalMoves + consolidateMoves
    if consolidateMoves > 0 then
        coroutine_yield("wait_locks")
        StartFrameTimer()
    end

    -- Phase 4: Sort specialized bags
    local specializedTypes = GetSpecializedTypes()
    for _, bagType in ipairs(specializedTypes) do
        local specialBags = containers[bagType]
        if specialBags then
            for _, bagID in ipairs(specialBags) do
                local items = CollectItems({bagID})
                if #items > 0 then
                    items = SortItems(items)
                    local targets = BuildTargetPositions({bagID}, #items)
                    local moves = ApplySort_Yielding(items, targets, bagFamilies)
                    totalMoves = totalMoves + moves
                    if moves > 0 then
                        coroutine_yield("wait_locks")
                        StartFrameTimer()
                    end
                end
            end
        end
        -- Yield between bag types if budget exceeded
        if IsFrameBudgetExceeded() then
            coroutine_yield("budget")
            StartFrameTimer()
        end
    end

    -- Phase 5: Sort regular bags (two-pass: non-junk forward, junk backward)
    local regularBags = containers.regular
    if #regularBags > 0 then
        local allItems = CollectItems(regularBags)
        if #allItems > 0 then
            allItems = SortItems(allItems)
            local nonJunk, junk = SplitJunkItems(allItems)

            if #nonJunk > 0 then
                local frontPositions = BuildTargetPositions(regularBags, #nonJunk)
                local moves = ApplySort_Yielding(nonJunk, frontPositions, bagFamilies)
                totalMoves = totalMoves + moves
                if moves > 0 then
                    coroutine_yield("wait_locks")
                    StartFrameTimer()
                end
            end

            if #junk > 0 then
                -- Re-collect only junk items (positions may have changed after non-junk sort)
                -- Uses sortKeyCache to identify junk without full re-sort
                local junkNow = {}
                for _, bagID in ipairs(regularBags) do
                    local numSlots = C_Container_GetContainerNumSlots(bagID)
                    for slot = 1, numSlots do
                        local itemInfo = C_Container_GetContainerItemInfo(bagID, slot)
                        if itemInfo and itemInfo.itemID and sortKeyCache[itemInfo.itemID] and sortKeyCache[itemInfo.itemID].isJunk then
                            junkNow[#junkNow + 1] = {
                                bagID = bagID, slot = slot,
                                itemID = itemInfo.itemID,
                                stackCount = tonumber(itemInfo.stackCount) or 1,
                            }
                        end
                    end
                end
                if #junkNow > 0 then
                    local tailPositions = BuildTailPositions(regularBags, #junkNow)
                    local moves = ApplySort_Yielding(junkNow, tailPositions, bagFamilies)
                    totalMoves = totalMoves + moves
                end
            end
        end
    end

    return totalMoves
end

--===========================================================================
-- MAIN SORT FUNCTIONS
--===========================================================================

local sortFrame = CreateFrame("Frame")
local sortStartTime = 0
local noProgressCount = 0
local sortTimeout = 30

local activeBagIDs = Constants.BAG_IDS

local function AnyItemsLocked()
    for _, bagID in ipairs(activeBagIDs) do
        local numSlots = C_Container_GetContainerNumSlots(bagID)
        for slot = 1, numSlots do
            local itemInfo = C_Container_GetContainerItemInfo(bagID, slot)
            if itemInfo and itemInfo.isLocked then
                return true
            end
        end
    end
    return false
end

-- Helper to finalize sort (clean up state and notify)
local function FinishSort(message)
    local isBankSort = (activeBagIDs == Constants.BANK_BAG_IDS)
    sortInProgress = false
    sortCoroutine = nil
    soundsMuted = false
    activeBagIDs = Constants.BAG_IDS
    currentFrameBudget = FRAME_BUDGET_US
    UnmutePickupSounds()
    SortEngine:ClearCache()
    if message then
        ns:Print(message)
    end
    if isBankSort and ns.OnBankUpdated then
        ns.OnBankUpdated()
    else
        Events:Fire("BAGS_UPDATED")
    end
end

-- Coroutine-driven OnUpdate: resumes sort coroutine each frame within budget.
-- No fixed delays between passes — resumes as soon as item locks clear (~1-2 frames).
-- Each frame does at most 4-6ms of work instead of one 20-50ms spike.
sortFrame:SetScript("OnUpdate", function(self, elapsed)
    if not sortInProgress then return end

    -- Cancel sort immediately if combat starts mid-sort
    if InCombatLockdown() then
        ClearCursor()
        FinishSort("Sort cancelled: entered combat")
        return
    end

    -- Timeout check
    if GetTime() - sortStartTime > sortTimeout then
        FinishSort("Sort timed out")
        return
    end

    -- Wait for item locks to clear (check every frame, no fixed delay)
    if AnyItemsLocked() then
        return
    end

    -- Create new coroutine if needed (start of a new pass)
    if not sortCoroutine then
        currentPass = currentPass + 1
        if currentPass > maxPasses then
            FinishSort()
            return
        end
        sortCoroutine = coroutine_create(SortCoroutineBody)
    end

    -- Resume coroutine with frame budget
    StartFrameTimer()
    local passStart = debugprofilestop()
    local ok, result = coroutine_resume(sortCoroutine, activeBagIDs)
    local passTime = debugprofilestop() - passStart

    if not ok then
        -- Coroutine error
        ns:Debug(string.format("Sort pass %d error: %s", currentPass, tostring(result)))
        FinishSort("Sort error: " .. tostring(result))
        return
    end

    if coroutine_status(sortCoroutine) == "dead" then
        -- Coroutine completed this pass
        local moveCount = result or 0
        ns:Debug(string.format("Sort pass %d: %.2fms, %d moves", currentPass, passTime / 1000, moveCount))
        sortCoroutine = nil

        if moveCount == 0 then
            noProgressCount = noProgressCount + 1
        else
            noProgressCount = 0
        end

        -- Check if sort is complete
        if noProgressCount >= 3 then
            local outOfPlace = CountOutOfPlaceItems(activeBagIDs)
            if outOfPlace > 0 and currentPass < maxPasses then
                ns:Debug(string.format("Sort incomplete: %d items out of place, continuing...", outOfPlace))
                noProgressCount = 0
                return  -- Next frame will create new coroutine
            end

            if outOfPlace > 0 then
                ns:Debug(string.format("Sort finished with %d items still out of place (may need another sort)", outOfPlace))
            end

            FinishSort()
            return
        end

        -- More passes needed, next frame creates new coroutine automatically
    end
    -- If coroutine yielded ("wait_locks" or "budget"), it resumes next frame
end)

-------------------------------------------------
-- Public API
-------------------------------------------------
function SortEngine:SortBags()
    if InCombatLockdown() then
        ns:Print("Cannot sort in combat")
        return false
    end

    if sortInProgress then
        ns:Print("Sort already in progress...")
        return false
    end

    -- Use native Blizzard sort API on retail
    if Expansion.IsRetail and C_Container and C_Container.SortBags then
        C_Container.SortBags()
        -- Fire event after a short delay to let the sort complete
        C_Timer.After(0.5, function()
            Events:Fire("BAGS_UPDATED")
        end)
        return true
    end

    -- Quick check: skip sort if bags are already in order
    if IsSortComplete(Constants.BAG_IDS) then
        ns:Debug("Bags already sorted, skipping")
        return true
    end

    -- Classic expansions use custom sort engine
    activeBagIDs = Constants.BAG_IDS
    currentFrameBudget = FRAME_BUDGET_US
    self:ClearCache()
    soundsMuted = false
    sortInProgress = true
    sortCoroutine = nil
    currentPass = 0
    noProgressCount = 0
    sortStartTime = GetTime()

    return true
end

function SortEngine:IsSorting()
    return sortInProgress
end

function SortEngine:CancelSort()
    if sortInProgress then
        UnmutePickupSounds()
    end
    sortInProgress = false
    sortCoroutine = nil
    soundsMuted = false
    currentPass = 0
    noProgressCount = 0
    activeBagIDs = Constants.BAG_IDS
    currentFrameBudget = FRAME_BUDGET_US
    self:ClearCache()
end

function SortEngine:SortBank()
    if InCombatLockdown() then
        ns:Print("Cannot sort in combat")
        return false
    end

    local BankScanner = ns:GetModule("BankScanner")
    if not BankScanner or not BankScanner:IsBankOpen() then
        ns:Print("Cannot sort bank: not at banker")
        return false
    end

    if sortInProgress then
        ns:Print("Sort already in progress...")
        return false
    end

    -- Use native Blizzard sort API on retail
    if Expansion.IsRetail and C_Container and C_Container.SortBankBags then
        C_Container.SortBankBags()
        -- Fire event after a short delay to let the sort complete
        C_Timer.After(0.5, function()
            if ns.OnBankUpdated then
                ns.OnBankUpdated()
            else
                Events:Fire("BAGS_UPDATED")
            end
        end)
        return true
    end

    -- Quick check: skip sort if bank is already in order
    if IsSortComplete(Constants.BANK_BAG_IDS) then
        ns:Debug("Bank already sorted, skipping")
        return true
    end

    -- Classic expansions use custom sort engine
    activeBagIDs = Constants.BANK_BAG_IDS
    currentFrameBudget = FRAME_BUDGET_BANK_US
    self:ClearCache()
    soundsMuted = false
    sortInProgress = true
    sortCoroutine = nil
    currentPass = 0
    noProgressCount = 0
    sortStartTime = GetTime()

    return true
end

function SortEngine:SortWarbandBank()
    if InCombatLockdown() then
        ns:Print("Cannot sort in combat")
        return false
    end

    local BankScanner = ns:GetModule("BankScanner")
    if not BankScanner or not BankScanner:IsBankOpen() then
        ns:Print("Cannot sort Warband bank: not at banker")
        return false
    end

    if sortInProgress then
        ns:Print("Sort already in progress...")
        return false
    end

    -- Warband bank sorting is only available on Retail
    if not Expansion.IsRetail then
        ns:Print("Warband bank is not available in this version")
        return false
    end

    -- Use native Blizzard sort API for Warband/Account bank
    if C_Container and C_Container.SortAccountBankBags then
        C_Container.SortAccountBankBags()
        -- Fire event after a short delay to let the sort complete
        C_Timer.After(0.5, function()
            if ns.OnBankUpdated then
                ns.OnBankUpdated()
            else
                Events:Fire("BAGS_UPDATED")
            end
        end)
        return true
    else
        ns:Print("Warband bank sorting not available")
        return false
    end
end

-------------------------------------------------
-- Restack Only (for Category View)
-- Consolidates stacks without sorting positions
-------------------------------------------------
local restackInProgress = false
local restackBagIDs = nil
local restackCallback = nil
local restackPassCount = 0
local restackMaxPasses = 4
local restackNextPassTime = 0

local restackFrame = CreateFrame("Frame")
restackFrame:SetScript("OnUpdate", function(self, elapsed)
    if not restackInProgress then return end

    -- Cancel restack immediately if combat starts
    if InCombatLockdown() then
        ClearCursor()
        restackInProgress = false
        UnmutePickupSounds()
        ns:Print("Restack cancelled: entered combat")
        if restackCallback then
            restackCallback()
        end
        return
    end

    local now = GetTime()
    local isBankRestack = (restackBagIDs == Constants.BANK_BAG_IDS)

    -- Bank operations are server-side and need longer delays
    local lockWaitTime = isBankRestack and 0.3 or 0.1

    if now < restackNextPassTime then return end

    -- Check if any items are locked
    for _, bagID in ipairs(restackBagIDs) do
        local numSlots = C_Container_GetContainerNumSlots(bagID)
        for slot = 1, numSlots do
            local itemInfo = C_Container_GetContainerItemInfo(bagID, slot)
            if itemInfo and itemInfo.isLocked then
                restackNextPassTime = now + lockWaitTime
                return -- Wait for items to unlock
            end
        end
    end

    restackPassCount = restackPassCount + 1

    local _, bagFamilies = ClassifyBags(restackBagIDs)
    local moves = ConsolidateStacks(restackBagIDs, bagFamilies)

    if moves == 0 or restackPassCount >= restackMaxPasses then
        -- Done restacking
        restackInProgress = false
        UnmutePickupSounds()
        if restackCallback then
            restackCallback()
        end
    end
end)

function SortEngine:RestackBags(callback)
    if InCombatLockdown() then return false end

    if sortInProgress or restackInProgress then
        return false
    end

    restackInProgress = true
    restackBagIDs = Constants.BAG_IDS
    restackCallback = callback
    restackPassCount = 0
    restackNextPassTime = 0

    MutePickupSounds()
    return true
end

function SortEngine:RestackBank(callback)
    if InCombatLockdown() then return false end

    local BankScanner = ns:GetModule("BankScanner")
    if not BankScanner or not BankScanner:IsBankOpen() then
        return false
    end

    if sortInProgress or restackInProgress then
        return false
    end

    restackInProgress = true
    restackBagIDs = Constants.BANK_BAG_IDS
    restackCallback = callback
    restackPassCount = 0
    restackNextPassTime = 0

    MutePickupSounds()
    return true
end

function SortEngine:RestackWarbandBank(callback)
    if InCombatLockdown() then return false end

    local BankScanner = ns:GetModule("BankScanner")
    if not BankScanner or not BankScanner:IsBankOpen() then
        return false
    end

    if not Expansion.IsRetail or not Constants.WARBAND_BANK_TAB_IDS then
        return false
    end

    if sortInProgress or restackInProgress then
        return false
    end

    restackInProgress = true
    restackBagIDs = Constants.WARBAND_BANK_TAB_IDS
    restackCallback = callback
    restackPassCount = 0
    restackNextPassTime = 0

    MutePickupSounds()
    return true
end

function SortEngine:IsRestacking()
    return restackInProgress
end
