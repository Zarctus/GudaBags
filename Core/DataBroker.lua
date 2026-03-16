local addonName, ns = ...

-- DataBroker plugin for minimap button integration
-- Requires LibDataBroker-1.1 (provided by many addons like Titan Panel, Broker2FuBar, etc.)
-- This is optional — if LDB is not available, no minimap button is created

local DataBroker = {}
ns:RegisterModule("DataBroker", DataBroker)

local ldb = nil
local dataObj = nil

function DataBroker:Initialize()
    -- Check if LibDataBroker exists (loaded by another addon)
    ldb = LibStub and LibStub("LibDataBroker-1.1", true)
    if not ldb then return end

    local L = ns.L
    local Constants = ns.Constants
    local Database = ns:GetModule("Database")
    local BagScanner = ns:GetModule("BagScanner")
    local Events = ns:GetModule("Events")

    dataObj = ldb:NewDataObject("GudaBags", {
        type = "data source",
        icon = "Interface\\AddOns\\GudaBags\\Assets\\bags.png",
        label = "GudaBags",
        text = "...",

        OnClick = function(_, button)
            if button == "LeftButton" then
                local BagFrame = ns:GetModule("BagFrame")
                if BagFrame then
                    BagFrame:Toggle()
                end
            elseif button == "RightButton" then
                local SettingsPopup = ns:GetModule("SettingsPopup")
                if SettingsPopup then
                    SettingsPopup:Toggle()
                end
            end
        end,

        OnTooltipShow = function(tooltip)
            if not tooltip then return end
            tooltip:AddLine("GudaBags", 1, 1, 1)

            if BagScanner then
                local total, free = BagScanner:GetTotalSlots()
                local used = total - free
                local pct = total > 0 and math.floor((used / total) * 100) or 0

                tooltip:AddLine(" ")
                tooltip:AddDoubleLine(L["TOOLTIP_BAGS"], string.format("%d / %d (%d%%)", used, total, pct), 0.8, 0.8, 0.8, 1, 1, 1)
                tooltip:AddDoubleLine(L["LDB_FREE_SLOTS"], tostring(free), 0.8, 0.8, 0.8, 0.2, 1, 0.2)
            end

            tooltip:AddLine(" ")
            tooltip:AddLine(L["LDB_HINT"], 0.5, 0.5, 0.5)
        end,
    })

    -- Update text on bag changes
    local function UpdateText()
        if not dataObj or not BagScanner then return end
        local total, free = BagScanner:GetTotalSlots()
        local used = total - free
        dataObj.text = string.format("%d/%d", used, total)
    end

    Events:Register("BAGS_UPDATED", UpdateText, DataBroker)

    -- Initial update after a short delay (bags may not be scanned yet)
    C_Timer.After(2, UpdateText)
end

-- Initialize when addon finishes loading
local Events = ns:GetModule("Events")
Events:OnPlayerLogin(function()
    DataBroker:Initialize()
end, DataBroker)
