local addonName, ns = ...

local SettingsSchema = {}
ns:RegisterModule("SettingsSchema", SettingsSchema)

-------------------------------------------------
-- General Tab Schema
-------------------------------------------------
function SettingsSchema.GetGeneral()
    local L = ns.L
    return {
        { type = "description", text = L["SETTINGS_GENERAL_DESCRIPTION"], height = 28 },
        { type = "separator", label = L["SETTINGS_SECTION_APPEARANCE"] },
        { type = "select", key = "theme", label = L["SETTINGS_THEME"], tooltip = L["SETTINGS_THEME_TIP"], options = (function()
            local opts = {
                { value = "guda", label = L["SETTINGS_THEME_GUDA"] },
                { value = "blizzard", label = L["SETTINGS_THEME_BLIZZARD"] },
            }
            if not ns.IsRetail then
                table.insert(opts, { value = "retail", label = L["SETTINGS_THEME_RETAIL"] })
            end
            return opts
        end)()},
        { type = "slider", key = "bgAlpha", label = L["SETTINGS_BG_OPACITY"], min = 0, max = 100, step = 5, format = "%" },
        { type = "slider", key = "borderOpacity", label = L["SETTINGS_BORDER_OPACITY"], min = 0, max = 100, step = 5, format = "%" },
        { type = "slider", key = "uiScale", label = L["SETTINGS_UI_SCALE"], tooltip = L["SETTINGS_UI_SCALE_TIP"], min = 50, max = 150, step = 5, format = "%" },
        { type = "row", children = {
            { type = "checkbox", key = "retailEmptySlots", label = L["SETTINGS_RETAIL_EMPTY_SLOTS"], tooltip = L["SETTINGS_RETAIL_EMPTY_SLOTS_TIP"],
              hidden = function() return ns.IsRetail end },
            { type = "checkbox", key = "minimalEmptySlots", label = L["SETTINGS_MINIMAL_EMPTY_SLOTS"], tooltip = L["SETTINGS_MINIMAL_EMPTY_SLOTS_TIP"] },
        }},

        { type = "separator", label = L["SETTINGS_SECTION_CUSTOM_BG"] },
        { type = "row", children = {
            { type = "slider", key = "bgColorR", label = L["SETTINGS_BG_RED"], min = 0, max = 255, step = 1, format = "" },
            { type = "slider", key = "bgColorG", label = L["SETTINGS_BG_GREEN"], min = 0, max = 255, step = 1, format = "" },
        }},
        { type = "slider", key = "bgColorB", label = L["SETTINGS_BG_BLUE"], min = 0, max = 255, step = 1, format = "" },
        { type = "description", text = L["SETTINGS_BG_COLOR_TIP"], height = 20 },

        { type = "separator", label = L["SETTINGS_SECTION_OPTIONS"] },
        { type = "row", children = {
            { type = "checkbox", key = "locked", label = L["SETTINGS_LOCK_WINDOW"], tooltip = L["SETTINGS_LOCK_WINDOW_TIP"] },
            { type = "checkbox", key = "showBorders", label = L["SETTINGS_SHOW_BORDERS"], tooltip = L["SETTINGS_SHOW_BORDERS_TIP"] },
        }},

        { type = "row", children = {
            { type = "checkbox", key = "hoverBagline", label = L["SETTINGS_SHOW_ALL_BAGS"], tooltip = L["SETTINGS_SHOW_ALL_BAGS_TIP"] },
            { type = "checkbox", key = "showTooltipCounts", label = L["SETTINGS_INVENTORY_COUNTS"], tooltip = L["SETTINGS_INVENTORY_COUNTS_TIP"] },
        }},
        { type = "row", children = {
            { type = "checkbox", key = "compactMode", label = L["SETTINGS_COMPACT_MODE"], tooltip = L["SETTINGS_COMPACT_MODE_TIP"] },
        }},

        { type = "separator", label = L["SETTINGS_SECTION_SORT"] },
        { type = "select", key = "categorySortOrder", label = L["SETTINGS_CATEGORY_SORT_ORDER"], tooltip = L["SETTINGS_CATEGORY_SORT_ORDER_TIP"], options = {
            { value = "quality", label = L["SETTINGS_SORT_BY_QUALITY"] },
            { value = "name", label = L["SETTINGS_SORT_BY_NAME"] },
            { value = "itemLevel", label = L["SETTINGS_SORT_BY_ILVL"] },
            { value = "type", label = L["SETTINGS_SORT_BY_TYPE"] },
        }},
        { type = "row", children = {
            { type = "checkbox", key = "gudaSort", label = L["SETTINGS_GUDA_SORT"], tooltip = L["SETTINGS_GUDA_SORT_TIP"],
              hidden = function() local Expansion = ns:GetModule("Expansion") return not (Expansion and Expansion.IsRetail) end },
            { type = "checkbox", key = "reverseStackSort", label = L["SETTINGS_REVERSE_STACK"], tooltip = L["SETTINGS_REVERSE_STACK_TIP"] },
        }},
        { type = "row", children = {
            { type = "checkbox", key = "sortRightToLeft", label = L["SETTINGS_SORT_RTL"], tooltip = L["SETTINGS_SORT_RTL_TIP"],
              hidden = function() local Expansion = ns:GetModule("Expansion")
                if not (Expansion and Expansion.IsRetail) then return false end
                return not ns:GetModule("Database"):GetSetting("gudaSort") end },
            { type = "checkbox", key = "smoothSort", label = L["SETTINGS_SMOOTH_SORT"], tooltip = L["SETTINGS_SMOOTH_SORT_TIP"],
              hidden = function() local Expansion = ns:GetModule("Expansion")
                if not (Expansion and Expansion.IsRetail) then return false end
                return not ns:GetModule("Database"):GetSetting("gudaSort") end },
        }},

        { type = "separator", label = L["SETTINGS_SECTION_AUTOMATION"] },
        { type = "row", children = {
            { type = "checkbox", key = "autoOpenBags", label = L["SETTINGS_AUTO_OPEN_BAGS"], tooltip = L["SETTINGS_AUTO_OPEN_BAGS_TIP"] },
            { type = "checkbox", key = "autoCloseBags", label = L["SETTINGS_AUTO_CLOSE_BAGS"], tooltip = L["SETTINGS_AUTO_CLOSE_BAGS_TIP"] },
        }},
        { type = "row", children = {
            { type = "checkbox", key = "autoVendorJunk", label = L["SETTINGS_AUTO_VENDOR_JUNK"], tooltip = L["SETTINGS_AUTO_VENDOR_JUNK_TIP"] },
            { type = "checkbox", key = "autoRepair", label = L["SETTINGS_AUTO_REPAIR"], tooltip = L["SETTINGS_AUTO_REPAIR_TIP"] },
        }},
        { type = "slider", key = "bagFullThreshold", label = L["SETTINGS_BAG_FULL_THRESHOLD"], tooltip = L["SETTINGS_BAG_FULL_THRESHOLD_TIP"], min = 0, max = 100, step = 5, format = "%" },
    }
end

-------------------------------------------------
-- Layout Tab Schema
-------------------------------------------------
function SettingsSchema.GetLayout()
    local L = ns.L
    return {
        { type = "separator", label = L["SETTINGS_SECTION_VIEW"] },
        { type = "select", key = "bagViewType", label = L["SETTINGS_BAG_VIEW"], tooltip = L["SETTINGS_BAG_VIEW_TIP"], options = {
            { value = "single", label = L["SETTINGS_VIEW_SINGLE"] },
            { value = "category", label = L["SETTINGS_VIEW_CATEGORY"] },
            { value = "split", label = L["SETTINGS_VIEW_SPLIT"] },
        }},
        { type = "select", key = "bankViewType", label = L["SETTINGS_BANK_VIEW"], tooltip = L["SETTINGS_BANK_VIEW_TIP"], options = {
            { value = "single", label = L["SETTINGS_VIEW_SINGLE"] },
            { value = "category", label = L["SETTINGS_VIEW_CATEGORY"] },
            { value = "split", label = L["SETTINGS_VIEW_SPLIT"] },
        }},

        { type = "separator", label = L["SETTINGS_SECTION_SPLIT"],
          hidden = function() local Database = ns:GetModule("Database")
            return Database:GetSetting("bagViewType") ~= "split" and Database:GetSetting("bankViewType") ~= "split" end },
        { type = "slider", key = "splitBagColumns", label = L["SETTINGS_SPLIT_BAG_COLUMNS"], min = 1, max = 3, step = 1,
          hidden = function() local Database = ns:GetModule("Database") return Database:GetSetting("bagViewType") ~= "split" end },
        { type = "slider", key = "splitBankColumns", label = L["SETTINGS_SPLIT_BANK_COLUMNS"], min = 1, max = 4, step = 1,
          hidden = function() local Database = ns:GetModule("Database") return Database:GetSetting("bankViewType") ~= "split" end },
        { type = "row", hidden = function() local Database = ns:GetModule("Database")
            return Database:GetSetting("bagViewType") ~= "split" and Database:GetSetting("bankViewType") ~= "split" end,
          children = {
            { type = "checkbox", key = "splitFullWidthBackpack", label = L["SETTINGS_SPLIT_FULL_WIDTH_BACKPACK"], tooltip = L["SETTINGS_SPLIT_FULL_WIDTH_BACKPACK_TIP"] },
            { type = "checkbox", key = "splitFullWidthReagent", label = L["SETTINGS_SPLIT_FULL_WIDTH_REAGENT"], tooltip = L["SETTINGS_SPLIT_FULL_WIDTH_REAGENT_TIP"],
              hidden = function() local Expansion = ns:GetModule("Expansion") return not (Expansion and Expansion.IsRetail) end },
            { type = "checkbox", key = "splitFullWidthKeyring", label = L["SETTINGS_SPLIT_FULL_WIDTH_KEYRING"], tooltip = L["SETTINGS_SPLIT_FULL_WIDTH_KEYRING_TIP"],
              hidden = function() local Expansion = ns:GetModule("Expansion") return Expansion and Expansion.IsRetail end },
        }},

        { type = "separator", label = L["SETTINGS_SECTION_COLUMNS"] },
        { type = "slider", key = "bagColumns", label = L["SETTINGS_BAG_COLUMNS"], min = 5, max = 22, step = 1 },
        { type = "slider", key = "bankColumns", label = L["SETTINGS_BANK_COLUMNS"], min = 5, max = 36, step = 1 },
        { type = "slider", key = "guildBankColumns", label = L["SETTINGS_GUILD_BANK_COLUMNS"], min = 10, max = 36, step = 1 },

        { type = "separator", label = L["SETTINGS_SECTION_OPTIONS"] },
        { type = "row", children = {
            { type = "checkbox", key = "showSearchBar", label = L["SETTINGS_SHOW_SEARCH"], tooltip = L["SETTINGS_SHOW_SEARCH_TIP"] },
            { type = "checkbox", key = "showFilterChips", label = L["SETTINGS_SHOW_FILTER_CHIPS"], tooltip = L["SETTINGS_SHOW_FILTER_CHIPS_TIP"] },
        }},
        { type = "row", children = {
            { type = "checkbox", key = "showFooter", label = L["SETTINGS_SHOW_FOOTER"], tooltip = L["SETTINGS_SHOW_FOOTER_TIP"] },
            { type = "checkbox", key = "showCategoryCount", label = L["SETTINGS_SHOW_CAT_COUNT"], tooltip = L["SETTINGS_SHOW_CAT_COUNT_TIP"] },
        }},

        { type = "row", children = {
            { type = "checkbox", key = "groupIdenticalItems", label = L["SETTINGS_GROUP_IDENTICAL"], tooltip = L["SETTINGS_GROUP_IDENTICAL_TIP"] },
            { type = "checkbox", key = "showEquipSetCategories", label = L["SETTINGS_EQUIP_SET_CATEGORIES"], tooltip = L["SETTINGS_EQUIP_SET_CATEGORIES_TIP"] },
        }},
        { type = "row", children = {
            { type = "checkbox", key = "sortByExpansion", label = L["SETTINGS_SORT_BY_EXPANSION"], tooltip = L["SETTINGS_SORT_BY_EXPANSION_TIP"],
              hidden = function() local Database = ns:GetModule("Database")
                return Database:GetSetting("bagViewType") ~= "category" and Database:GetSetting("bankViewType") ~= "category" end },
        }},

    }
end

-------------------------------------------------
-- Icons Tab Schema
-------------------------------------------------
function SettingsSchema.GetIcons()
    local L = ns.L
    return {
        { type = "separator", label = L["SETTINGS_SECTION_ICON"] },
        { type = "slider", key = "iconSize", label = L["SETTINGS_ICON_SIZE"], min = 22, max = 64, step = 1, format = "px" },
        { type = "slider", key = "iconFontSize", label = L["SETTINGS_ICON_FONT_SIZE"], min = 8, max = 20, step = 1, format = "px" },
        { type = "slider", key = "iconSpacing", label = L["SETTINGS_ICON_SPACING"], min = 0, max = 20, step = 1, format = "px" },

        { type = "separator", label = L["SETTINGS_SECTION_ICON_OPTIONS"] },
        { type = "row", children = {
            { type = "checkbox", key = "equipmentBorders", label = L["SETTINGS_QUALITY_BORDERS"], tooltip = L["SETTINGS_QUALITY_BORDERS_TIP"] },
            { type = "checkbox", key = "otherBorders", label = L["SETTINGS_OTHER_BORDERS"], tooltip = L["SETTINGS_OTHER_BORDERS_TIP"] },
        }},

        -- Row 2
        { type = "row", children = {
            { type = "checkbox", key = "markUnusableItems", label = L["SETTINGS_MARK_UNUSABLE"], tooltip = L["SETTINGS_MARK_UNUSABLE_TIP"] },
            { type = "checkbox", key = "grayoutJunk", label = L["SETTINGS_GRAYOUT_JUNK"], tooltip = L["SETTINGS_GRAYOUT_JUNK_TIP"] },
        }},

        -- Row 3 - Junk and equipment set options
        { type = "row", children = {
            { type = "checkbox", key = "whiteItemsJunk", label = L["SETTINGS_WHITE_JUNK"], tooltip = L["SETTINGS_WHITE_JUNK_TIP"] },
            { type = "checkbox", key = "markEquipmentSets", label = L["SETTINGS_MARK_EQUIP_SETS"], tooltip = L["SETTINGS_MARK_EQUIP_SETS_TIP"] },
        }},

        -- Row 4 - Item level
        { type = "row", children = {
            { type = "checkbox", key = "showItemLevel", label = L["SETTINGS_SHOW_ITEM_LEVEL"], tooltip = L["SETTINGS_SHOW_ITEM_LEVEL_TIP"] },
        }},
    }
end

-------------------------------------------------
-- Bar Tab Schema
-------------------------------------------------
function SettingsSchema.GetBar()
    local L = ns.L
    return {
        { type = "separator", label = L["SETTINGS_SECTION_QUEST_BAR"] },
        { type = "slider", key = "questBarSize", label = L["SETTINGS_QUEST_BAR_SIZE"], min = 22, max = 64, step = 1, format = "px" },
        { type = "slider", key = "questBarColumns", label = L["SETTINGS_QUEST_BAR_COLS"], min = 1, max = 5, step = 1 },
        { type = "slider", key = "questBarSpacing", label = L["SETTINGS_QUEST_BAR_SPACING"], min = 0, max = 12, step = 1, format = "px" },
        { type = "row", children = {
            { type = "checkbox", key = "showQuestBar", label = L["SETTINGS_SHOW_QUEST_BAR"], tooltip = L["SETTINGS_SHOW_QUEST_BAR_TIP"] },
            { type = "checkbox", key = "hideQuestBarInBGs", label = L["SETTINGS_HIDE_QUEST_BAR_BG"], tooltip = L["SETTINGS_HIDE_QUEST_BAR_BG_TIP"] },
        }},

        { type = "separator", label = L["SETTINGS_SECTION_TRACKED"] },
        { type = "slider", key = "trackedBarSize", label = L["SETTINGS_TRACKED_BAR_SIZE"], min = 22, max = 64, step = 1, format = "px" },
        { type = "slider", key = "trackedBarColumns", label = L["SETTINGS_TRACKED_BAR_COLS"], min = 2, max = 12, step = 1 },
        { type = "slider", key = "trackedBarSpacing", label = L["SETTINGS_TRACKED_BAR_SPACING"], min = 0, max = 12, step = 1, format = "px" },
    }
end

-- Backwards compatibility - these will be called as functions now
SettingsSchema.GENERAL = nil
SettingsSchema.LAYOUT = nil
SettingsSchema.ICONS = nil

return SettingsSchema
