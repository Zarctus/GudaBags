local addonName, ns = ...

local SettingsPopup = {}
ns:RegisterModule("SettingsPopup", SettingsPopup)

local Events = ns:GetModule("Events")
local Theme = ns:GetModule("Theme")

-- Components (loaded after this file via TOC order)
local Slider, Checkbox, ToggleButton, Select
local VerticalStack, HorizontalRow
local TabPanel, SettingsSchema

local frame
local tabPanel

local Constants = ns.Constants
local L = ns.L
local POPUP_WIDTH = Constants.CATEGORY_UI.POPUP_WIDTH
local POPUP_HEIGHT = Constants.CATEGORY_UI.POPUP_HEIGHT
local PADDING = Constants.CATEGORY_UI.POPUP_PADDING

-- Debounced category save
local categorySaveTimer = nil
local SAVE_DEBOUNCE_TIME = Constants.CATEGORY_UI.SAVE_DEBOUNCE_TIME

local function DebouncedSaveCategories(categories)
    local CategoryManager = ns:GetModule("CategoryManager")

    -- Cancel existing timer
    if categorySaveTimer then
        categorySaveTimer:Cancel()
    end

    -- Fire event immediately for instant UI update
    Events:Fire("CATEGORIES_UPDATED")

    -- Debounce the actual save to disk
    categorySaveTimer = C_Timer.NewTimer(SAVE_DEBOUNCE_TIME, function()
        CategoryManager:SaveCategories(categories)
        categorySaveTimer = nil
    end)
end

-- Tab list is built once after locales are loaded, then cached
local cachedTabList = nil
local function GetTabList()
    if not cachedTabList then
        cachedTabList = {
            { id = "general", label = ns.L["TAB_GENERAL"], tooltip = ns.L["TAB_GENERAL_TIP"] },
            { id = "layout", label = ns.L["TAB_LAYOUT"], tooltip = ns.L["TAB_LAYOUT_TIP"] },
            { id = "icons", label = ns.L["TAB_ICONS"], tooltip = ns.L["TAB_ICONS_TIP"] },
            { id = "bar", label = ns.L["TAB_BAR"], tooltip = ns.L["TAB_BAR_TIP"] },
            { id = "categories", label = ns.L["TAB_CATEGORIES"], tooltip = ns.L["TAB_CATEGORIES_TIP"] },
            { id = "profiles", label = ns.L["TAB_PROFILES"], tooltip = ns.L["TAB_PROFILES_TIP"] },
            { id = "guide", label = ns.L["TAB_GUIDE"], tooltip = ns.L["TAB_GUIDE_TIP"] },
        }
    end
    return cachedTabList
end

-------------------------------------------------
-- Control Factory
-------------------------------------------------
local function CreateControl(parent, config)
    -- Check if control should be hidden
    if config.hidden then
        local shouldHide = config.hidden
        if type(shouldHide) == "function" then
            shouldHide = shouldHide()
        end
        if shouldHide then
            return nil
        end
    end

    if config.type == "slider" then
        return Slider:Create(parent, config)
    elseif config.type == "checkbox" then
        return Checkbox:Create(parent, config)
    elseif config.type == "toggle" then
        return ToggleButton:Create(parent, config)
    elseif config.type == "select" then
        return Select:Create(parent, config)
    elseif config.type == "description" then
        -- Simple text description
        local frame = CreateFrame("Frame", nil, parent)
        frame:SetHeight(config.height or 32)
        local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        text:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
        text:SetJustifyH("LEFT")
        text:SetSpacing(2)
        text:SetTextColor(0.7, 0.7, 0.7)
        text:SetText(config.text)
        frame.text = text
        return frame
    elseif config.type == "separator" then
        local frame = CreateFrame("Frame", nil, parent)
        frame:SetHeight(20)
        local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("LEFT", frame, "LEFT", 0, 0)
        text:SetJustifyH("LEFT")
        text:SetTextColor(0.9, 0.75, 0.3)
        text:SetText(config.label or "")
        local line = frame:CreateTexture(nil, "ARTWORK")
        line:SetHeight(1)
        line:SetPoint("LEFT", text, "RIGHT", 6, 0)
        line:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
        line:SetColorTexture(0.5, 0.5, 0.5, 0.5)
        return frame
    elseif config.type == "row" then
        -- Count visible children
        local visibleCount = 0
        for _, childConfig in ipairs(config.children) do
            local shouldHide = childConfig.hidden
            if type(shouldHide) == "function" then
                shouldHide = shouldHide()
            end
            if not shouldHide then
                visibleCount = visibleCount + 1
            end
        end
        if visibleCount == 0 then
            return nil
        end
        local row = HorizontalRow:Create(parent, { columns = visibleCount })
        for _, childConfig in ipairs(config.children) do
            local child = CreateControl(row, childConfig)
            if child then
                row:AddChild(child)
            end
        end
        return row
    end
end

-------------------------------------------------
-- Create Tab from Schema
-------------------------------------------------
local settingsScrollCounter = 0

local function CreateTabFromSchema(parent, schemaOrFunc)
    settingsScrollCounter = settingsScrollCounter + 1
    local scrollName = "GudaSettingsScroll" .. settingsScrollCounter

    -- Scroll frame wrapper for scrollable content
    local scrollFrame = CreateFrame("ScrollFrame", scrollName, parent, "UIPanelScrollFrameTemplate")

    local scrollBar = scrollFrame.ScrollBar or _G[scrollName .. "ScrollBar"]
    if scrollBar then
        scrollBar:SetAlpha(0.7)
    end

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(scrollFrame:GetWidth() or 400)
    scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(scrollChild)

    scrollFrame:SetScript("OnSizeChanged", function(self, width)
        scrollChild:SetWidth(width)
    end)

    local stack = VerticalStack:Create(scrollChild, { spacing = 10 })
    stack:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, 0)
    stack:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", -18, 0)

    local function UpdateScrollHeight()
        local height = stack:GetHeight()
        if height and height > 0 then
            scrollChild:SetHeight(height)
        end
    end

    local function BuildFromSchema(schema)
        for _, item in ipairs(schema) do
            local control = CreateControl(stack, item)
            if control then
                stack:AddChild(control)
            end
        end
        UpdateScrollHeight()
    end

    if type(schemaOrFunc) == "function" then
        BuildFromSchema(schemaOrFunc())
        scrollFrame.RefreshAll = function(self)
            stack:Clear()
            BuildFromSchema(schemaOrFunc())
        end
    else
        BuildFromSchema(schemaOrFunc)
    end

    return scrollFrame
end

-------------------------------------------------
-- Create Categories Tab
-------------------------------------------------

local categoryRows = {}
local groupHeaders = {}
local groupDropZones = {}
local collapsedGroups = {}  -- Track collapsed state per group
local categoriesScrollChild
local draggedRow = nil
local dropIndicator = nil

local function CreateDropIndicator(parent)
    local indicator = CreateFrame("Frame", nil, parent)
    indicator:SetHeight(2)
    indicator:SetFrameLevel(100)

    local tex = indicator:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    local c = Constants.CATEGORY_COLORS.DROP_INDICATOR
    tex:SetColorTexture(c[1], c[2], c[3], c[4])

    indicator:Hide()
    return indicator
end

local function CreateGroupDropZone(parent, groupName, yOffset)
    local DROP_ZONE_HEIGHT = Constants.CATEGORY_UI.DROP_ZONE_HEIGHT

    local zone = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    zone:SetHeight(DROP_ZONE_HEIGHT)
    zone:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    zone:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    zone:SetBackdrop({
        bgFile = Constants.TEXTURES.WHITE_8x8,
    })
    zone:SetBackdropColor(0, 0, 0, 0)  -- Invisible by default

    zone.isDropZone = true
    zone.groupName = groupName
    zone:EnableMouse(true)

    zone:SetScript("OnEnter", function(self)
        local showIndicator = false
        local isGlobalTopZone = groupName == "__TOP__"
        local baseGroupName = string.gsub(groupName, "__TOP__$", "")

        -- Accept groups (and not dropping on same group's zone)
        if draggedRow and draggedRow.isGroupHeader then
            local validTarget = isGlobalTopZone or (draggedRow.groupName ~= baseGroupName)
            if validTarget then
                self.isDropTarget = true
                showIndicator = true
            end
        end

        -- Accept categories (to add them to this group) - not for global __TOP__ zone
        if draggedRow and draggedRow.categoryId and not isGlobalTopZone then
            self.isCategoryDropTarget = true
            showIndicator = true
        end

        if showIndicator then
            local c = Constants.CATEGORY_COLORS.DROP_ZONE_ACTIVE
            self:SetBackdropColor(c[1], c[2], c[3], c[4])
            if dropIndicator then
                dropIndicator:ClearAllPoints()
                dropIndicator:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -DROP_ZONE_HEIGHT/2)
                dropIndicator:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, -DROP_ZONE_HEIGHT/2)
                dropIndicator:Show()
            end
        end
    end)

    zone:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0, 0, 0, 0)
        self.isDropTarget = false
        self.isCategoryDropTarget = false
    end)

    return zone, DROP_ZONE_HEIGHT
end

local function CreateGroupHeader(parent, groupName, yOffset, groupIndex)
    local ROW_HEIGHT = Constants.CATEGORY_UI.GROUP_HEADER_HEIGHT

    local header = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    header:SetHeight(ROW_HEIGHT)
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    header:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    header:SetBackdrop({
        bgFile = Constants.TEXTURES.WHITE_8x8,
    })
    local bgColor = Constants.CATEGORY_COLORS.GROUP_HEADER_BG
    header:SetBackdropColor(bgColor[1], bgColor[2], bgColor[3], bgColor[4])

    -- Merge checkbox (show group as single section)
    local Database = ns:GetModule("Database")
    local mergedGroups = Database:GetSetting("mergedGroups") or {}

    local mergeCB = CreateFrame("CheckButton", nil, header, "UICheckButtonTemplate")
    mergeCB:SetPoint("LEFT", header, "LEFT", 4, 0)
    mergeCB:SetSize(22, 22)
    mergeCB:SetChecked(mergedGroups[groupName] == true)
    mergeCB:SetScript("OnClick", function(self)
        local current = Database:GetSetting("mergedGroups") or {}
        current[groupName] = self:GetChecked()
        Database:SetSetting("mergedGroups", current)
        Events:Fire("SETTING_CHANGED", "mergedGroups", current)
    end)
    mergeCB:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L["MERGE_GROUP"])
        GameTooltip:AddLine(L["MERGE_GROUP_TIP"], 1, 1, 1, true)
        GameTooltip:Show()
        -- Propagate drop target detection to parent header
        if draggedRow and draggedRow ~= header and draggedRow.categoryId then
            header.isCategoryDropTarget = true
            if dropIndicator then
                dropIndicator:ClearAllPoints()
                dropIndicator:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 1)
                dropIndicator:SetPoint("TOPRIGHT", header, "TOPRIGHT", 0, 1)
                dropIndicator:Show()
            end
        end
    end)
    mergeCB:SetScript("OnLeave", function()
        GameTooltip:Hide()
        header.isCategoryDropTarget = false
    end)
    header.mergeCB = mergeCB

    -- Drag handle icon
    local dragHandle = header:CreateTexture(nil, "ARTWORK")
    dragHandle:SetSize(12, 12)
    dragHandle:SetPoint("LEFT", mergeCB, "RIGHT", 2, 0)
    dragHandle:SetTexture(Constants.TEXTURES.CURSOR_MOVE)
    dragHandle:SetVertexColor(0.6, 0.6, 0.6, 0.8)

    -- Group icon
    local icon = header:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", dragHandle, "RIGHT", 6, 0)
    icon:SetTexture(Constants.TEXTURES.GROUP_ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local text = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    text:SetText(ns.DefaultCategories:GetLocalizedGroupName(groupName))
    local textColor = Constants.CATEGORY_COLORS.GROUP_NAME_TEXT
    text:SetTextColor(textColor[1], textColor[2], textColor[3])

    -- Collapse/expand button
    local collapseBtn = CreateFrame("Button", nil, header)
    collapseBtn:SetSize(16, 16)
    collapseBtn:SetPoint("RIGHT", header, "RIGHT", -4, 0)
    collapseBtn:SetNormalTexture("Interface\\Buttons\\UI-MinusButton-Up")
    collapseBtn:SetPushedTexture("Interface\\Buttons\\UI-MinusButton-Down")
    collapseBtn:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight")

    local function UpdateCollapseButton()
        if collapsedGroups[groupName] then
            collapseBtn:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-Up")
            collapseBtn:SetPushedTexture("Interface\\Buttons\\UI-PlusButton-Down")
        else
            collapseBtn:SetNormalTexture("Interface\\Buttons\\UI-MinusButton-Up")
            collapseBtn:SetPushedTexture("Interface\\Buttons\\UI-MinusButton-Down")
        end
    end
    UpdateCollapseButton()

    collapseBtn:SetScript("OnClick", function()
        collapsedGroups[groupName] = not collapsedGroups[groupName]
        UpdateCollapseButton()
        RefreshCategoriesList()
    end)
    collapseBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if collapsedGroups[groupName] then
            GameTooltip:SetText(L["EXPAND_GROUP"])
        else
            GameTooltip:SetText(L["COLLAPSE_GROUP"])
        end
        GameTooltip:Show()
        -- Propagate drop target detection to parent header
        if draggedRow and draggedRow ~= header and draggedRow.categoryId then
            header.isCategoryDropTarget = true
            if dropIndicator then
                dropIndicator:ClearAllPoints()
                dropIndicator:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 1)
                dropIndicator:SetPoint("TOPRIGHT", header, "TOPRIGHT", 0, 1)
                dropIndicator:Show()
            end
        end
    end)
    collapseBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
        header.isCategoryDropTarget = false
    end)
    header.collapseBtn = collapseBtn

    -- Make header draggable
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header.isGroupHeader = true
    header.groupName = groupName

    header:SetScript("OnEnter", function(self)
        SetCursor(Constants.TEXTURES.CURSOR_MOVE)
        local hoverColor = Constants.CATEGORY_COLORS.GROUP_HEADER_HOVER
        self:SetBackdropColor(hoverColor[1], hoverColor[2], hoverColor[3], hoverColor[4])
        dragHandle:SetVertexColor(1, 1, 1, 1)

        -- Drop target detection - for groups or categories being dragged
        if draggedRow and draggedRow ~= self then
            if draggedRow.isGroupHeader then
                -- Accept other groups
                self.isDropTarget = true
            elseif draggedRow.categoryId then
                -- Accept categories (to move them into this group)
                self.isCategoryDropTarget = true
            end

            if self.isDropTarget or self.isCategoryDropTarget then
                if dropIndicator then
                    dropIndicator:ClearAllPoints()
                    dropIndicator:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 1)
                    dropIndicator:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, 1)
                    dropIndicator:Show()
                end
            end
        end
    end)
    header.isUngroupedDropTarget = false
    header.isCategoryDropTarget = false
    header:SetScript("OnLeave", function(self)
        SetCursor(nil)
        local bgColor = Constants.CATEGORY_COLORS.GROUP_HEADER_BG
        self:SetBackdropColor(bgColor[1], bgColor[2], bgColor[3], bgColor[4])
        dragHandle:SetVertexColor(0.6, 0.6, 0.6, 0.8)
        self.isCategoryDropTarget = false
        self.isDropTarget = false
    end)

    header:SetScript("OnDragStart", function(self)
        draggedRow = self
        self:SetAlpha(0.5)
        if not dropIndicator then
            dropIndicator = CreateDropIndicator(categoriesScrollChild)
        end
    end)

    header:SetScript("OnDragStop", function(self)
        self:SetAlpha(1)
        if dropIndicator then
            dropIndicator:Hide()
        end
        if draggedRow and draggedRow.isGroupHeader then
            local CategoryManager = ns:GetModule("CategoryManager")
            local categories = CategoryManager:GetCategories()
            local order = categories.order

            -- Check for group header drop target (drop BEFORE that group)
            local targetGroupBefore = nil
            for _, h in ipairs(groupHeaders) do
                if h.isDropTarget and h ~= draggedRow then
                    targetGroupBefore = h.groupName
                    break
                end
            end

            -- Check for drop zone target (drop AFTER that group)
            local targetGroupAfter = nil
            if not targetGroupBefore then
                for _, zone in ipairs(groupDropZones) do
                    if zone.isDropTarget then
                        targetGroupAfter = zone.groupName
                        break
                    end
                end
            end

            -- Check for ungrouped category drop target
            local targetUngroupedCatId = nil
            if not targetGroupBefore and not targetGroupAfter then
                for _, r in ipairs(categoryRows) do
                    if r.isDropTarget then
                        local catDef = categories.definitions[r.categoryId]
                        if catDef and (not catDef.group or catDef.group == "") then
                            targetUngroupedCatId = r.categoryId
                            break
                        end
                    end
                end
            end

            if targetGroupBefore or targetGroupAfter or targetUngroupedCatId then
                -- Collect categories by group
                local draggedGroupCats = {}
                local ungroupedCats = {}
                local otherGroupedCats = {}  -- { groupName = { cats } }
                local groupOrder = {}  -- Track order of groups as they appear

                for _, catId in ipairs(order) do
                    local def = categories.definitions[catId]
                    if def then
                        local grp = def.group
                        if grp == draggedRow.groupName then
                            table.insert(draggedGroupCats, catId)
                        elseif grp and grp ~= "" then
                            if not otherGroupedCats[grp] then
                                otherGroupedCats[grp] = {}
                                table.insert(groupOrder, grp)
                            end
                            table.insert(otherGroupedCats[grp], catId)
                        else
                            table.insert(ungroupedCats, catId)
                        end
                    end
                end

                local newOrder = {}

                if targetUngroupedCatId then
                    -- Dropping group on ungrouped category - insert group before that category
                    for _, catId in ipairs(ungroupedCats) do
                        if catId == targetUngroupedCatId then
                            -- Insert dragged group here
                            for _, gCatId in ipairs(draggedGroupCats) do
                                table.insert(newOrder, gCatId)
                            end
                        end
                        table.insert(newOrder, catId)
                    end
                    -- Add remaining groups in their original order
                    for _, grp in ipairs(groupOrder) do
                        local cats = otherGroupedCats[grp]
                        if cats then
                            for _, catId in ipairs(cats) do
                                table.insert(newOrder, catId)
                            end
                        end
                    end
                else
                    -- Dropping group on another group header or drop zone
                    -- Add ungrouped categories first
                    for _, catId in ipairs(ungroupedCats) do
                        table.insert(newOrder, catId)
                    end

                    -- Build new group order
                    local finalGroupOrder = {}

                    -- Handle top drop zone - insert at beginning
                    if targetGroupAfter == "__TOP__" then
                        table.insert(finalGroupOrder, draggedRow.groupName)
                    end

                    for _, grp in ipairs(groupOrder) do
                        if grp == targetGroupBefore then
                            -- Insert dragged group BEFORE target
                            table.insert(finalGroupOrder, draggedRow.groupName)
                        end
                        if grp ~= draggedRow.groupName then
                            table.insert(finalGroupOrder, grp)
                        end
                        if grp == targetGroupAfter and targetGroupAfter ~= "__TOP__" then
                            -- Insert dragged group AFTER target
                            table.insert(finalGroupOrder, draggedRow.groupName)
                        end
                    end

                    -- Add groups in new order
                    for _, grp in ipairs(finalGroupOrder) do
                        local cats
                        if grp == draggedRow.groupName then
                            cats = draggedGroupCats
                        else
                            cats = otherGroupedCats[grp]
                        end
                        if cats then
                            for _, catId in ipairs(cats) do
                                table.insert(newOrder, catId)
                            end
                        end
                    end
                end

                categories.order = newOrder
                DebouncedSaveCategories(categories)
                RefreshCategoriesList()
            end
        end
        draggedRow = nil
    end)

    return header
end

local function CreateCategoryRow(parent, categoryId, categoryDef, index)
    local ROW_HEIGHT = Constants.CATEGORY_UI.ROW_HEIGHT

    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetHeight(ROW_HEIGHT)
    row:SetBackdrop({
        bgFile = Constants.TEXTURES.WHITE_8x8,
    })

    local rowColor
    if index % 2 == 0 then
        rowColor = Constants.CATEGORY_COLORS.ROW_EVEN
    else
        rowColor = Constants.CATEGORY_COLORS.ROW_ODD
    end
    row:SetBackdropColor(rowColor[1], rowColor[2], rowColor[3], rowColor[4])
    row.baseColor = rowColor

    -- Make row draggable
    row:EnableMouse(true)
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnDragStart", function(self)
        draggedRow = self
        self:SetAlpha(0.5)
        if not dropIndicator then
            dropIndicator = CreateDropIndicator(categoriesScrollChild)
        end
    end)
    row:SetScript("OnDragStop", function(self)
        self:SetAlpha(1)
        if dropIndicator then
            dropIndicator:Hide()
        end

        if draggedRow and draggedRow.categoryId then
            local CategoryManager = ns:GetModule("CategoryManager")
            local categories = CategoryManager:GetCategories()
            local order = categories.order
            local draggedCatId = draggedRow.categoryId
            local draggedCatDef = categories.definitions[draggedCatId]

            -- Check if dropped on a group header (to move into that group)
            local targetGroupHeader = nil

            -- Get current mouse position for hit testing
            local mouseX, mouseY = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale()
            mouseX, mouseY = mouseX / scale, mouseY / scale

            for _, h in ipairs(groupHeaders) do
                -- Get header bounds
                local left, bottom, width, height = h:GetRect()
                local right, top = left + (width or 0), bottom + (height or 0)
                local isMouseOver = left and mouseX >= left and mouseX <= right and mouseY >= bottom and mouseY <= top

                -- Check hover flag first
                if h.isCategoryDropTarget then
                    targetGroupHeader = h
                    break
                end

                -- Check direct hit test based on mouse position
                if isMouseOver then
                    targetGroupHeader = h
                    break
                end

                -- Also check IsMouseOver() method
                if h:IsMouseOver() then
                    targetGroupHeader = h
                    break
                end
            end

            -- Check if dropped on a drop zone (to add to group at end)
            local targetDropZone = nil
            if not targetGroupHeader then
                for _, zone in ipairs(groupDropZones) do
                    -- Get zone bounds for hit test
                    local left, bottom, width, height = zone:GetRect()
                    local right, top = left + (width or 0), bottom + (height or 0)
                    local isMouseOver = left and mouseX >= left and mouseX <= right and mouseY >= bottom and mouseY <= top

                    if zone.isCategoryDropTarget then
                        targetDropZone = zone
                        break
                    end
                    -- Check direct hit test
                    if isMouseOver and zone.groupName ~= "__TOP__" then
                        targetDropZone = zone
                        break
                    end
                    -- Also check IsMouseOver() method
                    if zone:IsMouseOver() and zone.groupName ~= "__TOP__" then
                        targetDropZone = zone
                        break
                    end
                end
            end

            if targetGroupHeader and draggedCatDef then
                -- Move category to the target group (at the beginning)
                local newGroup = targetGroupHeader.groupName
                local oldGroup = draggedCatDef.group

                if newGroup ~= oldGroup then
                    -- Update the category's group
                    draggedCatDef.group = newGroup

                    -- Find the first category of the target group and insert before it
                    local draggedOrderIdx = nil
                    local insertIdx = nil
                    for i, id in ipairs(order) do
                        if id == draggedCatId then
                            draggedOrderIdx = i
                        end
                        local def = categories.definitions[id]
                        if def and def.group == newGroup and insertIdx == nil and id ~= draggedCatId then
                            insertIdx = i
                        end
                    end

                    if draggedOrderIdx then
                        table.remove(order, draggedOrderIdx)
                        -- Adjust insertIdx if needed
                        if insertIdx and insertIdx > draggedOrderIdx then
                            insertIdx = insertIdx - 1
                        end
                        if insertIdx then
                            table.insert(order, insertIdx, draggedCatId)
                        else
                            -- No other categories in group, add at end
                            table.insert(order, draggedCatId)
                        end
                    end

                    DebouncedSaveCategories(categories)
                    RefreshCategoriesList()
                end
            elseif targetDropZone and draggedCatDef then
                -- Check if this is a top drop zone (insert at beginning) or bottom (insert at end)
                local dropZoneName = targetDropZone.groupName
                local isTopDropZone = string.find(dropZoneName, "__TOP__$")
                local newGroup = isTopDropZone and string.gsub(dropZoneName, "__TOP__$", "") or dropZoneName

                -- Update the category's group
                draggedCatDef.group = newGroup

                local draggedOrderIdx = nil
                local firstGroupCatIdx = nil
                local lastGroupCatIdx = nil
                for i, id in ipairs(order) do
                    if id == draggedCatId then
                        draggedOrderIdx = i
                    end
                    local def = categories.definitions[id]
                    if def and def.group == newGroup and id ~= draggedCatId then
                        if not firstGroupCatIdx then
                            firstGroupCatIdx = i
                        end
                        lastGroupCatIdx = i
                    end
                end

                if draggedOrderIdx then
                    table.remove(order, draggedOrderIdx)

                    if isTopDropZone then
                        -- Insert at beginning of group
                        if firstGroupCatIdx and firstGroupCatIdx > draggedOrderIdx then
                            firstGroupCatIdx = firstGroupCatIdx - 1
                        end
                        if firstGroupCatIdx then
                            table.insert(order, firstGroupCatIdx, draggedCatId)
                        else
                            table.insert(order, draggedCatId)
                        end
                    else
                        -- Insert at end of group
                        if lastGroupCatIdx and lastGroupCatIdx > draggedOrderIdx then
                            lastGroupCatIdx = lastGroupCatIdx - 1
                        end
                        if lastGroupCatIdx then
                            table.insert(order, lastGroupCatIdx + 1, draggedCatId)
                        else
                            table.insert(order, draggedCatId)
                        end
                    end
                end

                DebouncedSaveCategories(categories)
                RefreshCategoriesList()
            else
                -- Normal category reordering
                local targetIndex = nil
                local draggedIndex = nil
                for i, r in ipairs(categoryRows) do
                    if r == draggedRow then
                        draggedIndex = i
                    end
                    -- Check hover flag
                    if r.isDropTarget then
                        targetIndex = i
                    end
                    -- Check direct hit test based on mouse position
                    if not targetIndex then
                        local left, bottom, width, height = r:GetRect()
                        if left then
                            local right, top = left + (width or 0), bottom + (height or 0)
                            if mouseX >= left and mouseX <= right and mouseY >= bottom and mouseY <= top then
                                targetIndex = i
                            end
                        end
                    end
                    -- Also check IsMouseOver() method
                    if not targetIndex and r:IsMouseOver() then
                        targetIndex = i
                    end
                end

                if draggedIndex and targetIndex and draggedIndex ~= targetIndex then
                    local targetCatId = categoryRows[targetIndex].categoryId
                    local targetCatDef = categories.definitions[targetCatId]

                    -- Check if moving to a different group
                    local targetGroup = targetCatDef and targetCatDef.group or ""
                    local draggedGroup = draggedCatDef and draggedCatDef.group or ""

                    if targetGroup ~= draggedGroup and draggedCatDef then
                        -- Update the category's group to match target
                        draggedCatDef.group = targetGroup
                    end

                    -- Find positions in order array
                    local draggedOrderIdx, targetOrderIdx
                    for i, id in ipairs(order) do
                        if id == draggedCatId then draggedOrderIdx = i end
                        if id == targetCatId then targetOrderIdx = i end
                    end

                    if draggedOrderIdx and targetOrderIdx then
                        -- Remove from old position and insert at new position
                        table.remove(order, draggedOrderIdx)
                        if targetOrderIdx > draggedOrderIdx then
                            targetOrderIdx = targetOrderIdx - 1
                        end
                        table.insert(order, targetOrderIdx, draggedCatId)
                        DebouncedSaveCategories(categories)
                        RefreshCategoriesList()
                    end
                end
            end

            draggedRow = nil
        end
    end)

    row:SetScript("OnEnter", function(self)
        SetCursor(Constants.TEXTURES.CURSOR_MOVE)
        local hoverColor = Constants.CATEGORY_COLORS.ROW_HOVER
        self:SetBackdropColor(hoverColor[1], hoverColor[2], hoverColor[3], hoverColor[4])

        -- Drop target detection
        -- Categories accept: other categories OR groups (if this category is ungrouped)
        if draggedRow and draggedRow ~= self then
            local CategoryManager = ns:GetModule("CategoryManager")
            local categories = CategoryManager:GetCategories()
            local thisCatDef = categories.definitions[self.categoryId]
            local isUngrouped = not thisCatDef or not thisCatDef.group or thisCatDef.group == ""

            -- Accept if: dragging a category, OR dragging a group and this is ungrouped
            if not draggedRow.isGroupHeader or (draggedRow.isGroupHeader and isUngrouped) then
                self.isDropTarget = true
                if dropIndicator then
                    dropIndicator:ClearAllPoints()
                    dropIndicator:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 1)
                    dropIndicator:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, 1)
                    dropIndicator:Show()
                end
            end
        end
    end)
    row:SetScript("OnLeave", function(self)
        SetCursor(nil)
        -- Restore original color
        local c = self.baseColor or Constants.CATEGORY_COLORS.ROW_ODD
        self:SetBackdropColor(c[1], c[2], c[3], c[4])
        self.isDropTarget = false
    end)

    -- Enable checkbox
    local enableCB = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    enableCB:SetPoint("LEFT", row, "LEFT", 4, 0)
    enableCB:SetSize(22, 22)
    enableCB:SetChecked(categoryDef.enabled)
    enableCB:SetScript("OnClick", function(self)
        local CategoryManager = ns:GetModule("CategoryManager")
        CategoryManager:ToggleCategory(categoryId)
    end)
    -- Allow drag to start from checkbox
    enableCB:RegisterForDrag("LeftButton")
    enableCB:SetScript("OnDragStart", function()
        row:GetScript("OnDragStart")(row)
    end)
    enableCB:SetScript("OnDragStop", function()
        row:GetScript("OnDragStop")(row)
    end)
    row.enableCB = enableCB

    -- Category icon
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("LEFT", enableCB, "RIGHT", 4, 0)
    icon:SetTexture(categoryDef.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Category name (use localized name for built-in categories)
    local displayName = categoryDef.isBuiltIn
        and ns.DefaultCategories:GetLocalizedName(categoryId, categoryDef.name)
        or (categoryDef.name or categoryId)
    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameText:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    nameText:SetWidth(100)
    nameText:SetJustifyH("LEFT")
    nameText:SetText(displayName)
    if categoryDef.isBuiltIn then
        nameText:SetTextColor(0.9, 0.9, 0.9)
    else
        nameText:SetTextColor(0.4, 0.8, 1)
    end
    row.nameText = nameText

    -- Delete button (custom categories only) - rightmost
    local deleteBtn = CreateFrame("Button", nil, row)
    deleteBtn:SetSize(16, 16)
    deleteBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    deleteBtn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
    deleteBtn:SetHighlightTexture("Interface\\Buttons\\UI-StopButton")
    deleteBtn:GetHighlightTexture():SetVertexColor(1, 0.3, 0.3)
    deleteBtn:SetScript("OnClick", function()
        local CategoryManager = ns:GetModule("CategoryManager")
        if CategoryManager:DeleteCategory(categoryId) then
            RefreshCategoriesList()
        end
    end)
    deleteBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L["DELETE_CATEGORY"])
        GameTooltip:Show()
    end)
    deleteBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- Allow drag from button
    deleteBtn:RegisterForDrag("LeftButton")
    deleteBtn:SetScript("OnDragStart", function() row:GetScript("OnDragStart")(row) end)
    deleteBtn:SetScript("OnDragStop", function() row:GetScript("OnDragStop")(row) end)
    if categoryDef.isBuiltIn then
        deleteBtn:Hide()
    end

    -- Check if category can move up/down
    local CategoryManager = ns:GetModule("CategoryManager")
    local canMoveUp = CategoryManager:CanMoveUp(categoryId)
    local canMoveDown = CategoryManager:CanMoveDown(categoryId)

    -- Move down button
    local downBtn = CreateFrame("Button", nil, row)
    downBtn:SetSize(16, 16)
    downBtn:SetPoint("RIGHT", deleteBtn, "LEFT", -2, 0)
    downBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    downBtn:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Down")
    downBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
    downBtn:SetScript("OnClick", function()
        local CategoryManager = ns:GetModule("CategoryManager")
        CategoryManager:MoveCategoryDown(categoryId)
        RefreshCategoriesList()
    end)
    downBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L["MOVE_DOWN"])
        GameTooltip:Show()
    end)
    downBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- Allow drag from button
    downBtn:RegisterForDrag("LeftButton")
    downBtn:SetScript("OnDragStart", function() row:GetScript("OnDragStart")(row) end)
    downBtn:SetScript("OnDragStop", function() row:GetScript("OnDragStop")(row) end)
    -- Disable if can't move down
    if not canMoveDown then
        downBtn:Disable()
        downBtn:GetNormalTexture():SetVertexColor(0.4, 0.4, 0.4)
    end

    -- Move up button
    local upBtn = CreateFrame("Button", nil, row)
    upBtn:SetSize(16, 16)
    upBtn:SetPoint("RIGHT", downBtn, "LEFT", -2, 0)
    upBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up")
    upBtn:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Down")
    upBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
    upBtn:SetScript("OnClick", function()
        local CategoryManager = ns:GetModule("CategoryManager")
        CategoryManager:MoveCategoryUp(categoryId)
        RefreshCategoriesList()
    end)
    upBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L["MOVE_UP"])
        GameTooltip:Show()
    end)
    upBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- Allow drag from button
    upBtn:RegisterForDrag("LeftButton")
    upBtn:SetScript("OnDragStart", function() row:GetScript("OnDragStart")(row) end)
    upBtn:SetScript("OnDragStop", function() row:GetScript("OnDragStop")(row) end)
    -- Disable if can't move up
    if not canMoveUp then
        upBtn:Disable()
        upBtn:GetNormalTexture():SetVertexColor(0.4, 0.4, 0.4)
    end

    -- Edit button (wider for some locales)
    local editBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    local locale = GetLocale()
    local editBtnWidth = (locale == "ruRU" or locale == "frFR" or locale == "deDE" or locale == "itIT") and 80 or 40
    editBtn:SetSize(editBtnWidth, 20)
    editBtn:SetPoint("RIGHT", upBtn, "LEFT", -4, 0)
    editBtn:SetText(L["EDIT"])
    editBtn:SetScript("OnClick", function()
        local CategoryEditor = ns:GetModule("CategoryEditor")
        CategoryEditor:Open(categoryId)
    end)
    -- Allow drag from button
    editBtn:RegisterForDrag("LeftButton")
    editBtn:SetScript("OnDragStart", function() row:GetScript("OnDragStart")(row) end)
    editBtn:SetScript("OnDragStop", function() row:GetScript("OnDragStop")(row) end)

    -- Group indicator (repositioned to be before Edit button)
    local groupText
    if categoryDef.group and categoryDef.group ~= "" then
        groupText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        groupText:SetPoint("RIGHT", editBtn, "LEFT", -4, 0)
        groupText:SetText("[" .. categoryDef.group .. "]")
        groupText:SetTextColor(0.5, 0.7, 0.9, 0.8)
    end

    -- Hide edit button for special categories (but keep up/down buttons)
    if categoryDef.hideControls then
        editBtn:Hide()
    end

    -- Equipment set categories: hide delete (auto-synced), distinct color
    if categoryDef.isEquipSet then
        deleteBtn:Hide()
        nameText:SetTextColor(0.6, 0.9, 0.6)
    end

    row.categoryId = categoryId
    row.rowIndex = index
    return row
end

-- Forward declarations
local mergeAllCheckbox
local UpdateMergeAllCheckbox

local function ReleaseFrame(frame)
    if not frame then return end
    frame:Hide()
    frame:ClearAllPoints()
    -- Note: Don't set scripts to nil or change parent, as this can break
    -- child frames and cause issues with WoW's frame system
end

function RefreshCategoriesList()
    if not categoriesScrollChild then return end

    -- Ensure scroll child has proper width
    local parent = categoriesScrollChild:GetParent()
    if parent then
        local width = parent:GetWidth()
        if width and width > 0 then
            categoriesScrollChild:SetWidth(width)
        else
            categoriesScrollChild:SetWidth(320)
        end
    end

    -- Clear drop indicator
    if dropIndicator then
        dropIndicator:Hide()
        dropIndicator:ClearAllPoints()
        dropIndicator:SetParent(nil)
        dropIndicator = nil
    end

    -- Reset dragged row state
    draggedRow = nil

    -- Clear existing rows, group headers, and drop zones
    for _, row in ipairs(categoryRows) do
        ReleaseFrame(row)
    end
    categoryRows = {}

    for _, header in ipairs(groupHeaders) do
        ReleaseFrame(header)
    end
    groupHeaders = {}

    for _, zone in ipairs(groupDropZones) do
        ReleaseFrame(zone)
    end
    groupDropZones = {}

    local CategoryManager = ns:GetModule("CategoryManager")
    if not CategoryManager then return end
    local categories = CategoryManager:GetCategories()

    -- Reset to defaults if categories are missing or corrupted
    if not categories or not categories.definitions or not categories.order or #categories.order == 0 then
        categories = CategoryManager:ResetToDefaults()
    end

    local order = categories.order or {}
    local definitions = categories.definitions or {}

    -- Build grouped structure
    local groupedCategories = {}  -- { groupName = { categoryIds } }
    local groupOrder = {}  -- Track order of groups as they appear
    local ungroupedCategories = {}  -- Categories without a group

    for _, categoryId in ipairs(order) do
        local categoryDef = categories.definitions[categoryId]
        if categoryDef then
            local groupName = categoryDef.group
            if groupName and groupName ~= "" then
                if not groupedCategories[groupName] then
                    groupedCategories[groupName] = {}
                    table.insert(groupOrder, groupName)
                end
                table.insert(groupedCategories[groupName], categoryId)
            else
                table.insert(ungroupedCategories, categoryId)
            end
        end
    end

    local yOffset = 0
    local ROW_HEIGHT = Constants.CATEGORY_UI.ROW_HEIGHT
    local GROUP_HEADER_HEIGHT = Constants.CATEGORY_UI.GROUP_HEADER_HEIGHT
    local rowIndex = 0
    local groupIndex = 0

    -- First render ungrouped categories
    for _, categoryId in ipairs(ungroupedCategories) do
        local categoryDef = categories.definitions[categoryId]
        if categoryDef then
            rowIndex = rowIndex + 1
            local row = CreateCategoryRow(categoriesScrollChild, categoryId, categoryDef, rowIndex)
            row:SetPoint("TOPLEFT", categoriesScrollChild, "TOPLEFT", 0, yOffset)
            row:SetPoint("RIGHT", categoriesScrollChild, "RIGHT", 0, 0)
            row:Show()
            table.insert(categoryRows, row)

            yOffset = yOffset - ROW_HEIGHT - 2
        end
    end

    -- Add top drop zone before groups (for dropping at the beginning)
    if #groupOrder > 0 then
        local topDropZone, zoneHeight = CreateGroupDropZone(categoriesScrollChild, "__TOP__", yOffset)
        topDropZone:Show()
        table.insert(groupDropZones, topDropZone)
        yOffset = yOffset - zoneHeight
    end

    -- Then render each group
    for _, groupName in ipairs(groupOrder) do
        local categoryIds = groupedCategories[groupName]
        if categoryIds and #categoryIds > 0 then
            -- Add group header
            groupIndex = groupIndex + 1
            local header = CreateGroupHeader(categoriesScrollChild, groupName, yOffset, groupIndex)
            header:Show()
            table.insert(groupHeaders, header)
            yOffset = yOffset - GROUP_HEADER_HEIGHT - 1

            -- Only show categories if group is not collapsed
            if not collapsedGroups[groupName] then
                -- Add categories in this group (drop on header to add at beginning)
                for _, categoryId in ipairs(categoryIds) do
                    local categoryDef = categories.definitions[categoryId]
                    if categoryDef then
                        rowIndex = rowIndex + 1
                        local row = CreateCategoryRow(categoriesScrollChild, categoryId, categoryDef, rowIndex)
                        row:SetPoint("TOPLEFT", categoriesScrollChild, "TOPLEFT", 10, yOffset)  -- Indent grouped categories
                        row:SetPoint("RIGHT", categoriesScrollChild, "RIGHT", 0, 0)
                        row:Show()
                        table.insert(categoryRows, row)

                        yOffset = yOffset - ROW_HEIGHT - 2
                    end
                end

                -- Add drop zone at bottom of group (for dropping at end of group)
                local bottomDropZone, bottomZoneHeight = CreateGroupDropZone(categoriesScrollChild, groupName, yOffset)
                bottomDropZone:Show()
                table.insert(groupDropZones, bottomDropZone)
                yOffset = yOffset - bottomZoneHeight
            else
                -- Group is collapsed - add a drop zone below the header
                local collapsedDropZone, zoneHeight = CreateGroupDropZone(categoriesScrollChild, groupName, yOffset)
                collapsedDropZone:Show()
                table.insert(groupDropZones, collapsedDropZone)
                yOffset = yOffset - zoneHeight
            end
        end
    end

    categoriesScrollChild:SetHeight(math.abs(yOffset) + 10)

    -- Update merge all checkbox state
    C_Timer.After(0, UpdateMergeAllCheckbox)
end

UpdateMergeAllCheckbox = function()
    if not mergeAllCheckbox then return end
    local Database = ns:GetModule("Database")
    local mergedGroups = Database:GetSetting("mergedGroups") or {}

    -- Check if all groups are merged
    local allMerged = true
    local anyMerged = false
    for _, header in ipairs(groupHeaders) do
        if mergedGroups[header.groupName] then
            anyMerged = true
        else
            allMerged = false
        end
    end

    mergeAllCheckbox:SetChecked(allMerged and anyMerged)
end

local function CreateCategoriesTab(parent)
    local content = CreateFrame("Frame", nil, parent)

    -- Header row with space-between layout
    -- Left: Merge All checkbox
    mergeAllCheckbox = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    mergeAllCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -1)
    mergeAllCheckbox:SetSize(22, 22)
    mergeAllCheckbox:SetScript("OnClick", function(self)
        local Database = ns:GetModule("Database")
        local CategoryManager = ns:GetModule("CategoryManager")
        local categories = CategoryManager:GetCategories()

        -- Get all unique groups
        local groups = {}
        for _, catId in ipairs(categories.order) do
            local def = categories.definitions[catId]
            if def and def.group and def.group ~= "" then
                groups[def.group] = true
            end
        end

        -- Set all groups to checked/unchecked state
        local newMerged = {}
        local checked = self:GetChecked()
        for groupName, _ in pairs(groups) do
            newMerged[groupName] = checked
        end

        Database:SetSetting("mergedGroups", newMerged)
        Events:Fire("SETTING_CHANGED", "mergedGroups", newMerged)

        -- Update group header checkboxes
        for _, header in ipairs(groupHeaders) do
            if header.mergeCB then
                header.mergeCB:SetChecked(checked)
            end
        end
    end)

    local mergeAllLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mergeAllLabel:SetPoint("LEFT", mergeAllCheckbox, "RIGHT", 0, 0)
    mergeAllLabel:SetText(L["MERGE_ALL"])

    -- Right: Add Category button
    local addBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    addBtn:SetSize(80, 20)
    addBtn:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -1)
    addBtn:SetText(L["ADD_CATEGORY"])
    addBtn:GetFontString():SetFont(GameFontNormalSmall:GetFont())
    addBtn:SetScript("OnClick", function()
        local CategoryEditor = ns:GetModule("CategoryEditor")
        CategoryEditor:CreateNew()
    end)

    -- Footer: Reset Defaults button
    local resetBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    resetBtn:SetSize(100, 22)
    resetBtn:SetPoint("BOTTOM", content, "BOTTOM", 0, 0)
    resetBtn:SetText(L["RESET_DEFAULTS"])
    resetBtn:SetScript("OnClick", function()
        StaticPopup_Show("GUDABAGS_RESET_CATEGORIES")
    end)

    -- Scroll frame for category list
    local scrollFrame = CreateFrame("ScrollFrame", nil, content, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -30)
    scrollFrame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -14, 28)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(320)  -- Set explicit width
    scrollChild:SetHeight(1)   -- Will be updated by RefreshCategoriesList
    scrollFrame:SetScrollChild(scrollChild)
    categoriesScrollChild = scrollChild

    content.Refresh = RefreshCategoriesList

    -- Refresh when content becomes visible
    content:SetScript("OnShow", function()
        RefreshCategoriesList()
    end)

    -- Refresh when categories are updated (from editor save, drag-drop, etc.)
    Events:Register("CATEGORIES_UPDATED", function()
        if categoriesScrollChild and categoriesScrollChild:IsVisible() then
            RefreshCategoriesList()
        end
    end, SettingsPopup)

    -- Initial refresh
    C_Timer.After(0.1, RefreshCategoriesList)

    -- Static popup for reset confirmation
    StaticPopupDialogs["GUDABAGS_RESET_CATEGORIES"] = {
        text = L["RESET_CONFIRM"],
        button1 = L["RESET"],
        button2 = L["CANCEL"],
        OnAccept = function()
            local CategoryManager = ns:GetModule("CategoryManager")
            CategoryManager:ResetToDefaults()
            RefreshCategoriesList()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    return content
end

-------------------------------------------------
-- Create Guide Tab
-------------------------------------------------
local function CreateGuideSection(parent, yOffset, imagePath, title, description)
    local IMAGE_WIDTH = 72
    local IMAGE_HEIGHT = 56
    local SECTION_HEIGHT = 90

    -- Image
    local image = parent:CreateTexture(nil, "ARTWORK")
    image:SetSize(IMAGE_WIDTH, IMAGE_HEIGHT)
    image:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    image:SetTexture(imagePath)

    -- Title
    local titleText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOPLEFT", image, "TOPRIGHT", 10, 0)
    titleText:SetPoint("RIGHT", parent, "RIGHT", -24, 0)
    titleText:SetJustifyH("LEFT")
    titleText:SetTextColor(1, 0.82, 0)
    titleText:SetText(title)

    -- Description
    local descText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    descText:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -4)
    descText:SetPoint("RIGHT", parent, "RIGHT", -24, 0)
    descText:SetJustifyH("LEFT")
    descText:SetSpacing(2)
    descText:SetText(description)

    return SECTION_HEIGHT
end

-------------------------------------------------
-- Profiles Tab
-------------------------------------------------

local profilesScrollChild = nil
local includeCategories = false
local includePositions = false

local function RefreshProfilesList()
    if not profilesScrollChild then return end

    -- Clear old children (frames)
    for _, child in ipairs({profilesScrollChild:GetChildren()}) do
        child:Hide()
        child:SetParent(nil)
    end
    -- Clear old regions (FontStrings, Textures) that GetChildren() does not return
    for _, region in ipairs({profilesScrollChild:GetRegions()}) do
        region:Hide()
        region:SetParent(nil)
    end

    local Database = ns:GetModule("Database")
    local yOffset = 0

    -- --- Create Profile Section ---
    local createHeader = profilesScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    createHeader:SetPoint("TOPLEFT", profilesScrollChild, "TOPLEFT", 0, yOffset)
    createHeader:SetText(L["PROFILE_SECTION_CREATE"])
    createHeader:SetTextColor(0.9, 0.75, 0.3)
    yOffset = yOffset - 20

    -- Name input row
    local inputRow = CreateFrame("Frame", nil, profilesScrollChild)
    inputRow:SetHeight(26)
    inputRow:SetPoint("TOPLEFT", profilesScrollChild, "TOPLEFT", 0, yOffset)
    inputRow:SetPoint("RIGHT", profilesScrollChild, "RIGHT", 0, 0)

    local nameInput = CreateFrame("EditBox", "GudaProfileNameInput", inputRow, "InputBoxTemplate")
    nameInput:SetSize(180, 22)
    nameInput:SetPoint("LEFT", inputRow, "LEFT", 6, 0)
    nameInput:SetAutoFocus(false)
    nameInput:SetMaxLetters(30)
    nameInput:SetFontObject(GameFontHighlightSmall)
    nameInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local saveBtn = CreateFrame("Button", nil, inputRow, "UIPanelButtonTemplate")
    saveBtn:SetSize(70, 22)
    saveBtn:SetPoint("LEFT", nameInput, "RIGHT", 8, 0)
    saveBtn:SetText(L["PROFILE_SAVE"])
    saveBtn:SetScript("OnClick", function()
        local name = nameInput:GetText()
        if not name or name:match("^%s*$") then
            ns:Print(L["PROFILE_NAME_EMPTY"])
            return
        end
        name = name:match("^%s*(.-)%s*$") -- trim
        Database:SaveProfile(name, includeCategories)
        ns:Print(string.format(L["PROFILE_SAVED"], name))
        nameInput:SetText("")
        nameInput:ClearFocus()
        RefreshProfilesList()
    end)
    saveBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["PROFILE_SAVE_TIP"])
        GameTooltip:Show()
    end)
    saveBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    nameInput:SetScript("OnEnterPressed", function(self)
        saveBtn:Click()
    end)

    yOffset = yOffset - 30

    -- Include categories checkbox
    local catRow = CreateFrame("Frame", nil, profilesScrollChild)
    catRow:SetHeight(22)
    catRow:SetPoint("TOPLEFT", profilesScrollChild, "TOPLEFT", 0, yOffset)
    catRow:SetPoint("RIGHT", profilesScrollChild, "RIGHT", 0, 0)

    local catCB = CreateFrame("CheckButton", nil, catRow, "UICheckButtonTemplate")
    catCB:SetPoint("LEFT", catRow, "LEFT", 2, 0)
    catCB:SetSize(22, 22)
    catCB:SetChecked(includeCategories)
    catCB:SetScript("OnClick", function(self)
        includeCategories = self:GetChecked()
    end)

    local catLabel = catRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    catLabel:SetPoint("LEFT", catCB, "RIGHT", 4, 0)
    catLabel:SetText(L["PROFILE_INCLUDE_CATEGORIES"])
    catLabel:SetTextColor(0.8, 0.8, 0.8)

    catCB:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["PROFILE_INCLUDE_CATEGORIES"])
        GameTooltip:AddLine(L["PROFILE_INCLUDE_CATEGORIES_TIP"], 1, 1, 1, true)
        GameTooltip:Show()
    end)
    catCB:SetScript("OnLeave", function() GameTooltip:Hide() end)

    yOffset = yOffset - 24

    -- Include positions checkbox
    local posRow = CreateFrame("Frame", nil, profilesScrollChild)
    posRow:SetHeight(22)
    posRow:SetPoint("TOPLEFT", profilesScrollChild, "TOPLEFT", 0, yOffset)
    posRow:SetPoint("RIGHT", profilesScrollChild, "RIGHT", 0, 0)

    local posCB = CreateFrame("CheckButton", nil, posRow, "UICheckButtonTemplate")
    posCB:SetPoint("LEFT", posRow, "LEFT", 2, 0)
    posCB:SetSize(22, 22)
    posCB:SetChecked(includePositions)
    posCB:SetScript("OnClick", function(self)
        includePositions = self:GetChecked()
    end)

    local posLabel = posRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    posLabel:SetPoint("LEFT", posCB, "RIGHT", 4, 0)
    posLabel:SetText(L["PROFILE_INCLUDE_POSITIONS"])
    posLabel:SetTextColor(0.8, 0.8, 0.8)

    posCB:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["PROFILE_INCLUDE_POSITIONS"])
        GameTooltip:AddLine(L["PROFILE_INCLUDE_POSITIONS_TIP"], 1, 1, 1, true)
        GameTooltip:Show()
    end)
    posCB:SetScript("OnLeave", function() GameTooltip:Hide() end)

    yOffset = yOffset - 30

    -- --- Separator ---
    local sep = profilesScrollChild:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", profilesScrollChild, "TOPLEFT", 0, yOffset)
    sep:SetPoint("RIGHT", profilesScrollChild, "RIGHT", 0, 0)
    sep:SetColorTexture(0.5, 0.5, 0.5, 0.5)
    yOffset = yOffset - 10

    -- --- Saved Profiles Section ---
    local savedHeader = profilesScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    savedHeader:SetPoint("TOPLEFT", profilesScrollChild, "TOPLEFT", 0, yOffset)
    savedHeader:SetText(L["PROFILE_SECTION_SAVED"])
    savedHeader:SetTextColor(0.9, 0.75, 0.3)
    yOffset = yOffset - 22

    local profiles = Database:GetProfileList()

    if #profiles == 0 then
        local noProfiles = profilesScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        noProfiles:SetPoint("TOPLEFT", profilesScrollChild, "TOPLEFT", 4, yOffset)
        noProfiles:SetText(L["PROFILE_NO_PROFILES"])
        noProfiles:SetTextColor(0.5, 0.5, 0.5)
        yOffset = yOffset - 20
    else
        for _, profileName in ipairs(profiles) do
            local profile = Database:GetProfile(profileName)
            local ROW_HEIGHT = 50

            local row = CreateFrame("Frame", nil, profilesScrollChild, "BackdropTemplate")
            row:SetHeight(ROW_HEIGHT)
            row:SetPoint("TOPLEFT", profilesScrollChild, "TOPLEFT", 0, yOffset)
            row:SetPoint("RIGHT", profilesScrollChild, "RIGHT", 0, 0)
            row:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                edgeSize = 1,
                insets = { left = 1, right = 1, top = 1, bottom = 1 },
            })
            row:SetBackdropColor(0.12, 0.12, 0.12, 0.6)
            row:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.5)

            -- Profile name (top-left, limited width to avoid overlapping buttons)
            local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            nameText:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -6)
            nameText:SetText(profileName)
            nameText:SetTextColor(1, 1, 1)
            nameText:SetWordWrap(false)
            nameText:SetMaxLines(1)

            -- Buttons row (anchored to left-right on the bottom half of the row)
            -- Delete button (rightmost)
            local deleteBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            deleteBtn:SetText(L["PROFILE_DELETE"])
            deleteBtn:SetSize(deleteBtn:GetFontString():GetStringWidth() + 20, 20)
            deleteBtn:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, 6)

            -- Load button
            local loadBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            loadBtn:SetText(L["PROFILE_LOAD"])
            loadBtn:SetSize(loadBtn:GetFontString():GetStringWidth() + 20, 20)
            loadBtn:SetPoint("RIGHT", deleteBtn, "LEFT", -4, 0)

            -- Overwrite button
            local overwriteBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            overwriteBtn:SetText(L["PROFILE_SAVE"])
            overwriteBtn:SetSize(overwriteBtn:GetFontString():GetStringWidth() + 20, 20)
            overwriteBtn:SetPoint("RIGHT", loadBtn, "LEFT", -4, 0)

            -- Export button (leftmost)
            local exportBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            exportBtn:SetText(L["PROFILE_EXPORT"])
            exportBtn:SetSize(exportBtn:GetFontString():GetStringWidth() + 20, 20)
            exportBtn:SetPoint("RIGHT", overwriteBtn, "LEFT", -4, 0)

            -- Info line (below name, limited to avoid going under buttons)
            local infoText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            infoText:SetPoint("TOPLEFT", nameText, "BOTTOMLEFT", 0, -2)
            infoText:SetPoint("RIGHT", exportBtn, "LEFT", -4, 0)
            infoText:SetWordWrap(false)
            infoText:SetMaxLines(1)
            infoText:SetJustifyH("LEFT")
            local infoStr = ""
            if profile.savedBy then
                infoStr = string.format(L["PROFILE_SAVED_BY"], profile.savedBy)
            end
            if profile.categories then
                if infoStr ~= "" then infoStr = infoStr .. "  |  " end
                infoStr = infoStr .. "|cff00cc00" .. L["PROFILE_HAS_CATEGORIES"] .. "|r"
            end
            infoText:SetText(infoStr)
            infoText:SetTextColor(0.6, 0.6, 0.6)

            -- Button click/tooltip handlers
            deleteBtn:SetScript("OnClick", function()
                StaticPopupDialogs["GUDABAGS_DELETE_PROFILE"] = {
                    text = string.format(L["PROFILE_CONFIRM_DELETE"], profileName),
                    button1 = YES,
                    button2 = NO,
                    OnAccept = function()
                        Database:DeleteProfile(profileName)
                        ns:Print(string.format(L["PROFILE_DELETED"], profileName))
                        RefreshProfilesList()
                    end,
                    timeout = 0,
                    whileDead = true,
                    hideOnEscape = true,
                    preferredIndex = 3,
                }
                StaticPopup_Show("GUDABAGS_DELETE_PROFILE")
            end)
            deleteBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(L["PROFILE_DELETE_TIP"])
                GameTooltip:Show()
            end)
            deleteBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            loadBtn:SetScript("OnClick", function()
                StaticPopupDialogs["GUDABAGS_LOAD_PROFILE"] = {
                    text = string.format(L["PROFILE_CONFIRM_LOAD"], profileName),
                    button1 = YES,
                    button2 = NO,
                    OnAccept = function()
                        if Database:LoadProfile(profileName, includePositions) then
                            ns:Print(string.format(L["PROFILE_LOADED"], profileName))
                            Events:Fire("SETTING_CHANGED", "theme", Database:GetSetting("theme"))
                            Events:Fire("CATEGORIES_UPDATED")
                        else
                            ns:Print(string.format(L["PROFILE_NOT_FOUND"], profileName))
                        end
                    end,
                    timeout = 0,
                    whileDead = true,
                    hideOnEscape = true,
                    preferredIndex = 3,
                }
                StaticPopup_Show("GUDABAGS_LOAD_PROFILE")
            end)
            loadBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(L["PROFILE_LOAD_TIP"])
                GameTooltip:Show()
            end)
            loadBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            overwriteBtn:SetScript("OnClick", function()
                Database:SaveProfile(profileName, includeCategories)
                ns:Print(string.format(L["PROFILE_SAVED"], profileName))
                RefreshProfilesList()
            end)
            overwriteBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(L["PROFILE_SAVE_TIP"])
                GameTooltip:Show()
            end)
            overwriteBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            exportBtn:SetScript("OnClick", function()
                local encoded = Database:ExportProfile(profileName)
                if encoded then
                    -- Show a dialog with the export string
                    StaticPopupDialogs["GUDABAGS_EXPORT_PROFILE"] = {
                        text = string.format(L["PROFILE_EXPORT_TIP"], profileName),
                        button1 = CLOSE,
                        hasEditBox = true,
                        editBoxWidth = 280,
                        OnShow = function(dialog)
                            dialog.editBox:SetText(encoded)
                            dialog.editBox:HighlightText()
                            dialog.editBox:SetFocus()
                        end,
                        EditBoxOnEscapePressed = function(self)
                            self:GetParent():Hide()
                        end,
                        timeout = 0,
                        whileDead = true,
                        hideOnEscape = true,
                        preferredIndex = 3,
                    }
                    StaticPopup_Show("GUDABAGS_EXPORT_PROFILE")
                end
            end)
            exportBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(L["PROFILE_EXPORT"])
                GameTooltip:Show()
            end)
            exportBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            -- Hover effect
            row:EnableMouse(true)
            row:SetScript("OnEnter", function(self)
                self:SetBackdropColor(0.18, 0.18, 0.18, 0.8)
                self:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.7)
            end)
            row:SetScript("OnLeave", function(self)
                self:SetBackdropColor(0.12, 0.12, 0.12, 0.6)
                self:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.5)
            end)

            yOffset = yOffset - ROW_HEIGHT - 4
        end
    end

    -- --- Import Profile Section ---
    yOffset = yOffset - 10
    local importSep = profilesScrollChild:CreateTexture(nil, "ARTWORK")
    importSep:SetHeight(1)
    importSep:SetPoint("TOPLEFT", profilesScrollChild, "TOPLEFT", 0, yOffset)
    importSep:SetPoint("RIGHT", profilesScrollChild, "RIGHT", 0, 0)
    importSep:SetColorTexture(0.5, 0.5, 0.5, 0.5)
    yOffset = yOffset - 10

    local importHeader = profilesScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    importHeader:SetPoint("TOPLEFT", profilesScrollChild, "TOPLEFT", 0, yOffset)
    importHeader:SetText(L["PROFILE_IMPORT"])
    importHeader:SetTextColor(0.9, 0.75, 0.3)
    yOffset = yOffset - 22

    local importInput = CreateFrame("EditBox", "GudaProfileImportInput", profilesScrollChild, "InputBoxTemplate")
    importInput:SetSize(240, 22)
    importInput:SetPoint("TOPLEFT", profilesScrollChild, "TOPLEFT", 6, yOffset)
    importInput:SetAutoFocus(false)
    importInput:SetMaxLetters(10000)
    importInput:SetFontObject(GameFontHighlightSmall)
    importInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local importBtn = CreateFrame("Button", nil, profilesScrollChild, "UIPanelButtonTemplate")
    importBtn:SetSize(70, 22)
    importBtn:SetPoint("LEFT", importInput, "RIGHT", 8, 0)
    importBtn:SetText(L["PROFILE_IMPORT"])
    importBtn:SetScript("OnClick", function()
        local text = importInput:GetText()
        if not text or text == "" then return end
        local success, result = Database:ImportProfile(text)
        if success then
            ns:Print(string.format(L["PROFILE_IMPORTED"], result))
            importInput:SetText("")
            importInput:ClearFocus()
            RefreshProfilesList()
        else
            ns:Print(L["PROFILE_IMPORT_FAILED"])
        end
    end)
    importInput:SetScript("OnEnterPressed", function()
        importBtn:Click()
    end)

    yOffset = yOffset - 30

    local importTip = profilesScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    importTip:SetPoint("TOPLEFT", profilesScrollChild, "TOPLEFT", 4, yOffset)
    importTip:SetText(L["PROFILE_IMPORT_TIP"])
    importTip:SetTextColor(0.5, 0.5, 0.5)
    yOffset = yOffset - 20

    profilesScrollChild:SetHeight(math.abs(yOffset) + 10)
end

local function CreateProfilesTab(parent)
    local scrollFrame = CreateFrame("ScrollFrame", "GudaProfilesScroll", parent, "UIPanelScrollFrameTemplate")

    local scrollBar = scrollFrame.ScrollBar or _G["GudaProfilesScrollScrollBar"]
    if scrollBar then
        scrollBar:SetAlpha(0.7)
    end

    profilesScrollChild = CreateFrame("Frame", nil, scrollFrame)
    profilesScrollChild:SetWidth(1)
    profilesScrollChild:SetHeight(400)
    scrollFrame:SetScrollChild(profilesScrollChild)

    -- Match width to scroll frame on size change
    scrollFrame:SetScript("OnSizeChanged", function(self, width)
        profilesScrollChild:SetWidth(width)
    end)

    RefreshProfilesList()
    return scrollFrame
end

local function CreateGuideTab(parent)
    local scrollFrame = CreateFrame("ScrollFrame", "GudaGuideScroll", parent, "UIPanelScrollFrameTemplate")

    local scrollBar = scrollFrame.ScrollBar or _G["GudaGuideScrollScrollBar"]
    if scrollBar then
        scrollBar:SetAlpha(0.7)
    end

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(1)
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)

    scrollFrame:SetScript("OnSizeChanged", function(self, width)
        content:SetWidth(width)
    end)

    local yOffset = 0

    -- Quest Item Bar Section
    yOffset = yOffset - CreateGuideSection(content, yOffset,
        "Interface\\AddOns\\GudaBags\\Assets\\questbar.png",
        L["GUIDE_QUEST_BAR_TITLE"],
        L["GUIDE_QUEST_BAR_DESC"])

    yOffset = yOffset - 20

    -- Tracked Item Bar Section
    yOffset = yOffset - CreateGuideSection(content, yOffset,
        "Interface\\AddOns\\GudaBags\\Assets\\trackedbar.png",
        L["GUIDE_TRACKED_BAR_TITLE"],
        L["GUIDE_TRACKED_BAR_DESC"])

    yOffset = yOffset - 20

    -- Extra spacing for German locale
    if GetLocale() == "deDE" then
        yOffset = yOffset - 20
    end

    -- Item Buttons Section
    yOffset = yOffset - CreateGuideSection(content, yOffset,
        "Interface\\AddOns\\GudaBags\\Assets\\itembar.png",
        L["GUIDE_BAG_ITEMS_TITLE"],
        L["GUIDE_BAG_ITEMS_DESC"])

    yOffset = yOffset - 20

    -- Pin Slot Section
    local pinTitle = L["GUIDE_PIN_SLOT_TITLE"]
    if ns.IsRetail then
        pinTitle = pinTitle .. "  |cff888888(" .. L["GUIDE_PIN_SLOT_RETAIL_NOTE"] .. ")|r"
    end
    yOffset = yOffset - CreateGuideSection(content, yOffset,
        "Interface\\AddOns\\GudaBags\\Assets\\pin.png",
        pinTitle,
        L["GUIDE_PIN_SLOT_DESC"])

    content:SetHeight(math.abs(yOffset) + 10)

    return scrollFrame
end

-------------------------------------------------
-- Apply theme to settings popup
-------------------------------------------------
local function ApplySettingsTheme()
    if not frame then return end
    Theme:ApplyPopupTheme(frame)

    -- Apply tab theme
    if tabPanel then
        local useMetal = Theme:GetValue("useMetalFrame")
        local useBlizzard = Theme:GetValue("useBlizzardFrame")
        tabPanel:ApplyTheme(useMetal and "retail" or useBlizzard and "blizzard" or "guda")
    end
end

-------------------------------------------------
-- Create Main Settings Frame
-------------------------------------------------
local function CreateSettingsFrame()
    -- Use ButtonFrameTemplate for standard Blizzard look
    local f = CreateFrame("Frame", "GudaBagsSettingsPopup", UIParent, "ButtonFrameTemplate")
    f:SetSize(POPUP_WIDTH, POPUP_HEIGHT)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(200)
    f:EnableMouse(true)

    -- Close on Escape
    tinsert(UISpecialFrames, "GudaBagsSettingsPopup")

    -- Hide portrait and button bar
    ButtonFrameTemplate_HidePortrait(f)
    ButtonFrameTemplate_HideButtonBar(f)
    if f.Inset then
        f.Inset:Hide()
    end

    -- Set title
    f:SetTitle(L["SETTINGS_TITLE"])

    -- Make draggable - create invisible drag region over title bar
    local dragRegion = CreateFrame("Frame", nil, f)
    dragRegion:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    dragRegion:SetPoint("TOPRIGHT", f, "TOPRIGHT", -28, 0)  -- Leave space for close button
    dragRegion:SetHeight(24)
    dragRegion:EnableMouse(true)
    dragRegion:RegisterForDrag("LeftButton")
    dragRegion:SetScript("OnDragStart", function()
        f:StartMoving()
        f:SetUserPlaced(false)
    end)
    dragRegion:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        f:SetUserPlaced(false)
    end)

    -- Store Tabs array for PanelTemplates
    f.Tabs = {}

    -- Tab content factories for lazy loading (content created on first tab select)
    local tabFactories = {
        general = function() return CreateTabFromSchema(f, function() return SettingsSchema.GetGeneral() end) end,
        layout = function() return CreateTabFromSchema(f, function() return SettingsSchema.GetLayout() end) end,
        icons = function() return CreateTabFromSchema(f, SettingsSchema.GetIcons()) end,
        bar = function() return CreateTabFromSchema(f, SettingsSchema.GetBar()) end,
        categories = function() return CreateCategoriesTab(f) end,
        profiles = function() return CreateProfilesTab(f) end,
        guide = function() return CreateGuideTab(f) end,
    }

    local function EnsureTabContent(tabId)
        if not tabPanel then return end
        if not tabPanel:GetContent(tabId) and tabFactories[tabId] then
            local content = tabFactories[tabId]()
            tabPanel:SetContent(tabId, content)
            content:Show()
        end
    end

    -- Create TabPanel
    tabPanel = TabPanel:Create(f, {
        tabs = GetTabList(),
        topMargin = 4,
        padding = PADDING,
        onSelect = function(tabId)
            EnsureTabContent(tabId)
            if tabId == "categories" then
                RefreshCategoriesList()
            elseif tabId == "profiles" then
                RefreshProfilesList()
            end
        end,
    })
    tabPanel:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -20)
    tabPanel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 8)

    -- Eagerly create only the default tab
    EnsureTabContent("general")
    tabPanel.SelectTab("general")

    -- Rebuild layout tab when view type changes (to show/hide split column sliders)
    -- Also re-apply theme when theme setting changes
    Events:Register("SETTING_CHANGED", function(event, key)
        if key == "gudaSort" then
            local generalContent = tabPanel:GetContent("general")
            if generalContent and generalContent.RefreshAll then
                generalContent:RefreshAll()
            end
        end
        if key == "bagViewType" or key == "bankViewType" then
            local layoutContent = tabPanel:GetContent("layout")
            if layoutContent and layoutContent.RefreshAll then
                layoutContent:RefreshAll()
            end
        end
        if key == "theme" then
            ApplySettingsTheme()
            -- Auto-enable retail empty slots when switching to Retail theme (Classic only)
            if not ns.IsRetail then
                local Database = ns:GetModule("Database")
                local themeName = Database:GetSetting("theme")
                if themeName == "retail" then
                    Database:SetSetting("retailEmptySlots", true)
                end
            end
            -- Refresh general tab to update retailEmptySlots checkbox
            local generalContent = tabPanel:GetContent("general")
            if generalContent and generalContent.RefreshAll then
                generalContent:RefreshAll()
            end
        end
    end, f)

    -- Apply theme to settings frame
    ApplySettingsTheme()

    f:Hide()
    return f
end

-------------------------------------------------
-- Initialize Components (called after all modules loaded)
-------------------------------------------------
local function InitComponents()
    Slider = ns:GetModule("Controls.Slider")
    Checkbox = ns:GetModule("Controls.Checkbox")
    ToggleButton = ns:GetModule("Controls.ToggleButton")
    Select = ns:GetModule("Controls.Select")
    VerticalStack = ns:GetModule("Layout.VerticalStack")
    HorizontalRow = ns:GetModule("Layout.HorizontalRow")
    TabPanel = ns:GetModule("TabPanel")
    SettingsSchema = ns:GetModule("SettingsSchema")
end

-------------------------------------------------
-- Public API
-------------------------------------------------
function SettingsPopup:Toggle()
    InitComponents()
    if not frame then
        frame = CreateSettingsFrame()
    end

    if frame:IsShown() then
        frame:Hide()
    else
        ApplySettingsTheme()
        tabPanel:RefreshAll()
        frame:Show()
        -- Re-select active tab after show (OnShow deselects all tabs)
        local activeTab = tabPanel.GetActiveTab() or "general"
        tabPanel.SelectTab(activeTab)
    end
end

function SettingsPopup:Show()
    InitComponents()
    if not frame then
        frame = CreateSettingsFrame()
    end
    ApplySettingsTheme()
    tabPanel:RefreshAll()
    frame:Show()
    -- Re-select active tab after show (OnShow deselects all tabs)
    local activeTab = tabPanel.GetActiveTab() or "general"
    tabPanel.SelectTab(activeTab)
end

function SettingsPopup:Hide()
    if frame then
        frame:Hide()
    end
end

function SettingsPopup:IsShown()
    return frame and frame:IsShown()
end

-------------------------------------------------
-- Blizzard Interface Options Integration
-------------------------------------------------
local function CreateInterfaceOptionsPanel()
    local panel = CreateFrame("Frame", "GudaBagsOptionsPanel", UIParent)

    local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge3")
    header:SetPoint("CENTER", panel, 0, 60)
    header:SetText("|cffffd100" .. L["ADDON_NAME"] .. "|r")

    local versionText = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    versionText:SetPoint("CENTER", panel, 0, 30)
    versionText:SetText("|cffffffff" .. string.format(L["VERSION_COLON"], ns.version or "1.0.0") .. "|r")

    local instructions = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    instructions:SetPoint("CENTER", panel, 0, 0)
    instructions:SetText("|cffffffff" .. L["SETTINGS_CLICK_TO_OPEN"] .. "|r")

    local openBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    openBtn:SetSize(180, 32)
    openBtn:SetPoint("CENTER", panel, 0, -40)
    openBtn:SetText(L["SETTINGS_OPEN"])
    openBtn:SetScript("OnClick", function()
        SettingsPopup:Show()
    end)

    panel.OnCommit = function() end
    panel.OnDefault = function() end
    panel.OnRefresh = function() end

    local category = Settings.RegisterCanvasLayoutCategory(panel, "GudaBags")
    category.ID = "GudaBags"
    Settings.RegisterAddOnCategory(category)

    return panel
end

Events:OnPlayerLogin(function()
    CreateInterfaceOptionsPanel()
end, SettingsPopup)
