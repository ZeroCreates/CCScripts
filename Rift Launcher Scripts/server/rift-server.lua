local PROTOCOL = "rift_jobs_v1"
local ACCOUNT_PROTOCOL = "rift_account_v1"
local LOGIN_SERVER_NAME = "rift-server"
local JOBS_SERVER_NAME = "rift-jobs"
local MARKET_PROTOCOL = "order_system_v1"
local MARKET_SERVER_NAME = "rift-market"
local MAIL_PROTOCOL = "rift_mail_v1"
local MAIL_SERVER_NAME = "rift-mail"
local CASINO_PROTOCOL = "rift_casino_wallet_v1"
local CASINO_SERVER_NAME = "rift-casino"
local DATA_FILE = "jobs.db"
local BACKUP_FILE = "jobs.db.bak"
local TEMP_FILE = "jobs.db.tmp"
local ACCOUNTS_FILE = "accounts.db"
local ACCOUNTS_BACKUP_FILE = "accounts.db.bak"
local ACCOUNTS_TEMP_FILE = "accounts.db.tmp"
local state
local sessions = {}
local handleJobsRequest
local handleMarketRequest
local getMarketDashboardStats
local cleanupMarketOrders
local handleMailRequest
local getMailStats
local handleCasinoRequest
local getCasinoStats

local function openModems()
    local found = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            found = true
        end
    end
    if not found then error("Attach a modem before starting the combined Rift server.") end
end

local function readState(path)
    if not fs.exists(path) then return nil end
    local file = fs.open(path, "r")
    if not file then return nil end
    local contents = file.readAll()
    file.close()
    local ok, saved = pcall(textutils.unserialize, contents)
    if ok and type(saved) == "table" and type(saved.jobs) == "table" then
        return saved
    end
end

local function readAccounts(path)
    if not fs.exists(path) then return nil end
    local file = fs.open(path, "r")
    if not file then return nil end
    local contents = file.readAll()
    file.close()
    local ok, saved = pcall(textutils.unserialize, contents)
    if ok and type(saved) == "table" and type(saved.accounts) == "table" then
        return saved.accounts
    end
end

local function validateAccounts(accounts)
    if type(accounts) ~= "table" then
        error("Saved Rift account data is invalid; refusing to overwrite it.")
    end
    for username, account in pairs(accounts) do
        if type(username) ~= "string" or type(account) ~= "table"
            or type(account.username) ~= "string" or account.username:lower() ~= username
            or #account.username < 3 or #account.username > 24
            or not account.username:match("^[%w_-]+$") or type(account.password) ~= "string"
            or #account.password < 1 or #account.password > 128 then
            error("Saved Rift account data is invalid; refusing to overwrite it.")
        end
    end
    return accounts
end

local function loadState()
    local loaded
    if fs.exists(DATA_FILE) or fs.exists(BACKUP_FILE) then
        loaded = readState(DATA_FILE) or readState(BACKUP_FILE)
        if not loaded then error("Could not read saved Jobs data; refusing to overwrite it.") end
    else
        loaded = { nextId = 1, jobs = {} }
    end
    loaded.nextId = type(loaded.nextId) == "number" and loaded.nextId or 1
    loaded.jobs = type(loaded.jobs) == "table" and loaded.jobs or {}

    local hasEmbeddedAccounts = loaded.accounts ~= nil
    local accountFileExists = fs.exists(ACCOUNTS_FILE) or fs.exists(ACCOUNTS_BACKUP_FILE)
    if accountFileExists then
        local accounts = readAccounts(ACCOUNTS_FILE) or readAccounts(ACCOUNTS_BACKUP_FILE)
        if not accounts then
            error("Could not read saved Rift account data; refusing to overwrite it.")
        end
        loaded.accounts = validateAccounts(accounts)
    else
        local legacyAccounts = loaded.accounts
        if legacyAccounts == nil then legacyAccounts = {} end
        loaded.accounts = validateAccounts(legacyAccounts)
    end
    for _, job in ipairs(loaded.jobs) do
        if type(job.id) == "number" then loaded.nextId = math.max(loaded.nextId, job.id + 1) end
    end
    return loaded, hasEmbeddedAccounts
end

local function saveState()
    local file = fs.open(TEMP_FILE, "w")
    if not file then return false, "Could not create the temporary Jobs data file." end
    file.write(textutils.serialize({
        nextId = state.nextId,
        jobs = state.jobs,
    }))
    file.close()

    if fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
    if fs.exists(DATA_FILE) then fs.move(DATA_FILE, BACKUP_FILE) end
    local ok, saveError = pcall(fs.move, TEMP_FILE, DATA_FILE)
    if not ok then
        if fs.exists(BACKUP_FILE) and not fs.exists(DATA_FILE) then fs.move(BACKUP_FILE, DATA_FILE) end
        return false, "Could not save Jobs data: " .. tostring(saveError)
    end
    if fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
    return true
end

local function saveAccounts()
    local file = fs.open(ACCOUNTS_TEMP_FILE, "w")
    if not file then return false, "Could not create the temporary Rift account data file." end
    file.write(textutils.serialize({ accounts = state.accounts }))
    file.close()

    if fs.exists(ACCOUNTS_BACKUP_FILE) then fs.delete(ACCOUNTS_BACKUP_FILE) end
    if fs.exists(ACCOUNTS_FILE) then fs.move(ACCOUNTS_FILE, ACCOUNTS_BACKUP_FILE) end
    local ok, saveError = pcall(fs.move, ACCOUNTS_TEMP_FILE, ACCOUNTS_FILE)
    if not ok then
        if fs.exists(ACCOUNTS_BACKUP_FILE) and not fs.exists(ACCOUNTS_FILE) then
            fs.move(ACCOUNTS_BACKUP_FILE, ACCOUNTS_FILE)
        end
        return false, "Could not save Rift account data: " .. tostring(saveError)
    end
    if fs.exists(ACCOUNTS_BACKUP_FILE) then fs.delete(ACCOUNTS_BACKUP_FILE) end
    return true
end

local function sendError(senderId, message, protocol)
    rednet.send(senderId, { type = "error", message = message }, protocol or ACCOUNT_PROTOCOL)
end

local function accountKey(username)
    if type(username) ~= "string" then return nil end
    local cleaned = username:match("^%s*(.-)%s*$")
    if #cleaned < 3 or #cleaned > 24 or cleaned:find("%c") then return nil end
    if not cleaned or not cleaned:match("^[%w_-]+$") then return nil end
    return cleaned:lower(), cleaned
end

local function registerAccount(senderId, message, protocol)
    local key, username = accountKey(message.username)
    local password = message.password
    if not key then
        return sendError(senderId, "Username must be 3-24 letters, numbers, underscores, or dashes.", protocol)
    end
    if type(password) ~= "string" or #password < 1 or #password > 128 then
        return sendError(senderId, "Password must be 1 to 128 characters.", protocol)
    end
    if state.accounts[key] then
        return sendError(senderId, "That Rift username is already registered.", protocol)
    end

    state.accounts[key] = { username = username, password = password }
    local saved, saveError = saveAccounts()
    if not saved then
        state.accounts[key] = nil
        return sendError(senderId, saveError, protocol)
    end
    sessions[senderId] = username
    rednet.send(senderId, { type = "authenticated", username = username }, protocol or ACCOUNT_PROTOCOL)
end

local function persistAccountMigration(legacyAccountsEmbedded)
    local accountsFileExists = fs.exists(ACCOUNTS_FILE) or fs.exists(ACCOUNTS_BACKUP_FILE)
    if not accountsFileExists then
        local saved, saveError = saveAccounts()
        if not saved then error(saveError, 0) end
    end
    if not accountsFileExists or legacyAccountsEmbedded then
        local saved, saveError = saveState()
        if not saved then error(saveError, 0) end
    end
end

local function loginAccount(senderId, message, protocol)
    local key = accountKey(message.username)
    local account = key and state.accounts[key]
    if not account or type(message.password) ~= "string"
        or account.password ~= message.password then
        return sendError(senderId, "Username or password is incorrect.", protocol)
    end
    sessions[senderId] = account.username
    rednet.send(senderId, { type = "authenticated", username = account.username }, protocol or ACCOUNT_PROTOCOL)
end

local function handleAccountRequest(senderId, message, protocol)
    if type(message) ~= "table" or type(message.type) ~= "string" then
        return sendError(senderId, "Invalid Rift account request.", protocol)
    end
    if message.type == "register" then return registerAccount(senderId, message, protocol) end
    if message.type == "login" then return loginAccount(senderId, message, protocol) end
    if message.type == "logout" then
        sessions[senderId] = nil
        return rednet.send(senderId, { type = "logged_out" }, protocol or ACCOUNT_PROTOCOL)
    end
    sendError(senderId, "The Rift account endpoint only accepts account requests.", protocol)
end

local startedAt = os.clock()
local requestsByService = { login = 0, jobs = 0, market = 0, mail = 0, casino = 0 }
local lastRequest = "Waiting for network requests"
local monitorErrors = {}

local function drawServerStatus()
    local width, height = term.getSize()
    local text = "SERVER ONLINE"
    term.setBackgroundColor(colors.black)
    term.setTextColor(term.isColor() and colors.lime or colors.white)
    term.clear()
    term.setCursorPos(math.max(1, math.floor((width - #text) / 2) + 1),
        math.max(1, math.floor((height + 1) / 2)))
    term.write(text)
    term.setBackgroundColor(colors.black)
end

local function drawDashboard()
    local width, height = term.getSize()
    local color = term.isColor()
    local background = colors.black
    local foreground = colors.white
    local accent = color and colors.cyan or colors.white
    local panel = color and colors.blue or colors.gray
    local muted = color and colors.lightGray or colors.white
    local good = color and colors.lime or colors.white
    local warning = color and colors.yellow or colors.white

    local function lineAt(column, row, text, textColor, fill, cellWidth)
        if row < 1 or row > height then return end
        local available = math.min(cellWidth or (width - column + 1), width - column + 1)
        if available < 1 then return end
        term.setCursorPos(column, row)
        term.setBackgroundColor(fill or background)
        term.setTextColor(textColor or foreground)
        local content = tostring(text):sub(1, available)
        term.write(content .. string.rep(" ", math.max(0, available - #content)))
    end

    local function line(row, text, textColor, fill)
        lineAt(1, row, text, textColor, fill)
    end

    local function section(column, row, title, cellWidth)
        lineAt(column, row, " " .. title, foreground, panel, cellWidth)
    end

    local market = getMarketDashboardStats()
    local casino = getCasinoStats()
    local openCount, activeCount, completedCount = 0, 0, 0
    for _, job in ipairs(state.jobs) do
        if job.status == "open" then
            openCount = openCount + 1
        elseif job.status == "claimed" or job.status == "review" then
            activeCount = activeCount + 1
        elseif job.status == "completed" then
            completedCount = completedCount + 1
        end
    end

    local sessionCount = 0
    for _ in pairs(sessions) do sessionCount = sessionCount + 1 end

    term.setBackgroundColor(background)
    term.setTextColor(foreground)
    term.clear()
    line(1, " RIFT SERVER  /  JOBS + MARKET + MAIL + CASINO", foreground, accent)
    line(2, " ONLINE  |  COMPUTER #" .. os.getComputerID()
        .. "  |  UP " .. string.format("%02d:%02d", math.floor((os.clock() - startedAt) / 60),
            math.floor((os.clock() - startedAt) % 60)), muted)

    if width < 40 or height < 15 then
        if height <= 7 then
            line(3, "Jobs " .. openCount .. " open / " .. activeCount .. " active", good)
            line(4, "Market " .. market.activeOrders .. " orders / "
                .. market.liveProducts .. " products", good)
            if height >= 5 then
                line(5, "Users " .. sessionCount .. " / chips " .. casino.totalChips, muted)
            end
            if height >= 6 then
                line(6, "Last: " .. lastRequest, muted)
            end
            if height >= 7 then
                line(7, "RIFT SERVER  |  Ctrl+T to stop", muted)
            end
            term.setBackgroundColor(background)
            return
        end
        section(1, 4, "JOBS", width)
        line(5, " Open " .. openCount .. "  |  Active " .. activeCount
            .. "  |  Done " .. completedCount, good)
        section(1, 6, "MARKET", width)
        line(7, " Orders " .. market.activeOrders .. "  |  Products "
            .. market.liveProducts .. "/" .. market.totalProducts, good)
        line(8, " Done " .. market.completedOrders .. "  |  Cancelled "
            .. market.cancelledOrders, muted)
        section(1, 9, "RIFT ACCOUNTS + CASINO", width)
        line(10, " Signed in " .. sessionCount .. "  |  Wallets " .. casino.wallets, good)
        line(11, " Chips in play " .. casino.totalChips, muted)
        if height >= 13 then
            line(12, " Last: " .. lastRequest, muted)
        end
        if height >= 14 then
            section(1, 13, "RECENT ACTIVITY", width)
            local row = 14
            local jobIndex, orderIndex = #state.jobs, 1
            while row < height and (jobIndex > 0 or orderIndex <= #market.recentOrders) do
                if jobIndex > 0 then
                    local job = state.jobs[jobIndex]
                    line(row, "J #" .. job.id .. " " .. job.status:upper() .. " " .. job.title,
                        job.status == "open" and good or warning)
                    jobIndex = jobIndex - 1
                    row = row + 1
                end
                if orderIndex <= #market.recentOrders and row < height then
                    local order = market.recentOrders[orderIndex]
                    line(row, "M #" .. order.id .. " " .. order.status:upper(), muted)
                    orderIndex = orderIndex + 1
                    row = row + 1
                end
            end
        end
        if height >= 14 then
            for name, monitorError in pairs(monitorErrors) do
                line(height - 1, " Monitor " .. name .. " error: " .. monitorError, warning)
                break
            end
        end
        if height >= 13 then
            line(height, " RIFT SERVER  |  Ctrl+T to stop", muted)
        end
        term.setBackgroundColor(background)
        return
    end

    local jobsColumnWidth = math.max(1, math.floor(width / 2))
    local marketColumn = jobsColumnWidth + 1
    local marketColumnWidth = width - jobsColumnWidth
    if width >= 40 then
        section(1, 4, "JOBS", jobsColumnWidth)
        section(marketColumn, 4, "MARKET", marketColumnWidth)
        lineAt(1, 5, " Open " .. openCount .. "  |  Active " .. activeCount
            .. "  |  Done " .. completedCount, good, nil, jobsColumnWidth)
        lineAt(marketColumn, 5, " Orders " .. market.activeOrders
            .. " active  |  Products " .. market.liveProducts .. "/" .. market.totalProducts,
            good, nil, marketColumnWidth)
        lineAt(1, 6, " Signed in: " .. sessionCount, muted, nil, jobsColumnWidth)
        lineAt(marketColumn, 6, " Done " .. market.completedOrders
            .. "  |  Cancelled " .. market.cancelledOrders, muted, nil, marketColumnWidth)
        lineAt(1, 7, " Casino wallets " .. casino.wallets
            .. "  |  Chips " .. casino.totalChips, good, nil, jobsColumnWidth)
    else
        section(1, 4, "JOBS", width)
        line(5, " Open " .. openCount .. "  Active " .. activeCount
            .. "  Done " .. completedCount, good)
        line(6, " Signed in: " .. sessionCount, muted)
        section(1, 7, "MARKET", width)
        line(8, " Active orders: " .. market.activeOrders
            .. "  Products: " .. market.liveProducts .. "/" .. market.totalProducts, good)
        line(9, " Completed: " .. market.completedOrders
            .. "  Cancelled: " .. market.cancelledOrders, muted)
        line(10, "Casino: " .. casino.wallets .. " wallets / " .. casino.totalChips .. " chips", good)
    end

    local endpointRow = width >= 40 and 9 or 12
    section(1, endpointRow, "NETWORK ENDPOINTS", width)
    line(endpointRow + 1, " Login / rift-server  |  Jobs / rift-jobs", muted)
    line(endpointRow + 2, " Market / rift-market  |  Mail / rift-mail", muted)
    line(endpointRow + 3, " Casino / rift-casino", muted)

    local activityRow = endpointRow + 5
    section(1, activityRow, "TRAFFIC", width)
    line(activityRow + 1, " Login " .. requestsByService.login
        .. "  |  Jobs " .. requestsByService.jobs
        .. "  |  Market " .. requestsByService.market
        .. "  |  Mail " .. requestsByService.mail
        .. "  |  Casino " .. requestsByService.casino, good)
    line(activityRow + 2, " Last: " .. lastRequest, muted)

    local recentHeaderRow = activityRow + 4
    if width >= 40 then
        section(1, recentHeaderRow, "RECENT JOBS", jobsColumnWidth)
        section(marketColumn, recentHeaderRow, "RECENT ORDERS", marketColumnWidth)
        local row = recentHeaderRow + 1
        local availableRows = math.max(0, height - row)
        local recentJobCount = math.min(#state.jobs, availableRows)
        for index = 1, recentJobCount do
            local job = state.jobs[#state.jobs - index + 1]
            local statusColor = job.status == "open" and good
                or (job.status == "completed" and muted or warning)
            lineAt(1, row, "#" .. job.id .. " " .. job.status:upper() .. " " .. job.title,
                statusColor, nil, jobsColumnWidth)
            row = row + 1
        end
        if #state.jobs == 0 and row <= height then
            lineAt(1, row, " No jobs posted", muted, nil, jobsColumnWidth)
        end

        row = recentHeaderRow + 1
        local recentOrderCount = math.min(#market.recentOrders, math.max(0, height - row))
        for index = 1, recentOrderCount do
            local order = market.recentOrders[index]
            local statusColor = order.status == "preparing" and warning or muted
            lineAt(marketColumn, row, "#" .. order.id .. " " .. order.status:upper()
                .. " $" .. string.format("%.2f", order.total / 100),
                statusColor, nil, marketColumnWidth)
            row = row + 1
        end
        if #market.recentOrders == 0 and row <= height then
            lineAt(marketColumn, row, " No active orders", muted, nil, marketColumnWidth)
        end
    else
        section(1, recentHeaderRow, "LATEST JOBS / ORDERS", width)
        local row = recentHeaderRow + 1
        local jobIndex, orderIndex = #state.jobs, 1
        while row < height and (jobIndex > 0 or orderIndex <= #market.recentOrders) do
            if jobIndex > 0 then
                local job = state.jobs[jobIndex]
                line(row, "J #" .. job.id .. " " .. job.status:upper() .. " " .. job.title, warning)
                jobIndex = jobIndex - 1
                row = row + 1
            end
            if orderIndex <= #market.recentOrders and row < height then
                local order = market.recentOrders[orderIndex]
                line(row, "M #" .. order.id .. " " .. order.status:upper(), good)
                orderIndex = orderIndex + 1
                row = row + 1
            end
        end
        if #state.jobs == 0 and #market.recentOrders == 0 and row < height then
            line(row, " No recent activity", muted)
        end
    end

    if height >= 2 then
        term.setCursorPos(1, height)
        term.setBackgroundColor(background)
        term.setTextColor(muted)
        term.write((" Ctrl+T / terminate  |  Computer #%s"):format(os.getComputerID()):sub(1, width))
    end
    for name, monitorError in pairs(monitorErrors) do
        line(height, " Monitor " .. name .. " error: " .. monitorError, warning)
        break
    end
    term.setBackgroundColor(background)
end

local function monitorPages(height, market)
    local bodyStart = height >= 6 and 5 or 3
    local bodyEnd = math.max(bodyStart, height - 1)
    local rowsPerPage = math.max(1, bodyEnd - bodyStart + 1)
    local pages = { { type = "overview", title = "SERVER OVERVIEW" } }

    local function addListPages(pageType, title, count)
        local pageCount = math.max(1, math.ceil(count / rowsPerPage))
        for page = 1, pageCount do
            table.insert(pages, {
                type = pageType,
                title = title,
                offset = (page - 1) * rowsPerPage + 1,
                count = count,
            })
        end
    end

    addListPages("jobs", "JOBS", #state.jobs)
    addListPages("orders", "MARKET ORDERS", #market.orders)
    addListPages("products", "MARKET PRODUCTS", #market.products)
    table.insert(pages, { type = "services", title = "SERVICES AND TRAFFIC" })
    local sessionCount = 0
    for _ in pairs(sessions) do sessionCount = sessionCount + 1 end
    addListPages("sessions", "SIGNED-IN USERS", sessionCount)
    return pages, rowsPerPage, bodyStart, bodyEnd
end

local function drawMonitorDashboard(page, pageNumber, pageCount, rowsPerPage, bodyStart, bodyEnd)
    local width, height = term.getSize()
    local color = term.isColor()
    local background = colors.black
    local foreground = colors.white
    local accent = color and colors.cyan or colors.white
    local panel = color and colors.blue or colors.gray
    local muted = color and colors.lightGray or colors.white
    local good = color and colors.lime or colors.white
    local warning = color and colors.yellow or colors.white
    local rows = {}

    local function add(text, foregroundColor)
        table.insert(rows, { text = text, color = foregroundColor or foreground })
    end

    local market = getMarketDashboardStats()
    local casino = getCasinoStats()
    local openJobs, activeJobs, completedJobs = 0, 0, 0
    for _, job in ipairs(state.jobs) do
        if job.status == "open" then
            openJobs = openJobs + 1
        elseif job.status == "claimed" or job.status == "review" then
            activeJobs = activeJobs + 1
        elseif job.status == "completed" then
            completedJobs = completedJobs + 1
        end
    end
    local accountCount, sessionCount = 0, 0
    for _ in pairs(state.accounts) do accountCount = accountCount + 1 end
    for _ in pairs(sessions) do sessionCount = sessionCount + 1 end

    if page.type == "overview" then
        add("JOBS  |  " .. openJobs .. " open  /  " .. activeJobs .. " active  /  "
            .. completedJobs .. " completed", good)
        add("MARKET  |  " .. market.activeOrders .. " active orders  /  "
            .. market.completedOrders .. " completed  /  " .. market.cancelledOrders .. " cancelled", good)
        add("CATALOG  |  " .. market.liveProducts .. " live  /  "
            .. market.totalProducts .. " total products", muted)
        add("RIFT ACCOUNTS  |  " .. accountCount .. " registered  /  "
            .. sessionCount .. " currently signed in", good)
        local mail = getMailStats()
        add("RIFT MAIL  |  " .. mail.mailboxes .. " mailboxes  /  "
            .. mail.messages .. " messages  /  " .. mail.categories .. " categories", good)
        add("CASINO  |  " .. casino.wallets .. " player wallets  /  "
            .. casino.totalChips .. " chips", good)
        add("UPTIME  |  " .. string.format("%02d:%02d:%02d",
            math.floor((os.clock() - startedAt) / 3600),
            math.floor((os.clock() - startedAt) / 60) % 60,
            math.floor((os.clock() - startedAt) % 60)), muted)
        add("LAST REQUEST  |  " .. lastRequest, warning)
    elseif page.type == "jobs" then
        if page.count == 0 then
            add("No jobs have been posted.", muted)
        else
            local last = math.min(page.offset + rowsPerPage - 1, page.count)
            for index = page.offset, last do
                local job = state.jobs[page.count - index + 1]
                local statusColor = job.status == "open" and good
                    or (job.status == "completed" and muted or warning)
                add("#" .. job.id .. "  " .. job.status:upper() .. "  " .. job.title
                    .. "  |  by " .. tostring(job.posterName or job.posterUser or "unknown"), statusColor)
            end
        end
    elseif page.type == "orders" then
        if page.count == 0 then
            add("No market orders have been placed.", muted)
        else
            local last = math.min(page.offset + rowsPerPage - 1, page.count)
            for index = page.offset, last do
                local order = market.orders[index]
                local total = type(order.total) == "number"
                    and ("$" .. string.format("%.2f", order.total / 100)) or "total n/a"
                add(tostring(order.reference or ("#" .. tostring(order.id))) .. "  "
                    .. tostring(order.status):upper() .. "  " .. total .. "  |  "
                    .. tostring(order.customerUser or "unknown") .. " -> "
                    .. tostring(order.providerUser or "unknown"),
                    order.status == "preparing" and warning or muted)
            end
        end
    elseif page.type == "products" then
        if page.count == 0 then
            add("No market products have been published.", muted)
        else
            local last = math.min(page.offset + rowsPerPage - 1, page.count)
            for index = page.offset, last do
                local product = market.products[index]
                local price = type(product.price) == "number"
                    and ("$" .. string.format("%.2f", product.price / 100)) or "price n/a"
                add((product.available and "LIVE" or "PAUSED") .. "  "
                    .. tostring(product.name or "unnamed") .. "  |  " .. price .. "  by "
                    .. tostring(product.providerName or product.providerUser or "unknown"),
                    product.available and good or muted)
            end
        end
    elseif page.type == "services" then
        add("RIFT ACCOUNTS  |  " .. ACCOUNT_PROTOCOL .. " @ " .. LOGIN_SERVER_NAME, good)
        add("RIFT JOBS  |  " .. PROTOCOL .. " @ " .. JOBS_SERVER_NAME, good)
        add("RIFT MARKET  |  " .. MARKET_PROTOCOL .. " @ " .. MARKET_SERVER_NAME, good)
        add("RIFT MAIL  |  " .. MAIL_PROTOCOL .. " @ " .. MAIL_SERVER_NAME, good)
        add("RIFT CASINO  |  " .. CASINO_PROTOCOL .. " @ " .. CASINO_SERVER_NAME, good)
        add("REQUESTS  |  Login " .. requestsByService.login .. "  /  Jobs "
            .. requestsByService.jobs .. "  /  Market " .. requestsByService.market, muted)
        add("REQUESTS  |  Mail " .. requestsByService.mail .. "  /  Casino "
            .. requestsByService.casino, muted)
        add("MAIL  |  " .. getMailStats().mailboxes .. " mailboxes  /  "
            .. getMailStats().messages .. " messages", muted)
        add("DATA  |  jobs.db  /  accounts.db  /  market data  /  Rift Mail data  /  casino wallets", muted)
    elseif page.type == "sessions" then
        if page.count == 0 then
            add("No users are currently signed in.", muted)
        else
            local activeSessions = {}
            for computerId, username in pairs(sessions) do
                table.insert(activeSessions, { computerId = computerId, username = username })
            end
            table.sort(activeSessions, function(first, second)
                return first.username:lower() < second.username:lower()
            end)
            local last = math.min(page.offset + rowsPerPage - 1, #activeSessions)
            for index = page.offset, last do
                local session = activeSessions[index]
                add(session.username .. "  |  computer #" .. session.computerId, good)
            end
        end
    end

    term.setBackgroundColor(background)
    term.setTextColor(foreground)
    term.clear()
    local function drawLine(row, text, textColor, fill)
        if row < 1 or row > height then return end
        term.setCursorPos(1, row)
        term.setBackgroundColor(fill or background)
        term.setTextColor(textColor or foreground)
        local content = tostring(text):sub(1, width)
        term.write(content .. string.rep(" ", math.max(0, width - #content)))
    end

    drawLine(1, " RIFT SERVER  /  " .. page.title .. "  [" .. pageNumber .. "/" .. pageCount .. "]",
        foreground, accent)
    drawLine(2, " ONLINE  |  COMPUTER #" .. os.getComputerID()
        .. "  |  UP " .. string.format("%02d:%02d",
            math.floor((os.clock() - startedAt) / 60), math.floor((os.clock() - startedAt) % 60)), muted)
    if height >= 6 then
        drawLine(4, " PAGE DETAILS", foreground, panel)
    end
    local row = bodyStart
    for index = 1, #rows do
        if row > bodyEnd then break end
        drawLine(row, rows[index].text, rows[index].color)
        row = row + 1
    end
    if height >= 3 then
        drawLine(height, " AUTO-PAGES  |  updates every 5s  |  Ctrl+T stops server", muted)
    end
    term.setBackgroundColor(background)
end

local function drawMonitorDashboards()
    local attachedMonitors = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            attachedMonitors[name] = true
            local ok, monitorOrError = pcall(peripheral.wrap, name)
            if ok and monitorOrError then
                local previous = term.current()
                local redirected, redirectError = pcall(term.redirect, monitorOrError)
                if redirected then
                    local market = getMarketDashboardStats()
                    local pages, rowsPerPage, bodyStart, bodyEnd =
                        monitorPages(select(2, term.getSize()), market)
                    local pageNumber = math.floor(os.clock() / 5) % #pages + 1
                    local drawn, drawError = pcall(
                        drawMonitorDashboard, pages[pageNumber], pageNumber, #pages,
                        rowsPerPage, bodyStart, bodyEnd
                    )
                    term.redirect(previous)
                    if drawn then
                        monitorErrors[name] = nil
                    else
                        monitorErrors[name] = tostring(drawError)
                    end
                else
                    monitorErrors[name] = tostring(redirectError)
                end
            else
                monitorErrors[name] = tostring(monitorOrError)
            end
        end
    end
    for name in pairs(monitorErrors) do
        if not attachedMonitors[name] then monitorErrors[name] = nil end
    end
end

openModems()

local marketServerPath = fs.combine(fs.getDir(shell.getRunningProgram()), "rift-server-market.lua")
local marketServerChunk, marketLoadError = loadfile(marketServerPath)
if not marketServerChunk then
    error("Could not load the Market server module at " .. marketServerPath .. ": "
        .. tostring(marketLoadError), 0)
end
local moduleLoaded, createMarketServer = pcall(marketServerChunk)
if not moduleLoaded or type(createMarketServer) ~= "function" then
    error("The Market server module is invalid: " .. tostring(createMarketServer), 0)
end
handleMarketRequest, getMarketDashboardStats, cleanupMarketOrders = createMarketServer(function(senderId)
    return sessions[senderId]
end)
if type(handleMarketRequest) ~= "function" then
    error("The Market server module did not provide a request handler.", 0)
end
if type(getMarketDashboardStats) ~= "function" then
    error("The Market server module did not provide dashboard statistics.", 0)
end
if type(cleanupMarketOrders) ~= "function" then
    error("The Market server module did not provide an order cleanup handler.", 0)
end

local legacyAccountsEmbedded
state, legacyAccountsEmbedded = loadState()
persistAccountMigration(legacyAccountsEmbedded)
local jobsServerPath = fs.combine(fs.getDir(shell.getRunningProgram()), "rift-server-jobs.lua")
local jobsServerChunk, jobsLoadError = loadfile(jobsServerPath)
if not jobsServerChunk then
    error("Could not load the Jobs module at " .. jobsServerPath .. ": "
        .. tostring(jobsLoadError), 0)
end
local jobsModuleLoaded, createJobsServer = pcall(jobsServerChunk)
if not jobsModuleLoaded or type(createJobsServer) ~= "function" then
    error("The Jobs module is invalid: " .. tostring(createJobsServer), 0)
end
handleJobsRequest = createJobsServer(state, saveState)
if type(handleJobsRequest) ~= "function" then
    error("The Jobs module did not provide a request handler.", 0)
end
local mailServerPath = fs.combine(fs.getDir(shell.getRunningProgram()), "rift-server-email.lua")
local mailServerChunk, mailLoadError = loadfile(mailServerPath)
if not mailServerChunk then
    error("Could not load the Rift Mail server module at " .. mailServerPath .. ": "
        .. tostring(mailLoadError), 0)
end
local mailModuleLoaded, createMailServer = pcall(mailServerChunk)
if not mailModuleLoaded or type(createMailServer) ~= "function" then
    error("The Rift Mail server module is invalid: " .. tostring(createMailServer), 0)
end
handleMailRequest, getMailStats = createMailServer(function(username)
    local key = accountKey(username)
    return key ~= nil and state.accounts[key] ~= nil
end)
if type(handleMailRequest) ~= "function" or type(getMailStats) ~= "function" then
    error("The Rift Mail server module did not provide its required handlers.", 0)
end
local casinoServerPath = fs.combine(fs.getDir(shell.getRunningProgram()), "rift-server-casino.lua")
local casinoServerChunk, casinoLoadError = loadfile(casinoServerPath)
if not casinoServerChunk then
    error("Could not load the Rift Casino server module at " .. casinoServerPath .. ": "
        .. tostring(casinoLoadError), 0)
end
local casinoModuleLoaded, createCasinoServer = pcall(casinoServerChunk)
if not casinoModuleLoaded or type(createCasinoServer) ~= "function" then
    error("The Rift Casino server module is invalid: " .. tostring(createCasinoServer), 0)
end
handleCasinoRequest, getCasinoStats = createCasinoServer()
if type(handleCasinoRequest) ~= "function" or type(getCasinoStats) ~= "function" then
    error("The Rift Casino server module did not provide its required handlers.", 0)
end
rednet.host(PROTOCOL, JOBS_SERVER_NAME)
rednet.host(ACCOUNT_PROTOCOL, LOGIN_SERVER_NAME)
rednet.host(MARKET_PROTOCOL, MARKET_SERVER_NAME)
rednet.host(MAIL_PROTOCOL, MAIL_SERVER_NAME)
rednet.host(CASINO_PROTOCOL, CASINO_SERVER_NAME)
drawServerStatus()
drawMonitorDashboards()

while true do
    local senderId, message, receivedProtocol = rednet.receive(nil, 1)
    if senderId and receivedProtocol == ACCOUNT_PROTOCOL then
        requestsByService.login = requestsByService.login + 1
        lastRequest = "Login from #" .. senderId .. "  /  "
            .. tostring(type(message) == "table" and message.type or "invalid request")
        handleAccountRequest(senderId, message, ACCOUNT_PROTOCOL)
    elseif senderId and receivedProtocol == PROTOCOL then
        local requestType = type(message) == "table" and message.type
        if requestType == "login" or requestType == "register" or requestType == "logout" then
            requestsByService.login = requestsByService.login + 1
            lastRequest = "Legacy login from #" .. senderId .. "  /  " .. requestType
            handleAccountRequest(senderId, message, PROTOCOL)
        else
            requestsByService.jobs = requestsByService.jobs + 1
            lastRequest = "Jobs from #" .. senderId .. "  /  "
                .. tostring(requestType or "invalid request")
            local username = sessions[senderId]
            local response
            if not username then
                response = { type = "error", message = "Sign in to your Rift account first." }
            else
                response = handleJobsRequest(senderId, username, message)
            end
            rednet.send(senderId, response, PROTOCOL)
        end
    elseif senderId and receivedProtocol == MARKET_PROTOCOL then
        requestsByService.market = requestsByService.market + 1
        lastRequest = "Market from #" .. senderId .. "  /  "
            .. tostring(type(message) == "table" and message.type or "invalid request")
        handleMarketRequest(senderId, message)
    elseif senderId and receivedProtocol == MAIL_PROTOCOL then
        requestsByService.mail = requestsByService.mail + 1
        lastRequest = "Rift Mail from #" .. senderId .. "  /  "
            .. tostring(type(message) == "table" and message.type or "invalid request")
        local username = sessions[senderId]
        local response
        if not username then
            response = { type = "error", message = "Sign in to your Rift account first." }
        else
            response = handleMailRequest(username, message)
        end
        rednet.send(senderId, response, MAIL_PROTOCOL)
    elseif senderId and receivedProtocol == CASINO_PROTOCOL then
        requestsByService.casino = requestsByService.casino + 1
        lastRequest = "Rift Casino from #" .. senderId .. "  /  "
            .. tostring(type(message) == "table" and message.type or "invalid request")
        local username = sessions[senderId]
        local response
        if not username then
            response = { type = "error", message = "Sign in to your Rift account first." }
        else
            response = handleCasinoRequest(username, message)
        end
        rednet.send(senderId, response, CASINO_PROTOCOL)
    end
    cleanupMarketOrders()
    drawServerStatus()
    drawMonitorDashboards()
end
