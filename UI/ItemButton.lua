local addonName, ns = ...

local ItemButton = {}
ns:RegisterModule("ItemButton", ItemButton)

local Constants = ns.Constants
local Database = ns:GetModule("Database")
local Tooltip = ns:GetModule("Tooltip")

-- Suppress spurious "Item isn't ready yet" errors on retail
-- ContainerFrameItemButtonTemplate shows this error incorrectly when clicking usable items
local suppressItemErrors = false
local suppressUntil = 0

-- Hook UIErrorsFrame to filter out incorrect item errors
if UIErrorsFrame and ns.IsRetail then
    local originalAddMessage = UIErrorsFrame.AddMessage
    UIErrorsFrame.AddMessage = function(self, msg, ...)
        -- Suppress item-not-ready errors briefly after our button clicks
        if suppressItemErrors and GetTime() < suppressUntil then
            -- Check if this is one of the spurious error messages
            local errItemNotReady = ERR_ITEM_NOT_READY or "Item is not ready yet"
            local errGenericNoTarget = ERR_GENERIC_NO_TARGET or "You have no target"
            if msg and (msg:find(errItemNotReady) or msg == errItemNotReady) then
                return  -- Suppress this error
            end
        end
        return originalAddMessage(self, msg, ...)
    end
end

-- Call this before clicking to suppress errors for a brief moment
local function SuppressItemErrors()
    if ns.IsRetail then
        suppressItemErrors = true
        suppressUntil = GetTime() + 0.1  -- Suppress for 100ms
    end
end

-- Apply retail/default slot textures to a single button
local function ApplyThemeToButton(button, slotTex)
    if slotTex then
        button.slotBackground:Hide()
        button.retailSlotBg:SetTexture(slotTex.background)
        button.retailSlotBg:Show()
        button.highlight:Hide()
        button.retailHighlight:SetTexture(slotTex.highlight)
        button.retailHighlight:Show()
    else
        button.slotBackground:Show()
        if button.retailSlotBg then button.retailSlotBg:Hide() end
        button.highlight:Show()
        if button.retailHighlight then button.retailHighlight:Hide() end
    end
end

-- Phase 1: Use Blizzard's optimized CreateObjectPool API
local buttonPool = nil  -- Lazy initialized
local buttonIndex = 0

-- Full reset function for pool (called on Release)
local function ResetButton(pool, button)
    button:SetShown(false)  -- Use SetShown to avoid taint during combat
    button.wrapper:SetShown(false)
    button.wrapper:ClearAllPoints()
    button.itemData = nil
    button.owner = nil
    button.isEmptySlotButton = nil
    button.categoryId = nil
    button.iconSize = nil
    button.layoutX = nil
    button.layoutY = nil
    button.layoutIndex = nil
    button.containerFrame = nil

    -- Hide Blizzard template's built-in textures
    if button.IconBorder then button.IconBorder:Hide() end
    if button.IconOverlay then button.IconOverlay:Hide() end
    if button.NewItemTexture then button.NewItemTexture:Hide() end
    if button.BattlepayItemTexture then button.BattlepayItemTexture:Hide() end
    local normalTex = button:GetNormalTexture()
    if normalTex then normalTex:Hide() end

    -- Clear visual state to prevent texture bleeding
    SetItemButtonTexture(button, nil)
    SetItemButtonCount(button, 0)
    SetItemButtonDesaturated(button, false)
    if button.border then button.border:Hide() end
    if button.innerShadow then
        for _, tex in pairs(button.innerShadow) do tex:Hide() end
    end
    if button.lockOverlay then button.lockOverlay:Hide() end
    if button.unusableOverlay then button.unusableOverlay:Hide() end
    if button.junkOverlay then button.junkOverlay:Hide() end
    if button.junkIcon then button.junkIcon:Hide() end
    if button.trackedIcon then button.trackedIcon:Hide() end
    if button.trackedIconShadow then button.trackedIconShadow:Hide() end
    if button.equipSetIcon then button.equipSetIcon:Hide() end
    if button.equipSetIconShadow then button.equipSetIconShadow:Hide() end
    if button.itemLevelText then button.itemLevelText:Hide() end
    if button.questIcon then button.questIcon:Hide() end
    if button.questStarterIcon then button.questStarterIcon:Hide() end
    if button.craftingQualityIcon then button.craftingQualityIcon:Hide() end
    if button.cooldown then CooldownFrame_Set(button.cooldown, 0, 0, false) end
end

local BASE_BUTTON_SIZE = 37

local function ApplyFontSize(button, fontSize)
    fontSize = fontSize or Database:GetSetting("iconFontSize")
    if button.Count then
        button.Count:SetFont(Constants.FONTS.DEFAULT, fontSize, "OUTLINE")
        button.Count:ClearAllPoints()
        button.Count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 1)
        button.Count:SetJustifyH("RIGHT")
    end
    if button.itemLevelText then
        button.itemLevelText:SetFont(Constants.FONTS.DEFAULT, fontSize, "OUTLINE")
    end
end

local function IsTool(itemName)
    if not itemName then return false end
    local nameLower = string.lower(itemName)

    if string.find(nameLower, "mining pick") then return true end
    if string.find(nameLower, "fishing pole") then return true end
    if string.find(nameLower, "fishing rod") then return true end
    if string.find(nameLower, "skinning knife") then return true end
    if string.find(nameLower, "blacksmith hammer") then return true end
    if string.find(nameLower, "jumper cables") then return true end
    if string.find(nameLower, "gnomish") then return true end
    if string.find(nameLower, "goblin") then return true end
    if string.find(nameLower, "arclight spanner") then return true end
    if string.find(nameLower, "gyromatic") then return true end

    return false
end

local function IsJunkItem(itemData)
    if not itemData then return false end

    -- Profession tools are never junk
    if IsTool(itemData.name) then
        return false
    end

    -- Gray quality items are always junk (consistent with Category View isJunk rule)
    if itemData.quality == 0 then
        return true
    end

    -- White quality equipment (only if setting is enabled)
    if itemData.quality == 1 then
        local Database = ns:GetModule("Database")
        local whiteItemsJunk = Database and Database:GetSetting("whiteItemsJunk") or false

        if not whiteItemsJunk then
            return false  -- Setting is off, white items are never junk
        end

        local isEquipment = itemData.itemType == "Armor" or itemData.itemType == "Weapon"
        if isEquipment then
            -- Valuable slots (trinket, ring, neck, shirt, tabard) are never junk
            local equipSlot = itemData.equipSlot
            if equipSlot and Constants.VALUABLE_EQUIP_SLOTS[equipSlot] then
                return false
            end

            local isTool = IsTool(itemData.name)
            if isTool then
                return false
            end
            -- Check for special properties (unique, use, equip effects, green/yellow text)
            -- Use cached value from ItemScanner to avoid tooltip rescans
            if itemData.hasSpecialProperties then
                return false
            end
            return true
        end
    end

    return false
end

local function CreateBorder(button)
    local BORDER_THICKNESS = Constants.ICON.BORDER_THICKNESS

    local borderFrame = CreateFrame("Frame", nil, button, "BackdropTemplate")
    borderFrame:SetPoint("TOPLEFT", button, "TOPLEFT", -BORDER_THICKNESS, BORDER_THICKNESS)
    borderFrame:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", BORDER_THICKNESS, -BORDER_THICKNESS)
    borderFrame:SetFrameLevel(button:GetFrameLevel() + Constants.FRAME_LEVELS.BORDER)

    borderFrame:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = {left = 2, right = 2, top = 2, bottom = 2},
    })
    borderFrame:Hide()

    borderFrame.SetVertexColor = function(self, r, g, b, a)
        self:SetBackdropBorderColor(r, g, b, a)
    end

    return borderFrame
end

local function CreateButton(parent)
    buttonIndex = buttonIndex + 1
    local name = "GudaBagsItemButton" .. buttonIndex

    -- Wrapper frame holds bag ID for the template's click handler
    local wrapper = CreateFrame("Frame", name .. "Wrapper", parent)
    wrapper:SetSize(37, 37)
    wrapper:EnableMouse(false)  -- Wrapper should not intercept mouse

    -- ContainerFrameItemButtonTemplate provides secure item click handling
    local button = CreateFrame("ItemButton", name, wrapper, "ContainerFrameItemButtonTemplate")
    button:SetSize(37, 37)
    button:SetAllPoints(wrapper)
    button.wrapper = wrapper
    button.currentSize = nil  -- Track current size to avoid redundant SetSize calls

    -- Store reference to easily resize wrapper with button
    wrapper.button = button

    -- Initialize IDs to prevent errors from template handlers before SetItem is called
    wrapper:SetID(0)
    button:SetID(0)

    -- Disable mouse on all child frames from the template (retail has many overlays)
    -- This prevents them from intercepting mouse input meant for the button
    local function DisableChildMouse(frame)
        for _, child in pairs({frame:GetChildren()}) do
            if child.EnableMouse then
                child:EnableMouse(false)
            end
            if child.SetHitRectInsets then
                child:SetHitRectInsets(1000, 1000, 1000, 1000)
            end
            child:Hide()
            -- Recursively disable grandchildren
            if child.GetChildren then
                DisableChildMouse(child)
            end
        end
    end
    DisableChildMouse(button)

    -- Also check for and disable NineSlice (retail frame decoration)
    if button.NineSlice then
        button.NineSlice:Hide()
        if button.NineSlice.EnableMouse then button.NineSlice:EnableMouse(false) end
    end

    -- Disable button's built-in click handlers that might interfere
    -- We'll set up our own handlers
    button:EnableMouse(true)
    -- Only register for mouse up to prevent double-firing
    -- The template fires on both MouseDown and MouseUp with AnyDown, causing items to be used twice
    button:RegisterForClicks("AnyUp")
    -- Enable drag for all items including guild bank
    button:RegisterForDrag("LeftButton")

    -- Handle drag start for guild bank items (hook to preserve template behavior for regular items)
    button:HookScript("OnDragStart", function(self)
        if self.itemData and self.itemData.isGuildBank and not self.isReadOnly then
            local tabIndex = self.itemData.bagID
            local slotIndex = self.itemData.slot
            if self.itemData.itemID then  -- Only drag if there's an item
                PickupGuildBankItem(tabIndex, slotIndex)
            end
        end
    end)

    -- Hide template's built-in visual elements (we use our own)
    local normalTex = button:GetNormalTexture()
    if normalTex then
        normalTex:SetTexture(nil)
        normalTex:Hide()
    end

    if button.IconBorder then button.IconBorder:Hide() end
    if button.IconOverlay then button.IconOverlay:Hide() end
    if button.NormalTexture then
        button.NormalTexture:SetTexture(nil)
        button.NormalTexture:Hide()
    end
    if button.NewItemTexture then button.NewItemTexture:Hide() end
    if button.BattlepayItemTexture then button.BattlepayItemTexture:Hide() end

    -- Hide retail-specific template elements (Midnight/TWW)
    -- These overlays block mouse input - reparent them to remove completely
    local function DisableOverlay(overlay)
        if not overlay then return end
        overlay:Hide()
        overlay:SetAlpha(0)
        overlay:ClearAllPoints()
        -- Reparent to remove from button hierarchy entirely
        if overlay.SetParent then
            overlay:SetParent(nil)
        end
        if overlay.EnableMouse then overlay:EnableMouse(false) end
        if overlay.SetHitRectInsets then overlay:SetHitRectInsets(1000, 1000, 1000, 1000) end
        if overlay.SetScript then
            overlay:SetScript("OnShow", function(self) self:Hide() end)
            overlay:SetScript("OnEnter", nil)
            overlay:SetScript("OnLeave", nil)
            overlay:SetScript("OnMouseDown", nil)
            overlay:SetScript("OnMouseUp", nil)
        end
    end

    DisableOverlay(button.ItemContextOverlay)
    DisableOverlay(button.SearchOverlay)
    DisableOverlay(button.ExtendedSlot)
    DisableOverlay(button.UpgradeIcon)
    DisableOverlay(button.ItemSlotBackground)
    DisableOverlay(button.JunkIcon)
    DisableOverlay(button.flash)
    DisableOverlay(button.NewItem)
    DisableOverlay(button.Cooldown)  -- Template's cooldown (we create our own)
    DisableOverlay(button.WidgetContainer)  -- Retail widget container
    DisableOverlay(button.LevelLinkLockIcon)
    DisableOverlay(button.BagIndicator)
    DisableOverlay(button.StackSplitFrame)

    -- Disable any mouse blocking on the icon texture layer
    if button.icon then button.icon:SetDrawLayer("ARTWORK", 0) end

    -- Ensure the button is the topmost interactive element
    button:SetFrameLevel(button:GetParent():GetFrameLevel() + Constants.FRAME_LEVELS.BUTTON)

    -- Sync child frame levels to match the (potentially new) button level
    local btnLvl = button:GetFrameLevel()
    if button.border then button.border:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.BORDER) end
    if button.cooldown then button.cooldown:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.COOLDOWN) end
    if button.questStarterIcon then button.questStarterIcon:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.QUEST_ICON) end
    if button.questIcon then button.questIcon:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.QUEST_ICON) end

    -- Reset hit rect to cover the full button (template might shrink it)
    button:SetHitRectInsets(0, 0, 0, 0)

    -- Ensure button receives all mouse events (check if methods exist)
    if button.SetMouseClickEnabled then button:SetMouseClickEnabled(true) end
    if button.SetMouseMotionEnabled then button:SetMouseMotionEnabled(true) end

    -- Hide global texture created by template XML
    local globalNormal = _G[name .. "NormalTexture"]
    if globalNormal then
        globalNormal:SetTexture(nil)
        globalNormal:Hide()
    end

    -- Custom slot background (extended to match item icon visual size)
    local slotBackground = button:CreateTexture(nil, "BACKGROUND", nil, -1)
    slotBackground:SetPoint("TOPLEFT", button, "TOPLEFT", -9, 9)
    slotBackground:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 9, -9)
    slotBackground:SetTexture("Interface\\Buttons\\UI-EmptySlot")
    button.slotBackground = slotBackground

    -- Retail theme slot background (hidden by default)
    local retailSlotBg = button:CreateTexture(nil, "BACKGROUND", nil, -1)
    retailSlotBg:SetPoint("TOPLEFT", button, "TOPLEFT", -2, 2)
    retailSlotBg:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 2, -2)
    retailSlotBg:Hide()
    button.retailSlotBg = retailSlotBg

    -- Item icon fills button completely to match empty slot size
    local icon = button.icon or button.Icon or _G[name .. "IconTexture"]
    if icon then
        icon:ClearAllPoints()
        icon:SetAllPoints(button)
        icon:SetTexCoord(0, 1, 0, 1)
    end

    -- Quality border (our custom one, not template's)
    local border = CreateBorder(button)
    button.border = border

    -- Inner shadow/glow for quality colors (inset effect)
    local shadowSize = 4
    local innerShadow = {
        top = button:CreateTexture(nil, "ARTWORK", nil, 1),
        bottom = button:CreateTexture(nil, "ARTWORK", nil, 1),
        left = button:CreateTexture(nil, "ARTWORK", nil, 1),
        right = button:CreateTexture(nil, "ARTWORK", nil, 1),
    }
    -- Top edge
    innerShadow.top:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    innerShadow.top:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, 0)
    innerShadow.top:SetHeight(shadowSize)
    innerShadow.top:SetTexture("Interface\\Buttons\\WHITE8x8")
    innerShadow.top:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.6))
    -- Bottom edge
    innerShadow.bottom:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    innerShadow.bottom:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    innerShadow.bottom:SetHeight(shadowSize)
    innerShadow.bottom:SetTexture("Interface\\Buttons\\WHITE8x8")
    innerShadow.bottom:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0.6), CreateColor(0, 0, 0, 0))
    -- Left edge
    innerShadow.left:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    innerShadow.left:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    innerShadow.left:SetWidth(shadowSize)
    innerShadow.left:SetTexture("Interface\\Buttons\\WHITE8x8")
    innerShadow.left:SetGradient("HORIZONTAL", CreateColor(0, 0, 0, 0.6), CreateColor(0, 0, 0, 0))
    -- Right edge
    innerShadow.right:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, 0)
    innerShadow.right:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    innerShadow.right:SetWidth(shadowSize)
    innerShadow.right:SetTexture("Interface\\Buttons\\WHITE8x8")
    innerShadow.right:SetGradient("HORIZONTAL", CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.6))
    -- Hide by default
    for _, tex in pairs(innerShadow) do tex:Hide() end
    button.innerShadow = innerShadow

    -- Custom highlight
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")
    button.highlight = highlight

    -- Retail theme highlight (hidden by default)
    local retailHighlight = button:CreateTexture(nil, "HIGHLIGHT")
    retailHighlight:SetPoint("TOPLEFT", button, "TOPLEFT", -4, 4)
    retailHighlight:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 4, -4)
    retailHighlight:SetBlendMode("ADD")
    retailHighlight:Hide()
    button.retailHighlight = retailHighlight

    -- Cooldown frame
    local cooldown = CreateFrame("Cooldown", name .. "Cooldown", button, "CooldownFrameTemplate")
    cooldown:SetAllPoints()
    cooldown:SetDrawEdge(false)
    cooldown:SetFrameLevel(button:GetFrameLevel() + Constants.FRAME_LEVELS.COOLDOWN)
    if cooldown.SetHideCountdownNumbers then
        cooldown:SetHideCountdownNumbers(false)
    end
    button.cooldown = cooldown

    -- Lock overlay for locked items
    local lockOverlay = button:CreateTexture(nil, "OVERLAY", nil, 1)
    lockOverlay:SetAllPoints()
    lockOverlay:SetTexture("Interface\\Buttons\\WHITE8x8")
    lockOverlay:SetVertexColor(0, 0, 0, 0.5)
    lockOverlay:Hide()
    button.lockOverlay = lockOverlay

    -- Unusable item overlay
    local unusableOverlay = button:CreateTexture(nil, "OVERLAY", nil, 2)
    unusableOverlay:SetAllPoints()
    unusableOverlay:SetTexture("Interface\\Buttons\\WHITE8x8")
    unusableOverlay:SetVertexColor(1, 0.1, 0.1, 0.4)
    unusableOverlay:Hide()
    button.unusableOverlay = unusableOverlay

    -- Junk item overlay (gray)
    local junkOverlay = button:CreateTexture(nil, "OVERLAY", nil, 2)
    junkOverlay:SetAllPoints()
    junkOverlay:SetTexture("Interface\\Buttons\\WHITE8x8")
    junkOverlay:SetVertexColor(0.3, 0.3, 0.3, 0.6)
    junkOverlay:Hide()
    button.junkOverlay = junkOverlay

    -- Junk coin icon
    local junkIcon = button:CreateTexture(nil, "OVERLAY", nil, 3)
    junkIcon:SetSize(12, 12)
    junkIcon:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
    junkIcon:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
    junkIcon:Hide()
    button.junkIcon = junkIcon

    -- Crafting quality icon (top-left corner, Retail only)
    local craftingQualityIcon = button:CreateTexture(nil, "OVERLAY", nil, 3)
    craftingQualityIcon:SetSize(20, 20)
    craftingQualityIcon:SetPoint("TOPLEFT", button, "TOPLEFT", -3, 3)
    craftingQualityIcon:Hide()
    button.craftingQualityIcon = craftingQualityIcon

    -- Tracked/favorite icon shadow (for darker stroke effect)
    local trackedIconShadow = button:CreateTexture(nil, "OVERLAY", nil, 2)
    trackedIconShadow:SetSize(14, 14)
    trackedIconShadow:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, 0)
    trackedIconShadow:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\fav.png")
    trackedIconShadow:SetVertexColor(0, 0, 0, 1)
    trackedIconShadow:Hide()
    button.trackedIconShadow = trackedIconShadow

    -- Tracked/favorite icon (top right corner)
    local trackedIcon = button:CreateTexture(nil, "OVERLAY", nil, 3)
    trackedIcon:SetSize(12, 12)
    trackedIcon:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, -1)
    trackedIcon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\fav.png")
    trackedIcon:Hide()
    button.trackedIcon = trackedIcon

    -- Equipment set icon shadow (bottom-left corner)
    local equipSetIconShadow = button:CreateTexture(nil, "OVERLAY", nil, 2)
    equipSetIconShadow:SetSize(15, 15)
    equipSetIconShadow:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    equipSetIconShadow:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\equipment.png")
    equipSetIconShadow:SetVertexColor(0, 0, 0, 1)
    equipSetIconShadow:Hide()
    button.equipSetIconShadow = equipSetIconShadow

    -- Equipment set icon (bottom-left corner)
    local equipSetIcon = button:CreateTexture(nil, "OVERLAY", nil, 3)
    equipSetIcon:SetSize(13, 13)
    equipSetIcon:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 1, 1)
    equipSetIcon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\equipment.png")
    equipSetIcon:Hide()
    button.equipSetIcon = equipSetIcon

    -- Item level text (top-left corner)
    local itemLevelText = button:CreateFontString(nil, "OVERLAY", nil)
    itemLevelText:SetFont(Constants.FONTS.DEFAULT, 12, "OUTLINE")
    itemLevelText:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
    itemLevelText:SetJustifyH("LEFT")
    itemLevelText:Hide()
    button.itemLevelText = itemLevelText

    -- Quest starter icon (top left corner) - exclamation mark for quest starter items
    -- Use a frame container to ensure it draws above the border
    local questStarterFrame = CreateFrame("Frame", nil, button)
    questStarterFrame:SetFrameLevel(button:GetFrameLevel() + Constants.FRAME_LEVELS.QUEST_ICON)
    questStarterFrame:SetSize(14, 14)
    questStarterFrame:SetPoint("TOPLEFT", button, "TOPLEFT", -4, 2)
    local questStarterIcon = questStarterFrame:CreateTexture(nil, "OVERLAY")
    questStarterIcon:SetAllPoints()
    questStarterIcon:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
    questStarterFrame:Hide()
    button.questStarterIcon = questStarterFrame

    -- Quest item icon (top left corner) - question mark for regular quest items
    -- Use a frame container to ensure it draws above the border
    local questIconFrame = CreateFrame("Frame", nil, button)
    questIconFrame:SetFrameLevel(button:GetFrameLevel() + Constants.FRAME_LEVELS.QUEST_ICON)
    questIconFrame:SetSize(14, 14)
    questIconFrame:SetPoint("TOPLEFT", button, "TOPLEFT", -4, 2)
    local questIcon = questIconFrame:CreateTexture(nil, "OVERLAY")
    questIcon:SetAllPoints()
    questIcon:SetTexture("Interface\\GossipFrame\\ActiveQuestIcon")
    questIconFrame:Hide()
    button.questIcon = questIconFrame

    -- Replace tooltip scripts (not hook, to prevent template's SetBagItem from running first)
    button:SetScript("OnEnter", function(self)
        -- Wrap in pcall to prevent errors from breaking interaction
        local success, err = pcall(function()
            -- Initialize shift state tracking for tooltip refresh
            self.lastShiftState = IsShiftKeyDown()

            -- Call Blizzard's handler for sell cursor, inspect cursor, etc.
            -- Skip for pseudo-items (Empty/Soul) which don't have real bag slots
            if self.itemData and self.itemData.bagID and not self.isEmptySlotButton and not self.itemData.isEmptySlots then
                -- ContainerFrameItemButton_OnEnter may not exist on retail
                if ContainerFrameItemButton_OnEnter then
                    ContainerFrameItemButton_OnEnter(self)
                end
            end

            -- Show our custom tooltip (overrides Blizzard's if needed)
            -- Don't show tooltip for Empty/Soul pseudo-item buttons
            if not self.isEmptySlotButton and not (self.itemData and self.itemData.isEmptySlots) then
                Tooltip:ShowForItem(self)
            end


            -- Debug item info on hover
            if ns.debugItemMode and self.itemData and self.itemData.link then
                local d = self.itemData
                local catName = "?"
                if self.categoryId then
                    local CategoryManager = ns:GetModule("CategoryManager")
                    if CategoryManager then
                        local catDef = CategoryManager:GetCategory(self.categoryId)
                        catName = catDef and catDef.name or self.categoryId
                    end
                end
                ns:Print(format("|cff00ff00[DebugItem]|r %s | ID: %s | Bag: %s Slot: %s | Count: %s | Quality: %s | Category: %s | Type: %s - %s | Quest: %s | Duration: %s",
                    d.link or "?",
                    tostring(d.itemID or "?"),
                    tostring(d.bagID or "?"),
                    tostring(d.slot or "?"),
                    tostring(d.count or 1),
                    tostring(d.quality or "?"),
                    tostring(catName),
                    tostring(d.itemType or "?"),
                    tostring(d.itemSubType or "?"),
                    tostring(d.isQuestItem or false),
                    tostring(d.hasDuration or false)
                ))
            end

            -- Show drag-drop indicator if cursor has item and this is a category view item
            if self.categoryId and self.containerFrame then
                local cursorType = GetCursorInfo()
                if cursorType == "item" then
                    local CategoryDropIndicator = ns:GetModule("CategoryDropIndicator")
                    if CategoryDropIndicator then
                        CategoryDropIndicator:OnItemButtonEnter(self)
                    end
                end
            end
        end)
        if not success and ns.debugMode then
            ns:Print("OnEnter error: " .. tostring(err))
        end
    end)

    button:SetScript("OnLeave", function(self)
        -- Wrap in pcall to prevent errors
        local success, err = pcall(function()
            -- Clear shift state tracking
            self.lastShiftState = nil

            -- Call Blizzard's handler to clear cursor state (may not exist on retail)
            if ContainerFrameItemButton_OnLeave then
                ContainerFrameItemButton_OnLeave(self)
            end

            -- Hide our custom tooltip
            Tooltip:Hide()

            -- Hide drag-drop indicator
            local CategoryDropIndicator = ns:GetModule("CategoryDropIndicator")
            if CategoryDropIndicator then
                CategoryDropIndicator:OnItemButtonLeave()
            end
        end)
        if not success and ns.debugMode then
            ns:Print("OnLeave error: " .. tostring(err))
        end
    end)

    -- Update indicator position while hovering with dragged item
    -- Also refresh tooltip when shift key state changes (for price display)
    button:SetScript("OnUpdate", function(self)
        -- Track shift key state for tooltip refresh
        if self:IsMouseOver() then
            local shiftDown = IsShiftKeyDown()
            if self.lastShiftState ~= shiftDown then
                self.lastShiftState = shiftDown
                -- Refresh tooltip when shift state changes (for stack price vs single price)
                if self.itemData and not self.isEmptySlotButton and not self.itemData.isEmptySlots then
                    Tooltip:ShowForItem(self)
                end
            end
        end

        -- Update drag-drop indicator position
        if self.categoryId and self.containerFrame and self:IsMouseOver() then
            local CategoryDropIndicator = ns:GetModule("CategoryDropIndicator")
            if CategoryDropIndicator and CategoryDropIndicator:IsShown() then
                CategoryDropIndicator:OnItemButtonUpdate(self)
            end
        end
    end)

    -- Disable template's tooltip update mechanism
    button.UpdateTooltip = nil

    -- Helper function to find current first empty slot for pseudo-items
    -- For Soul pseudo-items, find empty slot in soul bags
    -- For Empty pseudo-items, find empty slot in regular bags
    local function FindCurrentEmptySlot(btn)
        if not btn.isEmptySlotButton and not (btn.itemData and btn.itemData.isEmptySlots) then
            return nil, nil
        end

        -- Check if this is a Soul category pseudo-item
        local isSoulCategory = btn.categoryId == "Soul" or (btn.itemData and btn.itemData.isSoulSlots)

        -- Use BagClassifier for accurate bag type detection
        local BagClassifier = ns:GetModule("BagFrame.BagClassifier")

        -- Scan bags to find first empty slot
        for bagID = 0, NUM_BAG_SLOTS do
            local numSlots = C_Container.GetContainerNumSlots(bagID)
            if numSlots and numSlots > 0 then
                -- Check bag type using BagClassifier
                local bagType = BagClassifier and BagClassifier:GetBagType(bagID) or "regular"
                local isSoulBag = (bagType == "soul")

                -- Match bag type to category
                local shouldSearchThisBag = false
                if isSoulCategory then
                    shouldSearchThisBag = isSoulBag
                else
                    -- Empty category: regular bags only (backpack or regular bag type)
                    shouldSearchThisBag = (bagID == 0) or (bagType == "regular")
                end

                if shouldSearchThisBag then
                    for slotID = 1, numSlots do
                        local itemInfo = C_Container.GetContainerItemInfo(bagID, slotID)
                        if not itemInfo then
                            -- Found empty slot
                            return bagID, slotID
                        end
                    end
                end
            end
        end

        return nil, nil
    end

    -- Update bagID/slotID for pseudo-item before click/drag
    local function UpdatePseudoItemSlot(btn)
        if not btn.isEmptySlotButton and not (btn.itemData and btn.itemData.isEmptySlots) then
            return false
        end

        local newBagID, newSlotID = FindCurrentEmptySlot(btn)
        if newBagID and newSlotID then
            btn.wrapper:SetID(newBagID)
            btn:SetID(newSlotID)
            if btn.itemData then
                btn.itemData.bagID = newBagID
                btn.itemData.slot = newSlotID
            end
            return true
        end

        return false  -- No empty slot found
    end

    -- Ctrl+Alt+Click to track/untrack items
    -- Also handle guild bank item clicks and read-only item linking
    button:HookScript("OnClick", function(self, mouseButton)
        -- Wrap in pcall to prevent errors from breaking item interaction
        local success, err = pcall(function()
            -- Handle shift-click to link items in chat for read-only items (cached/view mode)
            -- The template's handler doesn't work because we set IDs to 0 for read-only mode
            if mouseButton == "LeftButton" and IsShiftKeyDown() and self.isReadOnly then
                local link = self.itemData and (self.itemData.link or self.itemData.itemLink)
                if link then
                    HandleModifiedItemClick(link)
                end
                return
            end

            -- Track/untrack with Ctrl+Alt+Click
            if mouseButton == "LeftButton" and IsControlKeyDown() and IsAltKeyDown() then
                if self.itemData and self.itemData.itemID then
                    local TrackedBar = ns:GetModule("TrackedBar")
                    if TrackedBar then
                        TrackedBar:ToggleTrackItem(self.itemData.itemID)
                    end
                end
                return
            end

            -- Handle guild bank items (not handled by ContainerFrameItemButtonTemplate)
            if self.itemData and self.itemData.isGuildBank and not self.isReadOnly then
                local tabIndex = self.itemData.bagID  -- bagID is actually tabIndex for guild bank
                local slotIndex = self.itemData.slot

                if mouseButton == "LeftButton" then
                    if IsShiftKeyDown() and self.itemData.count and self.itemData.count > 1 then
                        -- Split stack
                        OpenStackSplitFrame(self.itemData.count, self, "BOTTOMLEFT", "TOPLEFT")
                    else
                        -- Pick up / place item
                        PickupGuildBankItem(tabIndex, slotIndex)
                    end
                elseif mouseButton == "RightButton" then
                    -- Right-click to auto-move to bags (if at guild bank)
                    local GuildBankScanner = ns:GetModule("GuildBankScanner")
                    if GuildBankScanner and GuildBankScanner:IsGuildBankOpen() then
                        AutoStoreGuildBankItem(tabIndex, slotIndex)
                    end
                end
            end
        end)
        if not success and ns.debugMode then
            ns:Print("OnClick error: " .. tostring(err))
        end
    end)

    -- Handle stack split for guild bank items
    button.SplitStack = function(self, amount)
        if self.itemData and self.itemData.isGuildBank and not self.isReadOnly then
            local tabIndex = self.itemData.bagID
            local slotIndex = self.itemData.slot
            SplitGuildBankItem(tabIndex, slotIndex, amount)
        end
    end

    -- Helper function to find where the cursor item is coming from
    -- Returns "bag", "bank", or nil if unknown
    local function GetCursorItemSource()
        -- Check player bags (0 to NUM_BAG_SLOTS) for locked slot
        for bagID = 0, NUM_BAG_SLOTS do
            local numSlots = C_Container.GetContainerNumSlots(bagID)
            for slot = 1, numSlots do
                local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                if itemInfo and itemInfo.isLocked then
                    return "bag"
                end
            end
        end

        -- Check bank slots for locked slot
        -- Build bank bag list based on game version
        local bankBags = {}

        -- On modern Retail (12.0+), use Character Bank Tabs
        if Constants.CHARACTER_BANK_TAB_IDS and #Constants.CHARACTER_BANK_TAB_IDS > 0 then
            for _, tabID in ipairs(Constants.CHARACTER_BANK_TAB_IDS) do
                table.insert(bankBags, tabID)
            end
        end

        -- Also check Warband/Account bank tabs
        if Constants.WARBAND_BANK_TAB_IDS and #Constants.WARBAND_BANK_TAB_IDS > 0 then
            for _, tabID in ipairs(Constants.WARBAND_BANK_TAB_IDS) do
                table.insert(bankBags, tabID)
            end
        end

        -- Use BANK_BAG_IDS as fallback (works for older Retail and Classic)
        if #bankBags == 0 and Constants.BANK_BAG_IDS and #Constants.BANK_BAG_IDS > 0 then
            for _, bagID in ipairs(Constants.BANK_BAG_IDS) do
                table.insert(bankBags, bagID)
            end
        end

        for _, bagID in ipairs(bankBags) do
            local numSlots = C_Container.GetContainerNumSlots(bagID)
            if numSlots and numSlots > 0 then
                for slot = 1, numSlots do
                    local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                    if itemInfo and itemInfo.isLocked then
                        return "bank"
                    end
                end
            end
        end

        return nil
    end

    -- Helper function to check if swap should be BLOCKED
    -- Returns true to BLOCK swap (same container - no swapping within bag or within bank)
    -- Returns false to ALLOW swap (cross-container only - bag↔bank)
    local function ShouldBlockSwap(targetButton)
        -- Only block in category view with valid target
        if not targetButton.categoryId or not targetButton.itemData then
            return false
        end

        local cursorType, cursorItemID = GetCursorInfo()
        if cursorType ~= "item" or not cursorItemID then
            return false
        end

        -- Determine if this is a cross-container operation
        -- Cross-container swaps (bag↔bank) are ALLOWED
        -- Same-container swaps (bag→bag or bank→bank) are BLOCKED
        if targetButton.containerFrame then
            local containerName = targetButton.containerFrame:GetName()
            local cursorSource = GetCursorItemSource()

            if containerName == "GudaBankContainer" then
                -- Target is in bank
                if cursorSource == "bag" then
                    return false  -- Bag to Bank - ALLOW
                else
                    return true   -- Bank to Bank - BLOCK
                end
            end

            if containerName == "GudaBagsSecureContainer" then
                -- Target is in bag
                if cursorSource == "bank" then
                    return false  -- Bank to Bag - ALLOW
                else
                    return true   -- Bag to Bag - BLOCK
                end
            end
        end

        -- Same container operation - block the swap
        return true
    end

    -- Prevent swapping via click within the same container (bag or bank)
    -- Only allow cross-container swaps (bag↔bank)
    -- Also update pseudo-item slots to use current empty slot
    -- NOTE: On Retail, skip these operations to avoid tainting the secure click handler
    button:HookScript("PreClick", function(self, mouseButton)
        -- Suppress spurious "Item isn't ready yet" errors on retail
        SuppressItemErrors()

        -- On Retail, don't do anything that could taint the secure click path
        if ns.IsRetail then return end

        -- For pseudo-item buttons, update to current empty slot BEFORE secure handler runs
        if self.isEmptySlotButton or (self.itemData and self.itemData.isEmptySlots) then
            local cursorType = GetCursorInfo()
            if cursorType == "item" then
                UpdatePseudoItemSlot(self)
            end
            return  -- Don't check same-category for pseudo-items
        end

        if mouseButton == "LeftButton" and ShouldBlockSwap(self) then
            ClearCursor()
        end
    end)

    -- Custom OnReceiveDrag to prevent swapping items within the same container
    -- Only allows cross-container swaps (bag↔bank)
    -- Also handles pseudo-item buttons to place items in current empty slot
    -- Also handles guild bank items
    local originalReceiveDrag = button:GetScript("OnReceiveDrag")
    button:SetScript("OnReceiveDrag", function(self)
        -- Handle guild bank items (works on both Classic and Retail)
        if self.itemData and self.itemData.isGuildBank and not self.isReadOnly then
            local cursorType = GetCursorInfo()
            if cursorType == "item" then
                local tabIndex = self.itemData.bagID
                local slotIndex = self.itemData.slot
                PickupGuildBankItem(tabIndex, slotIndex)
            end
            return
        end

        -- For pseudo-item buttons (Empty/Soul), find current empty slot
        if self.isEmptySlotButton or (self.itemData and self.itemData.isEmptySlots) then
            local cursorType = GetCursorInfo()
            if cursorType == "item" then
                local newBagID, newSlotID = FindCurrentEmptySlot(self)
                if newBagID and newSlotID then
                    -- Place item in the current first empty slot
                    C_Container.PickupContainerItem(newBagID, newSlotID)
                end
            end
            return
        end

        -- Block same-container swaps (only allow cross-container bag↔bank)
        -- This check applies to both Classic and Retail
        if ShouldBlockSwap(self) then
            ClearCursor()
            return
        end

        -- Allow cross-container swap (bag↔bank)
        -- Use itemData for bag/slot since GudaBags uses pooled buttons
        if self.itemData and self.itemData.bagID and self.itemData.slot then
            C_Container.PickupContainerItem(self.itemData.bagID, self.itemData.slot)
        elseif originalReceiveDrag then
            originalReceiveDrag(self)
        end
    end)

    return button
end

function ItemButton:Acquire(parent)
    -- Lazy initialize pool on first use
    if not buttonPool then
        buttonPool = CreateObjectPool(
            function() return CreateButton(parent) end,
            ResetButton
        )
    end

    local button = buttonPool:Acquire()
    button.wrapper:SetParent(parent)
    button.wrapper:SetShown(true)  -- Use SetShown to avoid taint during combat
    button:SetShown(true)
    button.owner = parent

    -- Apply retail slot textures immediately so first-open doesn't flash default
    local Theme = ns:GetModule("Theme")
    ApplyThemeToButton(button, Theme:Get().slotTextures)

    return button
end

function ItemButton:Release(button)
    if not buttonPool then return end

    -- Check if button is active before releasing (avoid double-release error)
    local isActive = false
    for activeButton in buttonPool:EnumerateActive() do
        if activeButton == button then
            isActive = true
            break
        end
    end
    if not isActive then return end

    -- Minimal cleanup - visual reset happens in SetItem (lazy cleanup)
    button.currentSize = nil

    -- Release to pool (ResetButton callback handles hide/clear/anchors)
    buttonPool:Release(button)
end

function ItemButton:ReleaseAll(owner)
    if not buttonPool then return end

    -- If owner specified, we need to iterate and release matching buttons
    if owner then
        -- Collect buttons to release (can't modify during iteration)
        local toRelease = {}
        for button in buttonPool:EnumerateActive() do
            if button.owner == owner then
                table.insert(toRelease, button)
            end
        end
        for _, button in ipairs(toRelease) do
            self:Release(button)
        end
    else
        -- Release all - pool's ReleaseAll handles cleanup via ResetButton callback
        -- Skip visual reset here - will be done in SetItem when button is reused
        buttonPool:ReleaseAll()
    end
end

-- Pre-create buttons so they're available during combat
-- ContainerFrameItemButtonTemplate is a secure template that cannot be created during combat
-- Call this on PLAYER_LOGIN before entering combat
function ItemButton:PreWarm(parent, count)
    count = count or 200  -- Default to 200 buttons (enough for all bag slots + buffer)

    -- Initialize pool if needed
    if not buttonPool then
        buttonPool = CreateObjectPool(
            function() return CreateButton(parent) end,
            ResetButton
        )
    end

    -- Create buttons by acquiring from pool
    for i = 1, count do
        local button = buttonPool:Acquire()
        button.wrapper:SetParent(parent)
    end

    -- Release all back to pool so they're available for use
    buttonPool:ReleaseAll()

end

-- Cached settings for batch updates (set by SetItemBatch or refreshed on demand)
local cachedSettings = nil
local cachedSettingsFrame = 0  -- Frame number when cached

local function GetCachedSettings()
    local currentFrame = GetTime()
    -- Cache settings for 0.1 second to avoid repeated lookups during batch updates
    if not cachedSettings or (currentFrame - cachedSettingsFrame) > 0.1 then
        cachedSettings = {
            iconSize = Database:GetSetting("iconSize"),
            bgAlpha = Database:GetSetting("bgAlpha") / 100,
            iconFontSize = Database:GetSetting("iconFontSize"),
            grayoutJunk = Database:GetSetting("grayoutJunk"),
            equipmentBorders = Database:GetSetting("equipmentBorders"),
            otherBorders = Database:GetSetting("otherBorders"),
            markUnusableItems = Database:GetSetting("markUnusableItems"),
            markEquipmentSets = Database:GetSetting("markEquipmentSets"),
            showItemLevel = Database:GetSetting("showItemLevel"),
        }
        cachedSettingsFrame = currentFrame
    end
    return cachedSettings
end

-- Invalidate cached settings (call when settings change)
function ItemButton:InvalidateSettingsCache()
    cachedSettings = nil
end

function ItemButton:SetItem(button, itemData, size, isReadOnly)
    -- Hide Blizzard template's built-in textures (they may re-show from events)
    if button.IconBorder then button.IconBorder:Hide() end
    if button.IconOverlay then button.IconOverlay:Hide() end
    if button.NewItemTexture then button.NewItemTexture:Hide() end
    if button.BattlepayItemTexture then button.BattlepayItemTexture:Hide() end
    local normalTex = button:GetNormalTexture()
    if normalTex then normalTex:Hide() end

    -- Reset visual state from previous item (lazy cleanup)
    -- These elements might not be explicitly set below
    if button.trackedIcon then button.trackedIcon:Hide() end
    if button.trackedIconShadow then button.trackedIconShadow:Hide() end
    if button.equipSetIcon then button.equipSetIcon:Hide() end
    if button.equipSetIconShadow then button.equipSetIconShadow:Hide() end
    if button.questIcon then button.questIcon:Hide() end
    if button.questStarterIcon then button.questStarterIcon:Hide() end
    if button.junkIcon then button.junkIcon:Hide() end
    if button.craftingQualityIcon then button.craftingQualityIcon:Hide() end

    button.itemData = itemData
    button.isReadOnly = isReadOnly or false

    local settings = GetCachedSettings()
    size = size or settings.iconSize

    -- Only resize if size actually changed
    if button.currentSize ~= size then
        button:SetSize(size, size)
        button.wrapper:SetSize(size, size)
        button.currentSize = size

    end

    button.slotBackground:SetVertexColor(0.5, 0.5, 0.5, settings.bgAlpha)

    ApplyFontSize(button, settings.iconFontSize)

    -- Special handling for "Empty" and "Soul" category pseudo-items
    if itemData and itemData.isEmptySlots then
        -- Display texture with count
        SetItemButtonTexture(button, itemData.texture or "Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag")
        SetItemButtonCount(button, itemData.emptyCount or 0)

        -- Gray out both Empty and Soul pseudo-items for consistent appearance
        SetItemButtonDesaturated(button, true)

        -- Hide all overlays
        button.border:Hide()
        if button.innerShadow then
            for _, tex in pairs(button.innerShadow) do tex:Hide() end
        end
        button.unusableOverlay:Hide()
        button.junkOverlay:Hide()
        button.lockOverlay:Hide()
        if button.itemLevelText then button.itemLevelText:Hide() end
        if button.cooldown then CooldownFrame_Set(button.cooldown, 0, 0, false) end

        -- Mark this button as empty slot handler
        button.isEmptySlotButton = true

        -- Set real bagID/slot so template's click handler places items correctly
        -- itemData now contains real bagID/slot of first empty slot
        button.wrapper:SetID(itemData.bagID)
        button:SetID(itemData.slot)

        return
    end

    if itemData then
        -- Set IDs for ContainerFrameItemButtonTemplate's secure click handler
        -- Use invalid IDs for read-only mode or guild bank items to prevent template from
        -- interfering (guild bank items are handled by our own OnClick hook)
        if isReadOnly or itemData.isGuildBank then
            -- Set to 0 for read-only mode or guild bank items
            -- Guild bank items use their own click handler, not the template's
            button.wrapper:SetID(0)
            button:SetID(0)
        else
            button.wrapper:SetID(itemData.bagID)
            button:SetID(itemData.slot)
        end

        -- Use template's built-in functions for icon and count
        SetItemButtonTexture(button, itemData.texture)
        SetItemButtonCount(button, itemData.count)

        -- Keep template's visual elements hidden (we use our own)
        if button.IconBorder then button.IconBorder:Hide() end
        if button.IconOverlay then button.IconOverlay:Hide() end

        -- Apply gray overlay for junk items
        if settings.grayoutJunk and IsJunkItem(itemData) then
            button.junkOverlay:Show()
        else
            button.junkOverlay:Hide()
        end

        -- Quality border (quest items override with golden border)
        local isEquipment = itemData.itemType == "Armor" or itemData.itemType == "Weapon"
        local showBorder = isEquipment and settings.equipmentBorders or (not isEquipment and settings.otherBorders)

        -- Helper to show inner shadow with color
        local function ShowInnerShadow(color)
            if button.innerShadow then
                local r, g, b = color[1], color[2], color[3]
                button.innerShadow.top:SetGradient("VERTICAL", CreateColor(r, g, b, 0), CreateColor(r, g, b, 0.5))
                button.innerShadow.bottom:SetGradient("VERTICAL", CreateColor(r, g, b, 0.5), CreateColor(r, g, b, 0))
                button.innerShadow.left:SetGradient("HORIZONTAL", CreateColor(r, g, b, 0.5), CreateColor(r, g, b, 0))
                button.innerShadow.right:SetGradient("HORIZONTAL", CreateColor(r, g, b, 0), CreateColor(r, g, b, 0.5))
                for _, tex in pairs(button.innerShadow) do tex:Show() end
            end
        end
        local function HideInnerShadow()
            if button.innerShadow then
                for _, tex in pairs(button.innerShadow) do tex:Hide() end
            end
        end

        -- Quest items and usable duration items show border with quest color
        local showQuestIndicator = not (itemData.quality == 0 and IsJunkItem(itemData)) and (itemData.isQuestItem or (itemData.hasDuration and itemData.itemID and GetItemSpell(itemData.itemID)))
        if showQuestIndicator then
            local questColor = itemData.isQuestStarter and Constants.COLORS.QUEST_STARTER or Constants.COLORS.QUEST
            button.border:SetVertexColor(questColor[1], questColor[2], questColor[3], 1)
            button.border:Show()
            ShowInnerShadow(questColor)
        elseif showBorder and itemData.quality ~= nil then
            local color = Constants.QUALITY_COLORS[itemData.quality]
            if color then
                button.border:SetVertexColor(color[1], color[2], color[3], 1)
                button.border:Show()
                ShowInnerShadow(color)
            else
                button.border:Hide()
                HideInnerShadow()
            end
        else
            button.border:Hide()
            HideInnerShadow()
        end

        if itemData.locked then
            button.lockOverlay:Show()
            SetItemButtonDesaturated(button, true)
        else
            button.lockOverlay:Hide()
            SetItemButtonDesaturated(button, false)
        end

        -- Update cooldown
        local isOnCooldown = false
        if button.cooldown and not isReadOnly then
            local start, duration, enable = C_Container.GetContainerItemCooldown(itemData.bagID, itemData.slot)
            if start and duration and enable and enable > 0 and duration > 0 then
                CooldownFrame_Set(button.cooldown, start, duration, true)
                isOnCooldown = true
            else
                CooldownFrame_Set(button.cooldown, 0, 0, false)
            end
        elseif button.cooldown then
            CooldownFrame_Set(button.cooldown, 0, 0, false)
        end

        if settings.markUnusableItems and itemData.isUsable == false and not isOnCooldown then
            button.unusableOverlay:Show()
        else
            button.unusableOverlay:Hide()
        end

        if button.junkIcon then
            if IsJunkItem(itemData) then
                button.junkIcon:Show()
            else
                button.junkIcon:Hide()
            end
        end

        -- Quest item icons (starter = exclamation, regular = question mark)
        if button.questStarterIcon then
            if itemData.isQuestStarter then
                button.questStarterIcon:Show()
            else
                button.questStarterIcon:Hide()
            end
        end
        if button.questIcon then
            if showQuestIndicator and not itemData.isQuestStarter then
                button.questIcon:Show()
            else
                button.questIcon:Hide()
            end
        end

        -- Crafting quality icon (Retail profession items)
        if button.craftingQualityIcon then
            if itemData.craftingQuality and itemData.craftingQuality > 0 then
                local cqSize = math.max(20, math.floor(size * 0.54))
                button.craftingQualityIcon:SetSize(cqSize, cqSize)
                button.craftingQualityIcon:SetAtlas("Professions-Icon-Quality-Tier" .. itemData.craftingQuality, false)
                button.craftingQualityIcon:Show()
            else
                button.craftingQualityIcon:Hide()
            end
        end

        -- Tracked item icon
        if button.trackedIcon then
            local TrackedBar = ns:GetModule("TrackedBar")
            if TrackedBar and TrackedBar:IsTracked(itemData.itemID) then
                button.trackedIcon:Show()
                if button.trackedIconShadow then
                    button.trackedIconShadow:Show()
                end
            else
                button.trackedIcon:Hide()
                if button.trackedIconShadow then
                    button.trackedIconShadow:Hide()
                end
            end
        end

        -- Equipment set icon (use category mark if available)
        if button.equipSetIcon then
            if settings.markEquipmentSets and itemData.itemID then
                local EquipSets = ns:GetModule("EquipmentSets")
                if EquipSets and EquipSets:IsInSet(itemData.itemID) then
                    -- Determine icon from category mark
                    local markIcon = "Interface\\AddOns\\GudaBags\\Assets\\equipment.png"
                    local Database = ns:GetModule("Database")
                    if Database and Database:GetSetting("showEquipSetCategories") then
                        local CategoryManager = ns:GetModule("CategoryManager")
                        if CategoryManager then
                            local setNames = EquipSets:GetSetNames(itemData.itemID)
                            if setNames and #setNames > 0 then
                                table.sort(setNames)
                                local catDef = CategoryManager:GetCategory("EquipSet:" .. setNames[1])
                                if catDef and catDef.categoryMark then
                                    markIcon = catDef.categoryMark
                                end
                            end
                        end
                    end
                    button.equipSetIcon:SetTexture(markIcon)
                    button.equipSetIcon:Show()
                    if button.equipSetIconShadow then
                        button.equipSetIconShadow:SetTexture(markIcon)
                        button.equipSetIconShadow:Show()
                    end
                else
                    button.equipSetIcon:Hide()
                    if button.equipSetIconShadow then button.equipSetIconShadow:Hide() end
                end
            else
                button.equipSetIcon:Hide()
                if button.equipSetIconShadow then button.equipSetIconShadow:Hide() end
            end
        end

        -- Item level display (Weapon classID=2, Armor classID=4)
        if button.itemLevelText then
            local isEquip = itemData.classID and (itemData.classID == 2 or itemData.classID == 4)
            if settings.showItemLevel and isEquip and itemData.itemLevel and itemData.itemLevel > 0 and (itemData.quality or 0) > 0 then
                button.itemLevelText:SetText(itemData.itemLevel)
                button.itemLevelText:Show()
            else
                button.itemLevelText:Hide()
            end
        end
    else
        button.wrapper:SetID(0)
        button:SetID(0)

        SetItemButtonTexture(button, nil)
        SetItemButtonCount(button, 0)
        button.icon:SetVertexColor(1, 1, 1, 1)
        button.border:Hide()
        if button.innerShadow then
            for _, tex in pairs(button.innerShadow) do tex:Hide() end
        end
        button.lockOverlay:Hide()
        button.unusableOverlay:Hide()
        if button.junkOverlay then
            button.junkOverlay:Hide()
        end
        if button.junkIcon then
            button.junkIcon:Hide()
        end
        if button.questIcon then
            button.questIcon:Hide()
        end
        if button.questStarterIcon then
            button.questStarterIcon:Hide()
        end
        if button.trackedIcon then
            button.trackedIcon:Hide()
        end
        if button.trackedIconShadow then
            button.trackedIconShadow:Hide()
        end
        if button.equipSetIcon then
            button.equipSetIcon:Hide()
        end
        if button.equipSetIconShadow then
            button.equipSetIconShadow:Hide()
        end
        if button.itemLevelText then
            button.itemLevelText:Hide()
        end
        if button.cooldown then
            CooldownFrame_Set(button.cooldown, 0, 0, false)
        end
    end
end

function ItemButton:SetEmpty(button, bagID, slot, size, isReadOnly, isGuildBank)
    -- Hide Blizzard template's built-in textures (they may re-show from events)
    if button.IconBorder then button.IconBorder:Hide() end
    if button.IconOverlay then button.IconOverlay:Hide() end
    if button.NewItemTexture then button.NewItemTexture:Hide() end
    if button.BattlepayItemTexture then button.BattlepayItemTexture:Hide() end
    local normalTex = button:GetNormalTexture()
    if normalTex then normalTex:Hide() end

    button.itemData = {bagID = bagID, slot = slot, isGuildBank = isGuildBank or false}
    button.isReadOnly = isReadOnly or false

    -- Set IDs for ContainerFrameItemButtonTemplate's secure click handler
    -- Use invalid IDs for read-only mode or guild bank items to prevent template from
    -- interfering (guild bank items are handled by our own OnClick hook)
    -- Skip during combat to avoid taint
    if not InCombatLockdown() then
        if isReadOnly or isGuildBank then
            -- Set to 0 for read-only mode or guild bank items
            button.wrapper:SetID(0)
            button:SetID(0)
        else
            button.wrapper:SetID(bagID)
            button:SetID(slot)
        end
    end

    local settings = GetCachedSettings()
    size = size or settings.iconSize

    -- Only resize if size actually changed
    if button.currentSize ~= size then
        button:SetSize(size, size)
        button.wrapper:SetSize(size, size)
        button.currentSize = size
    end

    button.slotBackground:SetVertexColor(0.5, 0.5, 0.5, settings.bgAlpha)

    SetItemButtonTexture(button, nil)
    SetItemButtonCount(button, 0)
    button.border:Hide()
    if button.innerShadow then
        for _, tex in pairs(button.innerShadow) do tex:Hide() end
    end
    button.lockOverlay:Hide()
    button.unusableOverlay:Hide()
    if button.junkOverlay then
        button.junkOverlay:Hide()
    end
    if button.junkIcon then
        button.junkIcon:Hide()
    end
    if button.questIcon then
        button.questIcon:Hide()
    end
    if button.questStarterIcon then
        button.questStarterIcon:Hide()
    end
    if button.trackedIcon then
        button.trackedIcon:Hide()
    end
    if button.trackedIconShadow then
        button.trackedIconShadow:Hide()
    end
    if button.equipSetIcon then
        button.equipSetIcon:Hide()
    end
    if button.equipSetIconShadow then
        button.equipSetIconShadow:Hide()
    end
    if button.craftingQualityIcon then
        button.craftingQualityIcon:Hide()
    end
    if button.itemLevelText then
        button.itemLevelText:Hide()
    end
    if button.cooldown then
        CooldownFrame_Set(button.cooldown, 0, 0, false)
    end
end

function ItemButton:UpdateSlotAlpha(alpha)
    if not buttonPool then return end
    for button in buttonPool:EnumerateActive() do
        if button.slotBackground then
            button.slotBackground:SetVertexColor(0.5, 0.5, 0.5, alpha)
        end
    end
end

function ItemButton:UpdateFontSize()
    if not buttonPool then return end
    for button in buttonPool:EnumerateActive() do
        ApplyFontSize(button)
    end
end

function ItemButton:ApplyThemeTextures()
    local Theme = ns:GetModule("Theme")
    local slotTex = Theme:Get().slotTextures
    if not buttonPool then return end
    for button in buttonPool:EnumerateActive() do
        ApplyThemeToButton(button, slotTex)
    end
end

function ItemButton:GetActiveButtons()
    -- Return iterator for active buttons
    if not buttonPool then return function() end end
    return buttonPool:EnumerateActive()
end

function ItemButton:HighlightBagSlots(bagID, owner)
    if not buttonPool then return end
    local bgAlpha = Database:GetSetting("bgAlpha") / 100

    for button in buttonPool:EnumerateActive() do
        -- Only affect buttons belonging to the specified owner (if provided)
        if owner and button.owner ~= owner then
            -- Skip buttons from other frames
        elseif button.itemData and button.itemData.bagID == bagID then
            button:SetAlpha(1.0)
            if button.slotBackground then
                button.slotBackground:SetVertexColor(0.5, 0.5, 0.5, bgAlpha)
            end
        else
            button:SetAlpha(0.25)
            if button.slotBackground then
                button.slotBackground:SetVertexColor(0.5, 0.5, 0.5, bgAlpha * 0.25)
            end
        end
    end
end

function ItemButton:ClearHighlightedSlots(parentFrame)
    if not buttonPool then return end
    local SearchBar = ns:GetModule("SearchBar")
    local hasSearch = (SearchBar and parentFrame) and SearchBar:HasActiveFilters(parentFrame) or false
    local bgAlpha = Database:GetSetting("bgAlpha") / 100

    for button in buttonPool:EnumerateActive() do
        if hasSearch then
            -- Respect search filter
            if button.itemData and SearchBar:ItemMatchesFilters(parentFrame, button.itemData) then
                button:SetAlpha(1.0)
                if button.slotBackground then
                    button.slotBackground:SetVertexColor(0.5, 0.5, 0.5, bgAlpha)
                end
            else
                button:SetAlpha(0.15)
                if button.slotBackground then
                    button.slotBackground:SetVertexColor(0.5, 0.5, 0.5, bgAlpha * 0.15)
                end
            end
        else
            button:SetAlpha(1.0)
            if button.slotBackground then
                button.slotBackground:SetVertexColor(0.5, 0.5, 0.5, bgAlpha)
            end
        end
    end
end

-- Reset all button alphas unconditionally (no search filter check)
-- If owner is specified, only reset buttons belonging to that owner
function ItemButton:ResetAllAlpha(owner)
    if not buttonPool then return end
    local bgAlpha = Database:GetSetting("bgAlpha") / 100

    for button in buttonPool:EnumerateActive() do
        -- Only affect buttons belonging to the specified owner (if provided)
        if not owner or button.owner == owner then
            button:SetAlpha(1.0)
            if button.slotBackground then
                button.slotBackground:SetVertexColor(0.5, 0.5, 0.5, bgAlpha)
            end
        end
    end
end

--- Re-sync frame levels for all active buttons owned by the given container.
--- Call after changing a container's frame level (e.g. raise/lower on click).
function ItemButton:SyncFrameLevels(owner)
    if not buttonPool then return end
    local ownerLvl = owner and owner:GetFrameLevel() or 0
    for button in buttonPool:EnumerateActive() do
        if not owner or button.owner == owner then
            -- Update wrapper level first (wrapper is parented to owner container)
            if button.wrapper then
                button.wrapper:SetFrameLevel(ownerLvl + 1)
            end
            local btnLvl = ownerLvl + 1 + Constants.FRAME_LEVELS.BUTTON
            button:SetFrameLevel(btnLvl)
            if button.border then button.border:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.BORDER) end
            if button.cooldown then button.cooldown:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.COOLDOWN) end
            if button.questStarterIcon then button.questStarterIcon:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.QUEST_ICON) end
            if button.questIcon then button.questIcon:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.QUEST_ICON) end
        end
    end
end

-- Update lock state for a specific item (called on ITEM_LOCK_CHANGED)
function ItemButton:UpdateLockForItem(bagID, slotID)
    if not buttonPool then return end

    for button in buttonPool:EnumerateActive() do
        if button.itemData and button.itemData.bagID == bagID and button.itemData.slot == slotID then
            local itemInfo = C_Container.GetContainerItemInfo(bagID, slotID)
            local isLocked = itemInfo and itemInfo.isLocked or false

            -- Update cached state
            button.itemData.locked = isLocked

            -- Update visual state
            if isLocked then
                button.lockOverlay:Show()
                SetItemButtonDesaturated(button, true)
            else
                button.lockOverlay:Hide()
                SetItemButtonDesaturated(button, false)
            end
            return  -- Found the button, done
        end
    end
end

-- Update cooldowns on all active buttons when BAG_UPDATE_COOLDOWN fires
-- Without this, cooldowns (e.g. Hearthstone) only update during full bag refresh
local Events = ns:GetModule("Events")
if Events then
    Events:Register("BAG_UPDATE_COOLDOWN", function()
        if not buttonPool then return end
        for button in buttonPool:EnumerateActive() do
            if button.cooldown and button.itemData and button.itemData.bagID and button.itemData.slot
                and not button.isReadOnly and not button.isEmptySlotButton
                and not (button.itemData.isEmptySlots) then
                local start, duration, enable = C_Container.GetContainerItemCooldown(button.itemData.bagID, button.itemData.slot)
                if start and duration and enable and enable > 0 and duration > 0 then
                    CooldownFrame_Set(button.cooldown, start, duration, true)
                else
                    CooldownFrame_Set(button.cooldown, 0, 0, false)
                end
            end
        end
    end, ItemButton)
end

-- Invalidate settings cache when relevant settings change
if Events then
    Events:Register("SETTING_CHANGED", function(event, key, value)
        -- Invalidate cache for any setting that affects item buttons
        if key == "iconSize" or key == "bgAlpha" or key == "iconFontSize"
            or key == "grayoutJunk" or key == "equipmentBorders"
            or key == "otherBorders" or key == "markUnusableItems"
            or key == "markEquipmentSets"
            or key == "showItemLevel" then
            ItemButton:InvalidateSettingsCache()
        end
    end, ItemButton)
end

-- Debug: Get pool statistics
function ItemButton:GetPoolStats()
    if not buttonPool then
        return { active = 0, inactive = 0 }
    end

    local active = buttonPool:GetNumActive() or 0
    local inactive = 0

    -- Count inactive objects if available
    if buttonPool.EnumerateInactive then
        for _ in buttonPool:EnumerateInactive() do
            inactive = inactive + 1
        end
    end

    return {
        active = active,
        inactive = inactive,
        total = active + inactive,
    }
end
