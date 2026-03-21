local addonName, ns = ...

local Tooltip = {}
ns:RegisterModule("Tooltip", Tooltip)

local L = ns.L
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")
local Utils = ns:GetModule("Utils")

-- Track if we've already added inventory section to prevent duplicates
local tooltipReady = true

-- Tooltip for scanning item properties (hidden, used for data extraction)
local scanTooltip = CreateFrame("GameTooltip", "GudaBags_ScanTooltip", nil, "GameTooltipTemplate")
scanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")

-- Custom tooltip for items (avoids secure frame conflicts with ContainerFrameItemButtonTemplate)
local itemTooltip = CreateFrame("GameTooltip", "GudaBags_ItemTooltip", UIParent, "GameTooltipTemplate")
itemTooltip:SetFrameStrata("TOOLTIP")

-- Extract itemID from item link
local function GetItemIDFromLink(link)
    if not link then return nil end
    local itemID = link:match("item:(%d+)")
    return itemID and tonumber(itemID)
end

-- Add inventory section to a tooltip
local function AddInventorySection(tooltip, itemID, skipReadyCheck)
    if not itemID then return end

    -- Prevent duplicate inventory sections on same tooltip (unless skipReadyCheck for specific hooks)
    if not skipReadyCheck and not tooltipReady then return end
    tooltipReady = false

    if Database:GetSetting("showTooltipCounts") == false then return end

    local totalCount, characterCounts, warbandCount = Database:CountItemAcrossCharacters(itemID)

    -- Don't show if only 1 item in current character's bags (no useful cross-location info)
    if warbandCount == 0 and #characterCounts == 1 and characterCounts[1].isCurrent and characterCounts[1].count == 1
        and (characterCounts[1].equippedCount or 0) == 0 then
        return
    end

    -- Don't show if no items found
    if totalCount == 0 then return end

    tooltip:AddLine(" ")
    tooltip:AddLine(L["TOOLTIP_INVENTORY"], 1, 0.82, 0)

    for _, charInfo in ipairs(characterCounts) do
        local classColor = RAID_CLASS_COLORS[charInfo.class]
        local r, g, b = 0.7, 0.7, 0.7
        if classColor then
            r, g, b = classColor.r, classColor.g, classColor.b
        end

        local raceIcon = Utils:GetRaceIcon(charInfo.race, charInfo.sex)
        local displayName = raceIcon .. " " .. (charInfo.isCurrent and (charInfo.name .. L["TOOLTIP_YOU"]) or charInfo.name)

        -- Build count string with label: count format
        local cyan = "|cFF00CCCC"
        local white = "|cFFFFFFFF"
        local countParts = {}
        if charInfo.bagCount and charInfo.bagCount > 0 then
            table.insert(countParts, cyan .. L["TOOLTIP_BAGS"] .. ": " .. white .. charInfo.bagCount .. "|r")
        end
        if charInfo.bankCount and charInfo.bankCount > 0 then
            table.insert(countParts, cyan .. L["TOOLTIP_BANK_LOWER"] .. ": " .. white .. charInfo.bankCount .. "|r")
        end
        if charInfo.mailCount and charInfo.mailCount > 0 then
            table.insert(countParts, cyan .. L["TOOLTIP_MAIL_LOWER"] .. ": " .. white .. charInfo.mailCount .. "|r")
        end
        if charInfo.equippedCount and charInfo.equippedCount > 0 then
            table.insert(countParts, cyan .. L["TOOLTIP_EQUIPPED"] .. ": " .. white .. charInfo.equippedCount .. "|r")
        end
        local countStr = table.concat(countParts, white .. ", ")

        tooltip:AddDoubleLine(displayName, countStr, r, g, b, 1, 1, 1)
    end

    -- Show warband bank as a separate line (account-wide, not per-character)
    if warbandCount > 0 then
        tooltip:AddDoubleLine(L["TOOLTIP_WARBAND_BANK"] or "Warband Bank", warbandCount, 0.0, 0.8, 0.6, 1, 0.82, 0)
    end

    if #characterCounts > 1 or warbandCount > 0 then
        tooltip:AddDoubleLine(L["TOOLTIP_TOTAL"], totalCount, 0.8, 0.8, 0.8, 1, 0.82, 0)
    end

    tooltip:Show()
end

-- Reset ready flag when tooltip is cleared (allows next tooltip to show inventory)
GameTooltip:HookScript("OnTooltipCleared", function()
    tooltipReady = true
end)

-- Show tooltip for an item button (uses GameTooltip for addon compatibility)
function Tooltip:ShowForItem(button)
    if not button.itemData then return end

    -- Reset ready flag so inventory section will be added
    tooltipReady = true

    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")

    local bagID = button.itemData.bagID
    local slot = button.itemData.slot
    local link = button.itemData.link or button.itemData.itemLink
    local itemID = button.itemData.itemID
    local isKeyring = bagID == -2
    local isGuildBank = button.itemData.isGuildBank

    -- Check if this is a bank item
    -- Use simple range check that covers both Classic (5-11) and Retail (6-12) bank bags
    -- This is more robust than relying on Constants arrays which depend on Expansion detection
    local isBankItem = false
    if bagID == -1 then
        -- Main bank container (all versions)
        isBankItem = true
    elseif bagID and bagID >= 5 and bagID <= 12 then
        -- Bank bags: Classic uses 5-11, older Retail uses 6-12
        -- This range covers both to handle detection edge cases
        isBankItem = true
    end
    -- Retail only: check Warband and Character bank tabs (high bag IDs)
    if not isBankItem and ns.IsRetail then
        local Constants = ns.Constants
        if Constants and Constants.WARBAND_BANK_TAB_IDS then
            for _, warbandBagID in ipairs(Constants.WARBAND_BANK_TAB_IDS) do
                if bagID == warbandBagID then
                    isBankItem = true
                    break
                end
            end
        end
        if not isBankItem and Constants and Constants.CHARACTER_BANK_TAB_IDS then
            for _, charBankTabID in ipairs(Constants.CHARACTER_BANK_TAB_IDS) do
                if bagID == charBankTabID then
                    isBankItem = true
                    break
                end
            end
        end
    end

    if isGuildBank then
        -- Guild bank items - use SetGuildBankItem if at bank, otherwise hyperlink
        local GuildBankScanner = ns:GetModule("GuildBankScanner")
        local tooltipSet = false
        if GuildBankScanner and GuildBankScanner:IsGuildBankOpen() and GameTooltip.SetGuildBankItem then
            GameTooltip:SetGuildBankItem(bagID, slot)  -- bagID is tab index for guild bank
            tooltipSet = GameTooltip:NumLines() and GameTooltip:NumLines() > 0
        end
        if not tooltipSet and link then
            GameTooltip:SetHyperlink(link)
            tooltipSet = GameTooltip:NumLines() and GameTooltip:NumLines() > 0
        end
        if not tooltipSet and itemID then
            GameTooltip:SetHyperlink("item:" .. itemID)
            tooltipSet = GameTooltip:NumLines() and GameTooltip:NumLines() > 0
        end
        if not tooltipSet and button.itemData then
            local name = button.itemData.name
            local quality = button.itemData.quality or 0
            if name and name ~= "" then
                local r, g, b = GetItemQualityColor(quality)
                GameTooltip:SetText(name, r, g, b)
            end
        end
    elseif button.isReadOnly or isKeyring then
        -- Cached items and keyring use hyperlink
        local tooltipSet = false
        if link then
            GameTooltip:SetHyperlink(link)
            tooltipSet = GameTooltip:NumLines() and GameTooltip:NumLines() > 0
        end
        -- Fallback 1: try SetItemByID if available
        if not tooltipSet and itemID and GameTooltip.SetItemByID then
            GameTooltip:SetItemByID(itemID)
            tooltipSet = GameTooltip:NumLines() and GameTooltip:NumLines() > 0
        end
        -- Fallback 2: construct link from itemID
        if not tooltipSet and itemID then
            GameTooltip:SetHyperlink("item:" .. itemID)
            tooltipSet = GameTooltip:NumLines() and GameTooltip:NumLines() > 0
        end
        -- Fallback 3: manually show item name and icon
        if not tooltipSet and button.itemData then
            local name = button.itemData.name
            local quality = button.itemData.quality or 0
            if name and name ~= "" then
                local r, g, b = GetItemQualityColor(quality)
                GameTooltip:SetText(name, r, g, b)
            end
        end
    elseif isBankItem then
        -- Bank items handling
        local BankScanner = ns:GetModule("BankScanner")
        local isBankOpen = BankScanner and BankScanner:IsBankOpen()
        local tooltipSet = false

        if isBankOpen and bagID ~= nil and slot then
            if bagID == -1 then
                -- Main bank container uses inventory slots, not bag slots
                local invSlot = BankButtonIDToInvSlotID and BankButtonIDToInvSlotID(slot)
                if invSlot then
                    GameTooltip:SetInventoryItem("player", invSlot)
                    tooltipSet = GameTooltip:NumLines() and GameTooltip:NumLines() > 0
                end
            else
                -- Bank bags (5-11) use SetBagItem like regular bags
                GameTooltip:SetBagItem(bagID, slot)
                tooltipSet = GameTooltip:NumLines() and GameTooltip:NumLines() > 0
            end
        end
        -- Fallback to hyperlink if direct access didn't work
        if not tooltipSet and link then
            GameTooltip:SetHyperlink(link)
            tooltipSet = GameTooltip:NumLines() and GameTooltip:NumLines() > 0
        end
        -- Fallback to itemID
        if not tooltipSet and itemID then
            if GameTooltip.SetItemByID then
                GameTooltip:SetItemByID(itemID)
                tooltipSet = GameTooltip:NumLines() and GameTooltip:NumLines() > 0
            end
            if not tooltipSet then
                GameTooltip:SetHyperlink("item:" .. itemID)
                tooltipSet = GameTooltip:NumLines() and GameTooltip:NumLines() > 0
            end
        end
        -- Last resort: show item name
        if not tooltipSet and button.itemData then
            local name = button.itemData.name
            local quality = button.itemData.quality or 0
            if name and name ~= "" then
                local r, g, b = GetItemQualityColor(quality)
                GameTooltip:SetText(name, r, g, b)
            end
        end
    else
        -- Regular bag items use bag slot for full info (binding, cooldown, etc.)
        local tooltipSet = false
        if bagID ~= nil and slot then
            GameTooltip:SetBagItem(bagID, slot)
            tooltipSet = GameTooltip:NumLines() and GameTooltip:NumLines() > 0
        end
        if not tooltipSet and link then
            GameTooltip:SetHyperlink(link)
            tooltipSet = GameTooltip:NumLines() and GameTooltip:NumLines() > 0
        end
        -- Fallback to itemID
        if not tooltipSet and itemID then
            if GameTooltip.SetItemByID then
                GameTooltip:SetItemByID(itemID)
                tooltipSet = GameTooltip:NumLines() and GameTooltip:NumLines() > 0
            end
            if not tooltipSet then
                GameTooltip:SetHyperlink("item:" .. itemID)
            end
        end
    end

    -- Add inventory section
    AddInventorySection(GameTooltip, button.itemData.itemID)

    -- Add tracking hint for bag items (not read-only/cached)
    if not button.isReadOnly and button.itemData.itemID then
        local TrackedBar = ns:GetModule("TrackedBar")
        if TrackedBar then
            GameTooltip:AddLine(" ")
            if TrackedBar:IsTracked(button.itemData.itemID) then
                GameTooltip:AddLine(L["HINT_UNTRACK"], 0.7, 0.7, 0.7)
            else
                GameTooltip:AddLine(L["HINT_TRACK"], 0.7, 0.7, 0.7)
            end
        end
    end

    GameTooltip:Show()
end

-- Hide the item tooltip
function Tooltip:Hide()
    GameTooltip:Hide()
end

-- Public function to add inventory section to any tooltip
function Tooltip:AddInventorySection(tooltip, itemID)
    AddInventorySection(tooltip, itemID)
end

-- Helper to create a hook that adds inventory section
local function HookWithInventory(method, getLinkFunc)
    if not GameTooltip[method] then return end

    hooksecurefunc(GameTooltip, method, function(self, ...)
        local success, link = pcall(getLinkFunc, ...)
        if success and link then
            AddInventorySection(self, GetItemIDFromLink(link))
        end
    end)
end

-- Initialize GameTooltip hooks
local function InitializeHooks()
    -- General OnTooltipSetItem hook - catches most item tooltips
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
        -- Retail/modern approach
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
            if data and data.id then
                AddInventorySection(tooltip, data.id)
            end
        end)
    else
        -- Classic/TBC approach - use OnTooltipSetItem script
        GameTooltip:HookScript("OnTooltipSetItem", function(self)
            local _, link = self:GetItem()
            if link then
                AddInventorySection(self, GetItemIDFromLink(link))
            end
        end)
    end

    -- Hook SetHyperlink for chat links
    hooksecurefunc(GameTooltip, "SetHyperlink", function(self, link)
        if link and link:match("^item:") then
            AddInventorySection(self, GetItemIDFromLink(link))
        end
    end)

    -- Hook SetBagItem for bag tooltips (other addons using GameTooltip)
    hooksecurefunc(GameTooltip, "SetBagItem", function(self, bagID, slot)
        local link = C_Container.GetContainerItemLink(bagID, slot)
        if link then
            AddInventorySection(self, GetItemIDFromLink(link))
        end
    end)

    -- Hook SetAuctionItem for auction house (OnTooltipSetItem doesn't fire for this)
    if GameTooltip.SetAuctionItem then
        hooksecurefunc(GameTooltip, "SetAuctionItem", function(self, auctionType, index)
            local link = GetAuctionItemLink(auctionType, index)
            if link then
                AddInventorySection(self, GetItemIDFromLink(link), true)
            end
        end)
    end

    -- Hook SetCraftItem for enchanting/crafting professions (OnTooltipSetItem doesn't fire for this)
    if GameTooltip.SetCraftItem then
        hooksecurefunc(GameTooltip, "SetCraftItem", function(self, recipeIndex, reagentIndex)
            local link
            if reagentIndex then
                link = GetCraftReagentItemLink(recipeIndex, reagentIndex)
            else
                link = GetCraftItemLink(recipeIndex)
            end
            if link then
                AddInventorySection(self, GetItemIDFromLink(link), true)
            end
        end)
    end

    -- Hook SetTradeSkillItem for professions (OnTooltipSetItem doesn't fire for this)
    if GameTooltip.SetTradeSkillItem then
        hooksecurefunc(GameTooltip, "SetTradeSkillItem", function(self, recipeIndex, reagentIndex)
            local link
            if reagentIndex then
                link = GetTradeSkillReagentItemLink(recipeIndex, reagentIndex)
            else
                link = GetTradeSkillItemLink(recipeIndex)
            end
            if link then
                AddInventorySection(self, GetItemIDFromLink(link), true)
            end
        end)
    end

    -- Hook SetInboxItem for mail
    HookWithInventory("SetInboxItem", function(mailIndex, attachmentIndex)
        return GetInboxItemLink(mailIndex, attachmentIndex or 1)
    end)

    -- Hook SetMerchantItem for vendors
    HookWithInventory("SetMerchantItem", GetMerchantItemLink)

    -- Hook SetTradePlayerItem and SetTradeTargetItem for trade window
    HookWithInventory("SetTradePlayerItem", GetTradePlayerItemLink)
    HookWithInventory("SetTradeTargetItem", GetTradeTargetItemLink)

    -- Hook SetLootItem for loot window
    HookWithInventory("SetLootItem", GetLootSlotLink)

    -- Hook SetQuestItem for quest rewards
    HookWithInventory("SetQuestItem", function(questType, index)
        return GetQuestItemLink(questType, index)
    end)

    -- Hook SetQuestLogItem for quest log items
    HookWithInventory("SetQuestLogItem", function(itemType, index)
        return GetQuestLogItemLink(itemType, index)
    end)

    -- Hook SetInventoryItem for equipped items and bank
    HookWithInventory("SetInventoryItem", function(unit, slot)
        return GetInventoryItemLink(unit, slot)
    end)

    -- Hook SetGuildBankItem for guild bank
    if GameTooltip.SetGuildBankItem then
        HookWithInventory("SetGuildBankItem", function(tab, slot)
            return GetGuildBankItemLink(tab, slot)
        end)
    end

    -- Hook SetSendMailItem for mail attachments when composing
    if GameTooltip.SetSendMailItem then
        HookWithInventory("SetSendMailItem", function(index)
            local name, itemID = GetSendMailItem(index)
            if itemID then
                return select(2, GetItemInfo(itemID))  -- Get item link from itemID
            end
            return nil
        end)
    end

    -- Hook SetItemByID for items shown by ID (some UI elements)
    if GameTooltip.SetItemByID then
        hooksecurefunc(GameTooltip, "SetItemByID", function(self, itemID)
            if itemID then
                AddInventorySection(self, itemID)
            end
        end)
    end
end

-- Hook secondary tooltips (ItemRefTooltip for chat links, ShoppingTooltips for comparison)
local function InitializeSecondaryTooltipHooks()
    -- ItemRefTooltip - shown when clicking item links in chat
    if ItemRefTooltip and ItemRefTooltip.SetHyperlink then
        hooksecurefunc(ItemRefTooltip, "SetHyperlink", function(self, link)
            if link and link:match("^item:") then
                AddInventorySection(self, GetItemIDFromLink(link))
            end
        end)
    end

    -- ShoppingTooltip1 and ShoppingTooltip2 - comparison tooltips
    for i = 1, 2 do
        local shoppingTooltip = _G["ShoppingTooltip" .. i]
        if shoppingTooltip and shoppingTooltip.SetCompareItem then
            hooksecurefunc(shoppingTooltip, "SetCompareItem", function(self, ...)
                local _, link = self:GetItem()
                if link then
                    AddInventorySection(self, GetItemIDFromLink(link))
                end
            end)
        end
    end
end

-- Initialize hooks on player login (or immediately if already logged in)
local hooksInitialized = false
local function SafeInitializeHooks()
    if hooksInitialized then return end
    hooksInitialized = true
    InitializeHooks()
    InitializeSecondaryTooltipHooks()
end

Events:OnPlayerLogin(SafeInitializeHooks, Tooltip)

if IsLoggedIn() then
    SafeInitializeHooks()
end

-------------------------------------------------
-- Tooltip Scanning API (for junk detection, etc.)
-------------------------------------------------

-- Scan tooltip for item properties (returns scan tooltip for reading)
function Tooltip:ScanBagItem(bagID, slot)
    if not bagID or not slot then
        return nil, 0
    end

    scanTooltip:ClearLines()
    scanTooltip:SetBagItem(bagID, slot)

    return scanTooltip, scanTooltip:NumLines() or 0
end

-- Get a specific line from the scan tooltip
function Tooltip:GetScanLine(lineIndex)
    local line = _G["GudaBags_ScanTooltipTextLeft" .. lineIndex]
    if not line then
        return nil, nil, nil, nil
    end

    return line:GetText(), line:GetTextColor()
end

-- Check if item has special properties (Use:, Equip:, Unique, green/yellow text)
function Tooltip:HasSpecialProperties(bagID, slot)
    local _, numLines = self:ScanBagItem(bagID, slot)
    if numLines == 0 then return false end

    for i = 1, numLines do
        local text, r, g, b = self:GetScanLine(i)

        if text then
            local textLower = text:lower()

            -- Check for Use: or Equip: effects
            if textLower:find("use:") or textLower:find("equip:") then
                return true
            end

            -- Check for Unique items
            if textLower:find("^unique") or textLower:find("unique%-equipped") then
                return true
            end
        end

        if r and g and b then
            -- Green text (special effects, set bonuses)
            if g > 0.9 and r < 0.2 and b < 0.2 then
                return true
            end

            -- Yellow/gold text (flavor text, special properties) - skip first line (item name)
            if r > 0.9 and g > 0.7 and b < 0.2 and text and i > 1 then
                return true
            end
        end
    end

    return false
end
