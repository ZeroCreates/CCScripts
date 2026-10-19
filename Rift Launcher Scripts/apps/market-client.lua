local PROTOCOL = "order_system_v1"
local SERVER_NAME = "rift-market"
local ACCOUNT_PROTOCOL = "rift_account_v1"
local ACCOUNT_SERVER_NAME = "rift-server"
local LEGACY_ACCOUNT_PROTOCOL = "rift_jobs_v1"
local LEGACY_ACCOUNT_SERVER_NAME = "rift-jobs"
local TIMEOUT = 5
local USERDATA_FILE = "market-userdata.json"
local USERDATA_FILE_STORED = "market/"..USERDATA_FILE
local RIFT_LOGIN_PATH = "rift/account.json"
local LEGACY_LOGIN_PATH = "rift-jobs/login.json"
local storageLoaded, storage = pcall(require, "storage")
if not storageLoaded or type(storage) ~= "table"
    or type(storage.read) ~= "function" or type(storage.write) ~= "function"
    or type(storage.delete) ~= "function" then
    storage = nil
end

local function readRiftAccount(path)
    local storageError
    if storage then
        local ok, account, err = pcall(storage.read, path)
        if ok and account ~= nil then return account end
        if not ok then
            storageError = tostring(account)
        else
            storageError = err
        end
    end
    local absolutePath = "/" .. path
    if fs.exists(absolutePath) then
        if fs.isDir(absolutePath) then return nil, "Saved Rift account path is a folder." end
        local file = fs.open(absolutePath, "r")
        if not file then return nil, "Could not open the saved Rift account at " .. absolutePath .. "." end
        local contents = file.readAll()
        file.close()
        local decoded, account = pcall(textutils.unserializeJSON, contents)
        if not decoded or type(account) ~= "table" then
            return nil, "Saved Rift account data at " .. absolutePath .. " is invalid."
        end
        return account
    end
    if storageError and storageError ~= "Stored data was not found." then
        return nil, "Launcher storage: " .. tostring(storageError)
            .. "; no root account file exists at " .. absolutePath .. "."
    end
    return nil, "Stored data was not found."
end

local function writeRiftAccount(path, account)
    local storageError
    if storage then
        local called, saved, err = pcall(storage.write, path, account)
        if called and saved then return true end
        storageError = called and tostring(err or "storage write failed") or tostring(saved)
    end
    local encoded, contents = pcall(textutils.serializeJSON, account)
    if not encoded or type(contents) ~= "string" then
        return false, "Rift account data could not be serialized."
    end
    local directory = "/" .. path:match("^(.*)/[^/]+$")
    if not fs.exists(directory) then
        local made, makeError = pcall(fs.makeDir, directory)
        if not made then
            return false, "Could not create Rift account folder: " .. tostring(makeError)
                .. (storageError and "; launcher storage also failed: " .. storageError or "")
        end
    elseif not fs.isDir(directory) then
        return false, "Rift account folder path is not a directory."
    end
    local file = fs.open("/" .. path, "w")
    if not file then
        return false, "Could not create the saved Rift account file."
            .. (storageError and " Launcher storage also failed: " .. storageError or "")
    end
    local written, writeError = pcall(file.write, contents)
    local closed, closeError = pcall(file.close)
    if not written or not closed then
        return false, "Could not write the saved Rift account: "
            .. tostring(not written and writeError or closeError)
            .. (storageError and "; launcher storage also failed: " .. storageError or "")
    end
    return true
end

local function deleteRiftAccount(path)
    local storageError
    if storage then
        local called, deleted, err = pcall(storage.delete, path)
        if not called or not deleted then
            storageError = called and err or deleted
            if called and err == "Stored data was not found." then storageError = nil end
        end
    end
    local absolutePath = "/" .. path
    if fs.exists(absolutePath) then
        if fs.isDir(absolutePath) then return false, "Saved Rift account path is a folder." end
        local deleted, deleteError = pcall(fs.delete, absolutePath)
        if not deleted then
            return false, "Could not delete saved Rift account: " .. tostring(deleteError)
                .. (storageError and "; launcher storage also failed: " .. tostring(storageError) or "")
        end
    end
    if storageError then
        return false, "Could not delete account from launcher storage: " .. tostring(storageError)
    end
    return true
end

local mouseEnabled = false
local userData = {}
local riftAccount = {}
local themes = {
    { accent = colors.cyan, highlight = colors.blue },
    { accent = colors.lime, highlight = colors.green },
    { accent = colors.orange, highlight = colors.red },
    { accent = colors.purple, highlight = colors.magenta },
    { accent = colors.cyan, highlight = colors.blue },
}

local function loadTheme()
    if type(launcherTheme) == "table"
        and type(launcherTheme.accent) == "number"
        and type(launcherTheme.highlight) == "number" then
        return term.isColor() and launcherTheme.accent or colors.gray,
            term.isColor() and launcherTheme.highlight or colors.gray
    end
    local themeIndex = type(launcherTheme) == "number" and launcherTheme or nil
    local saved
    if type(themeIndex) ~= "number" or not themes[themeIndex] or themeIndex == #themes then
        local path = "/.launcher/settings.json"
        if fs.exists(path) then
            local file = fs.open(path, "r")
            if file then
                local contents = file.readAll()
                file.close()
                local ok, parsed = pcall(textutils.unserializeJSON, contents)
                if ok and type(parsed) == "table"
                    and type(parsed.theme) == "number" and themes[parsed.theme] then
                    themeIndex = parsed.theme
                    saved = parsed
                end
            end
        end
    end
    if themeIndex == #themes and type(saved) == "table"
        and term.isColor() and type(term.setPaletteColor) == "function"
        and type(saved.customAccent) == "string" and saved.customAccent:match("^#?%x%x%x%x%x%x$")
        and type(saved.customHighlight) == "string" and saved.customHighlight:match("^#?%x%x%x%x%x%x$") then
        local function applyHex(slot, hex)
            hex = hex:gsub("^#", "")
            term.setPaletteColor(slot, tonumber(hex:sub(1, 2), 16) / 255,
                tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255)
        end
        applyHex(colors.cyan, saved.customAccent)
        applyHex(colors.blue, saved.customHighlight)
    end
    local theme = themes[themeIndex] or themes[1]
    return term.isColor() and theme.accent or colors.gray,
        term.isColor() and theme.highlight or colors.gray
end

local themeAccent, themeHighlight = loadTheme()

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
    writeAt(2, 2, subtitle, colors.lightGray)
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

    if #options == 0 then return {} end
    local columns = math.min(3, #options)
    local rows = math.ceil(#options / columns)
    local buttons = {}
    for index, option in ipairs(options) do
        local row = height - rows + math.floor((index - 1) / columns)
        local column = (index - 1) % columns
        local left = math.floor(column * width / columns) + 1
        local right = math.floor((column + 1) * width / columns)
        local label = ("[" .. option.label .. "]"):sub(1, right - left + 1)
        writeAt(left, row, label, colors.black, themeHighlight)
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
        if event == "mouse_click" and button == 1 then
            for _, choice in ipairs(buttons) do
                if y == choice.row and x >= choice.left and x <= choice.right then
                    return choice.key
                end
            end
        end
    end
end

local function showNotice(title, message)
    drawHeader(title, "ORDER DESK  /  SHARED PRODUCT CATALOG")
    writeAt(2, 5, message, colors.white)
    if mouseEnabled then
        readChoice("ok continue")
    else
        writeAt(2, 7, "Press Enter to continue.", colors.lightGray)
        read()
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
    if not found then error("Attach a modem before starting the ordering page.") end
    mouseEnabled = term.isColor()
end

local function loadUserData()
    if storage then
        local data, storageError = storage.read(USERDATA_FILE_STORED)
        if data == nil and (not storageError or storageError == "Stored data was not found.")
            and fs.exists(USERDATA_FILE) then
            local file = fs.open(USERDATA_FILE, "r")
            if not file then error("Could not open the legacy Market profile file.") end
            data = file.readAll()
            file.close()
        end
        if data ~= nil then
            local saved = data
            if type(data) == "string" then
                local ok
                ok, saved = pcall(textutils.unserializeJSON, data)
                if not ok then saved = nil end
            end
            if type(saved) ~= "table" then
                error("Saved Market profile data is invalid.")
            end
            userData = saved
        end
        if storageError and storageError ~= "Stored data was not found." then
            error("Could not load the saved Market profile from private storage: " .. storageError)
        end
    else
        if not fs.exists(USERDATA_FILE) then return end
        local file = fs.open(USERDATA_FILE, "r")
        if not file then return end
        local contents = file.readAll()
        file.close()
        local ok, saved = pcall(textutils.unserializeJSON, contents)
        if not ok or type(saved) ~= "table" then
            error("Saved Market profile data is invalid.")
        end
        userData = saved
    end
end

local function saveUserData()
    if storage then
        local saved, saveError = storage.write(USERDATA_FILE_STORED, userData)
        if not saved then
            return false, "Could not save account details to private storage: "
                .. tostring(saveError or "unknown storage error")
        end
        if fs.exists(USERDATA_FILE) then
            local ok, deleteError = pcall(fs.delete, USERDATA_FILE)
            if not ok then
                return false, "Account was saved to private storage, but the old profile copy could not be removed: "
                    .. tostring(deleteError)
            end
        end
        return true
    end
    
    local file = fs.open(USERDATA_FILE, "w")
    if not file then return false end
    file.write(textutils.serializeJSON(userData))
    file.close()
    return true
end
local function request(message)
    local serverId = rednet.lookup(PROTOCOL, SERVER_NAME)
    if not serverId then
        return nil, "Order server not found. Check that it is running and connected."
    end
    rednet.send(serverId, message, PROTOCOL)
    local _, response = rednet.receive(PROTOCOL, TIMEOUT)
    if type(response) ~= "table" then return nil, "No response from the order server." end
    if response.type == "error" then
        return nil, response.message or "The server rejected the request."
    end
    return response
end

local function readAccountField(label, hidden)
    drawHeader("RIFT ACCOUNT", label)
    local _, height = term.getSize()
    writeAt(2, height - 1, "> ", themeAccent)
    term.setCursorPos(4, height - 1)
    return read(hidden and "*" or nil)
end

local function authenticateAccount(username, password, action)
    local accountProtocol = ACCOUNT_PROTOCOL
    local serverId = rednet.lookup(accountProtocol, ACCOUNT_SERVER_NAME)
    if not serverId then
        accountProtocol = LEGACY_ACCOUNT_PROTOCOL
        serverId = rednet.lookup(accountProtocol, LEGACY_ACCOUNT_SERVER_NAME)
    end
    if not serverId then return false, "Rift account server not found. Check that it is running and connected." end
    rednet.send(serverId, {
        type = action,
        username = username,
        password = password,
    }, accountProtocol)
    local senderId, response = rednet.receive(accountProtocol, TIMEOUT, serverId)
    if senderId ~= serverId or type(response) ~= "table" then
        return false, "No response from the Rift account server."
    end
    if response.type == "error" then
        return false, response.message or "Rift account authentication failed."
    end
    if response.type ~= "authenticated" then
        return false, "Unexpected response from the Rift account server."
    end

    local account, accountError = readRiftAccount(RIFT_LOGIN_PATH)
    if account == nil and accountError and accountError ~= "Stored data was not found." then
        return true, "Signed in, but the saved Rift account could not be read: " .. tostring(accountError)
    end
    if type(account) ~= "table"
        or type(account.username) ~= "string"
        or account.username:lower() ~= response.username:lower() then
        account = {}
    end
    account.username = response.username
    account.password = password
    riftAccount = account
    local saved, saveError = writeRiftAccount(RIFT_LOGIN_PATH, account)
    if not saved then
        return true, "Signed in as " .. response.username
            .. ", but the login could not be saved: " .. tostring(saveError or "unknown storage error")
    end
    local deleted, deleteError = deleteRiftAccount(LEGACY_LOGIN_PATH)
    if not deleted and deleteError ~= "Stored data was not found." then
        return true, "Signed in as " .. response.username
            .. ", but the legacy account entry could not be removed: " .. tostring(deleteError)
    end
    return true, "Signed in as " .. response.username .. "."
end

local function signOutRiftAccount()
    local accountProtocol = ACCOUNT_PROTOCOL
    local serverId = rednet.lookup(accountProtocol, ACCOUNT_SERVER_NAME)
    if not serverId then
        accountProtocol = LEGACY_ACCOUNT_PROTOCOL
        serverId = rednet.lookup(accountProtocol, LEGACY_ACCOUNT_SERVER_NAME)
    end
    if not serverId then
        return false, "Rift account server not found; saved credentials were not cleared."
    end
    rednet.send(serverId, { type = "logout" }, accountProtocol)
    local senderId, response = rednet.receive(accountProtocol, TIMEOUT, serverId)
    if senderId ~= serverId or type(response) ~= "table" or response.type ~= "logged_out" then
        return false, "No confirmation from the Rift account server; saved credentials were not cleared."
    end
    for _, path in ipairs({ RIFT_LOGIN_PATH, LEGACY_LOGIN_PATH }) do
        local deleted, deleteError = deleteRiftAccount(path)
        if not deleted and deleteError ~= "Stored data was not found." then
            return false, "Signed out of the Rift account, but could not clear saved credentials: "
                .. tostring(deleteError)
        end
    end
    riftAccount = {}
    return true
end

local function authenticateRiftAccount()
    local savedLoginError
    local login, storageError = readRiftAccount(RIFT_LOGIN_PATH)
    if login == nil and storageError == "Stored data was not found." then
        login, storageError = readRiftAccount(LEGACY_LOGIN_PATH)
        if login ~= nil then
            local saved, saveError = writeRiftAccount(RIFT_LOGIN_PATH, login)
            if not saved then
                savedLoginError = "Could not migrate the saved Rift account: " .. tostring(saveError)
            else
                local deleted, deleteError = deleteRiftAccount(LEGACY_LOGIN_PATH)
                if not deleted and deleteError ~= "Stored data was not found." then
                    savedLoginError = "Rift account was migrated, but the legacy account entry could not be removed: "
                        .. tostring(deleteError)
                end
            end
        end
    end
    if login ~= nil then
        if type(login) ~= "table" or type(login.username) ~= "string"
            or type(login.password) ~= "string" then
            savedLoginError = "Saved Rift account data is invalid."
        else
            riftAccount = login
            local authenticated, authError = authenticateAccount(login.username, login.password, "login")
            if authenticated then return true end
            savedLoginError = "Saved Rift account sign-in failed: " .. authError
        end
    elseif storageError and storageError ~= "Stored data was not found." then
        savedLoginError = "Could not read the saved Rift account: " .. tostring(storageError)
    end

    while true do
        drawHeader("RIFT", "RIFT MARKET  /  SIGN IN WITH YOUR RIFT ACCOUNT")
        if savedLoginError then writeAt(2, 4, savedLoginError, colors.yellow) end
        local choice = readChoice("s sign in|c create account|q quit")
        if choice == "q" then return false, "Sign-in cancelled." end

        local username = readAccountField("Username")
        local password = readAccountField("Password", true)
        local action = choice == "c" and "register" or "login"
        if action == "register" then
            local confirmation = readAccountField("Confirm password", true)
            if password ~= confirmation then
                showNotice("ACCOUNT NOT CREATED", "The passwords do not match.")
            else
                local authenticated, authMessage = authenticateAccount(username, password, action)
                if authenticated then return true, authMessage end
                showNotice("ACCOUNT NOT CREATED", authMessage)
            end
        else
            local authenticated, authMessage = authenticateAccount(username, password, action)
            if authenticated then return true, authMessage end
            showNotice("SIGN IN FAILED", authMessage)
        end
    end
end

local function saveDeliveryAddresses(addresses)
    local account, readError = readRiftAccount(RIFT_LOGIN_PATH)
    if account == nil and readError and readError ~= "Stored data was not found." then
        return false, "Could not read the saved Rift account: " .. tostring(readError)
    end
    if type(account) ~= "table" or type(account.username) ~= "string"
        or account.username:lower() ~= tostring(riftAccount.username or ""):lower()
        or type(account.password) ~= "string" then
        if readError ~= "Stored data was not found." then
            return false, "The saved Rift account does not match the signed-in account."
        end
        account = {}
        for key, value in pairs(riftAccount) do account[key] = value end
    end
    account.deliveryAddresses = addresses
    local saved, saveError = writeRiftAccount(RIFT_LOGIN_PATH, account)
    if not saved then
        return false, tostring(saveError or "Could not save Rift account addresses.")
    end
    local savedAccount, verifyError = readRiftAccount(RIFT_LOGIN_PATH)
    if type(savedAccount) ~= "table" or type(savedAccount.deliveryAddresses) ~= "table"
        or type(savedAccount.username) ~= "string"
        or savedAccount.username:lower() ~= account.username:lower()
        or #savedAccount.deliveryAddresses ~= #addresses then
        return false, "The saved Rift account addresses could not be verified."
            .. (verifyError and " " .. tostring(verifyError) or "")
    end
    for index, address in ipairs(addresses) do
        if savedAccount.deliveryAddresses[index] ~= address then
            return false, "The saved Rift account addresses did not match the address list."
        end
    end
    riftAccount = savedAccount
    return true
end

local function chooseDeliveryAddress()
    local addresses = {}
    if type(riftAccount.deliveryAddresses) == "table" then
        for _, address in ipairs(riftAccount.deliveryAddresses) do
            if type(address) == "string" and #address <= 100
                and not address:find("%c") and address ~= "" then
                table.insert(addresses, address)
            end
        end
    end

    local legacyAddress = type(userData.deliveryAddress) == "string"
        and userData.deliveryAddress:match("^%s*(.-)%s*$") or ""
    if legacyAddress ~= "" then
        local found = false
        for _, address in ipairs(addresses) do
            if address == legacyAddress then found = true break end
        end
        if not found then
            local migratedAddresses = {}
            for _, address in ipairs(addresses) do
                table.insert(migratedAddresses, address)
            end
            table.insert(migratedAddresses, legacyAddress)
            local saved, saveError = saveDeliveryAddresses(migratedAddresses)
            if not saved then
                return nil, "Could not migrate your saved delivery address: " .. saveError
            end
            addresses = migratedAddresses
        end
        userData.deliveryAddress = nil
        local cleared, clearError = saveUserData()
        if not cleared then
            showNotice("ADDRESS MIGRATED", "The delivery address is saved in your Rift account, but the old profile copy remains: "
                .. tostring(clearError))
        end
    end

    while true do
        drawHeader("RIFT ACCOUNT", "CHOOSE A DELIVERY ADDRESS")
        local options = {}
        if #addresses == 0 then
            writeAt(2, 5, "No saved delivery addresses yet.", colors.lightGray)
        else
            for index, address in ipairs(addresses) do
                writeAt(2, 3 + index, tostring(index) .. ". " .. address, colors.yellow)
                table.insert(options, tostring(index) .. " address " .. tostring(index))
            end
        end
        table.insert(options, "a add address")
        table.insert(options, "q cancel")
        local choice = readChoice(table.concat(options, "|"))
        if choice == "q" then return nil, "Address selection cancelled." end
        if choice == "a" then
            drawHeader("RIFT ACCOUNT", "ADD A DELIVERY ADDRESS")
            writeAt(2, 5, "Up to 100 characters.", colors.lightGray)
            term.setCursorPos(2, 7)
            write("Address: ")
            local address = read():match("^%s*(.-)%s*$")
            if #address < 1 or #address > 100 or address:find("%c") then
                showNotice("INVALID ADDRESS", "Enter a non-empty address up to 100 characters.")
            else
                local duplicate = false
                for _, savedAddress in ipairs(addresses) do
                    if savedAddress == address then duplicate = true break end
                end
                local updatedAddresses = {}
                for _, savedAddress in ipairs(addresses) do
                    table.insert(updatedAddresses, savedAddress)
                end
                if not duplicate then table.insert(updatedAddresses, address) end
                local saved, saveError = saveDeliveryAddresses(updatedAddresses)
                if not saved then
                    showNotice("ADDRESS NOT SAVED", saveError)
                else
                    addresses = updatedAddresses
                    return address
                end
            end
        else
            local index = tonumber(choice)
            if index and addresses[index] then return addresses[index] end
        end
    end
end

local function money(cents)
    return string.format("$%.2f", cents / 100)
end

local function appendReceiptText(lines, text, width)
    text = tostring(text)
    for start = 1, #text, width do
        table.insert(lines, text:sub(start, start + width - 1))
    end
end

local function printOrderReceipt(order)
    local printer = peripheral.find("printer")
    if not printer then return nil end

    local ok, err = pcall(function()
        if printer.getPaperLevel() < 1 then error("The printer needs paper.") end
        if printer.getInkLevel() < 1 then error("The printer needs ink.") end
        if not printer.newPage() then error("The printer could not start a page; check paper and ink.") end

        local width, height = printer.getPageSize()
        local lines = {
            "ORDER RECEIPT #" .. order.id,
            "PAYMENT REF: " .. (order.reference or string.format("ORD-%06d", order.id)),
            "STATUS: " .. order.status:upper(),
            "PROVIDER PAYMENT ADDRESS",
        }
        appendReceiptText(lines, order.providerAddress or "NOT REGISTERED", width)
        table.insert(lines, "")
        table.insert(lines, "DELIVERY ADDRESS")
        appendReceiptText(lines, order.deliveryAddress or "ADDRESS NOT SAVED", width)
        table.insert(lines, "")
        table.insert(lines, "ITEMS")
        for _, item in ipairs(order.items) do
            appendReceiptText(lines, item.quantity .. " x " .. item.name
                .. "  " .. money(item.lineTotal), width)
        end
        table.insert(lines, "")
        appendReceiptText(lines, "TOTAL: " .. money(order.total), width)

        local lineIndex = 1
        while lineIndex <= #lines do
            printer.setPageTitle("Order " .. (order.reference or order.id))
            for row = 1, height do
                if lineIndex > #lines then break end
                printer.setCursorPos(1, row)
                printer.write(lines[lineIndex]:sub(1, width))
                lineIndex = lineIndex + 1
            end
            if not printer.endPage() then error("The printer could not finish the receipt page.") end
            if lineIndex <= #lines and not printer.newPage() then
                error("The printer could not start another page; check paper and ink.")
            end
        end
    end)
    return ok, err
end

local function fetchCatalog()
    local response, err = request({ type = "get_catalog" })
    if not response then return nil, err end
    return response.products or {}
end

local function findProduct(products, productId)
    for _, product in ipairs(products) do
        if product.id == productId then return product end
    end
end

local function cartCount(cart)
    local count = 0
    for _, quantity in pairs(cart) do count = count + quantity end
    return count
end

local function renderCatalog(products, cart, errorMessage, page)
    local visibleProducts = {}
    drawHeader("RIFT MARKET", "CLICK TO ADD  /  N/V OR WHEEL TO BROWSE")
    sectionTitle(4, "AVAILABLE PRODUCTS  |  " .. #products)
    if errorMessage then
        writeAt(2, 6, errorMessage, colors.red)
    elseif #products == 0 then
        writeAt(2, 6, "No products are listed yet.", colors.lightGray)
        writeAt(2, 7, "Check back after a provider publishes a product.", colors.lightGray)
    else
        local width, height = term.getSize()
        local perPage = math.max(1, math.floor((height - 8) / 2))
        local pageCount = math.max(1, math.ceil(#products / perPage))
        page = math.max(1, math.min(page, pageCount))
        local first = (page - 1) * perPage + 1
        local last = math.min(#products, first + perPage - 1)
        for index = first, last do
            local product = products[index]
            local y = 5 + (index - first) * 2
            table.insert(visibleProducts, { product = product, firstRow = y })
            writeAt(2, y, product.name:sub(1, math.max(1, width - 14)), colors.white)
            writeAt(width - 9, y, money(product.price), colors.lime)
            local providerName = product.providerUser or product.providerName or "Provider"
            writeAt(4, y + 1, "By " .. providerName .. "  |  IN CART: "
                .. (cart[product.id] or 0), colors.lightGray)
        end
        writeAt(2, height - 3, "PAGE " .. page .. " / " .. pageCount, colors.yellow)
    end

    local help = "c cart " .. cartCount(cart)
        .. "|o my orders|s track|x sign out|r refresh|q quit"
    if not mouseEnabled then
        help = help .. "|n next|v previous"
    end
    if not mouseEnabled then return readChoice(help), page end

    local buttons = drawChoices(help)
    while true do
        local event, button, x, y = os.pullEvent()
        if event == "key" and (button == keys.n or button == keys.v) then
            return button == keys.n and "n" or "v", page
        elseif event == "mouse_click" and button == 1 then
            for _, choice in ipairs(buttons) do
                if y == choice.row and x >= choice.left and x <= choice.right then
                    return choice.key, page
                end
            end
            for _, entry in ipairs(visibleProducts) do
                if y >= entry.firstRow and y <= entry.firstRow + 1 then
                    return "product", page, entry.product
                end
            end
        elseif event == "mouse_scroll" and button > 0 then
            return "n", page
        elseif event == "mouse_scroll" then
            return "v", page
        end
    end
end

local addSelectedProduct

addSelectedProduct = function(products, product, cart)
    for existingId in pairs(cart) do
        local existingProduct = findProduct(products, existingId)
        if existingProduct and existingProduct.providerId ~= product.providerId then
            showNotice("ONE PROVIDER PER ORDER", "Place separate orders for different providers.")
            return
        end
    end
    drawHeader("ADD TO CART", product.name .. "  /  " .. money(product.price))
    term.setCursorPos(2, 6)
    write("Quantity (1-99): ")
    local quantity = tonumber(read())
    local newQuantity = quantity and ((cart[product.id] or 0) + quantity)
    if not quantity or quantity % 1 ~= 0 or quantity < 1 or newQuantity > 99 then
        showNotice("INVALID QUANTITY", "Choose a whole-number quantity; each product is capped at 99.")
        return
    end
    cart[product.id] = newQuantity
    showNotice("ADDED TO CART", quantity .. "x " .. product.name .. " added.")
end

local function cartPage(products, cart)
    drawHeader("YOUR CART", "REVIEW ITEMS  /  SERVER PRICES ARE FINAL")
    sectionTitle(4, "ITEMS  |  " .. cartCount(cart))
    local width, height = term.getSize()
    local entries, total, visibleEntries = {}, 0, {}
    for productId, quantity in pairs(cart) do
        table.insert(entries, { id = productId, quantity = quantity })
    end
    table.sort(entries, function(a, b) return a.id < b.id end)
    local visible = math.min(#entries, math.max(0, height - 10))
    if #entries > 0 then
        writeAt(2, 5, "Click an item to remove it.", colors.lightGray)
    end
    for index, entry in ipairs(entries) do
        local product = findProduct(products, entry.id)
        if product then total = total + entry.quantity * product.price end
        if index <= visible then
            local y = 5 + index
            if product then
                writeAt(2, y, entry.quantity .. "x " .. product.name, colors.white)
                writeAt(width - 9, y, money(entry.quantity * product.price), colors.lime)
            else
                writeAt(2, y, "Unavailable item", colors.red)
            end
            table.insert(visibleEntries, { id = entry.id, row = y })
        end
    end
    if #entries == 0 then
        writeAt(2, 6, "Your cart is empty.", colors.lightGray)
    else
        writeAt(2, height - 4, "ESTIMATE  " .. money(total), colors.white, themeHighlight)
        if visible < #entries then
            writeAt(2, height - 3, "Some items are below the visible area.", colors.yellow)
        end
    end
    local buttons = drawChoices("p place order|b back")
    while true do
        local event, button, x, y = os.pullEvent()
        if event == "mouse_click" and button == 1 then
            for _, choice in ipairs(buttons) do
                if y == choice.row and x >= choice.left and x <= choice.right then
                    return choice.key
                end
            end
            for _, entry in ipairs(visibleEntries) do
                if y == entry.row then return "remove", entry.id end
            end
        end
    end
end

local function showOrder(order)
    drawHeader("ORDER #" .. order.id, "STATUS  /  " .. order.status:upper())
    sectionTitle(4, "ORDER SUMMARY")
    local width, height = term.getSize()
    writeAt(2, 5, "MAIL PAYMENT WITH REFERENCE: "
        .. (order.reference or string.format("ORD-%06d", order.id)), themeAccent)
    local providerAddress = order.providerAddress or "Not registered"
    local providerLabel = "PAY PROVIDER: "
    local addressWidth = math.max(1, width - #providerLabel - 2)
    writeAt(2, 6, providerLabel .. providerAddress:sub(1, addressWidth), colors.lime)
    local row = 7
    for start = addressWidth + 1, #providerAddress, math.max(1, width - 2) do
        writeAt(2, row, providerAddress:sub(start, start + width - 3), colors.lime)
        row = row + 1
    end
    writeAt(2, row, "DELIVER TO  " .. (order.deliveryAddress or "Address not provided"), colors.yellow)
    row = row + 1
    local visible = math.min(#order.items, math.max(0, math.floor((height - 4 - row) / 2)))
    for index = 1, visible do
        local item = order.items[index]
        local y = row + (index - 1) * 2
        writeAt(2, y, item.quantity .. "x " .. item.name, colors.white)
        writeAt(2, y + 1, item.providerName or "Provider", colors.lightGray)
        writeAt(width - 9, y, money(item.lineTotal), colors.lime)
    end
    if visible < #order.items then
        writeAt(2, height - 3, "See the printed receipt for remaining items.", colors.yellow)
    end
    writeAt(2, height - 4, "TOTAL  " .. money(order.total), colors.white, themeHighlight)
    if mouseEnabled then
        readChoice("b back")
    else
        writeAt(2, height - 1, "Press Enter to return.", colors.lightGray)
        read()
    end
end

local function placeOrder(cart)
    local items = {}
    for productId, quantity in pairs(cart) do
        table.insert(items, { productId = productId, quantity = quantity })
    end
    if #items == 0 then
        showNotice("CART IS EMPTY", "Add a product before placing an order.")
        return
    end
    local deliveryAddress, addressError = chooseDeliveryAddress()
    if not deliveryAddress then
        if addressError ~= "Address selection cancelled." then
            showNotice("DELIVERY ADDRESS UNAVAILABLE", addressError)
        end
        return
    end
    drawHeader("ORDER REVIEW", "CONFIRM THE DELIVERY ADDRESS BEFORE PLACING")
    sectionTitle(4, "DELIVER TO")
    local width, height = term.getSize()
    local lineWidth = math.max(1, width - 3)
    local row = 6
    for start = 1, #deliveryAddress, lineWidth do
        writeAt(2, row, deliveryAddress:sub(start, start + lineWidth - 1), colors.yellow)
        row = row + 1
    end
    writeAt(2, math.min(row + 1, height - 5), "Items in order: " .. #items, colors.lightGray)
    local confirmed
    if mouseEnabled then
        writeAt(2, height - 4, "Confirm order?", colors.lime)
        confirmed = readChoice("y yes|n no") == "y"
    else
        writeAt(2, height - 4, "Place this order? [y/N]", colors.lime)
        term.setCursorPos(2, height - 3)
        confirmed = read():lower() == "y"
    end
    if not confirmed then return end

    local response, err = request({
        type = "place_order",
        items = items,
        deliveryAddress = deliveryAddress,
    })
    if not response then
        showNotice("ORDER NOT PLACED", err)
        return
    end
    for productId in pairs(cart) do cart[productId] = nil end
    if not response.order or response.order.deliveryAddress ~= deliveryAddress then
        local orderId = response.order and response.order.id or "unknown"
        showNotice("SERVER NEEDS UPDATE", "Order #" .. orderId
            .. " was accepted, but the server did not save its address. Update and restart rift-server.lua.")
        return
    end
    local printed, printError = printOrderReceipt(response.order)
    if printed == false then
        showNotice("ORDER SAVED, PRINT FAILED", tostring(printError))
    end
    showOrder(response.order)
end

local function checkStatus()
    drawHeader("TRACK AN ORDER", "ENTER THE ORDER NUMBER FROM CHECKOUT")
    term.setCursorPos(2, 6)
    write("Order number: ")
    local orderId = tonumber(read())
    if not orderId or orderId % 1 ~= 0 or orderId < 1 then
        showNotice("INVALID ORDER", "Enter a valid order number.")
        return
    end
    local response, err = request({ type = "get_order", orderId = orderId })
    if not response then
        showNotice("ORDER NOT FOUND", err)
        return
    end
    showOrder(response.order)
    if response.order.status ~= "preparing" then return end

    drawHeader("ORDER COMPLETION", "ONLY CONFIRM AFTER THE ORDER IS RECEIVED")
    writeAt(2, 5, "Order " .. (response.order.reference or response.order.id)
        .. " is being prepared.", colors.lightGray)
    local confirmCompletion
    if mouseEnabled then
        confirmCompletion = readChoice("y complete|n not yet") == "y"
    else
        writeAt(2, 7, "Mark this order completed? [y/N]", colors.lime)
        term.setCursorPos(2, 9)
        confirmCompletion = read():lower() == "y"
    end
    if not confirmCompletion then return end

    local completed, completionError = request({ type = "complete_order", orderId = orderId })
    if not completed then
        showNotice("ORDER NOT COMPLETED", completionError)
        return
    end
    showOrder(completed.order)
end

local function showMyOrders()
    local response, err = request({ type = "my_orders" })
    if not response then
        showNotice("ORDER HISTORY UNAVAILABLE", err)
        return
    end

    local orders = response.orders or {}
    if #orders == 0 then
        showNotice("NO ORDERS YET", "Orders placed with this Rift account will appear here.")
        return
    end

    local page, selectedIndex = 1, 1
    local orderPerPage
    local selectedOrder
    while not selectedOrder do
        drawHeader("MY ORDERS", "CLICK AN ORDER TO VIEW DETAILS")
        local width, height = term.getSize()
        orderPerPage = math.max(1, height - 8)
        local pageCount = math.max(1, math.ceil(#orders / orderPerPage))
        page = math.max(1, math.min(page, pageCount))
        local first = (page - 1) * orderPerPage + 1
        local last = math.min(#orders, first + orderPerPage - 1)
        selectedIndex = math.max(first, math.min(selectedIndex, last))
        local visibleOrders = {}
        for index = first, last do
            local order = orders[index]
            local y = 5 + index - first
            local selected = index == selectedIndex
            writeAt(2, y, "#" .. order.id .. "  " .. (order.reference or "ORDER")
                .. "  " .. tostring(order.status):upper(),
                selected and colors.white or colors.yellow,
                selected and themeHighlight or colors.black)
            writeAt(width - 10, y, money(order.total), colors.lime,
                selected and themeHighlight or colors.black)
            table.insert(visibleOrders, { index = index, row = y })
        end
        writeAt(2, height - 2, "PAGE " .. page .. " / " .. pageCount
            .. "  |  CLICK AN ORDER OR USE ARROWS + ENTER", colors.lightGray)
        local buttons = drawChoices("b back|v previous|n next")
        local event, key, x, y = os.pullEvent()
        if event == "mouse_click" and key == 1 then
            for _, entry in ipairs(visibleOrders) do
                if y == entry.row then
                    selectedOrder = orders[entry.index]
                    break
                end
            end
            if not selectedOrder then
                for _, choice in ipairs(buttons) do
                    if y == choice.row and x >= choice.left and x <= choice.right then
                        if choice.key == "b" then return end
                        if choice.key == "v" then
                            page = math.max(1, page - 1)
                            selectedIndex = (page - 1) * orderPerPage + 1
                        elseif choice.key == "n" then
                            page = math.min(pageCount, page + 1)
                            selectedIndex = (page - 1) * orderPerPage + 1
                        end
                    end
                end
            end
        elseif event == "key" then
            if key == keys.q or key == keys.backspace then return end
            if key == keys.up then
                selectedIndex = math.max(1, selectedIndex - 1)
                page = math.floor((selectedIndex - 1) / orderPerPage) + 1
            elseif key == keys.down then
                selectedIndex = math.min(#orders, selectedIndex + 1)
                page = math.floor((selectedIndex - 1) / orderPerPage) + 1
            elseif key == keys.enter then
                selectedOrder = orders[selectedIndex]
            elseif key == keys.v then
                page = math.max(1, page - 1)
                selectedIndex = (page - 1) * orderPerPage + 1
            elseif key == keys.n then
                page = math.min(pageCount, page + 1)
                selectedIndex = (page - 1) * orderPerPage + 1
            end
        elseif event == "mouse_scroll" then
            if key > 0 then
                page = math.min(pageCount, page + 1)
            else
                page = math.max(1, page - 1)
            end
            selectedIndex = (page - 1) * orderPerPage + 1
        end
    end

    local selected, orderError = request({ type = "get_order", orderId = selectedOrder.id })
    if not selected then
        showNotice("ORDER UNAVAILABLE", orderError)
        return
    end
    showOrder(selected.order)
end

openModems()
local authenticated, authenticationError = authenticateRiftAccount()
if not authenticated then
    if authenticationError ~= "Sign-in cancelled." then
        showNotice("RIFT ACCOUNT SIGN IN", authenticationError)
    end
    return
elseif authenticationError then
    showNotice("RIFT ACCOUNT SIGN IN", authenticationError)
end
loadUserData()
local cart = {}
local page = 1
while true do
    local products, err = fetchCatalog()
    local choice, shownPage, selectedProduct = renderCatalog(products or {}, cart, err, page)
    page = shownPage or page
    if choice == "product" then
        if products and selectedProduct then addSelectedProduct(products, selectedProduct, cart) end
    elseif choice == "c" then
        local cartChoice, productId = cartPage(products or {}, cart)
        if cartChoice == "p" then
            placeOrder(cart)
        elseif cartChoice == "remove" then
            cart[productId] = nil
        end
    elseif choice == "s" then
        checkStatus()
    elseif choice == "o" then
        showMyOrders()
    elseif choice == "x" then
        local signedOut, signOutError = signOutRiftAccount()
        showNotice(signedOut and "SIGNED OUT" or "SIGN OUT FAILED",
            signedOut and "You have been signed out of your Rift account." or signOutError)
        if signedOut then break end
    elseif choice == "n" then
        page = page + 1
    elseif choice == "v" then
        page = math.max(1, page - 1)
    elseif choice == "r" then
        page = 1
    elseif choice == "q" then
        break
    end
end
