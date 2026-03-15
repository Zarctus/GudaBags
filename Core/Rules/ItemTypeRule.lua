local addonName, ns = ...

local RuleEngine = ns:GetModule("RuleEngine")
local Utils = ns:GetModule("Utils")

-------------------------------------------------
-- Item Type Rule
-- Uses numeric classID for locale-independent matching.
-- Rule values use English names (Armor, Weapon, etc.)
-- which are mapped to classID constants.
-------------------------------------------------

-- Map English item type names to WoW Enum.ItemClass values
local ITEM_TYPE_TO_CLASS_ID = {
    ["Consumable"]   = 0,
    ["Container"]    = 1,
    ["Weapon"]       = 2,
    ["Gem"]          = 3,
    ["Armor"]        = 4,
    ["Reagent"]      = 5,
    ["Projectile"]   = 6,
    ["Trade Goods"]  = 7,
    ["Recipe"]       = 9,
    ["Quiver"]       = 11,
    ["Quest"]        = 12,
    ["Key"]          = 13,
    ["Miscellaneous"] = 15,
    ["Glyph"]        = 16,
    ["Battle Pets"]  = 17,
    ["WoW Token"]    = 18,
}

RuleEngine:RegisterEvaluator("itemType", function(ruleValue, itemData, context)
    -- Profession tools should not match Weapon category
    if ruleValue == "Weapon" and Utils:IsProfessionTool(itemData) then
        return false
    end

    -- Use classID (numeric, locale-independent) for matching
    local expectedClassID = ITEM_TYPE_TO_CLASS_ID[ruleValue]
    if expectedClassID then
        return itemData.classID == expectedClassID
    end

    -- Fallback to string comparison for unknown types
    return itemData.itemType == ruleValue
end)

-------------------------------------------------
-- Item Subtype Rule
-- Uses subClassID when possible for locale-independent matching,
-- falls back to localized string comparison.
-------------------------------------------------

-- Map known English subtype names to {classID, subClassID} pairs
local SUBTYPE_TO_IDS = {
    ["Soul Bag"] = {1, 2},  -- Container > Soul Bag
}

RuleEngine:RegisterEvaluator("itemSubtype", function(ruleValue, itemData, context)
    -- Try locale-independent match via classID/subClassID
    local ids = SUBTYPE_TO_IDS[ruleValue]
    if ids then
        return itemData.classID == ids[1] and itemData.subClassID == ids[2]
    end

    -- Fallback to localized string comparison
    local subtype = itemData.itemSubType or ""

    if subtype == ruleValue then
        return true
    end

    if subtype:find(ruleValue, 1, true) then
        return true
    end

    return false
end)

-------------------------------------------------
-- Reagent Rule (Crafting Materials)
-- Trade Goods (classID 7) excluding Explosives (2) and Devices (3)
-------------------------------------------------

RuleEngine:RegisterEvaluator("isReagent", function(ruleValue, itemData, context)
    -- Reagent = Trade Goods (classID 7) excluding Explosives (subClassID 2) and Devices (subClassID 3)
    if itemData.classID == 7 then
        return itemData.subClassID ~= 2 and itemData.subClassID ~= 3
    end
    return false
end)
