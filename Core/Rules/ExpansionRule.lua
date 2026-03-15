local addonName, ns = ...

local RuleEngine = ns:GetModule("RuleEngine")

-------------------------------------------------
-- Expansion Rule
-- Matches item expansion ID (expacID from GetItemInfo)
-- Locale-independent: uses numeric IDs
-------------------------------------------------

-- Expansion ID constants (from Blizzard API GetItemInfo return #15)
local EXPANSION_IDS = {
    CLASSIC     = 0,
    TBC         = 1,
    WOTLK       = 2,
    CATA        = 3,
    MOP         = 4,
    WOD         = 5,
    LEGION      = 6,
    BFA         = 7,
    SHADOWLANDS = 8,
    DRAGONFLIGHT = 9,
    TWW         = 10,  -- The War Within
    MIDNIGHT    = 11,   -- Midnight
}

-- Get current expansion ID based on interface version
local function GetCurrentExpansionID()
    local _, _, _, interfaceVersion = GetBuildInfo()
    if interfaceVersion >= 120000 then return 11 end  -- Midnight
    if interfaceVersion >= 110000 then return 10 end  -- TWW
    if interfaceVersion >= 100000 then return 9  end  -- Dragonflight
    if interfaceVersion >= 90000  then return 8  end  -- Shadowlands
    if interfaceVersion >= 80000  then return 7  end  -- BFA
    if interfaceVersion >= 70000  then return 6  end  -- Legion
    if interfaceVersion >= 60000  then return 5  end  -- WoD
    if interfaceVersion >= 50000  then return 4  end  -- MoP
    if interfaceVersion >= 40000  then return 3  end  -- Cata
    if interfaceVersion >= 30000  then return 2  end  -- WotLK
    if interfaceVersion >= 20000  then return 1  end  -- TBC
    return 0  -- Classic
end

local CURRENT_EXPANSION_ID = GetCurrentExpansionID()

-- Export for other modules
ns.EXPANSION_IDS = EXPANSION_IDS
ns.CURRENT_EXPANSION_ID = CURRENT_EXPANSION_ID

-------------------------------------------------
-- Expansion name mapping (English keys for rules)
-------------------------------------------------

local EXPANSION_NAME_TO_ID = {
    ["Classic"]       = 0,
    ["TBC"]           = 1,
    ["WotLK"]         = 2,
    ["Cataclysm"]     = 3,
    ["MoP"]           = 4,
    ["WoD"]           = 5,
    ["Legion"]        = 6,
    ["BfA"]           = 7,
    ["Shadowlands"]   = 8,
    ["Dragonflight"]  = 9,
    ["The War Within"] = 10,
    ["Midnight"]      = 11,
}

-------------------------------------------------
-- Rule: expansion (exact match)
-- Value: expansion name string or numeric ID
-------------------------------------------------

RuleEngine:RegisterEvaluator("expansion", function(ruleValue, itemData, context)
    local itemExpac = itemData.expacID
    if itemExpac == nil then return false end

    -- Support numeric value directly
    if type(ruleValue) == "number" then
        return itemExpac == ruleValue
    end

    -- Support string name
    local expectedID = EXPANSION_NAME_TO_ID[ruleValue]
    if expectedID then
        return itemExpac == expectedID
    end

    return false
end)

-------------------------------------------------
-- Rule: isCurrentExpansion
-- Value: true = current expansion, false = old expansions
-------------------------------------------------

RuleEngine:RegisterEvaluator("isCurrentExpansion", function(ruleValue, itemData, context)
    local itemExpac = itemData.expacID
    if itemExpac == nil then return false end

    local isCurrent = (itemExpac == CURRENT_EXPANSION_ID)
    return isCurrent == ruleValue
end)
