local PROTOCOL = "rift_jobs_v1"
local TIMEOUT = 5
local playerName
if type(rift) ~= "table" or type(rift.account) ~= "table" then
    error("This version of Rift Launcher does not support Rift accounts. Update the launcher.")
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

local function appendWrapped(lines, text, lineWidth, color)
    lineWidth = math.max(1, lineWidth)
    for paragraph in (tostring(text) .. "\n"):gmatch("(.-)\n") do
        while #paragraph > lineWidth do
            local segment = paragraph:sub(1, lineWidth)
            local breakAt = segment:match(".*()%s+")
            if breakAt and breakAt > 1 then
                table.insert(lines, { text = segment:sub(1, breakAt - 1), color = color })
                paragraph = paragraph:sub(breakAt + 1)
            else
                table.insert(lines, { text = segment, color = color })
                paragraph = paragraph:sub(lineWidth + 1)
            end
        end
        table.insert(lines, { text = paragraph, color = color })
    end
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

local function readDetails(label)
    local lines = {}
    local warning
    while true do
        local width, height = term.getSize()
        local current = table.concat(lines, "\n")
        drawHeader("RIFT  /  JOBS INPUT", label)
        writeAt(2, 3, "Blank line to finish  /  " .. #current .. "/360", colors.lightGray)
        local preview = {}
        for _, line in ipairs(lines) do
            appendWrapped(preview, line, math.max(1, width - 2), colors.white)
        end
        local visible = math.max(0, height - 6)
        local first = math.max(1, #preview - visible + 1)
        for index = first, #preview do
            writeAt(2, 4 + index - first, preview[index].text, preview[index].color)
        end
        if warning then writeAt(2, height - 2, warning, colors.red) end
        writeAt(2, height - 1, "> ", themeAccent)
        term.setCursorPos(4, height - 1)
        local line = read()
        if not line or line == "" then return current end
        if #current + (current ~= "" and 1 or 0) + #line > 360 then
            warning = "Details must be at most 360 characters."
        else
            table.insert(lines, line)
            warning = nil
        end
    end
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

local function showMessage(title, message, options)
    local width, height = term.getSize()
    local lines = {}
    appendWrapped(lines, message, math.max(1, width - 2), colors.white)
    local buttonRows = math.ceil(#options / math.min(3, #options))
    local pageSize = math.max(1, height - buttonRows - 4)
    if #lines > pageSize then
        table.insert(options, { id = "previous", label = "PREV (V)", key = keys.v })
        table.insert(options, { id = "next", label = "NEXT (N)", key = keys.n })
        buttonRows = math.ceil(#options / math.min(3, #options))
        pageSize = math.max(1, height - buttonRows - 4)
    end
    local pageCount = math.max(1, math.ceil(#lines / pageSize))
    local page = 1
    while true do
        drawHeader("RIFT", "JOBS  /  " .. title .. (pageCount > 1 and ("  /  " .. page .. "/" .. pageCount) or ""))
        local first = (page - 1) * pageSize + 1
        for index = first, math.min(#lines, first + pageSize - 1) do
            writeAt(2, 5 + index - first, lines[index].text, lines[index].color)
        end
        local choice = waitForAction(drawButtons(options))
        if choice == "previous" then
            page = math.max(1, page - 1)
        elseif choice == "next" then
            page = math.min(pageCount, page + 1)
        else
            return choice
        end
    end
end

local function showNotice(title, message)
    showMessage(title, message, { { id = "ok", label = "OK", key = keys.enter } })
end

local function confirm(title, message)
    return showMessage(title .. "  /  PLEASE CONFIRM", message, {
        { id = "yes", label = "CONFIRM", key = keys.y },
        { id = "no", label = "CANCEL", key = keys.n },
    }) == "yes"
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
    local protocol = PROTOCOL
    local serverId = rednet.lookup(protocol, "rift-jobs")
    if not serverId then
        return nil, "Rift Jobs server not found. Check that it is running and connected."
    end
    rednet.send(serverId, message, protocol)
    local _, response = rednet.receive(protocol, TIMEOUT, serverId)
    if type(response) ~= "table" then return nil, "No response from the Jobs server." end
    if response.type == "error" then
        return nil, response.message or "The Jobs server rejected the request."
    end
    return response
end

local function signOut()
    local ok, logoutError = rift.account.logout()
    playerName = nil
    if not ok then return showNotice("SIGNED OUT", tostring(logoutError)) end
end

local function drawJobs(title, subtitle, jobs, page, showStatus)
    drawHeader("RIFT", "JOBS  /  " .. title .. "  /  " .. subtitle)
    local width, height = term.getSize()
    local lines = {}
    local lineWidth = math.max(1, width - 2)
    for _, job in pairs(jobs) do
        local jobLines = {}
        local status = showStatus and (job.status:upper() .. "  ") or ""
        local kind = job.kind == "offer" and "OFFER" or "REQUEST"
        table.insert(jobLines, { text = "> " .. kind .. "  " .. status .. job.title, color = colors.yellow })
        table.insert(jobLines, { text = "BY " .. (job.posterName or "Unknown"), color = colors.lime })
        appendWrapped(jobLines, (job.kind == "offer" and "PRICE: " or "REWARD: ").. job.reward, lineWidth, colors.lime)
        table.insert(jobLines, { text = job.description:gsub("\n", " "), color = colors.white })
        local detail = job.submission and ("SUBMITTED: " .. job.submission)
            or job.reviewNote and ("REVISION: " .. job.reviewNote)
            or job.claimantName and ((job.kind == "offer" and "CUSTOMER: " or "WORKER: ") .. job.claimantName) or nil
        if detail then table.insert(jobLines, { text = detail, color = colors.lightGray }) end
        for _, line in pairs(jobLines) do
            line.job = job
            table.insert(lines, line)
        end
        table.insert(lines, { text = "", job = job })
    end
    if #lines > 0 then table.remove(lines) end
    local perPage = math.max(1, height - 8)
    local pageCount = math.max(1, math.ceil(#lines / perPage))
    page = math.max(1, math.min(page, pageCount))
    writeAt(2, 4, #jobs == 0 and "No jobs to show." or ("JOBS  " .. #jobs), themeAccent)
    local first = (page - 1) * perPage + 1
    local last = math.min(#lines, first + perPage - 1)
    local clickableRows = {}
    for index = first, last do
        local line = lines[index]
        local y = 5 + index - first
        writeAt(2, y, line.text, line.color)
        table.insert(clickableRows, { job = line.job, top = y, bottom = y, left = 1, right = width })
    end
    writeAt(2, height - 3, "PAGE " .. page .. " / " .. pageCount, colors.lightGray)
    return page, pageCount, clickableRows
end

local function postJob(kind)
    local offer = kind == "offer"
    if offer then
        local capabilities, err = request({ type = "jobs_capabilities" })
        if not capabilities or capabilities.type ~= "jobs_capabilities" or capabilities.serviceOffers ~= true then
            return showNotice("SERVER UPDATE REQUIRED", err or "The Jobs server does not support service offers.")
        end
    end
    local title = readText(offer and "Service title (3-40 characters)" or "Job title (3-40 characters)")
    local description = readDetails(offer and "Service details (5-360 characters)" or "Work details (5-360 characters)")
    local reward = readText(offer and "Price, e.g. 2 diamonds or $5.00" or "Reward, e.g. 2 diamonds or $5.00")
    local response, err = request({
        type = "create_job",
        title = title,
        description = description,
        reward = reward,
        kind = kind,
    })
    if not response then return showNotice("JOB NOT POSTED", err) end
    showNotice("JOB POSTED", "Job #" .. response.job.id .. " is on the board.")
end

local function claimJob(job)
    local response, err = request({ type = "claim_job", jobId = job.id })
    if not response then return showNotice("JOB NOT CLAIMED", err) end
    showNotice(job.kind == "offer" and "SERVICE ACCEPTED" or "JOB CLAIMED",
        job.kind == "offer" and "You hired: " .. response.job.posterName or "You are assigned to: " .. response.job.title)
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
    local isPoster = job.posterUser == playerName
        or (not job.posterUser and job.posterId == os.getComputerID())
    local isClaimant = job.claimantUser == playerName
        or (not job.claimantUser and job.claimantId == os.getComputerID())
    local isWorker = job.kind == "offer" and isPoster or job.kind ~= "offer" and isClaimant
    local isCustomer = job.kind == "offer" and isClaimant or job.kind ~= "offer" and isPoster
    local options = {}
    if isCustomer and job.status == "review" then
        table.insert(options, { id = "approve", label = "APPROVE", key = keys.a })
        table.insert(options, { id = "revise", label = "REQUEST REVISION", key = keys.r })
    end
    if isPoster and (job.status == "open" or job.status == "claimed") then
        table.insert(options, { id = "cancel", label = "CANCEL JOB", key = keys.x })
    end
    if isWorker and job.status == "claimed" then
        table.insert(options, { id = "submit", label = "SUBMIT WORK", key = keys.s })
    end
    if isClaimant and job.status == "claimed" then
        table.insert(options, { id = "withdraw", label = "WITHDRAW", key = keys.w })
    end
    if fromBoard and job.status == "open" and not isPoster then
        table.insert(options, { id = "claim", label = job.kind == "offer" and "HIRE" or "CLAIM JOB", key = keys.c })
    end
    table.insert(options, { id = "back", label = "BACK", key = keys.backspace })
    local width, height = term.getSize()
    local lines = {}
    local lineWidth = math.max(1, width - 2)
    appendWrapped(lines, job.title, lineWidth, colors.yellow)
    appendWrapped(lines, (job.kind == "offer" and "SERVICE BY  " or "POSTED BY  ")
        .. (job.posterName or "Unknown"), lineWidth, colors.lightGray)
    appendWrapped(lines, "REWARD  " .. job.reward, lineWidth, colors.lime)
    appendWrapped(lines, job.description, lineWidth, colors.white)
    if job.submission then appendWrapped(lines, "SUBMISSION  " .. job.submission, lineWidth, colors.yellow) end
    if job.reviewNote then appendWrapped(lines, "REVISION  " .. job.reviewNote, lineWidth, colors.orange) end
    if isWorker and job.status == "review" then
        appendWrapped(lines, "Waiting for the customer to review your work.", lineWidth, colors.lightGray)
    end
    local buttonRows = math.ceil(#options / math.min(3, #options))
    local pageSize = math.max(1, height - buttonRows - 3)
    if #lines > pageSize then
        table.insert(options, { id = "previous", label = "PREV (V)", key = keys.v })
        table.insert(options, { id = "next", label = "NEXT (N)", key = keys.n })
        buttonRows = math.ceil(#options / math.min(3, #options))
        pageSize = math.max(1, height - buttonRows - 3)
    end
    local pageCount = math.max(1, math.ceil(#lines / pageSize))
    local page, choice = 1, nil
    while not choice do
        drawHeader("RIFT", "JOBS  /  #" .. job.id .. "  /  " .. job.status:upper()
            .. (pageCount > 1 and ("  /  " .. page .. "/" .. pageCount) or ""))
        local first = (page - 1) * pageSize + 1
        for index = first, math.min(#lines, first + pageSize - 1) do
            writeAt(2, 4 + index - first, lines[index].text, lines[index].color)
        end
        local action = waitForAction(drawButtons(options))
        if action == "previous" then
            page = math.max(1, page - 1)
        elseif action == "next" then
            page = math.min(pageCount, page + 1)
        else
            choice = action
        end
    end

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
            response and "The customer can now review your work." or err)
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
if rift.account.saved() then
    local ok, result = rift.account.auto()
    if ok then
        playerName = result
    elseif result ~= "No saved Rift account." then
        showNotice("SAVED SIGN IN FAILED", tostring(result))
    end
end

while true do
    if playerName then
        drawHeader("RIFT", "JOBS  /  SIGNED IN AS " .. playerName:upper())
        writeAt(2, 5, "Request work, offer services, and track your jobs.", colors.white)
        local buttons = drawButtons({
            { id = "board", label = "BROWSE JOBS", key = keys.b },
            { id = "mine", label = "MY JOBS", key = keys.m },
            { id = "post", label = "POST A JOB", key = keys.p },
            { id = "offer", label = "OFFER SERVICE", key = keys.o },
            { id = "signout", label = "SIGN OUT", key = keys.s },
            { id = "quit", label = "QUIT", key = keys.q },
        })
        local choice = waitForAction(buttons)
        if choice == "post" then
            postJob("request")
        elseif choice == "offer" then
            postJob("offer")
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
        playerName = rift.account.signIn()
        if not playerName then break end
    end
end