local addonName, ns = ...

local MailScanner = {}
ns:RegisterModule("MailScanner", MailScanner)

local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")

-- State
local isMailboxOpen = false
local cachedMail = {}
local saveTimer = nil
local scanTimer = nil
local SAVE_DELAY = 1.0
local SCAN_DELAY = 0.5
local RESCAN_DEBOUNCE = 0.3

-------------------------------------------------
-- Public State
-------------------------------------------------

function MailScanner:IsMailboxOpen()
    return isMailboxOpen
end

function MailScanner:GetCachedMail()
    return cachedMail
end

-------------------------------------------------
-- Scanning
-------------------------------------------------

function MailScanner:ScanMailbox()
    if not isMailboxOpen then
        ns:Debug("MailScanner: Mailbox not open, returning cached")
        return cachedMail
    end

    local numItems = GetInboxNumItems()
    ns:Debug("MailScanner: Scanning", numItems, "mails")

    local rows = {}

    for mailIndex = 1, numItems do
        local _, _, sender, subject, money, CODAmount, daysLeft, numAttachments, wasRead, _, _, _, isGM = GetInboxHeaderInfo(mailIndex)

        if not sender then sender = UNKNOWN or "Unknown" end
        if not subject then subject = "" end

        local hasAttachments = numAttachments and numAttachments > 0

        if hasAttachments then
            for attachIndex = 1, numAttachments do
                local name, itemID, texture, count, quality, canUse = GetInboxItem(mailIndex, attachIndex)
                local link = GetInboxItemLink(mailIndex, attachIndex)

                if itemID then
                    local itemType, itemSubType, _, equipSlot
                    if link then
                        _, _, _, _, _, itemType, itemSubType, _, equipSlot = GetItemInfo(link)
                    end

                    table.insert(rows, {
                        mailIndex = mailIndex,
                        attachmentIndex = attachIndex,
                        sender = sender,
                        subject = subject,
                        money = money or 0,
                        CODAmount = CODAmount or 0,
                        daysLeft = daysLeft or 0,
                        wasRead = wasRead,
                        hasItem = true,
                        itemID = itemID,
                        link = link,
                        name = name or "",
                        texture = texture,
                        count = count or 1,
                        quality = quality or 0,
                        itemType = itemType,
                        itemSubType = itemSubType,
                        equipSlot = equipSlot,
                    })
                end
            end
        end

        -- Money-only or no-attachment mails get one row
        if not hasAttachments then
            table.insert(rows, {
                mailIndex = mailIndex,
                attachmentIndex = 0,
                sender = sender,
                subject = subject,
                money = money or 0,
                CODAmount = CODAmount or 0,
                daysLeft = daysLeft or 0,
                wasRead = wasRead,
                hasItem = false,
            })
        end
    end

    cachedMail = rows
    ns:Debug("MailScanner: Scanned", #rows, "rows from", numItems, "mails")

    return rows
end

-------------------------------------------------
-- Database Persistence
-------------------------------------------------

function MailScanner:SaveToDatabase()
    Database:SaveMailbox(cachedMail)
    ns:Debug("MailScanner: Saved", #cachedMail, "rows to database")
end

function MailScanner:LoadFromDatabase(fullName)
    local mailData = Database:GetMailbox(fullName)
    if mailData and #mailData > 0 then
        cachedMail = mailData
        ns:Debug("MailScanner: Loaded", #cachedMail, "rows from database for", fullName or "current")
    else
        cachedMail = {}
        ns:Debug("MailScanner: No mail data found for", fullName or "current")
    end
end

-------------------------------------------------
-- Deferred Save
-------------------------------------------------

local function ScheduleDeferredSave()
    if saveTimer then
        saveTimer:Cancel()
    end
    saveTimer = C_Timer.NewTimer(SAVE_DELAY, function()
        MailScanner:SaveToDatabase()
        saveTimer = nil
        ns:Debug("MailScanner: Deferred save complete")
    end)
end

-------------------------------------------------
-- Debounced Rescan
-------------------------------------------------

local function ScheduleRescan()
    if scanTimer then
        scanTimer:Cancel()
    end
    scanTimer = C_Timer.NewTimer(RESCAN_DEBOUNCE, function()
        scanTimer = nil
        if not isMailboxOpen then return end
        MailScanner:ScanMailbox()
        ScheduleDeferredSave()

        if ns.OnMailUpdated then
            ns.OnMailUpdated()
        end
    end)
end

-------------------------------------------------
-- Hooks
-------------------------------------------------

local function InitializeHooks()
    -- TakeInboxItem: player took an attachment
    if TakeInboxItem then
        hooksecurefunc("TakeInboxItem", function(mailIndex, attachIndex)
            ns:Debug("MailScanner: TakeInboxItem hook", mailIndex, attachIndex)
            ScheduleRescan()
        end)
    end

    -- TakeInboxMoney: player took money from mail
    if TakeInboxMoney then
        hooksecurefunc("TakeInboxMoney", function(mailIndex)
            ns:Debug("MailScanner: TakeInboxMoney hook", mailIndex)
            ScheduleRescan()
        end)
    end

    -- AutoLootMailItem: auto-loot attachment
    if AutoLootMailItem then
        hooksecurefunc("AutoLootMailItem", function(mailIndex)
            ns:Debug("MailScanner: AutoLootMailItem hook", mailIndex)
            ScheduleRescan()
        end)
    end

    -- DeleteInboxItem: player deleted a mail
    if DeleteInboxItem then
        hooksecurefunc("DeleteInboxItem", function(mailIndex)
            ns:Debug("MailScanner: DeleteInboxItem hook", mailIndex)
            ScheduleRescan()
        end)
    end
end

-------------------------------------------------
-- Event Handlers
-------------------------------------------------

Events:Register("MAIL_SHOW", function()
    ns:Debug("MailScanner: MAIL_SHOW")
    isMailboxOpen = true

    -- Delay initial scan to wait for server data
    if scanTimer then
        scanTimer:Cancel()
    end
    scanTimer = C_Timer.NewTimer(SCAN_DELAY, function()
        scanTimer = nil
        if not isMailboxOpen then return end
        MailScanner:ScanMailbox()
        MailScanner:SaveToDatabase()

        if ns.OnMailUpdated then
            ns.OnMailUpdated()
        end
    end)
end, MailScanner)

Events:Register("MAIL_CLOSED", function()
    ns:Debug("MailScanner: MAIL_CLOSED")
    -- Final save before closing
    if isMailboxOpen then
        MailScanner:ScanMailbox()
        MailScanner:SaveToDatabase()
    end
    isMailboxOpen = false

    if scanTimer then
        scanTimer:Cancel()
        scanTimer = nil
    end
end, MailScanner)

Events:Register("MAIL_INBOX_UPDATE", function()
    if not isMailboxOpen then return end
    ns:Debug("MailScanner: MAIL_INBOX_UPDATE")
    ScheduleRescan()
end, MailScanner)

-------------------------------------------------
-- Initialization
-------------------------------------------------

local hooksInitialized = false

Events:OnPlayerLogin(function()
    if not hooksInitialized then
        hooksInitialized = true
        InitializeHooks()
    end

    -- Load cached mail from database
    MailScanner:LoadFromDatabase()
end, MailScanner)
