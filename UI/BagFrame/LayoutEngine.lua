local addonName, ns = ...

local LayoutEngine = {}
ns:RegisterModule("BagFrame.LayoutEngine", LayoutEngine)

local Constants = ns.Constants

-- Check if an interaction window is open (bank, trade, mail, merchant, auction)
-- When these are open, items should be shown ungrouped for easier interaction
local function IsInteractionWindowOpen()
    -- Bank - check native Blizzard frame first (more reliable timing)
    -- BankFrame is the default UI bank frame that's shown when interacting with bank NPC
    if _G.BankFrame and _G.BankFrame:IsShown() then
        return true
    end

    -- Also check our custom BankFrame module
    local GudaBankFrame = ns:GetModule("BankFrame")
    if GudaBankFrame and GudaBankFrame:IsShown() then
        return true
    end

    -- Guild Bank - check native Blizzard frame
    if _G.GuildBankFrame and _G.GuildBankFrame:IsShown() then
        return true
    end

    -- Also check our custom GuildBankFrame module
    local GudaGuildBankFrame = ns:GetModule("GuildBankFrame")
    if GudaGuildBankFrame and GudaGuildBankFrame:IsShown() then
        return true
    end

    -- Trade window
    if TradeFrame and TradeFrame:IsShown() then
        return true
    end

    -- Mail window
    if MailFrame and MailFrame:IsShown() then
        return true
    end

    -- Merchant/Vendor window
    if MerchantFrame and MerchantFrame:IsShown() then
        return true
    end

    -- Auction house (Classic)
    if AuctionFrame and AuctionFrame:IsShown() then
        return true
    end

    -- Auction house (Retail)
    if AuctionHouseFrame and AuctionHouseFrame:IsShown() then
        return true
    end

    return false
end

-- Build display order from classified bags
-- Returns array of {bagID, needsSpacing, isKeyring, isSoulBag}
-- bags parameter is optional, used to check cached keyring data
-- showSoulBag parameter controls whether soul bags are included (default true)
function LayoutEngine:BuildDisplayOrder(classifiedBags, showKeyring, bags, showSoulBag)
    local bagsToShow = {}

    -- Regular bags first (no spacing)
    for _, bagID in ipairs(classifiedBags.regular or {}) do
        table.insert(bagsToShow, {bagID = bagID, needsSpacing = false})
    end

    -- Reagent bags (Retail only, with spacing)
    for i, bagID in ipairs(classifiedBags.reagent or {}) do
        table.insert(bagsToShow, {bagID = bagID, needsSpacing = (i == 1), isReagentBag = true})
    end

    -- Profession bags (with spacing before first bag of each type)
    local professionTypes = {"enchant", "herb", "engineering", "mining", "gem", "leatherworking", "inscription"}
    for _, bagType in ipairs(professionTypes) do
        local typeBags = classifiedBags[bagType] or {}
        for i, bagID in ipairs(typeBags) do
            table.insert(bagsToShow, {bagID = bagID, needsSpacing = (i == 1)})
        end
    end

    -- Soul bags (only if showSoulBag is true or not specified)
    if showSoulBag ~= false then
        for i, bagID in ipairs(classifiedBags.soul or {}) do
            table.insert(bagsToShow, {bagID = bagID, needsSpacing = (i == 1), isSoulBag = true})
        end
    end

    -- Quiver bags
    for i, bagID in ipairs(classifiedBags.quiver or {}) do
        table.insert(bagsToShow, {bagID = bagID, needsSpacing = (i == 1)})
    end

    -- Ammo bags
    for i, bagID in ipairs(classifiedBags.ammo or {}) do
        table.insert(bagsToShow, {bagID = bagID, needsSpacing = (i == 1)})
    end

    -- Keyring (if shown)
    if showKeyring then
        local keyringID = Constants.KEYRING_BAG_ID
        local numKeyringSlots = 0

        -- Check cached data first, then live data
        if bags and bags[keyringID] then
            numKeyringSlots = bags[keyringID].numSlots or 0
        else
            numKeyringSlots = C_Container.GetContainerNumSlots(keyringID) or 0
        end

        if numKeyringSlots > 0 then
            table.insert(bagsToShow, {bagID = keyringID, needsSpacing = true, isKeyring = true})
        end
    end

    return bagsToShow
end

-- Collect all slots from bags in display order
-- Returns array of {bagID, slot, itemData, needsSpacing}
-- If unifiedOrder is true (for Retail Single View), collect all slots sequentially by bag ID
-- without bag type separation, which matches Blizzard's native sorted display order
function LayoutEngine:CollectAllSlots(bagsToShow, bags, isViewingCached, unifiedOrder)
    local allSlots = {}

    -- On Retail Single View, collect all non-special bags in sequential order (0, 1, 2, 3, 4)
    -- This matches how C_Container.SortBags() organizes items across all bags
    -- Special bags (reagent, keyring) are shown separately with spacing
    if unifiedOrder then
        -- Collect unique bag IDs (excluding keyring and reagent bag) and sort them
        local bagIDs = {}
        local seenBags = {}
        local keyringInfo = nil
        local reagentBagInfo = nil

        for _, bagInfo in ipairs(bagsToShow) do
            if bagInfo.isKeyring then
                keyringInfo = bagInfo  -- Save keyring for later
            elseif bagInfo.isReagentBag then
                reagentBagInfo = bagInfo  -- Save reagent bag for later
            elseif not seenBags[bagInfo.bagID] then
                seenBags[bagInfo.bagID] = true
                table.insert(bagIDs, bagInfo.bagID)
            end
        end
        table.sort(bagIDs)

        -- Collect slots in bag ID order (no section spacing)
        for _, bagID in ipairs(bagIDs) do
            local bagData = bags[bagID]
            if bagData then
                for slot = 1, bagData.numSlots do
                    table.insert(allSlots, {
                        bagID = bagID,
                        slot = slot,
                        itemData = bagData.slots[slot],
                        needsSpacing = false,
                    })
                end
            end
        end

        -- Add reagent bag with spacing (if present)
        if reagentBagInfo then
            local bagID = reagentBagInfo.bagID
            local bagData = bags[bagID]
            if bagData then
                for slot = 1, bagData.numSlots do
                    local needsSpacing = (slot == 1)
                    table.insert(allSlots, {
                        bagID = bagID,
                        slot = slot,
                        itemData = bagData.slots[slot],
                        needsSpacing = needsSpacing,
                    })
                end
            end
        end

        -- Add keyring at the end with spacing (if present)
        if keyringInfo then
            local bagID = keyringInfo.bagID
            local bagData = bags[bagID]
            if isViewingCached and bagData then
                for slot = 1, bagData.numSlots do
                    local needsSpacing = (slot == 1)
                    table.insert(allSlots, {
                        bagID = bagID,
                        slot = slot,
                        itemData = bagData.slots[slot],
                        needsSpacing = needsSpacing,
                    })
                end
            else
                local numSlots = C_Container.GetContainerNumSlots(bagID)
                if numSlots and numSlots > 0 then
                    for slot = 1, numSlots do
                        local needsSpacing = (slot == 1)
                        local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                        local itemData = nil
                        if itemInfo then
                            local itemName, _, itemQuality, _, _, itemType, itemSubType = GetItemInfo(itemInfo.hyperlink or "")
                            itemData = {
                                bagID = bagID,
                                slot = slot,
                                link = itemInfo.hyperlink,
                                texture = itemInfo.iconFileID,
                                count = itemInfo.stackCount or 1,
                                quality = itemInfo.quality or 0,
                                name = itemName or "",
                                itemType = itemType or "",
                                itemSubType = itemSubType or "",
                                locked = itemInfo.isLocked,
                            }
                        end
                        table.insert(allSlots, {
                            bagID = bagID,
                            slot = slot,
                            itemData = itemData,
                            needsSpacing = needsSpacing,
                        })
                    end
                end
            end
        end

        return allSlots
    end

    -- Original behavior: collect in display order with bag type separation
    for _, bagInfo in ipairs(bagsToShow) do
        local bagID = bagInfo.bagID
        local bagData = bags[bagID]

        -- Handle keyring - use cached data if viewing cached character, otherwise live data
        if bagInfo.isKeyring then
            if isViewingCached and bagData then
                -- Use cached keyring data
                for slot = 1, bagData.numSlots do
                    local needsSpacing = bagInfo.needsSpacing and (slot == 1)
                    table.insert(allSlots, {
                        bagID = bagID,
                        slot = slot,
                        itemData = bagData.slots[slot],
                        needsSpacing = needsSpacing,
                    })
                end
            else
                -- Use live keyring data
                local numSlots = C_Container.GetContainerNumSlots(bagID)
                if numSlots and numSlots > 0 then
                    for slot = 1, numSlots do
                        local needsSpacing = bagInfo.needsSpacing and (slot == 1)
                        local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                        local itemData = nil
                        if itemInfo then
                            local itemName, _, itemQuality, _, _, itemType, itemSubType = GetItemInfo(itemInfo.hyperlink or "")
                            itemData = {
                                bagID = bagID,
                                slot = slot,
                                link = itemInfo.hyperlink,
                                texture = itemInfo.iconFileID,
                                count = itemInfo.stackCount or 1,
                                quality = itemInfo.quality or 0,
                                name = itemName or "",
                                itemType = itemType or "",
                                itemSubType = itemSubType or "",
                                locked = itemInfo.isLocked,
                            }
                        end
                        table.insert(allSlots, {
                            bagID = bagID,
                            slot = slot,
                            itemData = itemData,
                            needsSpacing = needsSpacing,
                        })
                    end
                end
            end
        elseif bagData then
            for slot = 1, bagData.numSlots do
                local needsSpacing = bagInfo.needsSpacing and (slot == 1)
                table.insert(allSlots, {
                    bagID = bagID,
                    slot = slot,
                    itemData = bagData.slots[slot],
                    needsSpacing = needsSpacing,
                })
            end
        end
    end

    return allSlots
end

-- Calculate frame dimensions based on slots and settings
-- Returns frameWidth, frameHeight
function LayoutEngine:CalculateFrameSize(allSlots, settings)
    local columns = settings.columns
    local iconSize = settings.iconSize
    local spacing = settings.spacing
    local showSearchBar = settings.showSearchBar
    local showFilterChips = settings.showFilterChips
    local showFooter = settings.showFooter

    -- Calculate actual row count and section count for spacing
    -- Count rows directly to avoid overcounting with section breaks
    local totalRows = 0
    local sectionCount = 0
    local col = 0

    for _, slotInfo in ipairs(allSlots) do
        if slotInfo.needsSpacing then
            if col > 0 then
                totalRows = totalRows + 1  -- Complete the partial row
                col = 0
            end
            sectionCount = sectionCount + 1
        end
        col = col + 1
        if col >= columns then
            col = 0
            totalRows = totalRows + 1
        end
    end

    -- Account for final partial row
    if col > 0 then
        totalRows = totalRows + 1
    end
    if totalRows < 1 then totalRows = 1 end

    local contentWidth = (iconSize * columns) + (spacing * (columns - 1))
    local contentHeight = (iconSize * totalRows) + (spacing * (totalRows - 1)) + (Constants.SECTION_SPACING * sectionCount)

    local chipHeight = (showSearchBar and showFilterChips) and (Constants.FRAME.CHIP_STRIP_HEIGHT + 1) or 0
    local searchBarHeight = showSearchBar and (Constants.FRAME.SEARCH_BAR_HEIGHT + chipHeight + 4) or 0
    local footerHeight = showFooter and (Constants.FRAME.FOOTER_HEIGHT + 6) or Constants.FRAME.PADDING

    local frameWidth = math.max(contentWidth + (Constants.FRAME.PADDING * 2), Constants.FRAME.MIN_WIDTH)
    local frameHeight = math.max(
        contentHeight + Constants.FRAME.TITLE_HEIGHT + searchBarHeight + footerHeight + Constants.FRAME.PADDING + 4,
        Constants.FRAME.MIN_HEIGHT
    )

    return frameWidth, frameHeight
end

-- Calculate position for each slot button
-- Returns array of {x, y} positions corresponding to allSlots indices
function LayoutEngine:CalculateButtonPositions(allSlots, settings)
    local columns = settings.columns
    local iconSize = settings.iconSize
    local spacing = settings.spacing

    local positions = {}
    local row = 0
    local col = 0
    local currentSectionOffset = 0

    for i, slotInfo in ipairs(allSlots) do
        -- Start new row for specialized bag sections with extra spacing
        if slotInfo.needsSpacing then
            if col > 0 then
                row = row + 1
                col = 0
            end
            currentSectionOffset = currentSectionOffset + Constants.SECTION_SPACING
        end

        local x = col * (iconSize + spacing)
        local y = -(row * (iconSize + spacing)) - currentSectionOffset

        positions[i] = {x = x, y = y}

        col = col + 1
        if col >= columns then
            col = 0
            row = row + 1
        end
    end

    return positions
end

-- Get section spacing constant
function LayoutEngine:GetSectionSpacing()
    return Constants.SECTION_SPACING
end

-------------------------------------------------
-- Category View Support
-------------------------------------------------

local CATEGORY_HEADER_HEIGHT = Constants.CATEGORY_UI.HEADER_HEIGHT

-- Collect items for category view (skips empty slots but counts them)
-- Returns array of {bagID, slot, itemData}, emptyCount, firstEmptySlot, soulEmptyCount, firstSoulEmptySlot
function LayoutEngine:CollectItemsForCategoryView(bagsToShow, bags, isViewingCached)
    local items = {}
    local emptyCount = 0
    local firstEmptySlot = nil  -- {bagID, slot} of first empty slot found
    local soulEmptyCount = 0
    local firstSoulEmptySlot = nil  -- {bagID, slot} of first soul bag empty slot

    -- Get BagClassifier for accurate bag type detection
    local BagClassifier = ns:GetModule("BagFrame.BagClassifier")

    for _, bagInfo in ipairs(bagsToShow) do
        local bagID = bagInfo.bagID
        local bagData = bags[bagID]
        -- Use bagInfo.isSoulBag if set, otherwise check via BagClassifier or bagData
        local isSoulBag = bagInfo.isSoulBag
        if isSoulBag == nil then
            if bagData and bagData.bagType then
                isSoulBag = (bagData.bagType == "soul")
            elseif BagClassifier then
                local bagType = BagClassifier:GetBagType(bagID)
                isSoulBag = (bagType == "soul")
            end
        end

        if bagInfo.isKeyring then
            if isViewingCached and bagData then
                for slot = 1, bagData.numSlots do
                    local itemData = bagData.slots[slot]
                    if itemData then
                        table.insert(items, {
                            bagID = bagID,
                            slot = slot,
                            itemData = itemData,
                        })
                    else
                        emptyCount = emptyCount + 1
                        if not firstEmptySlot then
                            firstEmptySlot = {bagID = bagID, slot = slot}
                        end
                    end
                end
            else
                local numSlots = C_Container.GetContainerNumSlots(bagID)
                if numSlots and numSlots > 0 then
                    for slot = 1, numSlots do
                        local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                        if itemInfo then
                            local itemName, _, itemQuality, _, _, itemType, itemSubType = GetItemInfo(itemInfo.hyperlink or "")
                            local itemData = {
                                bagID = bagID,
                                slot = slot,
                                link = itemInfo.hyperlink,
                                texture = itemInfo.iconFileID,
                                count = itemInfo.stackCount or 1,
                                quality = itemInfo.quality or 0,
                                name = itemName or "",
                                itemType = itemType or "",
                                itemSubType = itemSubType or "",
                                locked = itemInfo.isLocked,
                            }
                            table.insert(items, {
                                bagID = bagID,
                                slot = slot,
                                itemData = itemData,
                            })
                        else
                            emptyCount = emptyCount + 1
                            if not firstEmptySlot then
                                firstEmptySlot = {bagID = bagID, slot = slot}
                            end
                        end
                    end
                end
            end
        elseif bagData then
            for slot = 1, bagData.numSlots do
                local itemData = bagData.slots[slot]
                if itemData then
                    -- Mark soul shards from soul bags for special display
                    if isSoulBag then
                        itemData.isInSoulBag = true
                    end
                    table.insert(items, {
                        bagID = bagID,
                        slot = slot,
                        itemData = itemData,
                        isInSoulBag = isSoulBag,
                    })
                else
                    if isSoulBag then
                        soulEmptyCount = soulEmptyCount + 1
                        if not firstSoulEmptySlot then
                            firstSoulEmptySlot = {bagID = bagID, slot = slot}
                        end
                    else
                        emptyCount = emptyCount + 1
                        if not firstEmptySlot then
                            firstEmptySlot = {bagID = bagID, slot = slot}
                        end
                    end
                end
            end
        elseif not isViewingCached then
            -- No cached bag data but not viewing cached - use live data for empty count
            local numSlots = C_Container.GetContainerNumSlots(bagID)
            if numSlots and numSlots > 0 then
                for slot = 1, numSlots do
                    local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                    if not itemInfo then
                        if isSoulBag then
                            soulEmptyCount = soulEmptyCount + 1
                            if not firstSoulEmptySlot then
                                firstSoulEmptySlot = {bagID = bagID, slot = slot}
                            end
                        else
                            emptyCount = emptyCount + 1
                            if not firstEmptySlot then
                                firstEmptySlot = {bagID = bagID, slot = slot}
                            end
                        end
                    end
                end
            end
        end
    end

    -- When not viewing cached data, recalculate empty counts using LIVE data
    -- This ensures counts are accurate even if cache is stale
    if not isViewingCached then
        emptyCount = 0
        soulEmptyCount = 0
        firstEmptySlot = nil
        firstSoulEmptySlot = nil

        -- Get BagClassifier for accurate bag type detection
        local BagClassifier = ns:GetModule("BagFrame.BagClassifier")

        for _, bagInfo in ipairs(bagsToShow) do
            local bagID = bagInfo.bagID
            -- Use bagInfo.isSoulBag if set, otherwise check via BagClassifier
            local isSoulBag = bagInfo.isSoulBag
            if isSoulBag == nil and BagClassifier then
                local bagType = BagClassifier:GetBagType(bagID)
                isSoulBag = (bagType == "soul")
            end

            if not bagInfo.isKeyring then  -- Keyring already uses live data above
                local numSlots = C_Container.GetContainerNumSlots(bagID)
                if numSlots and numSlots > 0 then
                    for slot = 1, numSlots do
                        local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                        if not itemInfo then
                            if isSoulBag then
                                soulEmptyCount = soulEmptyCount + 1
                                if not firstSoulEmptySlot then
                                    firstSoulEmptySlot = {bagID = bagID, slot = slot}
                                end
                            else
                                emptyCount = emptyCount + 1
                                if not firstEmptySlot then
                                    firstEmptySlot = {bagID = bagID, slot = slot}
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return items, emptyCount, firstEmptySlot, soulEmptyCount, firstSoulEmptySlot
end

-- Build category sections from items
-- Returns { { categoryId, categoryName, categoryIcon, items = {} }, ... }
-- Groups with merge enabled show as single sections instead of individual categories
-- emptyCount: number of empty slots to show in "Empty" category
-- firstEmptySlot: {bagID, slot} of first empty slot for click handling
-- soulEmptyCount: number of soul bag empty slots
-- firstSoulEmptySlot: {bagID, slot} of first soul bag empty slot
function LayoutEngine:BuildCategorySections(items, isViewingCached, emptyCount, firstEmptySlot, soulEmptyCount, firstSoulEmptySlot)
    local CategoryManager = ns:GetModule("CategoryManager")
    if not CategoryManager then
        return {{ categoryId = "All", categoryName = "All Items", categoryIcon = nil, items = items }}
    end

    local Database = ns:GetModule("Database")
    local mergedGroups = Database and Database:GetSetting("mergedGroups") or {}

    local categories = CategoryManager:GetCategories()
    local order = categories.order or {}

    -- Build category order index map for sorting
    local categoryOrderIndex = {}
    for i, catId in ipairs(order) do
        categoryOrderIndex[catId] = i
    end

    local sectionMap = {}
    local sections = {}
    local groupMap = {}  -- For merged groups

    for _, categoryId in ipairs(order) do
        local def = categories.definitions[categoryId]
        if def and def.enabled then
            local groupName = def.group
            local isGroupMerged = groupName and groupName ~= "" and mergedGroups[groupName]

            if isGroupMerged then
                -- This group is merged - combine categories into single section
                if groupMap[groupName] then
                    -- Add to existing group section
                    sectionMap[categoryId] = groupMap[groupName]
                else
                    -- Create new group section (use localized group name)
                    local localizedGroupName = ns.DefaultCategories:GetLocalizedGroupName(groupName)
                    local section = {
                        categoryId = "group_" .. groupName,
                        categoryName = localizedGroupName,
                        categoryIcon = def.icon,
                        items = {},
                        hideControls = def.hideControls,
                        isGroup = true,
                        group = groupName,
                    }
                    groupMap[groupName] = section
                    sectionMap[categoryId] = section
                    table.insert(sections, section)
                end
            else
                -- Category is not in a merged group - show as individual section
                -- Use localized name for built-in categories
                local displayName = def.isBuiltIn
                    and ns.DefaultCategories:GetLocalizedName(categoryId, def.name)
                    or def.name
                local section = {
                    categoryId = categoryId,
                    categoryName = displayName,
                    categoryIcon = def.icon,
                    items = {},
                    hideControls = def.hideControls,
                    group = groupName,  -- Include group for layout calculations
                }
                sectionMap[categoryId] = section
                table.insert(sections, section)
            end
        end
    end

    -- Categorize each item and store category order index for merged group sorting
    for _, item in ipairs(items) do
        local categoryId = CategoryManager:CategorizeItem(item.itemData, item.bagID, item.slot, isViewingCached)
        local section = sectionMap[categoryId]
        if section then
            -- Store category order index for sorting within merged groups
            item.categoryOrderIndex = categoryOrderIndex[categoryId] or 999
            table.insert(section.items, item)
        elseif sectionMap["Miscellaneous"] then
            item.categoryOrderIndex = categoryOrderIndex["Miscellaneous"] or 999
            table.insert(sectionMap["Miscellaneous"].items, item)
        end
    end

    -- Add pseudo-item to "Empty" category if there are empty slots
    emptyCount = emptyCount or 0
    if emptyCount > 0 and sectionMap["Empty"] and firstEmptySlot then
        local emptySection = sectionMap["Empty"]
        -- Create a pseudo-item representing empty slots
        -- Use real bagID/slot so the button template's click handler works
        local emptyItem = {
            bagID = firstEmptySlot.bagID,
            slot = firstEmptySlot.slot,
            itemData = {
                bagID = firstEmptySlot.bagID,
                slot = firstEmptySlot.slot,
                isEmptySlots = true,
                emptyCount = emptyCount,
                texture = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag",
                count = emptyCount,
                name = "Empty Slots",
            },
        }
        table.insert(emptySection.items, emptyItem)
    end

    -- Add pseudo-item to "Soul" category if there are soul bag empty slots
    soulEmptyCount = soulEmptyCount or 0
    if soulEmptyCount > 0 and sectionMap["Soul"] and firstSoulEmptySlot then
        local soulSection = sectionMap["Soul"]
        -- Create a pseudo-item representing soul bag empty slots
        local soulItem = {
            bagID = firstSoulEmptySlot.bagID,
            slot = firstSoulEmptySlot.slot,
            itemData = {
                bagID = firstSoulEmptySlot.bagID,
                slot = firstSoulEmptySlot.slot,
                isEmptySlots = true,
                isSoulSlots = true,
                emptyCount = soulEmptyCount,
                texture = "Interface\\Icons\\INV_Misc_Gem_Amethyst_02",
                count = soulEmptyCount,
                name = "Soul Bag Slots",
            },
        }
        table.insert(soulSection.items, soulItem)
    end

    -- Group identical items into single slots with combined count (if setting enabled)
    -- Skip grouping when interaction windows are open (bank, trade, mail, etc.)
    -- so users can interact with individual stacks
    local Database = ns:GetModule("Database")
    local groupIdenticalItems = Database and Database:GetSetting("groupIdenticalItems")
    local shouldGroup = groupIdenticalItems and not IsInteractionWindowOpen()
    if shouldGroup then
        for _, section in ipairs(sections) do
            local itemsByID = {}  -- { [itemID] = { items } }
            local itemOrder = {}  -- Track order of first occurrence

            for _, item in ipairs(section.items) do
                local itemID = item.itemData and item.itemData.itemID
                if itemID then
                    if not itemsByID[itemID] then
                        itemsByID[itemID] = {}
                        table.insert(itemOrder, itemID)
                    end
                    table.insert(itemsByID[itemID], item)
                else
                    -- Items without itemID (like pseudo-items) go through as-is
                    if not itemsByID["_noID"] then
                        itemsByID["_noID"] = {}
                        table.insert(itemOrder, "_noID")
                    end
                    table.insert(itemsByID["_noID"], item)
                end
            end

            -- Rebuild section items with grouped items
            local newItems = {}
            for _, itemID in ipairs(itemOrder) do
                local items = itemsByID[itemID]
                if itemID == "_noID" then
                    -- Pass through items without itemID unchanged
                    for _, item in ipairs(items) do
                        table.insert(newItems, item)
                    end
                elseif #items == 1 then
                    -- Single item, no grouping needed
                    table.insert(newItems, items[1])
                else
                    -- Multiple identical items - consolidate into one
                    local firstItem = items[1]
                    local totalCount = 0
                    local locations = {}

                    for _, item in ipairs(items) do
                        totalCount = totalCount + (item.itemData.count or 1)
                        table.insert(locations, {
                            bagID = item.bagID,
                            slot = item.slot,
                        })
                    end

                    local consolidatedItem = {
                        bagID = firstItem.bagID,
                        slot = firstItem.slot,
                        categoryOrderIndex = firstItem.categoryOrderIndex,
                        itemData = {
                            bagID = firstItem.bagID,
                            slot = firstItem.slot,
                            itemID = itemID,
                            link = firstItem.itemData.link,
                            texture = firstItem.itemData.texture,
                            count = totalCount,
                            quality = firstItem.itemData.quality,
                            name = firstItem.itemData.name,
                            itemType = firstItem.itemData.itemType,
                            itemSubType = firstItem.itemData.itemSubType,
                            isGroupedStack = true,
                            groupedLocations = locations,
                        },
                    }
                    table.insert(newItems, consolidatedItem)
                end
            end
            section.items = newItems
        end
    end

    -- Remove empty sections (but keep empty custom categories so users can see them)
    local nonEmptySections = {}
    for _, section in ipairs(sections) do
        local def = categories.definitions[section.categoryId]
        local isCustomCategory = def and not def.isBuiltIn and not section.isGroup
        -- Also keep Empty/Soul category if it has items (empty slots)
        local isEmptyCategory = section.categoryId == "Empty" and #section.items > 0
        local isSoulCategory = section.categoryId == "Soul" and #section.items > 0
        if #section.items > 0 or isCustomCategory or isEmptyCategory or isSoulCategory then
            table.insert(nonEmptySections, section)
        end
    end

    return nonEmptySections
end

-- Sort key cache for category view (avoid repeated GetItemInfo calls)
local categorySortKeyCache = {}

local function GetCategorySortKey(itemData)
    local itemID = itemData.itemID
    if not itemID then return nil end

    -- Check cache first
    if categorySortKeyCache[itemID] then
        return categorySortKeyCache[itemID]
    end

    -- Fetch classID, subClassID, and itemLevel from GetItemInfo
    local _, _, _, itemLevel, _, _, _, _, _, _, _, classID, subClassID = GetItemInfo(itemID)

    local sortKey = {
        classID = classID or 15,  -- Default to Miscellaneous
        subClassID = subClassID or 0,
        itemLevel = itemLevel or 0,
    }

    categorySortKeyCache[itemID] = sortKey
    return sortKey
end

-- Clear sort key cache (call on login or when needed)
function LayoutEngine:ClearSortKeyCache()
    wipe(categorySortKeyCache)
end

-- Sort items within a category section
-- For merged groups, items are sorted by category order first to maintain category grouping
function LayoutEngine:SortCategoryItems(items, isMergedGroup)
    table.sort(items, function(a, b)
        -- For merged groups, sort by category order first
        if isMergedGroup then
            local aOrder = a.categoryOrderIndex or 999
            local bOrder = b.categoryOrderIndex or 999
            if aOrder ~= bOrder then
                return aOrder < bOrder
            end
        end

        local aData = a.itemData
        local bData = b.itemData

        -- Quality (descending)
        local aQuality = aData.quality or 0
        local bQuality = bData.quality or 0
        if aQuality ~= bQuality then
            return aQuality > bQuality
        end

        -- Get sort keys (classID, subClassID)
        local aKey = GetCategorySortKey(aData)
        local bKey = GetCategorySortKey(bData)

        if aKey and bKey then
            -- Class ID (groups items by major category)
            if aKey.classID ~= bKey.classID then
                return aKey.classID < bKey.classID
            end

            -- SubClass ID (groups similar items together - all marks of honor have same subClassID)
            if aKey.subClassID ~= bKey.subClassID then
                return aKey.subClassID < bKey.subClassID
            end

            -- Item level (higher first, like bag view)
            if aKey.itemLevel ~= bKey.itemLevel then
                return aKey.itemLevel > bKey.itemLevel
            end
        end

        -- Item type (fallback for items without classID)
        local aType = aData.itemType or ""
        local bType = bData.itemType or ""
        if aType ~= bType then
            return aType < bType
        end

        -- Item subtype
        local aSubType = aData.itemSubType or ""
        local bSubType = bData.itemSubType or ""
        if aSubType ~= bSubType then
            return aSubType < bSubType
        end

        -- Item ID (groups related items together - items added at same time have consecutive IDs)
        local aID = aData.itemID or 0
        local bID = bData.itemID or 0
        if aID ~= bID then
            return aID < bID
        end

        -- Name (alphabetical, for items with same ID which shouldn't happen)
        local aName = aData.name or ""
        local bName = bData.name or ""
        if aName ~= bName then
            return aName < bName
        end

        -- Stack count (higher stacks first)
        return (aData.count or 1) > (bData.count or 1)
    end)
end

-- Calculate gap between category blocks based on icon size
local function GetCategoryBlockGap(iconSize)
    if iconSize < Constants.CATEGORY_ICON_SIZE_THRESHOLD then
        return Constants.CATEGORY_GAP_SMALL_ICONS
    else
        return Constants.CATEGORY_GAP_LARGE_ICONS
    end
end

-- Calculate frame size for category view with inline layout
-- Returns frameWidth, frameHeight
function LayoutEngine:CalculateCategoryFrameSize(sections, settings)
    local columns = settings.columns
    local iconSize = settings.iconSize
    local spacing = settings.spacing
    local showSearchBar = settings.showSearchBar
    local showFilterChips = settings.showFilterChips
    local showFooter = settings.showFooter
    local blockGap = GetCategoryBlockGap(iconSize)

    local totalWidth = (iconSize * columns) + (spacing * (columns - 1))
    local currentX = 0
    local currentY = 0
    local rowMaxHeight = 0

    local lastGroup = nil

    for _, section in ipairs(sections) do
        if #section.items > 0 then
            -- Calculate block dimensions
            local numItems = #section.items
            local blockCols = numItems
            if blockCols > columns then blockCols = columns end
            local blockRows = math.ceil(numItems / columns)
            -- Block width: N icons + (N-1) spacing between them
            local blockWidth = (blockCols * iconSize) + (math.max(0, blockCols - 1) * spacing)
            local blockHeight = CATEGORY_HEADER_HEIGHT + (blockRows * iconSize) + (math.max(0, blockRows - 1) * spacing) + 5

            -- Check if group changed (entering or leaving a group requires new row)
            local currentGroup = section.group
            local groupChanged = currentGroup ~= lastGroup

            if groupChanged and currentX > 0 then
                -- Group boundary - start new row
                currentX = 0
                currentY = currentY + rowMaxHeight
                rowMaxHeight = 0
            -- Check if block fits in current row (gap only needed between blocks, not at end)
            elseif currentX > 0 and currentX + blockWidth > totalWidth then
                -- Start new row
                currentX = 0
                currentY = currentY + rowMaxHeight
                rowMaxHeight = 0
            end

            lastGroup = currentGroup

            -- Track max height for this row
            if blockHeight > rowMaxHeight then
                rowMaxHeight = blockHeight
            end

            -- Move X for next block (add gap for spacing to next block)
            currentX = currentX + blockWidth + blockGap
        end
    end

    -- Add final row height
    local contentHeight = currentY + rowMaxHeight
    if contentHeight < iconSize then contentHeight = iconSize end

    local chipHeight = (showSearchBar and showFilterChips) and (Constants.FRAME.CHIP_STRIP_HEIGHT + 1) or 0
    local searchBarHeight = showSearchBar and (Constants.FRAME.SEARCH_BAR_HEIGHT + chipHeight + 4) or 0
    local footerHeight = showFooter and (Constants.FRAME.FOOTER_HEIGHT + 6) or Constants.FRAME.PADDING

    local frameWidth = math.max(totalWidth + (Constants.FRAME.PADDING * 2), Constants.FRAME.MIN_WIDTH)
    local frameHeight = math.max(
        contentHeight + Constants.FRAME.TITLE_HEIGHT + searchBarHeight + footerHeight + Constants.FRAME.PADDING + 4,
        Constants.FRAME.MIN_HEIGHT
    )

    return frameWidth, frameHeight
end

-- Calculate positions for category view with inline layout
-- Returns { headers = { {section, x, y, width} }, items = { {item, x, y} } }
function LayoutEngine:CalculateCategoryPositions(sections, settings)
    local columns = settings.columns
    local iconSize = settings.iconSize
    local spacing = settings.spacing
    local blockGap = GetCategoryBlockGap(iconSize)

    local result = {
        headers = {},
        items = {},
    }

    local totalWidth = (iconSize * columns) + (spacing * (columns - 1))
    local currentX = 0
    local currentY = 0
    local rowMaxHeight = 0

    local lastGroup = nil

    for _, section in ipairs(sections) do
        if #section.items > 0 then
            -- Sort items within category (merged groups sort by category order first)
            self:SortCategoryItems(section.items, section.isGroup)

            -- Calculate block dimensions
            local numItems = #section.items
            local blockCols = numItems
            if blockCols > columns then blockCols = columns end
            local blockRows = math.ceil(numItems / columns)
            -- Block width: N icons + (N-1) spacing between them
            local blockWidth = (blockCols * iconSize) + (math.max(0, blockCols - 1) * spacing)
            local blockHeight = CATEGORY_HEADER_HEIGHT + (blockRows * iconSize) + (math.max(0, blockRows - 1) * spacing) + 5

            -- Check if group changed (entering or leaving a group requires new row)
            local currentGroup = section.group
            local groupChanged = currentGroup ~= lastGroup

            if groupChanged and currentX > 0 then
                -- Group boundary - start new row
                currentX = 0
                currentY = currentY + rowMaxHeight
                rowMaxHeight = 0
            -- Check if block fits in current row (gap only needed between blocks, not at end)
            elseif currentX > 0 and currentX + blockWidth > totalWidth then
                -- Start new row
                currentX = 0
                currentY = currentY + rowMaxHeight
                rowMaxHeight = 0
            end

            lastGroup = currentGroup

            -- Header position (y is negative offset from top)
            table.insert(result.headers, {
                section = section,
                x = currentX,
                y = -currentY,
                width = blockWidth,
            })

            -- Item positions within this block
            local itemStartY = currentY + CATEGORY_HEADER_HEIGHT
            local col = 0
            local row = 0
            for _, item in ipairs(section.items) do
                local x = currentX + (col * (iconSize + spacing))
                local y = -(itemStartY + (row * (iconSize + spacing)))

                table.insert(result.items, {
                    item = item,
                    x = x,
                    y = y,
                    categoryId = section.categoryId,
                })

                col = col + 1
                if col >= blockCols then
                    col = 0
                    row = row + 1
                end
            end

            -- Track max height for this row
            if blockHeight > rowMaxHeight then
                rowMaxHeight = blockHeight
            end

            -- Move X for next block
            currentX = currentX + blockWidth + blockGap
        end
    end

    return result
end

function LayoutEngine:GetCategoryHeaderHeight()
    return CATEGORY_HEADER_HEIGHT
end
