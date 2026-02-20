local addonName, ns = ...

local MailCharacters = {}
ns:RegisterModule("MailFrame.MailCharacters", MailCharacters)

local CharacterDropdown = ns:GetModule("CharacterDropdown")

local function GetDatabase()
    return ns:GetModule("Database")
end

local function HasMailData(fullName)
    local Database = GetDatabase()
    local mailbox = Database:GetMailbox(fullName)
    return mailbox and #mailbox > 0
end

local dropdown = CharacterDropdown:Create({
    frameName = "GudaBagsMailCharacterDropdown",
    hasDataFunc = HasMailData,
    getViewingCharacter = function()
        local MailFrame = ns:GetModule("MailFrame")
        return MailFrame and MailFrame:GetViewingCharacter() or nil
    end,
})

function MailCharacters:Show(anchor)
    dropdown:Show(anchor)
end

function MailCharacters:Hide()
    dropdown:Hide()
end

function MailCharacters:Toggle(anchor)
    dropdown:Toggle(anchor)
end

function MailCharacters:SetCallback(callback)
    dropdown:SetCallback(callback)
end

function MailCharacters:IsShown()
    return dropdown:IsShown()
end
