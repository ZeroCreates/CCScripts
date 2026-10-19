local STARTING_CHIPS = 1000
local REBUY_THRESHOLD = 10
local MAX_BALANCE = 2000000000
local MAX_TRANSACTION = 2000000000
local MAX_SAVED_TRANSACTIONS = 64
local DATA_FILE = "rift-casino-wallets.db"
local BACKUP_FILE = DATA_FILE .. ".bak"
local TEMP_FILE = DATA_FILE .. ".tmp"
local state

local function validUsername(username)
    return type(username) == "string" and #username >= 3 and #username <= 24
        and username:match("^[%w_-]+$") ~= nil
end

local function readState(path)
    if not fs.exists(path) then return nil end
    local file = fs.open(path, "r")
    if not file then return nil end
    local contents = file.readAll()
    file.close()
    local ok, saved = pcall(textutils.unserialize, contents)
    if ok and type(saved) == "table" and type(saved.wallets) == "table" then
        return saved
    end
end

local function loadState()
    if not fs.exists(DATA_FILE) and not fs.exists(BACKUP_FILE) then
        return { wallets = {} }
    end
    local loaded = readState(DATA_FILE) or readState(BACKUP_FILE)
    if not loaded then error("Could not read Rift Casino wallet data; refusing to overwrite it.") end
    for username, wallet in pairs(loaded.wallets) do
        if not validUsername(username) or type(wallet) ~= "table"
            or type(wallet.balance) ~= "number" or wallet.balance < 0
            or wallet.balance > MAX_BALANCE or wallet.balance % 1 ~= 0
            or type(wallet.transactions) ~= "table" then
            error("Rift Casino wallet data is invalid; refusing to overwrite it.")
        end
        for _, transaction in ipairs(wallet.transactions) do
            if type(transaction) ~= "table" or type(transaction.id) ~= "string"
                or type(transaction.response) ~= "table" then
                error("Rift Casino transaction data is invalid; refusing to overwrite it.")
            end
        end
    end
    return loaded
end

local function saveState()
    if fs.exists(TEMP_FILE) then fs.delete(TEMP_FILE) end
    local file = fs.open(TEMP_FILE, "w")
    if not file then return false, "Could not create temporary Rift Casino wallet data." end
    file.write(textutils.serialize(state))
    file.close()

    if fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
    if fs.exists(DATA_FILE) then fs.move(DATA_FILE, BACKUP_FILE) end
    local moved, moveError = pcall(fs.move, TEMP_FILE, DATA_FILE)
    if not moved then
        if fs.exists(BACKUP_FILE) and not fs.exists(DATA_FILE) then fs.move(BACKUP_FILE, DATA_FILE) end
        return false, "Could not save Rift Casino wallet data: " .. tostring(moveError)
    end
    if fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
    return true
end

local function getWallet(username)
    local key = username:lower()
    local wallet = state.wallets[key]
    if not wallet then
        wallet = { balance = STARTING_CHIPS, transactions = {} }
        state.wallets[key] = wallet
        local saved, saveError = saveState()
        if not saved then
            state.wallets[key] = nil
            return nil, saveError
        end
    end
    return wallet
end

local function validAmount(amount)
    return type(amount) == "number" and amount % 1 == 0
        and amount > 0 and amount <= MAX_TRANSACTION
end

local function findTransaction(wallet, requestId)
    for _, transaction in ipairs(wallet.transactions) do
        if transaction.id == requestId then return transaction.response end
    end
end

local function handleRequest(username, request)
    if not validUsername(username) or type(request) ~= "table"
        or type(request.type) ~= "string" then
        return { type = "error", message = "Sign in to a valid Rift account first." }
    end
    username = username:lower()
    local wallet, walletError = getWallet(username)
    if not wallet then return { type = "error", message = walletError } end
    if request.type == "balance" then
        return { type = "balance", balance = wallet.balance, requestId = request.requestId }
    end
    if type(request.requestId) ~= "string" or #request.requestId < 1
        or #request.requestId > 64 then
        return { type = "error", message = "A unique transaction ID is required." }
    end
    local previous = findTransaction(wallet, request.requestId)
    if previous then return previous end

    local oldBalance = wallet.balance
    local oldTransactions = {}
    for index, transaction in ipairs(wallet.transactions) do
        oldTransactions[index] = transaction
    end
    if request.type == "debit" then
        if not validAmount(request.amount) then
            return { type = "error", message = "Debit amount is invalid.", requestId = request.requestId }
        end
        if wallet.balance < request.amount then
            return { type = "error", message = "Not enough Casino chips.", requestId = request.requestId }
        end
        wallet.balance = wallet.balance - request.amount
    elseif request.type == "credit" then
        if not validAmount(request.amount) then
            return { type = "error", message = "Credit amount is invalid.", requestId = request.requestId }
        end
        if wallet.balance + request.amount > MAX_BALANCE then
            return { type = "error", message = "That payout exceeds the wallet limit.", requestId = request.requestId }
        end
        wallet.balance = wallet.balance + request.amount
    elseif request.type == "rebuy" then
        if wallet.balance >= REBUY_THRESHOLD then
            return { type = "error", message = "A rebuy is available only below "
                .. REBUY_THRESHOLD .. " chips.", requestId = request.requestId }
        end
        wallet.balance = STARTING_CHIPS
    else
        return { type = "error", message = "Unknown Rift Casino wallet request.", requestId = request.requestId }
    end

    local response = {
        type = "transaction",
        action = request.type,
        amount = request.amount or STARTING_CHIPS,
        balance = wallet.balance,
        requestId = request.requestId,
    }
    table.insert(wallet.transactions, { id = request.requestId, response = response })
    while #wallet.transactions > MAX_SAVED_TRANSACTIONS do table.remove(wallet.transactions, 1) end
    local saved, saveError = saveState()
    if not saved then
        wallet.balance = oldBalance
        wallet.transactions = oldTransactions
        return { type = "error", message = saveError, requestId = request.requestId }
    end
    return response
end

local function getStats()
    local walletCount, totalChips = 0, 0
    for _, wallet in pairs(state.wallets) do
        walletCount = walletCount + 1
        totalChips = totalChips + wallet.balance
    end
    return { wallets = walletCount, totalChips = totalChips }
end

local function createCasinoServer()
    state = loadState()
    return handleRequest, getStats
end

return createCasinoServer
