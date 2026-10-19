local PROTOCOL = "rift_jobs_v1"
local ACCOUNT_PROTOCOL = "rift_account_v1"
local ACCOUNT_SERVER_NAME = "rift-server"
local JOBS_SERVER_NAME = "rift-jobs"
local TIMEOUT = 5
local RIFT_LOGIN_PATH = "rift/account.json"
local LEGACY_LOGIN_PATH = "rift-jobs/login.json"
local playerName
local savedLogin
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
        storageError = ok and err or account
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
        if called and deleted then return true end
        storageError = called and err or deleted
        if called and err == "Stored data was not found." then storageError = nil end
    end
    local absolutePath = "/" .. path
    if not fs.exists(absolutePath) then
        if storageError then
            return false, "Could not delete account from launcher storage: " .. tostring(storageError)
        end
        return false, "Stored data was not found."
    end
    if fs.isDir(absolutePath) then return false, "Saved Rift account path is a folder." end
    local deleted, deleteError = pcall(fs.delete, absolutePath)
    if not deleted then
        return false, "Could not delete saved Rift account: " .. tostring(deleteError)
            .. (storageError and "; launcher storage also failed: " .. tostring(storageError) or "")
    end
    return true
end

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

local function readText(label, hidden)
    drawHeader("RIFT  /  JOBS INPUT", label)
    local _, height = term.getSize()
    writeAt(2, height - 1, "> ", themeAccent)
    term.setCursorPos(4, height - 1)
    return read(hidden and "*" or nil)
end

local function drawButtons(options)
    local width, height = term.getSize()
    local columns = math.min(3, #options)
    local rows = math.ceil(#options / columns)
    local buttons = {}
    for index, option in ipairs(options) do
        local column = (index - 1) % columns
        local row = height - rows + math.floor((index - 1) / columns) + 1
        local left = math.floor(column * width / columns) + 1
        local right = math.floor((column + 1) * width / columns)
        local label = ("[ " .. option.label .. " ]"):sub(1, right - left + 1)
        writeAt(left, row, string.rep(" ", right - left + 1), colors.black, themeHighlight)
        writeAt(left, row, label, colors.black, themeHighlight)
        table.insert(buttons, {
            id = option.id,
            key = option.key,
            row = row,
            left = left,
            right = right,
        })
    end
    return buttons
end

local function waitForAction(buttons, rows)
    while true do
        local event, button, x, y = os.pullEvent()
        if event == "mouse_click" and button == 1 then
            for _, entry in ipairs(rows or {}) do
                if y >= entry.top and y <= entry.bottom and x >= entry.left and x <= entry.right then
                    return "job", entry.job
                end
            end
            for _, choice in ipairs(buttons) do
                if y == choice.row and x >= choice.left and x <= choice.right then
                    return choice.id
                end
            end
        elseif event == "key" then
            for _, choice in ipairs(buttons) do
                if choice.key == button then return choice.id end
            end
        end
    end
end

local function showNotice(title, message)
    drawHeader("RIFT", "JOBS  /  " .. title)
    writeAt(2, 5, message, colors.white)
    local buttons = drawButtons({ { id = "ok", label = "OK", key = keys.enter } })
    waitForAction(buttons)
end

local function confirm(title, message)
    drawHeader("RIFT", "JOBS  /  " .. title .. "  /  PLEASE CONFIRM")
    writeAt(2, 5, message, colors.white)
    local buttons = drawButtons({
        { id = "yes", label = "CONFIRM", key = keys.y },
        { id = "no", label = "CANCEL", key = keys.n },
    })
    return waitForAction(buttons) == "yes"
end

local function openModems()
    local found = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            found = true
        end
    end
    if not found then error("Attach a modem before starting Rift Jobs.") end
end

local function request(message)
    local serverName = JOBS_SERVER_NAME
    local protocol = PROTOCOL
    if message.type == "login" or message.type == "register" or message.type == "logout" then
        serverName = ACCOUNT_SERVER_NAME
        protocol = ACCOUNT_PROTOCOL
    end
    local serverId = rednet.lookup(protocol, serverName)
    if not serverId and protocol == ACCOUNT_PROTOCOL then
        protocol = PROTOCOL
        serverName = JOBS_SERVER_NAME
        serverId = rednet.lookup(protocol, serverName)
    end
    if not serverId then
        return nil, (protocol == ACCOUNT_PROTOCOL and "Rift account server"
            or "Rift Jobs server") .. " not found. Check that it is running and connected."
    end
    rednet.send(serverId, message, protocol)
    local _, response = rednet.receive(protocol, TIMEOUT, serverId)
    if type(response) ~= "table" then return nil, "No response from the Jobs server." end
    if response.type == "error" then
        return nil, response.message or "The Jobs server rejected the request."
    end
    return response
end

local function saveLogin(username, password)
    local account, accountError = readRiftAccount(RIFT_LOGIN_PATH)
    if account == nil and accountError and accountError ~= "Stored data was not found." then
        return false, "Could not read the saved Rift account: " .. tostring(accountError)
    end
    if type(account) ~= "table" or type(account.username) ~= "string"
        or account.username:lower() ~= username:lower() then
        account = {}
    end
    account.username = username
    account.password = password
    local saved, saveError = writeRiftAccount(RIFT_LOGIN_PATH, account)
    if not saved then
        return false, "Could not save the Rift account: " .. tostring(saveError or "unknown storage error")
    end
    local legacyDeleted, legacyDeleteError = deleteRiftAccount(LEGACY_LOGIN_PATH)
    if not legacyDeleted and legacyDeleteError ~= "Stored data was not found." then
        return false, "Rift account was saved, but the legacy account entry could not be removed: "
            .. tostring(legacyDeleteError or "unknown storage error")
    end
    savedLogin = { username = username, password = password }
    return true
end

local function loadSavedLogin()
    local data, storageError = readRiftAccount(RIFT_LOGIN_PATH)
    if data == nil and storageError == "Stored data was not found." then
        data, storageError = readRiftAccount(LEGACY_LOGIN_PATH)
        if data ~= nil then
            local saved, saveError = writeRiftAccount(RIFT_LOGIN_PATH, data)
            if not saved then
                return nil, "Could not migrate the saved Rift account: "
                    .. tostring(saveError or "unknown storage error")
            end
            local deleted, deleteError = deleteRiftAccount(LEGACY_LOGIN_PATH)
            if not deleted and deleteError ~= "Stored data was not found." then
                return nil, "Rift account was migrated, but the legacy account entry could not be removed: "
                    .. tostring(deleteError or "unknown storage error")
            end
        end
    end
    if data == nil then
        if storageError == "Stored data was not found." then return nil end
        return nil, "Could not load the saved Rift account: "
            .. tostring(storageError or "unknown storage error")
    end
    if type(data) ~= "table" or type(data.username) ~= "string"
        or type(data.password) ~= "string" then
        return nil, "Saved Rift account data is invalid."
    end
    savedLogin = { username = data.username, password = data.password }
    return savedLogin
end

local function deleteSavedLogin()
    local deleted, deleteError = deleteRiftAccount(RIFT_LOGIN_PATH)
    if not deleted and deleteError ~= "Stored data was not found." then
        return false, "Could not remove the saved Rift account: "
            .. tostring(deleteError or "unknown storage error")
    end
    local legacyDeleted, legacyDeleteError = deleteRiftAccount(LEGACY_LOGIN_PATH)
    if not legacyDeleted and legacyDeleteError ~= "Stored data was not found." then
        return false, "Rift account was signed out, but the legacy account entry could not be removed: "
            .. tostring(legacyDeleteError or "unknown storage error")
    end
    savedLogin = nil
    return true
end

local function authenticate(username, password, failureTitle)
    local response, err = request({
        type = "login",
        username = username,
        password = password,
    })
    if not response then return showNotice(failureTitle, err) end
    local saved, saveError = saveLogin(response.username, password)
    if not saved then
        playerName = response.username
        showNotice("LOGIN NOT SAVED", saveError)
        return
    end
    playerName = response.username
end

local function createAccount()
    local username = readText("Choose a username (3-24 letters, numbers, _ or -)")
        :match("^%s*(.-)%s*$")
    local password = readText("Choose a password (1-128 characters)", true)
    local confirmation = readText("Confirm your password", true)
    if password ~= confirmation then
        return showNotice("ACCOUNT NOT CREATED", "The passwords do not match.")
    end
    local response, err = request({
        type = "register",
        username = username,
        password = password,
    })
    if not response then return showNotice("ACCOUNT NOT CREATED", err) end
    local saved, saveError = saveLogin(response.username, password)
    if not saved then
        playerName = response.username
        showNotice("ACCOUNT CREATED", "You are signed in, but " .. saveError)
        return
    end
    playerName = response.username
end

local function signIn()
    local username = readText("Username")
    local password = readText("Password", true)
    authenticate(username, password, "SIGN IN FAILED")
end

local function signOut()
    local response, logoutError = request({ type = "logout" })
    playerName = nil
    local deleted, deleteError = deleteSavedLogin()
    if not deleted then return showNotice("SIGNED OUT", deleteError) end
    if not response then return showNotice("SIGNED OUT", logoutError) end
end

local function drawJobs(title, subtitle, jobs, page, showStatus)
    drawHeader("RIFT", "JOBS  /  " .. title .. "  /  " .. subtitle)
    local _, height = term.getSize()
    local perPage = math.max(1, math.floor((height - 10) / 4))
    local pageCount = math.max(1, math.ceil(#jobs / perPage))
    page = math.max(1, math.min(page, pageCount))
    writeAt(2, 4, #jobs == 0 and "No jobs to show." or ("JOBS  " .. #jobs), themeAccent)
    local first = (page - 1) * perPage + 1
    local last = math.min(#jobs, first + perPage - 1)
    local clickableRows = {}
    for index = first, last do
        local job = jobs[index]
        local y = 5 + (index - first) * 4
        local status = showStatus and (job.status:upper() .. "  ") or ""
        writeAt(2, y, "#" .. job.id .. "  " .. status .. job.title, colors.yellow)
        writeAt(4, y + 1, "BY " .. (job.posterName or "Unknown") .. "  |  REWARD: " .. job.reward, colors.lime)
        writeAt(4, y + 2, job.description, colors.white)
        local detail = job.submission and ("SUBMITTED: " .. job.submission)
            or job.reviewNote and ("REVISION: " .. job.reviewNote)
            or job.claimantName and ("WORKER: " .. job.claimantName) or ""
        if detail ~= "" then writeAt(4, y + 3, detail, colors.lightGray) end
        table.insert(clickableRows, { job = job, top = y, bottom = y + 3, left = 1, right = term.getSize() })
    end
    writeAt(2, height - 3, "PAGE " .. page .. " / " .. pageCount, colors.lightGray)
    return page, pageCount, clickableRows
end

local function postJob()
    drawHeader("RIFT", "JOBS  /  POST A JOB  /  DESCRIBE THE WORK AND AGREED REWARD")
    local title = readText("Job title (3-40 characters)")
    local description = readText("Work details (5-180 characters)")
    local reward = readText("Reward, e.g. 2 diamonds or $5.00")
    local response, err = request({
        type = "create_job",
        title = title,
        description = description,
        reward = reward,
    })
    if not response then return showNotice("JOB NOT POSTED", err) end
    showNotice("JOB POSTED", "Job #" .. response.job.id .. " is on the board.")
end

local function claimJob(job)
    local response, err = request({ type = "claim_job", jobId = job.id })
    if not response then return showNotice("JOB NOT CLAIMED", err) end
    showNotice("JOB CLAIMED", "You are assigned to: " .. response.job.title)
end

local showJobDetails

local function browseJobs()
    local page = 1
    while true do
        local response, err = request({ type = "list_jobs" })
        if not response then return showNotice("BOARD UNAVAILABLE", err) end
        local jobs = response.jobs or {}
        local shownPage, pageCount, rows = drawJobs("JOB BOARD", "OPEN WORK  /  CLICK A JOB TO VIEW IT", jobs, page)
        page = shownPage
        local buttons = drawButtons({
            { id = "back", label = "BACK", key = keys.backspace },
            { id = "previous", label = "PREVIOUS (V)", key = keys.v },
            { id = "next", label = "NEXT (N)", key = keys.n },
            { id = "refresh", label = "REFRESH", key = keys.r },
        })
        local choice, selectedJob = waitForAction(buttons, rows)
        if choice == "job" then
            showJobDetails(selectedJob, true)
        elseif choice == "next" then
            page = math.min(page + 1, pageCount)
        elseif choice == "previous" then
            page = math.max(page - 1, 1)
        elseif choice == "refresh" then
            page = 1
        elseif choice == "back" then
            return
        end
    end
end

showJobDetails = function(job, fromBoard)
    drawHeader("RIFT", "JOBS  /  #" .. job.id .. "  /  " .. job.status:upper() .. "  /  " .. job.title)
    writeAt(2, 5, "POSTED BY  " .. (job.posterName or "Unknown"), colors.lightGray)
    writeAt(2, 6, "REWARD  " .. job.reward, colors.lime)
    writeAt(2, 8, job.description, colors.white)
    if job.submission then writeAt(2, 10, "SUBMISSION  " .. job.submission, colors.yellow) end
    if job.reviewNote then writeAt(2, 11, "REVISION  " .. job.reviewNote, colors.orange) end

    local isPoster = job.posterUser == playerName
        or (not job.posterUser and job.posterId == os.getComputerID())
    local isWorker = job.claimantUser == playerName
        or (not job.claimantUser and job.claimantId == os.getComputerID())
    local options = {}
    if isPoster and job.status == "review" then
        table.insert(options, { id = "approve", label = "APPROVE", key = keys.a })
        table.insert(options, { id = "revise", label = "REQUEST REVISION", key = keys.r })
    elseif isPoster and (job.status == "open" or job.status == "claimed") then
        table.insert(options, { id = "cancel", label = "CANCEL JOB", key = keys.x })
    elseif isWorker and job.status == "claimed" then
        table.insert(options, { id = "submit", label = "SUBMIT WORK", key = keys.s })
        table.insert(options, { id = "withdraw", label = "WITHDRAW", key = keys.w })
    elseif isWorker and job.status == "review" then
        writeAt(2, 13, "Waiting for the poster to review your work.", colors.lightGray)
    elseif fromBoard and job.status == "open" and not isPoster then
        table.insert(options, { id = "claim", label = "CLAIM JOB", key = keys.c })
    end
    table.insert(options, { id = "back", label = "BACK", key = keys.backspace })
    local buttons = drawButtons(options)
    local choice = waitForAction(buttons)

    if choice == "claim" then
        claimJob(job)
    elseif choice == "approve" then
        local response, err = request({ type = "approve_job", jobId = job.id })
        showNotice(response and "WORK APPROVED" or "APPROVAL FAILED",
            response and "Job #" .. job.id .. " is complete. Arrange the reward with the worker." or err)
    elseif choice == "revise" then
        local note = readText("What needs to be revised? (up to 120 characters)")
        local response, err = request({ type = "revise_job", jobId = job.id, note = note })
        showNotice(response and "REVISION REQUESTED" or "REQUEST FAILED",
            response and "The worker can update and resubmit." or err)
    elseif choice == "cancel" and confirm("CANCEL JOB", "Cancel job #" .. job.id .. "?") then
        local response, err = request({ type = "cancel_job", jobId = job.id })
        showNotice(response and "JOB CANCELLED" or "CANCEL FAILED",
            response and "Job #" .. job.id .. " was cancelled." or err)
    elseif choice == "submit" then
        local submission = readText("Describe the completed work (5-180 characters)")
        local response, err = request({ type = "submit_job", jobId = job.id, submission = submission })
        showNotice(response and "SENT FOR REVIEW" or "SUBMISSION FAILED",
            response and "The poster can now review your work." or err)
    elseif choice == "withdraw" and confirm("WITHDRAW CLAIM", "Return this job to the open board?") then
        local response, err = request({ type = "withdraw_claim", jobId = job.id })
        showNotice(response and "CLAIM WITHDRAWN" or "WITHDRAWAL FAILED",
            response and "The job is open for another worker." or err)
    end
end

local function myJobs()
    local page = 1
    while true do
        local response, err = request({ type = "my_jobs" })
        if not response then return showNotice("JOBS UNAVAILABLE", err) end
        local jobs = response.jobs or {}
        local shownPage, pageCount, rows = drawJobs("MY JOBS", "CLICK A JOB TO VIEW ITS STATUS OR ACTIONS", jobs, page, true)
        page = shownPage
        local buttons = drawButtons({
            { id = "back", label = "BACK", key = keys.backspace },
            { id = "previous", label = "PREVIOUS (V)", key = keys.v },
            { id = "next", label = "NEXT (N)", key = keys.n },
            { id = "refresh", label = "REFRESH", key = keys.r },
        })
        local choice, selectedJob = waitForAction(buttons, rows)
        if choice == "job" then
            showJobDetails(selectedJob, false)
        elseif choice == "next" then
            page = math.min(page + 1, pageCount)
        elseif choice == "previous" then
            page = math.max(page - 1, 1)
        elseif choice == "refresh" then
            page = 1
        elseif choice == "back" then
            return
        end
    end
end

openModems()
local login, loginError = loadSavedLogin()
if login then
    authenticate(login.username, login.password, "SAVED SIGN IN FAILED")
elseif loginError then
    showNotice("SAVED LOGIN UNAVAILABLE", loginError)
end

while true do
    if playerName then
        drawHeader("RIFT", "JOBS  /  SIGNED IN AS " .. playerName:upper())
        writeAt(2, 5, "Post work, pick up a contract, and track your jobs.", colors.white)
        local buttons = drawButtons({
            { id = "post", label = "POST A JOB", key = keys.p },
            { id = "board", label = "BROWSE JOBS", key = keys.b },
            { id = "mine", label = "MY JOBS", key = keys.m },
            { id = "signout", label = "SIGN OUT", key = keys.s },
            { id = "quit", label = "QUIT", key = keys.q },
        })
        local choice = waitForAction(buttons)
        if choice == "post" then
            postJob()
        elseif choice == "board" then
            browseJobs()
        elseif choice == "mine" then
            myJobs()
        elseif choice == "signout" then
            signOut()
        elseif choice == "quit" then
            break
        end
    else
        drawHeader("RIFT", "JOBS  /  CREATE AN ACCOUNT OR SIGN IN")
        local buttons = drawButtons({
            { id = "register", label = "CREATE ACCOUNT", key = keys.c },
            { id = "login", label = "SIGN IN", key = keys.l },
            { id = "quit", label = "QUIT", key = keys.q },
        })
        local choice = waitForAction(buttons)
        if choice == "register" then
            createAccount()
        elseif choice == "login" then
            signIn()
        elseif choice == "quit" then
            break
        end
    end
end