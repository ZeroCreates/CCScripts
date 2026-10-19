local PROTOCOL = "rift_mail_v1"
local SERVER_NAME = "rift-mail"
local ACCOUNT_PROTOCOL = "rift_account_v1"
local ACCOUNT_SERVER_NAME = "rift-server"
local LEGACY_ACCOUNT_PROTOCOL = "rift_jobs_v1"
local LEGACY_ACCOUNT_SERVER_NAME = "rift-jobs"
local TIMEOUT = 5
local RIFT_ACCOUNT_PATH = "rift/account.json"
local LEGACY_ACCOUNT_PATH = "rift-jobs/login.json"
local storageLoaded, storage = pcall(require, "storage")
if not storageLoaded or type(storage) ~= "table"
    or type(storage.read) ~= "function" or type(storage.write) ~= "function"
    or type(storage.delete) ~= "function" then
    storage = nil
end
local mouseEnabled = false
local account
local currentFolder = "Inbox"
local themeAccent = colors.cyan
local themeHighlight = colors.blue

if type(launcherTheme) == "table" then
    if type(launcherTheme.accent) == "number" then themeAccent = launcherTheme.accent end
    if type(launcherTheme.highlight) == "number" then themeHighlight = launcherTheme.highlight end
end
if not term.isColor() then
    themeAccent = colors.gray
    themeHighlight = colors.gray
end

local function clearScreen()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
end

local function writeAt(x, y, text, foreground, background)
    local width, height = term.getSize()
    if y < 1 or y > height or x > width then return end
    term.setCursorPos(x, y)
    term.setTextColor(foreground or colors.white)
    term.setBackgroundColor(background or colors.black)
    term.write(tostring(text):sub(1, width - x + 1))
    term.setBackgroundColor(colors.black)
end

local function drawHeader(title, subtitle)
    local width = term.getSize()
    clearScreen()
    writeAt(1, 1, string.rep(" ", width), colors.white, themeAccent)
    writeAt(2, 1, title, colors.white, themeAccent)
    writeAt(2, 2, subtitle or "", colors.lightGray)
end

local function sectionTitle(y, title)
    local width = term.getSize()
    writeAt(1, y, string.rep(" ", width), colors.white, themeHighlight)
    writeAt(2, y, title, colors.white, themeHighlight)
end

local function drawChoices(help)
    local width, height = term.getSize()
    local options = {}
    for part in help:gmatch("[^|]+") do
        local key, label = part:match("^%s*([%w/]+)%s*(.-)%s*$")
        if key then
            if key:find("/") then
                local first, second = key:match("([^/]+)/([^/]+)")
                table.insert(options, { key = first, label = "NEXT " .. label })
                table.insert(options, { key = second, label = "PREV " .. label })
            else
                table.insert(options, { key = key, label = label ~= "" and label or key })
            end
        end
    end

    local columns = math.min(3, #options)
    local rows = math.ceil(#options / columns)
    local buttons = {}
    for index, option in ipairs(options) do
        local row = height - rows + math.floor((index - 1) / columns)
        local column = (index - 1) % columns
        local left = math.floor(column * width / columns) + 1
        local right = math.floor((column + 1) * width / columns)
        writeAt(left, row, ("[" .. option.label .. "]"):sub(1, right - left + 1),
            colors.black, themeHighlight)
        table.insert(buttons, { key = option.key, row = row, left = left, right = right })
    end
    return buttons
end

local function readChoice(help)
    if not mouseEnabled then
        local _, height = term.getSize()
        writeAt(2, height - 2, help, colors.lightGray)
        writeAt(2, height - 1, "> ", themeAccent)
        term.setCursorPos(4, height - 1)
        return read():lower()
    end

    local buttons = drawChoices(help)
    while true do
        local event, button, x, y = os.pullEvent()
        if event == "mouse_scroll" then
            local action = button > 0 and "n" or "v"
            for _, choice in ipairs(buttons) do
                if choice.key == action then return action end
            end
        elseif event == "mouse_click" and button == 1 then
            for _, choice in ipairs(buttons) do
                if y == choice.row and x >= choice.left and x <= choice.right then
                    return choice.key
                end
            end
        elseif event == "key" and (button == keys.n or button == keys.v) then
            local action = button == keys.n and "n" or "v"
            for _, choice in ipairs(buttons) do
                if choice.key == action then return action end
            end
        end
    end
end

local function openModems()
    local found = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            found = true
        end
    end
    if not found then error("Attach a modem before starting the email client.") end
    mouseEnabled = term.isColor()
end

local function request(payload)
    local serverId = rednet.lookup(PROTOCOL, SERVER_NAME)
    if not serverId then
        return nil, "Rift server not found. Check that it is running and connected."
    end
    rednet.send(serverId, payload, PROTOCOL)
    local _, response = rednet.receive(PROTOCOL, TIMEOUT, serverId)
    if type(response) ~= "table" then return nil, "No response from Rift Mail." end
    if response.type == "error" then
        return nil, response.message or "Rift Mail rejected the request."
    end
    return response
end

local function choose(title, subtitle, choices)
    drawHeader(title, subtitle)
    local width, height = term.getSize()
    sectionTitle(4, "SELECT AN OPTION")
    local firstRow = 5
    local lastRow = height - 2
    for index, choice in ipairs(choices) do
        local row = firstRow + index - 1
        if row > lastRow then break end
        local background = index % 2 == 0 and colors.gray or colors.black
        writeAt(2, row, string.rep(" ", math.max(0, width - 2)), colors.white, background)
        writeAt(3, row, choice.label, colors.white, background)
    end

    if not mouseEnabled then
        writeAt(2, height - 1, "Choose an option by number and press Enter.", colors.lightGray)
        local input = read():lower()
        if input == "n" then return "next" end
        if input == "v" then return "previous" end
        local selected = tonumber(input)
        return selected and choices[selected] and choices[selected].key
    end

    while true do
        local event, button, x, y = os.pullEvent()
        if event == "mouse_scroll" then
            local scrollAction = button > 0 and "next" or "previous"
            for _, choice in ipairs(choices) do
                if choice.key == scrollAction then return scrollAction end
            end
        elseif event == "key" and (button == keys.n or button == keys.v) then
            local action = button == keys.n and "next" or "previous"
            for _, choice in ipairs(choices) do
                if choice.key == action then return action end
            end
        elseif event == "mouse_click" and button == 1 and x >= 2 then
            local index = y - firstRow + 1
            if index >= 1 and index <= #choices and y <= lastRow then
                return choices[index].key
            end
        end
    end
end

local function notice(title, message)
    drawHeader(title, "RIFT MAIL")
    sectionTitle(4, "NOTICE")
    local width = term.getSize()
    local row = 5
    for line in (tostring(message) .. "\n"):gmatch("(.-)\n") do
        writeAt(2, row, line, colors.white)
        row = row + 1
    end
    local _, height = term.getSize()
    writeAt(2, height - 1, "[ OK ]", colors.white, themeHighlight)
    if mouseEnabled then
        while true do
            local event, button, x, y = os.pullEvent()
            if event == "mouse_click" and button == 1 and y == height - 1 and x >= 2 and x <= math.min(width, 7) then
                return
            end
        end
    end
    read()
end

local function readField(label, secret)
    drawHeader("RIFT MAIL", "RIFT ACCOUNT")
    sectionTitle(4, "INPUT")
    writeAt(2, 6, label, colors.white)
    writeAt(2, 8, "> ", themeAccent)
    term.setCursorPos(4, 8)
    return read(secret and "*" or nil)
end

local function readSavedAccount(path)
    local storageError
    if storage then
        local ok, data, err = pcall(storage.read, path)
        if ok and data ~= nil then
            if type(data) ~= "table" or type(data.username) ~= "string"
                or (data.password ~= nil and type(data.password) ~= "string") then
                return nil, "Saved Rift account data is invalid."
            end
            return data
        end
        if not ok then
            storageError = data
        elseif err ~= "Stored data was not found." then
            storageError = err
        end
    end

    local absolutePath = "/" .. path
    if not fs.exists(absolutePath) then
        if storageError and storageError ~= "Stored data was not found." then
            return nil, "Launcher storage: " .. tostring(storageError)
                .. "; no root account file exists at " .. absolutePath .. "."
        end
        return nil
    end
    if fs.isDir(absolutePath) then return nil, "Saved Rift account path is a folder." end
    local file = fs.open(absolutePath, "r")
    if not file then return nil, "Could not open the saved Rift account." end
    local contents = file.readAll()
    file.close()
    local ok, data = pcall(textutils.unserializeJSON, contents)
    if not ok or type(data) ~= "table" or type(data.username) ~= "string"
        or (data.password ~= nil and type(data.password) ~= "string") then
        return nil, "Saved Rift account data is invalid."
    end
    return data
end

local function saveAccount(data)
    local storageError
    if storage then
        local ok, saved, err = pcall(storage.write, RIFT_ACCOUNT_PATH, data)
        if ok and saved then return true end
        storageError = ok and err or saved
    end

    local encoded, contents = pcall(textutils.serializeJSON, data)
    if not encoded or type(contents) ~= "string" then
        return false, "Rift account data could not be serialized."
    end
    local directory = "/rift"
    if not fs.exists(directory) then fs.makeDir(directory) end
    if not fs.isDir(directory) then return false, "The /rift account path is not a directory." end
    local file = fs.open("/" .. RIFT_ACCOUNT_PATH, "w")
    if not file then
        return false, "Could not save the Rift account to /rift/account.json."
            .. (storageError and " Launcher storage also failed: " .. tostring(storageError) or "")
    end
    local wrote, writeError = pcall(file.write, contents)
    local closed, closeError = pcall(file.close)
    if not wrote or not closed then
        return false, "Could not write the saved Rift account: "
            .. tostring(not wrote and writeError or closeError)
    end
    return true
end

local function loadAccount()
    local data, err = readSavedAccount(RIFT_ACCOUNT_PATH)
    if data then return type(data.password) == "string" and data or nil end
    if err then return nil, err end
    data, err = readSavedAccount(LEGACY_ACCOUNT_PATH)
    if data and type(data.password) == "string" then
        local saved, saveError = saveAccount(data)
        if not saved then notice("ACCOUNT STORAGE", saveError) end
    end
    return data and type(data.password) == "string" and data or nil, err
end

local function authenticateAccount(username, password)
    local accountProtocol = ACCOUNT_PROTOCOL
    local serverId = rednet.lookup(accountProtocol, ACCOUNT_SERVER_NAME)
    if not serverId then
        accountProtocol = LEGACY_ACCOUNT_PROTOCOL
        serverId = rednet.lookup(accountProtocol, LEGACY_ACCOUNT_SERVER_NAME)
    end
    if not serverId then
        return false, "Rift account server not found. Check that Rift Server is running."
    end
    rednet.send(serverId, {
        type = "login",
        username = username,
        password = password,
    }, accountProtocol)
    local senderId, response = rednet.receive(accountProtocol, TIMEOUT, serverId)
    if senderId ~= serverId or type(response) ~= "table" then
        return false, "No response from the Rift account server."
    end
    if response.type == "error" then
        return false, response.message or "Rift account sign-in failed."
    end
    if response.type ~= "authenticated" or type(response.username) ~= "string" then
        return false, "Unexpected response from the Rift account server."
    end
    local savedAccount = account
    if type(savedAccount) ~= "table"
        or type(savedAccount.username) ~= "string"
        or savedAccount.username:lower() ~= response.username:lower() then
        local storedAccount = readSavedAccount(RIFT_ACCOUNT_PATH)
        savedAccount = type(storedAccount) == "table"
            and type(storedAccount.username) == "string"
            and storedAccount.username:lower() == response.username:lower()
            and storedAccount or {}
    end
    savedAccount.username = response.username
    savedAccount.password = password
    account = savedAccount
    local saved, saveError = saveAccount(account)
    if not saved then
        return true, "Signed in, but account details could not be saved: " .. tostring(saveError)
    end
    return true
end

local function signOut()
    local accountProtocol = ACCOUNT_PROTOCOL
    local serverId = rednet.lookup(accountProtocol, ACCOUNT_SERVER_NAME)
    if not serverId then
        accountProtocol = LEGACY_ACCOUNT_PROTOCOL
        serverId = rednet.lookup(accountProtocol, LEGACY_ACCOUNT_SERVER_NAME)
    end
    if not serverId then
        notice("SIGN OUT", "Rift account server not found; could not sign out.")
        return false
    end
    rednet.send(serverId, { type = "logout" }, accountProtocol)
    local senderId, response = rednet.receive(accountProtocol, TIMEOUT, serverId)
    if senderId ~= serverId or type(response) ~= "table" or response.type ~= "logged_out" then
        notice("SIGN OUT", "No confirmation from the Rift account server.")
        return false
    end
    account.password = nil
    local saved, saveError = saveAccount(account)
    account = nil
    currentFolder = "Inbox"
    if not saved then
        notice("SIGN OUT", "Signed out, but saved credentials could not be cleared: "
            .. tostring(saveError))
    end
    return true
end

local function formatTime(timestamp)
    if os.date then return os.date("%Y-%m-%d %H:%M", math.floor(timestamp / 1000)) end
    return tostring(timestamp)
end

local function appendWrapped(lines, text, lineWidth)
    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
        if paragraph == "" then
            table.insert(lines, "")
        else
            while #paragraph > lineWidth do
                local segment = paragraph:sub(1, lineWidth)
                local breakAt = segment:match(".*()%s+")
                if breakAt and breakAt > 1 then
                    table.insert(lines, segment:sub(1, breakAt - 1))
                    paragraph = paragraph:sub(breakAt + 1)
                else
                    table.insert(lines, segment)
                    paragraph = paragraph:sub(lineWidth + 1)
                end
            end
            table.insert(lines, paragraph)
        end
    end
end

local function displayMessage(item)
    local width, height = term.getSize()
    local lines = {
        "From: " .. item.from,
        "Date: " .. formatTime(item.sentAt),
        "Subject: " .. item.subject,
        "",
    }
    appendWrapped(lines, item.body, math.max(1, width - 4))
    local pageSize = math.max(1, height - 9)
    local pageCount = math.max(1, math.ceil(#lines / pageSize))
    local page = 1

    while true do
        drawHeader("RIFT MAIL", account.username)
        sectionTitle(4, "MESSAGE  |  " .. item.subject)
        local firstLine = (page - 1) * pageSize + 1
        for index = firstLine, math.min(#lines, firstLine + pageSize - 1) do
            writeAt(2, 5 + index - firstLine, lines[index], colors.white)
        end
        writeAt(2, height - 4, "PAGE " .. page .. " / " .. pageCount, themeAccent)
        local action = readChoice("v prev|n next|m move|d delete|b back")
        if action == "b" then return "back" end
        if action == "d" then return "delete" end
        if action == "m" then return "move" end
        if action == "n" then page = math.min(pageCount, page + 1) end
        if action == "v" or action == "p" then page = math.max(1, page - 1) end
    end
end

local function fetchCategories()
    local response, err = request({
        type = "list_categories",
    })
    if not response then return nil, err end
    if type(response.categories) ~= "table" then
        return nil, "Rift Mail returned invalid categories."
    end
    return response.categories
end

local function chooseFolder(categories, title)
    local pageSize = math.max(1, select(2, term.getSize()) - 10)
    local page, pageCount = 1, math.max(1, math.ceil(#categories / pageSize))
    while true do
        local choices = {}
        local first = (page - 1) * pageSize + 1
        local last = math.min(#categories, first + pageSize - 1)
        for index = first, last do
            table.insert(choices, { key = "category:" .. categories[index], label = categories[index] })
        end
        if page > 1 then table.insert(choices, { key = "previous", label = "Previous page" }) end
        if page < pageCount then table.insert(choices, { key = "next", label = "Next page" }) end
        table.insert(choices, { key = "back", label = "Back" })
        local selected = choose(title, "Choose a folder", choices)
        if selected == "back" or not selected then return nil end
        if selected == "next" then
            page = math.min(pageCount, page + 1)
        elseif selected == "previous" then
            page = math.max(1, page - 1)
        else
            return selected:match("^category:(.+)$")
        end
    end
end

local function folders()
    local page = 1
    while true do
        local categories, err = fetchCategories()
        if not categories then notice("FOLDERS", err); return nil end
        local pageSize = math.max(1, select(2, term.getSize()) - 11)
        local pageCount = math.max(1, math.ceil(#categories / pageSize))
        page = math.min(page, pageCount)
        local choices = {}
        local first = (page - 1) * pageSize + 1
        local last = math.min(#categories, first + pageSize - 1)
        for index = first, last do
            table.insert(choices, {
                key = "category:" .. categories[index],
                label = "Open " .. categories[index],
            })
        end
        if page > 1 then table.insert(choices, { key = "previous", label = "Previous page" }) end
        if page < pageCount then table.insert(choices, { key = "next", label = "Next page" }) end
        table.insert(choices, { key = "create", label = "Create category" })
        table.insert(choices, { key = "back", label = "Back" })
        local selected = choose("RIFT MAIL FOLDERS", account.username, choices)
        if selected == "back" or not selected then return nil end
        if selected == "create" then
            local name = readField("New category name (up to 24 characters):")
            name = name:match("^%s*(.-)%s*$")
            local created, createError = request({
                type = "create_category",
                category = name,
            })
            if not created then
                notice("CREATE CATEGORY", createError)
            else
                notice("CREATE CATEGORY", "Created " .. created.category .. ".")
            end
        elseif selected == "next" then
            page = math.min(pageCount, page + 1)
        elseif selected == "previous" then
            page = math.max(1, page - 1)
        else
            return selected:match("^category:(.+)$")
        end
    end
end

local function inbox(category)
    local response, err = request({
        type = "list",
        category = category,
    })
    if not response then notice("INBOX", err); return "home" end
    if type(response.messages) ~= "table" then
        notice("INBOX", "Rift Mail returned an invalid inbox.")
        return "home"
    end

    local _, height = term.getSize()
    local page, pageSize = 1, math.max(1, math.floor((height - 9) / 2))
    while true do
        local startIndex = (page - 1) * pageSize + 1
        local endIndex = math.min(#response.messages, startIndex + pageSize - 1)

        drawHeader("RIFT MAIL", account.username)
        sectionTitle(4, category:upper() .. "  |  " .. #response.messages .. " MESSAGES")
        if #response.messages == 0 then
            writeAt(2, 6, "No messages in this folder.", colors.lightGray)
        else
            for index = startIndex, endIndex do
                local message = response.messages[index]
                local y = 5 + (index - startIndex) * 2
                local unreadMark = message.read and "" or "* "
                writeAt(2, y, string.format("%02d  %s%s | %s",
                    index - startIndex + 1, unreadMark, message.from, message.subject),
                    message.read and colors.white or themeAccent)
                writeAt(4, y + 1, message.read and "READ" or "UNREAD", colors.lightGray)
            end
        end
        local pageCount = math.max(1, math.ceil(#response.messages / pageSize))
        writeAt(2, height - 4, "PAGE " .. page .. " / " .. pageCount, themeAccent)
        local help = (page > 1 and "v prev|" or "")
            .. (endIndex < #response.messages and "n next|" or "")
            .. "i inbox|c compose|f folders|s sign out|q quit"
        local selected
        if mouseEnabled then
            local buttons = drawChoices(help)
            while true do
                local event, button, x, y = os.pullEvent()
                if event == "mouse_scroll" then
                    if button > 0 and endIndex < #response.messages then
                        selected = "n"
                    elseif button < 0 and page > 1 then
                        selected = "v"
                    end
                    if selected then break end
                elseif event == "key" and (button == keys.n or button == keys.v) then
                    if button == keys.n and endIndex < #response.messages then
                        selected = "n"
                    elseif button == keys.v and page > 1 then
                        selected = "v"
                    end
                    if selected then break end
                elseif event == "mouse_click" and button == 1 then
                    for _, choice in ipairs(buttons) do
                        if y == choice.row and x >= choice.left and x <= choice.right then
                            selected = choice.key
                            break
                        end
                    end
                    if selected then break end
                    if y >= 5 and y < height - 4 and #response.messages > 0 then
                        local visibleIndex = math.floor((y - 5) / 2) + 1
                        local messageIndex = startIndex + visibleIndex - 1
                        local message = response.messages[messageIndex]
                        if message then
                            selected = "message:" .. tostring(message.id)
                            break
                        end
                    end
                end
            end
        else
            writeAt(2, height - 2, help, colors.lightGray)
            writeAt(2, height - 1, "Message number or action: ", themeAccent)
            selected = read():lower()
            local choice = tonumber(selected)
            if choice then
                local message = response.messages[startIndex + choice - 1]
                if message and startIndex + choice - 1 <= endIndex then
                    selected = "message:" .. tostring(message.id)
                end
            end
        end
        if selected == "c" then return "compose" end
        if selected == "f" then return "folder", folders() end
        if selected == "i" then return "folder", "Inbox" end
        if selected == "s" then return "signout" end
        if selected == "q" then return "quit" end
        if selected == "v" or selected == "p" then page = math.max(1, page - 1) end
        if selected == "n" then page = math.min(pageCount, page + 1) end

        if type(selected) == "string" then
            local id = tonumber(selected:match("^message:(.+)$"))
            if id then
                local full, readError = request({
                    type = "read",
                    id = id,
                })
                if not full then
                    notice("MESSAGE", readError)
                elseif type(full.message) ~= "table" then
                    notice("MESSAGE", "Rift Mail returned an invalid message.")
                else
                    local item = full.message
                    local messageAction = displayMessage(item)
                    for _, inboxMessage in ipairs(response.messages) do
                        if inboxMessage.id == id then inboxMessage.read = true; break end
                    end
                    if messageAction == "delete" then
                        local confirmation = choose("DELETE MESSAGE",
                            "Delete this message permanently?",
                            {
                                { key = "yes", label = "Delete" },
                                { key = "no", label = "Cancel" },
                            })
                        if confirmation == "yes" then
                            local deleted, deleteError = request({
                                type = "delete",
                                id = id,
                            })
                            if not deleted then
                                notice("DELETE FAILED", deleteError)
                            else
                                for index, inboxMessage in ipairs(response.messages) do
                                    if inboxMessage.id == id then
                                        table.remove(response.messages, index)
                                        break
                                    end
                                end
                                page = math.max(1, math.ceil(#response.messages / pageSize))
                                notice("MESSAGE DELETED", "The email was permanently deleted.")
                            end
                        end
                    elseif messageAction == "move" then
                        local categories, categoryError = fetchCategories()
                        if not categories then
                            notice("MOVE MESSAGE", categoryError)
                        else
                            local destination = chooseFolder(categories, "MOVE MESSAGE")
                            if destination then
                                local moved, moveError = request({
                                    type = "move",
                                    id = id,
                                    category = destination,
                                })
                                if not moved then
                                    notice("MOVE MESSAGE", moveError)
                                else
                                    for index, inboxMessage in ipairs(response.messages) do
                                        if inboxMessage.id == id and destination ~= category then
                                            table.remove(response.messages, index)
                                            break
                                        end
                                    end
                                    page = math.max(1, math.ceil(#response.messages / pageSize))
                                    notice("MESSAGE MOVED", "Moved to " .. destination .. ".")
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function compose()
    local recipient = readField("Recipient Rift username:"):lower():match("^%s*(.-)%s*$")
    local subject = readField("Subject:")
    if #subject < 1 or #subject > 80 then
        notice("COMPOSE", "Subject must be 1 to 80 characters.")
        return
    end
    local bodyLines = {}
    local bodyLength = 0
    while bodyLength <= 2000 do
        local line = readField("Message body ('.' on a line sends):")
        if line == "." then break end
        bodyLength = bodyLength + #line + (#bodyLines > 0 and 1 or 0)
        if bodyLength <= 2000 then table.insert(bodyLines, line) end
    end
    local body = table.concat(bodyLines, "\n")
    if #body < 1 or #body > 2000 or bodyLength > 2000 then
        notice("COMPOSE", "Message body must be 1 to 2000 characters.")
        return
    end
    local response, err = request({
        type = "send",
        to = recipient,
        subject = subject,
        body = body,
    })
    if response then
        notice("COMPOSE", "Message sent to " .. recipient .. ".")
    else
        notice("COMPOSE", err)
    end
end

local function signIn()
    local username = readField("Rift username:")
    local password = readField("Password:", true)
    local signedIn, message = authenticateAccount(username, password)
    if not signedIn then notice("SIGN IN", message) end
    if signedIn and message then notice("ACCOUNT STORAGE", message) end
end

openModems()
local loadError
account, loadError = loadAccount()
if loadError then notice("ACCOUNT STORAGE", loadError) end

while true do
    if account then
        local signedIn, signInError = authenticateAccount(account.username, account.password)
        if not signedIn then
            account = nil
            notice("RIFT SIGN IN", signInError)
        end
    end
    if account then
        local action, selectedFolder = inbox(currentFolder)
        if action == "folder" then
            if selectedFolder then currentFolder = selectedFolder end
        elseif action == "home" then
            local homeAction = choose("RIFT MAIL", account.username, {
                { key = "inbox", label = "Inbox" },
                { key = "folders", label = "Folders" },
                { key = "compose", label = "Compose" },
                { key = "signout", label = "Sign out" },
                { key = "quit", label = "Quit" },
            })
            if homeAction == "inbox" then
                currentFolder = "Inbox"
            elseif homeAction == "folders" then
                currentFolder = folders() or "Inbox"
            elseif homeAction == "compose" then
                compose()
            elseif homeAction == "signout" then
                signOut()
            elseif homeAction == "quit" then
                return
            end
        elseif action == "compose" then
            compose()
        elseif action == "signout" then
            signOut()
        elseif action == "quit" then
            return
        end
    else
        local action = choose("RIFT MAIL", "Sign in with your Rift account", {
            { key = "login", label = "Sign in" },
            { key = "quit", label = "Quit" },
        })
        if action == "login" then
            signIn()
        elseif action == "quit" then
            return
        end
    end
end
