local addonName, ns = ...

local Constants = {}
ns.Constants = Constants

-- Get Expansion module (loaded before Constants)
local Expansion = ns:GetModule("Expansion")

-- Feature flags (enable/disable features during development)
-- KEYRING is TBC-only (keyring was removed in later expansions)
-- GUILD_BANK is available in TBC and later (introduced in TBC, interface 20000+)
-- Not available in Classic Era (interface 11xxx)
local isGuildBankSupported = false
if Expansion and not Expansion.IsClassicEra then
    -- Guild bank available in TBC+, check interface version >= 20000
    if Expansion.InterfaceVersion and Expansion.InterfaceVersion >= 20000 then
        isGuildBankSupported = true
    end
end

Constants.FEATURES = {
    BANK = true,
    GUILD_BANK = isGuildBankSupported,
    MAIL = true,
    CHARACTERS = true,
    SEARCH = true,
    SORT = true,
    KEYRING = Expansion and Expansion.IsTBC or false,
}

-- Guild Bank Constants (TBC and later)
Constants.GUILD_BANK_MAX_TABS = 6
Constants.GUILD_BANK_SLOTS_PER_TAB = 98  -- 14 columns x 7 rows

-- Bag ID Ranges (differ between retail and classic)
Constants.PLAYER_BAG_MIN = 0
if Expansion and Expansion.IsRetail then
    -- Retail: bags 0-4 (backpack + 4 equipped bags) + reagent bag (5)
    Constants.PLAYER_BAG_MAX = 4
    Constants.REAGENT_BAG = 5  -- Retail only
    -- Check if modern bank tabs are active (TWW and later)
    Constants.CHARACTER_BANK_TABS_ACTIVE = Enum and Enum.BagIndex and Enum.BagIndex.CharacterBankTab_1 ~= nil
    if Constants.CHARACTER_BANK_TABS_ACTIVE then
        -- Modern Retail: Each bank tab is a separate container
        Constants.BANK_BAG_MIN = Enum.BagIndex.CharacterBankTab_1
        Constants.BANK_BAG_MAX = Enum.BagIndex.CharacterBankTab_6 or Enum.BagIndex.CharacterBankTab_5
    else
        -- Older Retail: traditional bank + bank bags
        Constants.BANK_BAG_MIN = 6
        Constants.BANK_BAG_MAX = 12
    end
else
    -- Classic: bags 0-4 (backpack + 4 equipped bags)
    Constants.PLAYER_BAG_MAX = 4
    Constants.BANK_BAG_MIN = 5
    Constants.BANK_BAG_MAX = 11
    Constants.CHARACTER_BANK_TABS_ACTIVE = false
end
Constants.BANK_MAIN_BAG = -1

-- Keyring bag ID (Classic Era and TBC only, nil for other expansions)
Constants.KEYRING_BAG = Expansion and (Expansion.IsClassicEra or Expansion.IsTBC) and -2 or nil

-- Warband Bank (Retail only)
Constants.WARBAND_BANK_ACTIVE = Expansion and Expansion.IsRetail and Enum.BagIndex.AccountBankTab_1 ~= nil
Constants.WARBAND_BANK_TAB_IDS = {}
if Constants.WARBAND_BANK_ACTIVE then
    for i = 1, 5 do
        local tabIndex = Enum.BagIndex["AccountBankTab_" .. i]
        if tabIndex then
            table.insert(Constants.WARBAND_BANK_TAB_IDS, tabIndex)
        end
    end
end

-- Bag ID Arrays (derived from ranges for convenience)
if Expansion and Expansion.IsRetail then
    -- Retail: include reagent bag in player bags
    Constants.BAG_IDS = {0, 1, 2, 3, 4, 5}
    if Constants.CHARACTER_BANK_TABS_ACTIVE then
        -- Modern Retail: Bank tabs are separate containers
        Constants.BANK_BAG_IDS = {}
        Constants.CHARACTER_BANK_TAB_IDS = {}
        for i = 1, 6 do
            local tabIndex = Enum.BagIndex["CharacterBankTab_" .. i]
            if tabIndex then
                table.insert(Constants.BANK_BAG_IDS, tabIndex)
                table.insert(Constants.CHARACTER_BANK_TAB_IDS, tabIndex)
            end
        end
    else
        -- Older Retail: traditional bank + bank bags
        Constants.BANK_BAG_IDS = {-1, 6, 7, 8, 9, 10, 11, 12}
    end
else
    -- Classic
    Constants.BAG_IDS = {0, 1, 2, 3, 4}
    Constants.BANK_BAG_IDS = {-1, 5, 6, 7, 8, 9, 10, 11}
end
Constants.BANK_BAG_ID = -1

-- Keyring bag ID (Classic Era and TBC only, nil for other expansions)
Constants.KEYRING_BAG_ID = Expansion and (Expansion.IsClassicEra or Expansion.IsTBC) and -2 or nil

Constants.HEARTHSTONE_ID = 6948

-- Item IDs to ignore for quest item indicator
-- These items have itemType="Quest" but shouldn't show quest borders/icons
Constants.QUEST_INDICATOR_IGNORE = {
    -- Hakkari Bijou (Zul'Gurub reputation items)
    [19707] = true,  -- Blue Hakkari Bijou
    [19708] = true,  -- Bronze Hakkari Bijou
    [19709] = true,  -- Gold Hakkari Bijou
    [19710] = true,  -- Green Hakkari Bijou
    [19711] = true,  -- Orange Hakkari Bijou
    [19712] = true,  -- Purple Hakkari Bijou
    [19713] = true,  -- Red Hakkari Bijou
    [19714] = true,  -- Silver Hakkari Bijou
    [19715] = true,  -- Yellow Hakkari Bijou
}

-- Custom quest items to show in Quest Bar even without "Quest Item" tooltip text
-- These items are usable quest-related items that should appear in the quest bar
Constants.CUSTOM_QUEST_ITEMS = {
    [24287] = true,  -- Extinguishing Mixture
    [24501] = true,  -- Gordawg's Boulder
    [28038] = true,  -- Seaforium PU-36 Explosive Nether Modulator
    [28132] = true,  -- Area 52 Special
    [25465] = true,  -- Stormcrow Amulet
    [24355] = true,  -- Ironvine Seeds
    [25658] = true,  -- Damp Woolen Blanket
    [25555] = true,  -- Kil'sorrow Banner
    [25552] = true,  -- Warmaul Ogre Banner
    [31310] = true,  -- Wildhammer Flare Gun (Shadowmoon Valley, Alliance)
    [31108] = true,  -- Kor'kron Flare Gun (Shadowmoon Valley, Horde)
    [30652] = true,  -- Dertrok's Second Wand (Blade's Edge Mountains)
    [25853] = true,  -- Pack of Incendiary Bombs (Old Hillsbrad Foothills)
}

Constants.QUALITY_COLORS = {
    [0] = {0.62, 0.62, 0.62},  -- Poor (gray)
    [1] = {1.00, 1.00, 1.00},  -- Common (white)
    [2] = {0.12, 1.00, 0.00},  -- Uncommon (green)
    [3] = {0.00, 0.44, 0.87},  -- Rare (blue)
    [4] = {0.64, 0.21, 0.93},  -- Epic (purple)
    [5] = {1.00, 0.50, 0.00},  -- Legendary (orange)
    [6] = {0.90, 0.80, 0.50},  -- Artifact (light gold)
    [7] = {0.00, 0.80, 1.00},  -- Heirloom (light blue)
}

Constants.COLORS = {
    GOLD = {1.00, 0.82, 0.00},
    SILVER = {0.75, 0.75, 0.75},
    COPPER = {0.72, 0.45, 0.20},
    RED = {1.00, 0.20, 0.20},
    GREEN = {0.20, 1.00, 0.20},
    CYAN = {0.00, 0.80, 1.00},
    GRAY = {0.50, 0.50, 0.50},
    WHITE = {1.00, 1.00, 1.00},
    QUEST = {1.00, 0.80, 0.00},  -- Quest item golden yellow
    QUEST_STARTER = {1.00, 0.60, 0.00},  -- Quest starter orange
}

Constants.FRAME = {
    TITLE_HEIGHT = 24,
    SEARCH_BAR_HEIGHT = 20,
    CHIP_STRIP_HEIGHT = 22,
    CHIP_SIZE = 14,
    CHIP_SPACING = 3,
    FOOTER_HEIGHT = 32,
    PADDING = 8,
    BORDER_SIZE = 2,
    MIN_WIDTH = 125,
    MAX_WIDTH = 800,
    MIN_HEIGHT = 150,
    MAX_HEIGHT = 600,
    BANK_MIN_HEIGHT = 260,
    BANK_MIN_HEIGHT_RETAIL = 340,
    GUILD_BANK_MIN_WIDTH = 260,
    GUILD_BANK_MIN_HEIGHT = 340,
}

-- Frame level hierarchy for z-ordering between bag/bank frames.
-- The gap between BASE and RAISED must exceed the total child offset
-- (CONTAINER + BUTTON + highest button child) so the inactive frame's
-- content never bleeds through the active frame's background.
-- Total child depth from container: wrapper(1) + BUTTON + max(BORDER,COOLDOWN,QUEST_ICON)
-- Must be strictly less than RAISED - BASE - CONTAINER so the inactive
-- frame's content never bleeds through the active frame's background.
Constants.FRAME_LEVELS = {
    BASE            = 50,  -- Inactive bag/bank frame
    CONTAINER       = 1,   -- Secure container / scroll child above its frame
    RAISED          = 60,  -- Active (focused) bag/bank frame
    -- Offsets relative to parent / button
    BUTTON          = 2,   -- Item button above its wrapper
    BORDER          = 1,   -- Quality border above its button
    COOLDOWN        = 2,   -- Cooldown sweep above border
    QUEST_ICON      = 3,   -- Quest icon above cooldown
    HEADER          = 5,   -- Header above blizzardBg NineSlice
}

Constants.BAG_SLOT_SIZE = 20
Constants.FLYOUT_BAG_SIZE = 32
Constants.BANK_BAG_SLOT_SIZE = 24
Constants.BANK_BAG_COUNT = 7
Constants.SECTION_SPACING = 6

-- Split view settings
Constants.SPLIT_VIEW = {
    BLOCK_GAP = 8,
    BLOCK_SPACING = 8,
    HEADER_HEIGHT = 20,
    BLOCK_BG_ALPHA = 0.04,
    BLOCK_BORDER_ALPHA = 0.1,
}

-- Category view settings
Constants.CATEGORY_GAP_SMALL_ICONS = 20  -- Gap when icon size < threshold
Constants.CATEGORY_GAP_LARGE_ICONS = 18  -- Gap when icon size >= threshold
Constants.CATEGORY_FONT_SMALL = 9        -- Font size when icon size < threshold
Constants.CATEGORY_FONT_LARGE = 10       -- Font size when icon size >= threshold
Constants.CATEGORY_ICON_SIZE_THRESHOLD = 28

Constants.DEFAULTS = {
    -- General
    theme = "guda",
    bagColumns = 10,
    bankColumns = 15,
    guildBankColumns = 15,
    splitBagColumns = 2,
    splitBankColumns = 2,
    splitFullWidthBackpack = true,
    splitFullWidthReagent = true,
    splitFullWidthKeyring = true,
    bgAlpha = 85,
    locked = false,
    showBorders = true,
    showSearchBar = true,
    showFilterChips = false,
    showQuestBar = true,
    hideQuestBarInBGs = true,
    hoverBagline = false,
    showFooter = true,
    showTooltipCounts = true,
    goldTrackAllRealms = false,  -- Show gold from all realms in money tooltip (Retail only)
    bagViewType = "single",
    bankViewType = "single",
    showCategoryCount = true,
    groupIdenticalItems = false,  -- Group identical items into single slot in category view
    showEquipSetCategories = true,  -- Show equipment set items as named categories
    mergedGroups = {},  -- Per-group merge settings: { ["Main"] = true, ["Other"] = false }
    recentDuration = 15,  -- Minutes items stay in Recent category
    showSoulBag = true,  -- Show soul bag in single view (Warlock only)
    autoOpenBags = true,  -- Auto open bags when interacting with mail, trade, AH, bank, guild bank
    autoCloseBags = true,  -- Auto close bags when ending those interactions
    autoVendorJunk = true,  -- Auto sell gray items at merchants
    autoRepair = false,  -- Auto repair all items at repair-capable merchants
    retailEmptySlots = false,  -- Use retail-style empty slot textures (Classic only)
    minimalEmptySlots = false,  -- Show empty slots as thin border outline instead of slot icon
    gudaSort = false,  -- Use GudaBags custom sort engine instead of Blizzard's (Retail only)

    -- Icons
    iconSize = 37,
    iconFontSize = 12,
    iconSpacing = 3,
    questBarSize = 44,
    questBarColumns = 1,
    questBarSpacing = 2,
    trackedBarSize = 36,
    trackedBarColumns = 3,
    trackedBarSpacing = 3,
    grayoutJunk = true,
    whiteItemsJunk = false,  -- Treat white equippable items as junk (off by default)
    equipmentBorders = true,
    otherBorders = true,
    markUnusableItems = true,
    markEquipmentSets = true,
    autoLockSetItems = true,  -- Prevent selling/deleting equipment set items
    showItemLevel = true,
    reverseStackSort = false,
    sortRightToLeft = false,
    smoothSort = false,  -- Spread sort moves across frames to avoid stuttering

    -- Bag frame position
    framePoint = nil,
    frameRelativePoint = nil,
    frameX = nil,
    frameY = nil,

    -- Bank frame position
    bankFramePoint = nil,
    bankFrameRelativePoint = nil,
    bankFrameX = nil,
    bankFrameY = nil,

    -- Guild Bank frame position
    guildBankFramePoint = nil,
    guildBankFrameRelativePoint = nil,
    guildBankFrameX = nil,
    guildBankFrameY = nil,
}

Constants.ICON = {
    BORDER_THICKNESS = 2,
}

Constants.BACKDROP = {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 14,
    insets = {left = 3, right = 3, top = 3, bottom = 3},
}

Constants.BACKDROP_SOLID = {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
    insets = {left = 0, right = 0, top = 0, bottom = 0},
}

-------------------------------------------------
-- Textures
-------------------------------------------------
Constants.TEXTURES = {
    WHITE_8x8 = "Interface\\Buttons\\WHITE8x8",
    TOOLTIP_BORDER = "Interface\\Tooltips\\UI-Tooltip-Border",
    CURSOR_MOVE = "Interface\\CURSOR\\UI-Cursor-Move",
    GROUP_ICON = "Interface\\Icons\\INV_Misc_GroupLooking",
    COLLAPSE_EXPAND = "Interface\\Buttons\\UI-PlusButton-Up",
    COLLAPSE_EXPAND_MINUS = "Interface\\Buttons\\UI-MinusButton-Up",
}

-------------------------------------------------
-- Category UI Constants
-------------------------------------------------
Constants.CATEGORY_UI = {
    -- Row dimensions
    ROW_HEIGHT = 28,
    GROUP_HEADER_HEIGHT = 26,
    DROP_ZONE_HEIGHT = 12,
    HEADER_HEIGHT = 20,

    -- Settings popup
    POPUP_WIDTH = 520,
    POPUP_HEIGHT = 565,
    POPUP_PADDING = 16,

    -- Editor
    EDITOR_WIDTH = 420,
    EDITOR_HEIGHT = 516,
    EDITOR_PADDING = 12,
    RULE_ROW_HEIGHT = 34,

    -- Timing
    SAVE_DEBOUNCE_TIME = 0.3,
}

-------------------------------------------------
-- Category UI Colors
-------------------------------------------------
Constants.CATEGORY_COLORS = {
    -- Drop indicator
    DROP_INDICATOR = {0.2, 0.6, 1, 0.8},
    DROP_ZONE_ACTIVE = {0.2, 0.5, 0.8, 0.3},

    -- Group headers
    GROUP_HEADER_BG = {0.15, 0.25, 0.4, 0.8},
    GROUP_HEADER_HOVER = {0.2, 0.35, 0.5, 0.9},
    GROUP_NAME_TEXT = {0.7, 0.9, 1, 1},

    -- Category rows
    ROW_EVEN = {0.12, 0.12, 0.12, 0.5},
    ROW_ODD = {0.08, 0.08, 0.08, 0.5},
    ROW_HOVER = {0.18, 0.18, 0.18, 0.7},
    ROW_DISABLED = {0.5, 0.5, 0.5, 1},

    -- Text
    CATEGORY_NAME = {1, 1, 1, 1},
    CATEGORY_NAME_DISABLED = {0.5, 0.5, 0.5, 1},
    BUILTIN_BADGE = {0.6, 0.6, 0.6, 1},
}

-------------------------------------------------
-- Category System Constants
-------------------------------------------------
Constants.CATEGORY = {
    -- Default priorities
    PRIORITY_HOME = 100,
    PRIORITY_CUSTOM = 95,
    PRIORITY_CLASS_ITEMS = 90,
    PRIORITY_JUNK = 85,
    PRIORITY_QUEST = 80,
    PRIORITY_BOE = 75,
    PRIORITY_EQUIPMENT = 70,
    PRIORITY_TOOLS = 60,
    PRIORITY_CONSUMABLE = 50,
    PRIORITY_CONTAINER = 45,
    PRIORITY_TRADE_GOODS = 40,
    PRIORITY_FALLBACK = 0,

    -- Default groups
    GROUP_MAIN = "Main",
    GROUP_OTHER = "Other",
    GROUP_CLASS = "Class",

    -- Match modes
    MATCH_ANY = "any",
    MATCH_ALL = "all",
}

-------------------------------------------------
-- Profession Tool Item IDs
-------------------------------------------------
Constants.PROFESSION_TOOL_IDS = {
    -- Mining
    [2901] = true,   -- Mining Pick
    [778] = true,    -- Kobold Mining Shovel
    -- Skinning
    [7005] = true,   -- Skinning Knife
    [12709] = true,  -- Finkle's Skinner
    -- Herbalism
    [19727] = true,  -- Blood Scythe
    -- Blacksmithing
    [5956] = true,   -- Blacksmith Hammer
    -- Engineering
    [6219] = true,   -- Arclight Spanner
    [10498] = true,  -- Gyromatic Micro-Adjustor
    -- Alchemy
    [9149] = true,   -- Philosopher's Stone
    [13503] = true,  -- Alchemist's Stone
    -- Jewelcrafting
    [20815] = true,  -- Jeweler's Kit
    [20824] = true,  -- Simple Grinder
    -- Enchanting Rods
    [6218] = true,   -- Runed Copper Rod
    [6339] = true,   -- Runed Silver Rod
    [11130] = true,  -- Runed Golden Rod
    [11145] = true,  -- Runed Truesilver Rod
    [16207] = true,  -- Runed Arcanite Rod
    [22461] = true,  -- Runed Fel Iron Rod
    [22462] = true,  -- Runed Adamantite Rod
    [22463] = true,  -- Runed Eternium Rod
}

-------------------------------------------------
-- Valuable Equip Slots (never considered junk)
-------------------------------------------------
Constants.VALUABLE_EQUIP_SLOTS = {
    ["INVTYPE_TRINKET"] = true,
    ["INVTYPE_FINGER"] = true,
    ["INVTYPE_NECK"] = true,
    ["INVTYPE_HOLDABLE"] = true,
    ["INVTYPE_RELIC"] = true,
    ["INVTYPE_BODY"] = true,      -- Shirt
    ["INVTYPE_TABARD"] = true,    -- Tabard
}

-------------------------------------------------
-- Fonts
-------------------------------------------------
Constants.FONTS = {
    DEFAULT = "Fonts\\FRIZQT__.TTF",
}

-------------------------------------------------
-- Color Thresholds (for tooltip text analysis)
-------------------------------------------------
Constants.COLOR_THRESHOLDS = {
    RED = { min_r = 0.85, max_g = 0.3, max_b = 0.3 },
    GREEN = { max_r = 0.2, min_g = 0.9, max_b = 0.2 },
    YELLOW = { min_r = 0.9, min_g = 0.7, max_b = 0.2 },
}

-------------------------------------------------
-- Pickup Sound IDs (muted during sorting)
-------------------------------------------------
Constants.PICKUP_SOUND_IDS = {
    -- Standard pickup sounds
    567542, 567543, 567544, 567545, 567546, 567547, 567548, 567549,
    567550, 567551, 567552, 567553, 567554, 567555, 567556, 567557,
    567558, 567559, 567560, 567561, 567562, 567563, 567564, 567565,
    567566, 567567, 567568, 567569, 567570, 567571, 567572, 567573,
    567574, 567575, 567576, 567577,
    -- Additional pickup sounds
    2308876, 2308881, 2308889, 2308894, 2308901, 2308907, 2308914, 2308920,
    2308925, 2308930, 2308935, 2308942, 2308948, 2308956, 2308962, 2308968,
    2308974, 2308985, 2308992, 2309001, 2309006, 2309013, 2309025, 2309036,
    2309051, 2309057, 2309070, 2309078, 2309089, 2309100, 2309109, 2309120,
    2309126, 2309132, 2309137, 2309141
}
