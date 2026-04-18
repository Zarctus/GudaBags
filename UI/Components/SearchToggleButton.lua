local addonName, ns = ...

local SearchToggleButton = {}
ns:RegisterModule("SearchToggleButton", SearchToggleButton)

local L = ns.L
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")
local IconButton = ns:GetModule("IconButton")

-- Create a search-toggle IconButton on `parent`, anchored to the left of
-- `opts.anchorButton`. Clicking it calls `ns:GetModule(opts.targetModule):ToggleSearchBar()`.
-- Button visibility tracks the `showSearchBar` setting (hidden when always-on).
-- opts = {
--   targetModule = "BagFrame",   -- module that implements ToggleSearchBar
--   anchorButton = <Button>,      -- anchor for SetPoint("RIGHT", anchor, "LEFT", -4, 0)
--   tooltip      = string,        -- optional, defaults to L["TOOLTIP_TOGGLE_SEARCH"]
-- }
function SearchToggleButton:Create(parent, opts)
    local button = IconButton:Create(parent, "search", {
        tooltip = opts.tooltip or L["TOOLTIP_TOGGLE_SEARCH"],
        onClick = function()
            local mod = ns:GetModule(opts.targetModule)
            if mod and mod.ToggleSearchBar then
                mod:ToggleSearchBar()
            end
        end,
    })
    if opts.anchorButton then
        button:SetPoint("RIGHT", opts.anchorButton, "LEFT", -4, 0)
    end
    if Database:GetSetting("showSearchBar") then
        button:Hide()
    end

    -- Keep visibility in sync with the "Always Show Search Bar" setting.
    -- Uses the button itself as the listener owner so each header gets its own callback.
    Events:Register("SETTING_CHANGED", function(event, key)
        if key == "showSearchBar" then
            if Database:GetSetting("showSearchBar") then
                button:Hide()
            else
                button:Show()
            end
        end
    end, button)

    return button
end
