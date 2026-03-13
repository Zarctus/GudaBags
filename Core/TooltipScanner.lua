local addonName, ns = ...

local TooltipScanner = {}
ns:RegisterModule("TooltipScanner", TooltipScanner)

-------------------------------------------------
-- Tooltip Management
-------------------------------------------------

local scanningTooltip = nil
local TOOLTIP_NAME = "GudaBagsScanningTooltip"

function TooltipScanner:GetTooltip()
    if not scanningTooltip then
        scanningTooltip = CreateFrame("GameTooltip", TOOLTIP_NAME, nil, "GameTooltipTemplate")
        scanningTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
    end
    return scanningTooltip
end

function TooltipScanner:SetBagItem(bagID, slotID)
    if not bagID or not slotID then return false end

    local tooltip = self:GetTooltip()
    tooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
    tooltip:ClearLines()
    tooltip:SetBagItem(bagID, slotID)

    return tooltip:NumLines() and tooltip:NumLines() > 0
end

function TooltipScanner:SetHyperlink(link)
    if not link then return false end

    local tooltip = self:GetTooltip()
    tooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
    tooltip:ClearLines()
    tooltip:SetHyperlink(link)

    return tooltip:NumLines() and tooltip:NumLines() > 0
end

-------------------------------------------------
-- Line Access
-------------------------------------------------

function TooltipScanner:GetLineText(lineNumber)
    local tooltip = self:GetTooltip()
    local leftText = _G[TOOLTIP_NAME .. "TextLeft" .. lineNumber]

    if leftText and leftText:IsShown() then
        return leftText:GetText()
    end
    return nil
end

function TooltipScanner:GetNumLines()
    local tooltip = self:GetTooltip()
    return tooltip:NumLines() or 0
end

-------------------------------------------------
-- Scanning Functions
-------------------------------------------------

-- Scan tooltip lines and call callback for each line
-- callback(lineNumber, text) - return true to stop scanning
function TooltipScanner:ScanLines(callback, maxLines)
    local numLines = self:GetNumLines()
    if not numLines or numLines == 0 then return nil end

    maxLines = maxLines or numLines

    for i = 1, math.min(numLines, maxLines) do
        local text = self:GetLineText(i)
        if text then
            local result = callback(i, text)
            if result then
                return result
            end
        end
    end

    return nil
end

-- Find first matching pattern in tooltip
-- Returns: matchedPattern, fullText, lineNumber
function TooltipScanner:FindText(patterns, maxLines)
    if type(patterns) == "string" then
        patterns = {patterns}
    end

    local result = nil
    self:ScanLines(function(lineNum, text)
        for _, pattern in ipairs(patterns) do
            if text:find(pattern) then
                result = {pattern = pattern, text = text, line = lineNum}
                return true
            end
        end
    end, maxLines)

    return result
end

-- Check if any pattern exists in tooltip
function TooltipScanner:HasText(patterns, maxLines)
    return self:FindText(patterns, maxLines) ~= nil
end

-------------------------------------------------
-- Common Item Checks
-------------------------------------------------

-- Check if item is Bind on Equip
function TooltipScanner:IsBindOnEquip(bagID, slotID, itemData)
    if not bagID or not slotID then return false end

    -- Only weapons and armor can be BoE
    if itemData and itemData.itemType ~= "Weapon" and itemData.itemType ~= "Armor" then
        return false
    end

    if not self:SetBagItem(bagID, slotID) then
        return false
    end

    -- Check first 6 lines for binding info
    local isBoE = false
    self:ScanLines(function(lineNum, text)
        if text == ITEM_BIND_ON_EQUIP or text:find("Binds when equipped") then
            isBoE = true
            return true
        end
        if text == ITEM_SOULBOUND or text:find("Soulbound") then
            isBoE = false
            return true
        end
        if text == ITEM_BIND_ON_PICKUP or text:find("Binds when picked up") then
            isBoE = false
            return true
        end
    end, 6)

    return isBoE
end

-- Get consumable restore type (eat/drink/restore)
function TooltipScanner:GetRestoreTag(bagID, slotID, itemData)
    if not bagID or not slotID then return nil end

    -- Only consumables have restore tags
    if itemData and itemData.itemType ~= "Consumable" then
        return nil
    end

    if not self:SetBagItem(bagID, slotID) then
        return nil
    end

    local hasHealth = false
    local hasMana = false
    local hasRestores = false
    local mustRemainSeated = false

    self:ScanLines(function(lineNum, text)
        local textLower = text:lower()

        if textLower:find("use: restores") or textLower:find("use: regenerates") then
            hasRestores = true
            if textLower:find("health") then hasHealth = true end
            if textLower:find("mana") then hasMana = true end
        end

        if textLower:find("must remain seated") then
            mustRemainSeated = true
        end
    end)

    if mustRemainSeated then
        if hasHealth and hasMana then
            return "restore"
        elseif hasHealth then
            return "eat"
        elseif hasMana then
            return "drink"
        end
    end

    return nil
end

-- Check if item has special properties (Use:, Equip:, Chance on hit)
function TooltipScanner:HasSpecialProperties(bagID, slotID)
    if not bagID or not slotID then return false end

    if not self:SetBagItem(bagID, slotID) then
        return false
    end

    return self:HasText({"Use:", "Equip:", "Chance on hit"})
end
