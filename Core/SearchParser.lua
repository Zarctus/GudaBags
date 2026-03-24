local addonName, ns = ...

local SearchParser = {}
ns:RegisterModule("SearchParser", SearchParser)

local Expansion = ns:GetModule("Expansion")

-------------------------------------------------
-- Profession → Trade Goods subClassID mapping
-- Trade Goods classID = 7
-- WoW Retail skillLineID → subClassIDs that profession uses
-------------------------------------------------

-- skillLineID constants for primary professions
local PROF_ALCHEMY       = 171
local PROF_BLACKSMITHING  = 164
local PROF_ENCHANTING     = 333
local PROF_ENGINEERING    = 202
local PROF_HERBALISM      = 182
local PROF_INSCRIPTION    = 773
local PROF_JEWELCRAFTING  = 755
local PROF_LEATHERWORKING = 165
local PROF_MINING         = 186
local PROF_SKINNING       = 393
local PROF_TAILORING      = 197

-- Secondary professions
local PROF_COOKING        = 185
local PROF_FISHING        = 356

-- Trade Goods (classID 7) subClassID → set of professions that use them
-- SubClassIDs: 1=Parts, 4=Jewelcrafting, 5=Cloth, 6=Leather, 7=Metal&Stone,
--              8=Cooking, 9=Herb, 10=Elemental, 11=Other, 12=Enchanting,
--              16=Inscription, 18=OptionalReagents
local TRADEGOODS_SUBCLASS_TO_PROFESSIONS = {
    [1]  = {[PROF_ENGINEERING] = true},                                     -- Parts
    [4]  = {[PROF_JEWELCRAFTING] = true},                                   -- Jewelcrafting
    [5]  = {[PROF_TAILORING] = true},                                       -- Cloth
    [6]  = {[PROF_LEATHERWORKING] = true, [PROF_SKINNING] = true},          -- Leather
    [7]  = {[PROF_BLACKSMITHING] = true, [PROF_MINING] = true, [PROF_ENGINEERING] = true, [PROF_JEWELCRAFTING] = true}, -- Metal & Stone
    [8]  = {[PROF_COOKING] = true},                                         -- Cooking
    [9]  = {[PROF_ALCHEMY] = true, [PROF_INSCRIPTION] = true, [PROF_HERBALISM] = true}, -- Herb
    [12] = {[PROF_ENCHANTING] = true},                                      -- Enchanting
    [16] = {[PROF_INSCRIPTION] = true},                                     -- Inscription
}
-- SubClassIDs 0, 2, 3, 10, 11, 18 are generic/cross-profession — never flagged as "not my prof"
local TRADEGOODS_GENERIC_SUBCLASS = {
    [0] = true, [2] = true, [3] = true, [10] = true, [11] = true, [18] = true,
}

-- Also handle Reagent classID = 5 as generic crafting material (never flagged)
-- Also handle Recipe classID = 9 subClassID maps similarly
local RECIPE_SUBCLASS_TO_PROFESSIONS = {
    [1]  = {[PROF_LEATHERWORKING] = true},
    [2]  = {[PROF_TAILORING] = true},
    [3]  = {[PROF_ENGINEERING] = true},
    [4]  = {[PROF_BLACKSMITHING] = true},
    [5]  = {[PROF_COOKING] = true},
    [6]  = {[PROF_ALCHEMY] = true},
    [8]  = {[PROF_ENCHANTING] = true},
    [10] = {[PROF_JEWELCRAFTING] = true},
    [11] = {[PROF_INSCRIPTION] = true},
}

-- Cached set of the player's profession skillLineIDs
local playerProfessionCache = nil
local profCacheFrame = nil

local function GetPlayerProfessions()
    if playerProfessionCache then return playerProfessionCache end

    local profs = {}

    local function AddProfession(idx)
        if not idx then return end
        local _, _, _, _, _, _, skillLineID = GetProfessionInfo(idx)
        if skillLineID then
            profs[skillLineID] = true
        end
    end

    if GetProfessions then
        local prof1, prof2, arch, fishing, cooking = GetProfessions()
        AddProfession(prof1)
        AddProfession(prof2)
        AddProfession(arch)
        AddProfession(fishing)
        AddProfession(cooking)
    end

    playerProfessionCache = profs

    -- Register invalidation on first call
    if not profCacheFrame then
        profCacheFrame = CreateFrame("Frame")
        profCacheFrame:RegisterEvent("SKILL_LINES_CHANGED")
        profCacheFrame:SetScript("OnEvent", function()
            playerProfessionCache = nil
        end)
    end

    return profs
end

-- Check if a Trade Goods item belongs to at least one of the player's professions
-- Returns true if the item is NOT used by any of the player's professions
local function IsTradeGoodNotMyProfession(itemData)
    local classID = itemData.classID
    local subClassID = itemData.subClassID or 0

    local profMap
    if classID == 7 then
        -- Trade Goods
        if TRADEGOODS_GENERIC_SUBCLASS[subClassID] then
            return false -- generic material, always considered "useful"
        end
        profMap = TRADEGOODS_SUBCLASS_TO_PROFESSIONS[subClassID]
    elseif classID == 9 then
        -- Recipes
        profMap = RECIPE_SUBCLASS_TO_PROFESSIONS[subClassID]
    else
        return false
    end

    -- Unknown subclass mapping = treat as generic (not flagged)
    if not profMap then return false end

    local myProfs = GetPlayerProfessions()
    for profID in pairs(profMap) do
        if myProfs[profID] then
            return false -- at least one of my professions uses this
        end
    end

    return true -- none of my professions use this
end

-------------------------------------------------
-- Quality Aliases (name → quality number)
-------------------------------------------------
local QUALITY_ALIASES = {
    poor = 0, gray = 0, grey = 0, junk = 0, trash = 0,
    common = 1, white = 1,
    uncommon = 2, green = 2,
    rare = 3, blue = 3,
    epic = 4, purple = 4,
    legendary = 5, orange = 5,
    artifact = 6,
    heirloom = 7,
}

-------------------------------------------------
-- Equipment Slot Aliases (alias → INVTYPE constant)
-------------------------------------------------
local SLOT_ALIASES = {
    head = "INVTYPE_HEAD", helm = "INVTYPE_HEAD", helmet = "INVTYPE_HEAD",
    neck = "INVTYPE_NECK", necklace = "INVTYPE_NECK", amulet = "INVTYPE_NECK",
    shoulder = "INVTYPE_SHOULDER", shoulders = "INVTYPE_SHOULDER",
    chest = "INVTYPE_CHEST", robe = "INVTYPE_ROBE",
    waist = "INVTYPE_WAIST", belt = "INVTYPE_WAIST",
    legs = "INVTYPE_LEGS", pants = "INVTYPE_LEGS", leggings = "INVTYPE_LEGS",
    feet = "INVTYPE_FEET", boots = "INVTYPE_FEET",
    wrist = "INVTYPE_WRIST", bracers = "INVTYPE_WRIST", bracer = "INVTYPE_WRIST",
    hands = "INVTYPE_HAND", gloves = "INVTYPE_HAND", hand = "INVTYPE_HAND",
    finger = "INVTYPE_FINGER", ring = "INVTYPE_FINGER",
    trinket = "INVTYPE_TRINKET",
    cloak = "INVTYPE_CLOAK", back = "INVTYPE_CLOAK", cape = "INVTYPE_CLOAK",
    mainhand = "INVTYPE_WEAPONMAINHAND", ["main hand"] = "INVTYPE_WEAPONMAINHAND",
    offhand = "INVTYPE_WEAPONOFFHAND", ["off hand"] = "INVTYPE_WEAPONOFFHAND",
    holdable = "INVTYPE_HOLDABLE",
    shield = "INVTYPE_SHIELD",
    ranged = "INVTYPE_RANGED", gun = "INVTYPE_RANGEDRIGHT", bow = "INVTYPE_RANGED",
    wand = "INVTYPE_RANGEDRIGHT",
    tabard = "INVTYPE_TABARD",
    shirt = "INVTYPE_BODY",
    weapon = "INVTYPE_WEAPON", ["one-hand"] = "INVTYPE_WEAPON", onehand = "INVTYPE_WEAPON",
    ["two-hand"] = "INVTYPE_2HWEAPON", twohand = "INVTYPE_2HWEAPON",
}

-------------------------------------------------
-- Type Aliases (short → full item type)
-------------------------------------------------
local TYPE_ALIASES = {
    wpn = "Weapon", weapon = "Weapon", weapons = "Weapon",
    arm = "Armor", armor = "Armor", armour = "Armor",
    con = "Consumable", consumable = "Consumable", consumables = "Consumable",
    trd = "Trade Goods", trade = "Trade Goods", tradegood = "Trade Goods", tradegoods = "Trade Goods",
    qst = "Quest", quest = "Quest",
    recipe = "Recipe", recipes = "Recipe",
    container = "Container", bag = "Container", bags = "Container",
    misc = "Miscellaneous", miscellaneous = "Miscellaneous",
    reagent = "Reagent", reagents = "Reagent",
    gem = "Gem", gems = "Gem",
    glyph = "Glyph", glyphs = "Glyph",
    projectile = "Projectile",
    quiver = "Quiver",
}

-------------------------------------------------
-- classID mapping for type operators (locale-independent)
-- Enum.ItemClass values: 0=Consumable, 2=Weapon, 4=Armor, etc.
-------------------------------------------------
local TYPE_TO_CLASSID = {
    ["consumable"] = 0,
    ["container"] = 1,
    ["weapon"] = 2,
    ["gem"] = 3,
    ["armor"] = 4,
    ["reagent"] = 5,
    ["projectile"] = 6,
    ["trade goods"] = 7,
    ["recipe"] = 9,
    ["quest"] = 12,
    ["miscellaneous"] = 15,
    ["glyph"] = 16,
}

-------------------------------------------------
-- Operator pattern: key<op>value
-- Supports: q:epic, q>=3, q>2, q<=4, q<5, q=3
-- Also: ilvl>200, lvl>60, t:weapon, st:leather, s:head, n:name
-------------------------------------------------

local strfind = string.find
local strlower = string.lower
local strsub = string.sub
local tonumber = tonumber

-- Parse a quality value (name or number) → quality integer or nil
local function ParseQuality(val)
    local num = tonumber(val)
    if num and num >= 0 and num <= 7 then
        return num
    end
    return QUALITY_ALIASES[strlower(val)]
end

-- Parse operator+value from ">=3", ">rare", "=epic", ":4", "<3", "<=2"
local function ParseComparison(rest)
    -- rest is everything after the operator key, e.g. ":epic", ">=3", ">200"
    local op, val

    if strsub(rest, 1, 2) == ">=" or strsub(rest, 1, 2) == "=>" then
        op, val = ">=", strsub(rest, 3)
    elseif strsub(rest, 1, 2) == "<=" or strsub(rest, 1, 2) == "=<" then
        op, val = "<=", strsub(rest, 3)
    elseif strsub(rest, 1, 1) == ">" then
        op, val = ">", strsub(rest, 2)
    elseif strsub(rest, 1, 1) == "<" then
        op, val = "<", strsub(rest, 2)
    elseif strsub(rest, 1, 1) == "=" then
        op, val = "=", strsub(rest, 2)
    elseif strsub(rest, 1, 1) == ":" then
        op, val = "=", strsub(rest, 2)
    else
        return nil, nil
    end

    return op, val
end

-- Compare two numbers with an operator string
local function CompareNum(actual, op, target)
    if not actual or not target then return false end
    if op == "=" then return actual == target end
    if op == ">=" then return actual >= target end
    if op == ">" then return actual > target end
    if op == "<=" then return actual <= target end
    if op == "<" then return actual < target end
    return false
end

-------------------------------------------------
-- Parse cache: avoid re-parsing the same search text
-------------------------------------------------
local parseCache = {}
local PARSE_CACHE_MAX = 32
local parseCacheCount = 0

function SearchParser:ClearCache()
    parseCache = {}
    parseCacheCount = 0
end

-------------------------------------------------
-- ParseSearchInput(text) → parsed result table
-------------------------------------------------
function SearchParser:ParseSearchInput(text)
    if not text or text == "" then
        return nil
    end

    -- Check cache first (search bar calls this on every keystroke)
    local cached = parseCache[text]
    if cached ~= nil then
        return cached  -- cached can be false (meaning nil result was cached)
    end

    local result = {
        textSearch = nil,     -- remaining plain text for substring matching
        operators = {},       -- array of {type, op, value} parsed operators
        keywords = {},        -- array of keyword strings (boe, quest, new, usable, junk)
    }

    local textParts = {}

    -- Tokenize: split by spaces, process each token
    for token in text:gmatch("%S+") do
        local tokenLower = strlower(token)
        local handled = false

        -- Check standalone keywords first
        if tokenLower == "boe" or tokenLower == "bop" or tokenLower == "quest"
            or tokenLower == "new" or tokenLower == "usable" or tokenLower == "junk" then
            table.insert(result.keywords, tokenLower)
            handled = true
        end

        -- Bare comparison: <230, >230, >=230, <=230, =230, =<230, =>230
        -- Defaults to itemLevel filtering (equipment only)
        if not handled then
            local op, val = ParseComparison(tokenLower)
            if op and val and val ~= "" then
                local num = tonumber(val)
                if num then
                    table.insert(result.operators, {type = "itemLevelEquip", op = op, value = num})
                    handled = true
                end
            end
        end

        if not handled then
            -- Try to parse as operator: key<comparison>value
            -- Patterns: q:epic, q>=3, ilvl>200, t:weapon, st:leather, s:head, n:text
            local key, rest

            -- Match key + rest (key is letters, rest starts with :, =, >, <)
            local s, e, k, r = strfind(token, "^(%a+)([><=:].+)$")
            if s then
                key = strlower(k)
                rest = r
            end

            if key then
                local op, val = ParseComparison(rest)
                if op and val and val ~= "" then
                    local valLower = strlower(val)

                    if key == "q" or key == "quality" then
                        local qVal = ParseQuality(val)
                        if qVal then
                            table.insert(result.operators, {type = "quality", op = op, value = qVal})
                            handled = true
                        end
                    elseif key == "t" or key == "type" then
                        local resolved = TYPE_ALIASES[valLower] or val
                        table.insert(result.operators, {type = "itemType", op = "=", value = strlower(resolved)})
                        handled = true
                    elseif key == "st" or key == "subtype" then
                        table.insert(result.operators, {type = "itemSubType", op = "=", value = valLower})
                        handled = true
                    elseif key == "ilvl" or key == "itemlevel" then
                        local num = tonumber(val)
                        if num then
                            table.insert(result.operators, {type = "itemLevel", op = op, value = num})
                            handled = true
                        end
                    elseif key == "lvl" or key == "level" or key == "reqlvl" then
                        local num = tonumber(val)
                        if num then
                            table.insert(result.operators, {type = "itemMinLevel", op = op, value = num})
                            handled = true
                        end
                    elseif key == "s" or key == "slot" then
                        local resolved = SLOT_ALIASES[valLower]
                        if resolved then
                            table.insert(result.operators, {type = "equipSlot", op = "=", value = resolved})
                            handled = true
                        end
                    elseif key == "n" or key == "name" then
                        table.insert(result.operators, {type = "name", op = "=", value = valLower})
                        handled = true
                    end
                end
            end
        end

        if not handled then
            table.insert(textParts, token)
        end
    end

    -- Join remaining parts as plain text search
    if #textParts > 0 then
        result.textSearch = strlower(table.concat(textParts, " "))
    end

    -- Return nil if nothing was parsed
    if not result.textSearch and #result.operators == 0 and #result.keywords == 0 then
        -- Cache nil result as false to distinguish from "not cached"
        if parseCacheCount >= PARSE_CACHE_MAX then
            parseCache = {}
            parseCacheCount = 0
        end
        parseCache[text] = false
        parseCacheCount = parseCacheCount + 1
        return nil
    end

    -- Cache the parsed result
    if parseCacheCount >= PARSE_CACHE_MAX then
        parseCache = {}
        parseCacheCount = 0
    end
    parseCache[text] = result
    parseCacheCount = parseCacheCount + 1

    return result
end

-------------------------------------------------
-- MatchOperator(operator, itemData) → boolean
-------------------------------------------------
function SearchParser:MatchOperator(operator, itemData)
    if not itemData then return false end

    local t = operator.type

    if t == "quality" then
        return CompareNum(itemData.quality or 0, operator.op, operator.value)

    elseif t == "itemType" then
        -- Use classID for locale-independent matching
        local targetClassID = TYPE_TO_CLASSID[operator.value]
        if targetClassID then
            return (itemData.classID or -1) == targetClassID
        end
        -- Fallback to string comparison for unknown types
        if not itemData.itemType then return false end
        return strlower(itemData.itemType) == operator.value

    elseif t == "itemSubType" then
        if not itemData.itemSubType then return false end
        return strfind(strlower(itemData.itemSubType), operator.value, 1, true) ~= nil

    elseif t == "itemLevel" then
        return CompareNum(itemData.itemLevel or 0, operator.op, operator.value)

    elseif t == "itemLevelEquip" then
        -- Bare comparison (e.g. <230): only applies to equippable items (Armor, Weapon)
        -- Non-equipment items pass through (return true = not filtered out)
        -- Use classID (locale-independent) instead of itemType string:
        --   classID 2 = Weapon, classID 4 = Armor
        local cid = itemData.classID
        if not cid or (cid ~= 2 and cid ~= 4) then return true end
        return CompareNum(itemData.itemLevel or 0, operator.op, operator.value)

    elseif t == "itemMinLevel" then
        return CompareNum(itemData.itemMinLevel or 0, operator.op, operator.value)

    elseif t == "equipSlot" then
        if not itemData.equipSlot or itemData.equipSlot == "" then return false end
        -- Handle multiple possible slot types (e.g. INVTYPE_WEAPON matches INVTYPE_WEAPON, INVTYPE_WEAPONMAINHAND, etc.)
        return itemData.equipSlot == operator.value

    elseif t == "name" then
        if not itemData.name then return false end
        return strfind(strlower(itemData.name), operator.value, 1, true) ~= nil
    end

    return false
end

-------------------------------------------------
-- MatchKeyword(keyword, itemData, context) → boolean
-- context: { tooltipScanner, recentItems }
-------------------------------------------------
function SearchParser:MatchKeyword(keyword, itemData, context)
    if not itemData then return false end

    if keyword == "boe" then
        -- Need tooltip scanner and bag/slot info
        if context and context.tooltipScanner and itemData.bagID and itemData.slot then
            return context.tooltipScanner:IsBindOnEquip(itemData.bagID, itemData.slot, itemData)
        end
        return false

    elseif keyword == "bop" then
        -- Soulbound items: already bound, so NOT BoE and has equip slot or is bound
        if itemData.quality and itemData.quality >= 2 then
            if context and context.tooltipScanner and itemData.bagID and itemData.slot then
                return not context.tooltipScanner:IsBindOnEquip(itemData.bagID, itemData.slot, itemData)
                    and (itemData.equipSlot and itemData.equipSlot ~= "")
            end
        end
        return false

    elseif keyword == "quest" then
        return itemData.isQuestItem == true
            or (itemData.classID and itemData.classID == 12)

    elseif keyword == "new" then
        if context and context.recentItems and itemData.itemID then
            return context.recentItems:IsRecent(itemData.itemID)
        end
        return false

    elseif keyword == "lowlevel" then
        -- Weapons/Armor whose item level is 20+ below equipped avg ilvl
        local classID = itemData.classID
        if classID ~= 2 and classID ~= 4 then return false end
        local ilvl = itemData.itemLevel
        if not ilvl or ilvl <= 0 then return false end
        local _, equipped = GetAverageItemLevel()
        if not equipped or equipped <= 0 then return false end
        return ilvl <= (equipped - 20)

    elseif keyword == "notmyprof" then
        -- Trade Goods / Recipes not used by any of the player's professions
        local classID = itemData.classID
        if classID ~= 7 and classID ~= 9 then return false end
        return IsTradeGoodNotMyProfession(itemData)

    elseif keyword == "myprof" then
        -- Trade Goods / Recipes used by at least one of the player's professions
        local classID = itemData.classID
        if classID ~= 7 and classID ~= 9 then return false end
        return not IsTradeGoodNotMyProfession(itemData)

    elseif keyword == "usable" then
        return itemData.isUsable == true

    elseif keyword == "junk" then
        return (itemData.quality or 0) == 0
    end

    return false
end

-------------------------------------------------
-- MatchesTextSearch(itemData, textSearch) → boolean
-- Plain substring match against name/type/subtype
-------------------------------------------------
function SearchParser:MatchesTextSearch(itemData, textSearch)
    if not textSearch or textSearch == "" then return true end
    if not itemData then return false end

    if itemData.name and strfind(strlower(itemData.name), textSearch, 1, true) then
        return true
    end
    if itemData.itemType and strfind(strlower(itemData.itemType), textSearch, 1, true) then
        return true
    end
    if itemData.itemSubType and strfind(strlower(itemData.itemSubType), textSearch, 1, true) then
        return true
    end

    return false
end

-------------------------------------------------
-- MatchesParsed(parsed, itemData, context) → boolean
-- Check all operators + keywords + text against one item
-------------------------------------------------
function SearchParser:MatchesParsed(parsed, itemData, context)
    if not parsed then return true end
    if not itemData then return false end

    -- All operators must match (AND)
    for _, op in ipairs(parsed.operators) do
        if not self:MatchOperator(op, itemData) then
            return false
        end
    end

    -- All keywords must match (AND)
    for _, kw in ipairs(parsed.keywords) do
        if not self:MatchKeyword(kw, itemData, context) then
            return false
        end
    end

    -- Text search must match
    if not self:MatchesTextSearch(itemData, parsed.textSearch) then
        return false
    end

    return true
end
