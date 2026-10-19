local DATA_DIRECTORY = "/email-server"
local MAILBOX_PATH = DATA_DIRECTORY .. "/mailboxes.json"
local CATEGORY_PATH = DATA_DIRECTORY .. "/categories.json"
local LEGACY_MAILBOX_PATH = "/.launcher/email-mailboxes.json"
local MAX_MESSAGES_PER_MAILBOX = 100
local MAX_SUBJECT_LENGTH = 80
local MAX_BODY_LENGTH = 2000
local MAX_CATEGORIES_PER_ACCOUNT = 20
local MAX_CATEGORY_NAME_LENGTH = 24

local function validUsername(username)
    return type(username) == "string" and #username >= 3 and #username <= 24
        and username:match("^[%w_-]+$") ~= nil
end

local function usernameFromLegacyAddress(address)
    if type(address) ~= "string" then return nil end
    local username = address:match("^([^@]+)@") or address
    if not validUsername(username) then return nil end
    return username:lower()
end

local function validCategoryName(name)
    return type(name) == "string" and #name > 0 and #name <= MAX_CATEGORY_NAME_LENGTH
        and name:match("^[%w _%-]+$") ~= nil and name:match("^%s*$") == nil
        and name == name:match("^%s*(.-)%s*$")
end

local function isInbox(category)
    return type(category) == "string" and category:lower() == "inbox"
end

local function readJSON(path, label, default)
    if not fs.exists(path) then return default end
    local file = fs.open(path, "r")
    if not file then error("Could not open " .. path .. " for reading.") end
    local contents = file.readAll()
    file.close()
    local ok, data = pcall(textutils.unserializeJSON, contents)
    if not ok or type(data) ~= "table" then
        error(label .. " is invalid; refusing to overwrite it.")
    end
    return data
end

local function saveJSON(path, data, label)
    fs.makeDir(DATA_DIRECTORY)
    local temporary, backup = path .. ".tmp", path .. ".bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end

    local serialized, contents = pcall(textutils.serializeJSON, data)
    if not serialized or type(contents) ~= "string" then
        return false, "Could not serialize " .. label .. "."
    end
    local file = fs.open(temporary, "w")
    if not file then return false, "Could not create the " .. label .. " staging file." end
    local wrote, writeError = pcall(file.write, contents)
    local closed, closeError = pcall(file.close)
    if not wrote or not closed then
        if fs.exists(temporary) then fs.delete(temporary) end
        return false, "Could not write " .. label .. ": "
            .. tostring(not wrote and writeError or closeError)
    end

    if fs.exists(path) then
        local moved, moveError = pcall(fs.move, path, backup)
        if not moved then
            fs.delete(temporary)
            return false, "Could not back up " .. label .. ": " .. tostring(moveError)
        end
    end
    local moved, moveError = pcall(fs.move, temporary, path)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then fs.move(backup, path) end
        return false, "Could not save " .. label .. ": " .. tostring(moveError)
    end
    if fs.exists(backup) then fs.delete(backup) end
    return true
end

local function migrateKeys(data, migrateMessages, sourceIdentities)
    local migrated, changed = {}, false
    for oldKey, value in pairs(data) do
        local username = usernameFromLegacyAddress(oldKey)
        if not username and not validUsername(oldKey) then
            error("Legacy mail data key '" .. tostring(oldKey)
                .. "' cannot be mapped to a Rift username; resolve it before starting Rift Server.")
        end
        local key = username or oldKey
        local source = oldKey:lower()
        local previousSource = sourceIdentities[key]
        if previousSource and previousSource ~= source
            and previousSource:find("@", 1, true) and source:find("@", 1, true) then
            error("Legacy mail data has multiple addresses mapping to Rift username '"
                .. key .. "'; resolve the collision before starting Rift Server.")
        end
        if not previousSource or source:find("@", 1, true) then
            sourceIdentities[key] = source
        end
        if key ~= oldKey then changed = true end
        migrated[key] = value
    end
    if migrateMessages then
        for _, messages in pairs(migrated) do
            for _, message in ipairs(messages) do
                local sender = usernameFromLegacyAddress(message.from)
                if sender then
                    message.from = sender
                    changed = true
                elseif not validUsername(message.from) then
                    error("A legacy message sender cannot be mapped to a Rift username; "
                        .. "resolve it before starting Rift Server.")
                end
            end
        end
    end
    return migrated, changed
end

local function loadMailboxes(sourceIdentities)
    local path = fs.exists(MAILBOX_PATH) and MAILBOX_PATH or LEGACY_MAILBOX_PATH
    local data = readJSON(path, "Email mailbox data", {})
    for _, messages in pairs(data) do
        if type(messages) ~= "table" then error("Email mailbox data contains an invalid mailbox.") end
        for _, message in ipairs(messages) do
            if type(message) ~= "table" or type(message.id) ~= "number"
                or type(message.from) ~= "string" or type(message.subject) ~= "string"
                or type(message.body) ~= "string" or type(message.sentAt) ~= "number"
                or type(message.read) ~= "boolean" then
                error("Email mailbox data contains an invalid message.")
            end
        end
    end
    local migrated, changed = migrateKeys(data, true, sourceIdentities)
    return migrated, changed
end

local function loadCategories(sourceIdentities)
    local data = readJSON(CATEGORY_PATH, "Email category data", {})
    for _, names in pairs(data) do
        if type(names) ~= "table" then error("Email category data contains an invalid account.") end
        local seen, count = {}, 0
        for index, name in pairs(names) do
            if type(index) ~= "number" or index < 1 or index % 1 ~= 0
                or not validCategoryName(name) or isInbox(name) or seen[name:lower()] then
                error("Email category data contains an invalid category.")
            end
            seen[name:lower()] = true
            count = count + 1
        end
        if count > MAX_CATEGORIES_PER_ACCOUNT then
            error("Email category data exceeds the category limit.")
        end
        for index = 1, count do
            if names[index] == nil then error("Email category data contains an invalid category list.") end
        end
    end
    local migrated, changed = migrateKeys(data, false, sourceIdentities)
    return migrated, changed
end

local function mailboxFor(mailboxes, username)
    if not mailboxes[username] then mailboxes[username] = {} end
    return mailboxes[username]
end

local function summarize(messages, category)
    local result = {}
    for _, message in ipairs(messages) do
        if (message.category or "Inbox") == category then
            table.insert(result, {
                id = message.id,
                from = message.from,
                subject = message.subject,
                sentAt = message.sentAt,
                read = message.read,
            })
        end
    end
    return result
end

local function categoriesFor(categories, username)
    local result = { "Inbox" }
    for _, category in ipairs(categories[username] or {}) do
        table.insert(result, category)
    end
    return result
end

local function hasCategory(categories, username, requested)
    if isInbox(requested) then return true, "Inbox" end
    if type(requested) ~= "string" then return false end
    for _, category in ipairs(categories[username] or {}) do
        if category:lower() == requested:lower() then return true, category end
    end
    return false
end

local function nextMessageId(mailboxes, timestamp)
    local largestId = timestamp - 1
    for _, messages in pairs(mailboxes) do
        for _, message in ipairs(messages) do
            if message.id >= largestId then largestId = message.id end
        end
    end
    return largestId + 1
end

local function createEmailServer(isRegisteredUser)
    local sourceIdentities = {}
    local mailboxes, mailboxesChanged = loadMailboxes(sourceIdentities)
    local categories, categoriesChanged = loadCategories(sourceIdentities)
    if mailboxesChanged then
        local saved, saveError = saveJSON(MAILBOX_PATH, mailboxes, "mailbox data")
        if not saved then error(saveError) end
    end
    if categoriesChanged then
        local saved, saveError = saveJSON(CATEGORY_PATH, categories, "category data")
        if not saved then error(saveError) end
    end

    local function handleRequest(username, request)
        if not validUsername(username) or type(request) ~= "table"
            or type(request.type) ~= "string" then
            return { type = "error", message = "Sign in to a valid Rift account first." }
        end
        username = username:lower()

        if request.type == "send" then
            local recipient = type(request.to) == "string" and request.to:lower() or nil
            if not validUsername(recipient) or not isRegisteredUser(recipient) then
                return { type = "error", message = "Recipient Rift username is not registered." }
            end
            if type(request.subject) ~= "string" or #request.subject < 1
                or #request.subject > MAX_SUBJECT_LENGTH or request.subject:find("%c") then
                return { type = "error", message = "Subject must be 1 to 80 characters without control characters." }
            end
            if type(request.body) ~= "string" or #request.body < 1 or #request.body > MAX_BODY_LENGTH then
                return { type = "error", message = "Message body must be 1 to 2000 characters." }
            end
            local recipientMailbox = mailboxFor(mailboxes, recipient)
            if #recipientMailbox >= MAX_MESSAGES_PER_MAILBOX then
                return { type = "error", message = "The recipient mailbox is full." }
            end
            local sentAt = os.epoch and os.epoch("utc") or os.time() * 1000
            local id = nextMessageId(mailboxes, sentAt)
            table.insert(recipientMailbox, {
                id = id, from = username, subject = request.subject,
                body = request.body, sentAt = sentAt, read = false,
            })
            local saved, saveError = saveJSON(MAILBOX_PATH, mailboxes, "mailbox data")
            if not saved then
                table.remove(recipientMailbox)
                return { type = "error", message = saveError }
            end
            return { type = "sent", id = id }
        elseif request.type == "list" then
            local exists, category = hasCategory(categories, username, request.category or "Inbox")
            if not exists then return { type = "error", message = "Email category not found." } end
            return {
                type = "inbox",
                category = category,
                messages = summarize(mailboxFor(mailboxes, username), category),
            }
        elseif request.type == "list_categories" then
            return { type = "categories", categories = categoriesFor(categories, username) }
        elseif request.type == "create_category" then
            local name = request.category
            if not validCategoryName(name) or isInbox(name) then
                return { type = "error", message = "Category names must be 1 to 24 characters and cannot be Inbox." }
            end
            local accountCategories = categories[username] or {}
            categories[username] = accountCategories
            for _, existing in ipairs(accountCategories) do
                if existing:lower() == name:lower() then
                    return { type = "error", message = "That category already exists." }
                end
            end
            if #accountCategories >= MAX_CATEGORIES_PER_ACCOUNT then
                return { type = "error", message = "You have reached the category limit." }
            end
            table.insert(accountCategories, name)
            local saved, saveError = saveJSON(CATEGORY_PATH, categories, "category data")
            if not saved then
                table.remove(accountCategories)
                if #accountCategories == 0 then categories[username] = nil end
                return { type = "error", message = saveError }
            end
            return { type = "category_created", category = name }
        elseif request.type == "move" then
            if type(request.id) ~= "number" then
                return { type = "error", message = "Message request is invalid." }
            end
            local exists, destination = hasCategory(categories, username, request.category)
            if not exists then return { type = "error", message = "Email category not found." } end
            local messages = mailboxFor(mailboxes, username)
            for _, message in ipairs(messages) do
                if message.id == request.id then
                    local previousCategory = message.category
                    if destination == "Inbox" then
                        message.category = nil
                    else
                        message.category = destination
                    end
                    local saved, saveError = saveJSON(MAILBOX_PATH, mailboxes, "mailbox data")
                    if not saved then
                        message.category = previousCategory
                        return { type = "error", message = saveError }
                    end
                    return { type = "moved", id = request.id, category = destination }
                end
            end
            return { type = "error", message = "Message not found." }
        elseif request.type == "read" then
            if type(request.id) ~= "number" then
                return { type = "error", message = "Message request is invalid." }
            end
            for _, message in ipairs(mailboxFor(mailboxes, username)) do
                if message.id == request.id then
                    local wasRead = message.read
                    message.read = true
                    if not wasRead then
                        local saved, saveError = saveJSON(MAILBOX_PATH, mailboxes, "mailbox data")
                        if not saved then
                            message.read = false
                            return { type = "error", message = saveError }
                        end
                    end
                    return {
                        type = "message",
                        message = {
                            id = message.id, from = message.from, subject = message.subject,
                            body = message.body, sentAt = message.sentAt,
                        },
                    }
                end
            end
            return { type = "error", message = "Message not found." }
        elseif request.type == "delete" then
            if type(request.id) ~= "number" then
                return { type = "error", message = "Message request is invalid." }
            end
            local messages = mailboxFor(mailboxes, username)
            for index, message in ipairs(messages) do
                if message.id == request.id then
                    local deleted = table.remove(messages, index)
                    local saved, saveError = saveJSON(MAILBOX_PATH, mailboxes, "mailbox data")
                    if not saved then
                        table.insert(messages, index, deleted)
                        return { type = "error", message = saveError }
                    end
                    return { type = "deleted", id = request.id }
                end
            end
            return { type = "error", message = "Message not found." }
        end
        return { type = "error", message = "Unknown Rift Mail request." }
    end

    local function getStats()
        local mailboxCount, messageCount, categoryCount = 0, 0, 0
        for _, messages in pairs(mailboxes) do
            mailboxCount = mailboxCount + 1
            messageCount = messageCount + #messages
        end
        for _, userCategories in pairs(categories) do
            categoryCount = categoryCount + #userCategories
        end
        return {
            mailboxes = mailboxCount,
            messages = messageCount,
            categories = categoryCount,
        }
    end

    return handleRequest, getStats
end

return createEmailServer
