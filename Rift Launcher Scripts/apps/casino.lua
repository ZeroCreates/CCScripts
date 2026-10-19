local HOST_BASE_URL = "https://rift.zerocreates.org/"
local CASINO_PROTOCOL = "rift_casino_wallet_v1"
local CASINO_SERVER = "rift-casino"
local ACCOUNT_PROTOCOL = "rift_account_v1"
local ACCOUNT_SERVER = "rift-server"
local LEGACY_ACCOUNT_PROTOCOL = "rift_jobs_v1"
local LEGACY_ACCOUNT_SERVER = "rift-jobs"
local TIMEOUT = 5
local transactionSequence = 0
local RIFT_ACCOUNT_PATH = "rift/account.json"
local LEGACY_ACCOUNT_PATH = "rift-jobs/login.json"
local storageLoaded, storage = pcall(require, "storage")
if not storageLoaded or type(storage) ~= "table"
    or type(storage.read) ~= "function" or type(storage.write) ~= "function" then
    storage = nil
end
local games = {
    { name = "Blackjack", file = "blackjack.lua", source = "computercraft/apps/blackjack.lua", argument = "blackjack" },
    { name = "Texas Hold'em", file = "texas-holdem.lua", source = "computercraft/apps/texas-holdem.lua", argument = "holdem" },
}
local GAMES_DIRECTORY = "/games"
local balance
local account
local statusMessage = ""
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

local function writeAt(x, y, text, foreground, background)
    local width, height = term.getSize()
    if y < 1 or y > height or x > width then return end
    term.setCursorPos(x, y)
    term.setTextColor(foreground or colors.white)
    term.setBackgroundColor(background or colors.black)
    term.write(tostring(text):sub(1, width - x + 1))
    term.setBackgroundColor(colors.black)
end

local function drawHeader(subtitle)
    local width = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    writeAt(1, 1, string.rep(" ", width), colors.white, themeAccent)
    writeAt(2, 1, "RIFT CASINO  /  RIFT ACCOUNT WALLET", colors.white, themeAccent)
    writeAt(2, 2, subtitle, colors.lightGray)
    writeAt(1, 3, string.rep("=", width), themeHighlight)
end

local function drawButtons(options)
    local width, height = term.getSize()
    local columns = math.min(3, #options)
    local rowCount = math.ceil(#options / columns)
    local buttons = {}
    for index, option in ipairs(options) do
        local column = (index - 1) % columns
        local row = height - rowCount + math.floor((index - 1) / columns) + 1
        local left = math.floor(column * width / columns) + 1
        local right = math.floor((column + 1) * width / columns)
        local label = ("[ " .. option.label .. " ]"):sub(1, right - left + 1)
        writeAt(left, row, string.rep(" ", right - left + 1), colors.black, themeHighlight)
        writeAt(left, row, label, colors.black, themeHighlight)
        table.insert(buttons, { id = option.id, key = option.key, row = row, left = left, right = right })
    end
    return buttons
end

local function waitForAction(buttons)
    while true do
        local event, value, x, y = os.pullEvent()
        if event == "mouse_click" and value == 1 then
            for _, choice in ipairs(buttons) do
                if y == choice.row and x >= choice.left and x <= choice.right then return choice.id end
            end
        elseif event == "key" then
            for _, choice in ipairs(buttons) do
                if choice.key == value then return choice.id end
            end
        end
    end
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
        if storageError then
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
    local ok, contents = pcall(textutils.serializeJSON, data)
    if not ok or type(contents) ~= "string" then
        return false, "Rift account data could not be serialized."
    end
    if not fs.exists("/rift") then fs.makeDir("/rift") end
    if not fs.isDir("/rift") then return false, "The /rift account path is not a directory." end
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
    local saved, err = readSavedAccount(RIFT_ACCOUNT_PATH)
    if saved then return type(saved.password) == "string" and saved or nil end
    if err then return nil, err end
    saved, err = readSavedAccount(LEGACY_ACCOUNT_PATH)
    if saved and type(saved.password) == "string" then
        local written, writeError = saveAccount(saved)
        if not written then statusMessage = writeError end
        return saved
    end
    return nil, err
end

local function authenticateAccount(username, password, action)
    local accountProtocol = ACCOUNT_PROTOCOL
    local serverId = rednet.lookup(accountProtocol, ACCOUNT_SERVER)
    if not serverId then
        accountProtocol = LEGACY_ACCOUNT_PROTOCOL
        serverId = rednet.lookup(accountProtocol, LEGACY_ACCOUNT_SERVER)
    end
    if not serverId then
        return false, "Rift account server not found. Check that Rift Server is running."
    end
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
        return false, response.message or "Rift account sign-in failed."
    end
    if response.type ~= "authenticated" or type(response.username) ~= "string" then
        return false, "Unexpected response from the Rift account server."
    end
    local savedAccount = account
    if type(savedAccount) ~= "table" or type(savedAccount.username) ~= "string"
        or savedAccount.username:lower() ~= response.username:lower() then
        local stored = readSavedAccount(RIFT_ACCOUNT_PATH)
        savedAccount = type(stored) == "table"
            and stored.username:lower() == response.username:lower() and stored or {}
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
    local serverId = rednet.lookup(accountProtocol, ACCOUNT_SERVER)
    if not serverId then
        accountProtocol = LEGACY_ACCOUNT_PROTOCOL
        serverId = rednet.lookup(accountProtocol, LEGACY_ACCOUNT_SERVER)
    end
    if not serverId then
        statusMessage = "Rift account server not found; could not sign out."
        return false
    end
    rednet.send(serverId, { type = "logout" }, accountProtocol)
    local senderId, response = rednet.receive(accountProtocol, TIMEOUT, serverId)
    if senderId ~= serverId or type(response) ~= "table" or response.type ~= "logged_out" then
        statusMessage = "No confirmation from the Rift account server."
        return false
    end
    account.password = nil
    local saved, saveError = saveAccount(account)
    account = nil
    balance = nil
    if not saved then
        statusMessage = "Signed out, but saved credentials could not be cleared: " .. tostring(saveError)
    end
    return true
end

local function nextRequestId()
    transactionSequence = transactionSequence + 1
    return os.getComputerID() .. "-" .. os.epoch("utc") .. "-casino-" .. transactionSequence
end

local function serverRequest(message)
    local serverId = rednet.lookup(CASINO_PROTOCOL, CASINO_SERVER)
    if not serverId then return nil, "Rift Casino is offline. Start the combined Rift Server." end
    message.requestId = message.requestId or nextRequestId()
    for _ = 1, 2 do
        rednet.send(serverId, message, CASINO_PROTOCOL)
        local _, response = rednet.receive(CASINO_PROTOCOL, TIMEOUT, serverId)
        if type(response) == "table"
            and (response.requestId == nil or response.requestId == message.requestId) then
            if response.type == "error" then
                return nil, response.message or "Casino server rejected the request."
            end
            return response
        end
    end
    return nil, "No matching response from the Casino server."
end

local walletApi = {}
function walletApi.getBalance()
    return serverRequest({ type = "balance" })
end
function walletApi.transact(action, amount, requestId)
    return serverRequest({ type = action, amount = amount, requestId = requestId })
end

local function openModems()
    local found = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            found = true
        end
    end
    return found
end

local function readAccountField(label, hidden)
    drawHeader("RIFT ACCOUNT  /  " .. label)
    local _, height = term.getSize()
    writeAt(2, height - 2, "> ", themeAccent)
    term.setCursorPos(4, height - 2)
    return read(hidden and "*" or nil)
end

local function signIn(action)
    local username = readAccountField("USERNAME")
    local password = readAccountField("PASSWORD", true)
    if action == "register" then
        local confirmation = readAccountField("CONFIRM PASSWORD", true)
        if password ~= confirmation then
            statusMessage = "The passwords do not match."
            return false
        end
    end
    local authenticated, message = authenticateAccount(username, password, action)
    if not authenticated then
        statusMessage = tostring(message)
        return false
    end
    statusMessage = message or ("Signed in as " .. account.username .. ".")
    return true
end

local function requireSignIn()
    if account then
        local authenticated, message = authenticateAccount(
            account.username, account.password, "login"
        )
        if authenticated then return true end
        statusMessage = "Saved Rift sign-in failed: " .. tostring(message)
        account = nil
    end
    while not account do
        drawHeader("SIGN IN TO PLAY")
        writeAt(2, 5, "Casino wallets are saved to your Rift username.", colors.lightGray)
        writeAt(2, 6, statusMessage, colors.yellow)
        local buttons = drawButtons({
            { id = "login", label = "SIGN IN", key = keys.l },
            { id = "register", label = "CREATE RIFT ACCOUNT", key = keys.c },
            { id = "quit", label = "QUIT", key = keys.q },
        })
        local choice = waitForAction(buttons)
        if choice == "quit" then return false end
        if signIn(choice) then return true end
    end
    return true
end

local function gamePath(game)
    return fs.combine(GAMES_DIRECTORY, game.file)
end

local function gameInstalled(game)
    return fs.exists(gamePath(game))
end

local function downloadGame(game)
    if not http or not http.get then return false, "Enable HTTP to install Casino games." end
    local response, requestError = http.get(HOST_BASE_URL .. game.source)
    if not response then return false, tostring(requestError or "Download failed.") end
    local statusCode = response.getResponseCode and response.getResponseCode()
    if statusCode and statusCode ~= 200 then
        response.close()
        return false, "Script host returned HTTP " .. statusCode .. "."
    end
    local contents = response.readAll()
    response.close()
    if type(contents) ~= "string" or contents == "" then return false, "The downloaded game was empty." end

    fs.makeDir(GAMES_DIRECTORY)
    local destination = gamePath(game)
    local temporary = destination .. ".casino-tmp"
    local backup = destination .. ".casino-bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file = fs.open(temporary, "w")
    if not file then return false, "Could not create the install file." end
    file.write(contents)
    file.close()

    if fs.exists(destination) then fs.move(destination, backup) end
    local moved, moveError = pcall(fs.move, temporary, destination)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then fs.move(backup, destination) end
        return false, "Could not install " .. game.name .. ": " .. tostring(moveError)
    end
    if fs.exists(backup) then fs.delete(backup) end
    return true
end

local function installGames(onlyMissing)
    for _, game in ipairs(games) do
        if not onlyMissing or not gameInstalled(game) then
            drawHeader("INSTALLING  /  " .. game.name:upper())
            writeAt(2, 5, "Downloading the latest game script...", colors.white)
            local installed, err = downloadGame(game)
            if not installed then return false, err end
        end
    end
    return true
end

local function updateBalance()
    local response, err = walletApi.getBalance()
    if response then
        balance = response.balance
        statusMessage = "Balance refreshed from Casino server."
    else
        balance = nil
        statusMessage = tostring(err)
    end
end

local function drawGamePanel(x, y, width, index, title, description)
    if width < 12 then return end
    local border = "+" .. string.rep("-", width - 2) .. "+"
    writeAt(x, y, border, themeHighlight)
    writeAt(x, y + 1, "|" .. (" " .. index .. "  " .. title):sub(1, width - 2)
        .. "|", colors.yellow)
    writeAt(x, y + 2, "|" .. (" " .. description):sub(1, width - 2) .. "|", colors.lightGray)
    writeAt(x, y + 3, border, themeHighlight)
end

local function drawCasinoMenu(options)
    local width, height = term.getSize()
    local bankroll = balance and ("" .. balance .. " CHIPS") or "SERVER OFFLINE"
    drawHeader("PLAYER  /  " .. (account and account.username or "SIGNED OUT"))
    writeAt(2, 5, "YOUR BANKROLL", themeAccent)
    writeAt(2, 6, bankroll, colors.yellow)
    local connected = balance ~= nil
    local connectionText = connected and "+ ONLINE" or "! OFFLINE"
    writeAt(math.max(2, width - #connectionText - 1), 6, connectionText,
        connected and colors.lime or colors.red)

    if width >= 42 then
        local panelWidth = math.floor((width - 5) / 2)
        local rightPanelX = 2 + panelWidth + 2
        drawGamePanel(2, 8, panelWidth, "01", "BLACKJACK", "Dealer  /  3:2 natural")
        drawGamePanel(rightPanelX, 8, panelWidth, "02", "HOLD'EM", "You + three table bots")
    else
        local panelWidth = width - 3
        drawGamePanel(2, 8, panelWidth, "01", "BLACKJACK", "Dealer  /  3:2 natural")
        drawGamePanel(2, 11, panelWidth, "02", "HOLD'EM", "You + three bots")
    end

    local statusHeadingRow = width >= 42 and height - 5 or height - 4
    local statusRow = statusHeadingRow + 1
    writeAt(2, statusHeadingRow, "HOUSE NOTE", themeAccent)
    writeAt(2, statusRow, statusMessage, colors.lightGray)
    return drawButtons(options)
end

local function launchGame(game)
    if not gameInstalled(game) then
        local installed, err = downloadGame(game)
        if not installed then
            statusMessage = "INSTALL FAILED  /  " .. tostring(err)
            return
        end
    end
    local path = gamePath(game)
    local file = fs.open(path, "r")
    if not file then
        statusMessage = "Could not open " .. game.file .. "."
        return
    end
    local source = file.readAll()
    file.close()

    local gameEnvironment = setmetatable({ riftCasino = walletApi }, { __index = _ENV })
    gameEnvironment._G = gameEnvironment
    local gameChunk, compileError = load(source, "@" .. path, "t", gameEnvironment)
    if not gameChunk then
        statusMessage = "Could not load " .. game.name .. ": " .. tostring(compileError)
        return
    end
    local ok, runError = pcall(gameChunk)
    if not ok then statusMessage = game.name .. " stopped: " .. tostring(runError) end
    updateBalance()
end

local function startModemsAndInstall()
    openModems()
    local installed, err = installGames(false)
    statusMessage = installed and "Casino games installed and current."
        or ("GAME UPDATE FAILED  /  " .. tostring(err))
    updateBalance()
end

local requestedGame = select(1, ...)
if not openModems() then error("Attach a modem before starting Rift Casino.") end
local accountLoadError
account, accountLoadError = loadAccount()
if accountLoadError then statusMessage = accountLoadError end

local requestedGameLaunched = false
local gamesInitialized = false
while true do
    if not requireSignIn() then break end
    if not gamesInitialized then
        startModemsAndInstall()
        gamesInitialized = true
    else
        updateBalance()
    end
    if not requestedGameLaunched and requestedGame == "blackjack" then
        launchGame(games[1])
        requestedGameLaunched = true
    elseif not requestedGameLaunched and requestedGame == "holdem" then
        launchGame(games[2])
        requestedGameLaunched = true
    end
    if requestedGame and requestedGameLaunched then
        break
    end

    local options = {
        { id = "blackjack", label = "BLACKJACK", key = keys.b },
        { id = "holdem", label = "HOLD'EM", key = keys.h },
        { id = "install", label = "INSTALL / UPDATE", key = keys.i },
        { id = "refresh", label = "BALANCE", key = keys.r },
        { id = "signout", label = "SIGN OUT", key = keys.s },
    }
    if balance and balance < 10 then
        table.insert(options, { id = "rebuy", label = "REBUY", key = keys.e })
    end
    table.insert(options, { id = "quit", label = "QUIT", key = keys.q })

    local choice = waitForAction(drawCasinoMenu(options))
    if choice == "blackjack" then
        launchGame(games[1])
    elseif choice == "holdem" then
        launchGame(games[2])
    elseif choice == "install" then
        local installed, err = installGames(false)
        statusMessage = installed and "Both games installed or updated." or ("INSTALL FAILED  /  " .. tostring(err))
    elseif choice == "refresh" then
        updateBalance()
    elseif choice == "rebuy" then
        local response, err = walletApi.transact("rebuy")
        if response then
            balance = response.balance
            statusMessage = "Rebuy complete."
        else
            statusMessage = "REBUY FAILED  /  " .. tostring(err)
        end
    elseif choice == "quit" then
        break
    elseif choice == "signout" then
        signOut()
    end
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
