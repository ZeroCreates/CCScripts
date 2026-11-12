
local SYSTEM_APP_DIRECTORY = "/.launcher/apps"
local DOWNLOADER_PATH = SYSTEM_APP_DIRECTORY .. "/app-downloader.lua"
local SYSTEM_FILE_BROWSER_PATH = SYSTEM_APP_DIRECTORY .. "/file-browser.lua"
local LUA_CONSOLE_PATH = "/.launcher/recovery/apps/lua-console.lua"
local RECOVERY_PROFILE_INSPECTOR_PATH = "recovery://profile-inspector"
local LEGACY_CLOUD_PATH = SYSTEM_APP_DIRECTORY .. "/cloud.lua"
local SETTINGS_PROGRAM_PATH = SYSTEM_APP_DIRECTORY .. "/settings.lua"
local HOST_BASE_URL = "https://rift.zerocreates.org/"
local LAUNCHER_PATH = "/launcher.lua"
local nativeFs = fs
local nativeOs = os
local nativeRequire = require
local nativePullEvent = nativeOs.pullEvent
local nativePullEventRaw = nativeOs.pullEventRaw

-- Black box recorder: every entry is appended and closed at once, so it survives crashes and reboots.
local BOOT_LOG_PATH = "/.launcher/system/boot.log"
local BOOT_LOG_OLD_PATH = BOOT_LOG_PATH .. ".old"
local BOOT_LOG_LIMIT = 16384

local function bootLog(text)
    pcall(function()
        if fs.getFreeSpace("/") < 4096 then return end
        if fs.exists(BOOT_LOG_PATH) and fs.getSize(BOOT_LOG_PATH) > BOOT_LOG_LIMIT then
            if fs.exists(BOOT_LOG_OLD_PATH) then fs.delete(BOOT_LOG_OLD_PATH) end
            fs.move(BOOT_LOG_PATH, BOOT_LOG_OLD_PATH)
        end
        local handle = fs.open(BOOT_LOG_PATH, "a")
        if not handle then return end
        handle.write(string.format("[d%d %s +%ds] %s\n", nativeOs.day("local"),
            textutils.formatTime(nativeOs.time("local"), true), math.floor(nativeOs.clock()),
            tostring(text):gsub("[%c]", " "):sub(1, 300)))
        handle.close()
    end)
end
local sessionMenuAllowed = false
local showSessionMenu
local lockScreen
local screenLocked = false
local lastActivity = 0
-- Replaced once settings load; defaults keep early boot and status-bar code safe.
local idleLockMinutes = function() return 0 end
local bootLogoEnabled = function() return true end
local clockTime = function() return textutils.formatTime(nativeOs.time("local"), true) end
local activeApps = 0
local driverThreads = {}
local closeAppRequested = false
local inAppChain = false
local pendingSessionAction
-- Tracks Alt so the terminate menu can reveal the hidden Services list (Alt + Ctrl+T).
local altState = { left = false, right = false }
local rawPullEventRaw = nativePullEventRaw
local function unfilteredPullEventRaw(filter)
    local event = table.pack(rawPullEventRaw(filter))
    if event[1] == "key" and event[2] == keys.leftAlt then altState.left = true
    elseif event[1] == "key" and event[2] == keys.rightAlt then altState.right = true
    elseif event[1] == "key_up" and event[2] == keys.leftAlt then altState.left = false
    elseif event[1] == "key_up" and event[2] == keys.rightAlt then altState.right = false end
    return table.unpack(event, 1, event.n)
end
-- Terminate never reaches the launcher; it opens the session menu instead.
nativePullEventRaw = function(filter)
    -- Inside the app's coroutine chain, yielding hands control back to the launcher's driver.
    -- Outside it (ComputerCraft's event pump), yielding would stall everything.
    local function abandonApp()
        while true do coroutine.yield("rift_close_app") end
    end
    while true do
        if closeAppRequested and activeApps > 0 and inAppChain then abandonApp() end
        local event = table.pack(unfilteredPullEventRaw(filter))
        if closeAppRequested and activeApps > 0 then
            if inAppChain then abandonApp() end
            return "rift_close_app"
        end
        if event[1] ~= "terminate" then
            return table.unpack(event, 1, event.n)
        end
        if sessionMenuAllowed and showSessionMenu then
            local inApp = activeApps > 0
            local action = showSessionMenu(inApp)
            if inApp then
                if action == "close_app" or action == "switch_user" or action == "logout" then
                    if action ~= "close_app" then pendingSessionAction = action end
                    closeAppRequested = true
                    if inAppChain then abandonApp() end
                    -- The event pump returns an event so every coroutine, including the driver, wakes.
                    return "rift_close_app"
                elseif action == "switch_task" and not inAppChain then
                    -- Wake the driver, which performs the switch without dropping the running app.
                    nativeOs.queueEvent("rift_switch")
                    return "rift_switch"
                end
            elseif action == "switch_user" or action == "logout" or action == "switch_task" then
                return "session_action", action
            end
            if filter == nil then return "menu_closed" end
        end
    end
end
nativeOs.pullEventRaw = nativePullEventRaw
nativeOs.pullEvent = function(filter)
    local event = table.pack(nativePullEventRaw(filter))
    if event[1] == "terminate" then error("Terminated", 0) end
    return table.unpack(event, 1, event.n)
end
local apps = {}
local selected = 1
local firstVisible = 1
local message = ""
local currentUser
local homeDirectory
local recoverySession = false
local showRecoveryProfileInspector
local profilePasswords = {}
local profileAdmins = {}
local authorizedProfiles = {}
local autoLaunchSession = false
local driverDepth = setmetatable({}, { __mode = "k" })

local statusBarActive = false
local statusBarRedraw
local notificationHistory = {}
local currentToast

local function playNotificationSound()
    if type(peripheral) ~= "table" then return end
    local ok, speaker = pcall(peripheral.find, "speaker")
    if ok and speaker and type(speaker.playNote) == "function" then
        pcall(speaker.playNote, "bell", 1, 18)
        pcall(speaker.playNote, "bell", 1, 22)
    end
end

-- Shared state for rift.permissions, rift.account and notification muting; one table keeps top-level locals low.
local riftModules = { muted = {} }

local function notifyUser(text, options)
    options = type(options) == "table" and options or {}
    text = tostring(text):gsub("[%c]", " ")
    if options.title ~= nil then
        text = tostring(options.title):gsub("[%c]", " "):sub(1, 30) .. ": " .. text
    end
    text = text:sub(1, 120)
    if options.app and riftModules.muted[tostring(options.app)] then return false end
    -- A key makes a notification unique: identical text is skipped, new text replaces the old entry.
    local key = type(options.key) == "string" and options.key:sub(1, 64) or nil
    if key then
        for index, entry in ipairs(notificationHistory) do
            if entry.key == key then
                if entry.text == text then return false end
                table.remove(notificationHistory, index)
                break
            end
        end
    end
    local priority = options.priority == "low" and "low" or options.priority == "high" and "high" or "normal"
    notificationHistory[#notificationHistory + 1] = {
        text = text, time = nativeOs.time("local"), key = key, app = options.app, priority = priority,
    }
    if #notificationHistory > 20 then table.remove(notificationHistory, 1) end
    local seconds = priority == "high" and 10 or priority == "low" and 3 or 5
    currentToast = { text = text, expires = nativeOs.clock() + seconds }
    bootLog("NOTIFY " .. (priority ~= "normal" and ("[" .. priority .. "] ") or "") .. text)
    if priority ~= "low" then playNotificationSound() end
    if statusBarRedraw then
        pcall(statusBarRedraw)
    else
        message = text
    end
    return true
end

local serviceTick = { timer = nil, deadline = 0 }
local updateCheck = { pending = false, notifiedFor = nil }
local UPDATE_CHECK_URL = HOST_BASE_URL .. "launcher.lua"

local function normalizeSource(text)
    text = text:gsub("^\239\187\191", "")
    text = text:gsub("\r\n", "\n")
    return (text:gsub("\r", "\n"))
end

local function startUpdateCheck()
    if updateCheck.pending or not http or type(http.request) ~= "function" then return end
    if pcall(http.request, UPDATE_CHECK_URL) then updateCheck.pending = true end
end

local function finishUpdateCheck(event)
    updateCheck.pending = false
    if event[1] ~= "http_success" or type(event[3]) ~= "table" then return end
    local response = event[3]
    local code = response.getResponseCode and response.getResponseCode()
    local ok, contents = pcall(response.readAll)
    pcall(response.close)
    if (code and code ~= 200) or not ok or type(contents) ~= "string" or contents == "" then
        bootLog("UPDATE-CHECK failed code=" .. tostring(code))
        return
    end
    contents = normalizeSource(contents)
    if updateCheck.notifiedFor == contents then return end
    local file = fs.open(LAUNCHER_PATH, "r")
    local current = file and normalizeSource(file.readAll())
    if file then file.close() end
    if current == contents then
        bootLog("UPDATE-CHECK up to date")
        return
    end
    updateCheck.notifiedFor = contents
    bootLog("UPDATE-CHECK new launcher available (" .. #contents .. " bytes)")
    notifyUser("Launcher update available. Reboot to apply it.")
end

-- Background services: interval jobs and event hooks that run alongside any app.
local services = {
    {
        name = "update-check", interval = 1800, nextRun = nativeOs.clock() + 1800,
        run = startUpdateCheck,
        onEvent = function(event)
            if updateCheck.pending and (event[1] == "http_success" or event[1] == "http_failure")
                and event[2] == UPDATE_CHECK_URL then
                finishUpdateCheck(event)
                return true
            end
        end,
    },
    {
        name = "disk-watch",
        onEvent = function(event)
            if event[1] == "disk" then
                bootLog("DISK inserted " .. tostring(event[2]))
                notifyUser("Disk inserted (" .. tostring(event[2]) .. ").")
            elseif event[1] == "disk_eject" then
                bootLog("DISK removed " .. tostring(event[2]))
                notifyUser("Disk removed (" .. tostring(event[2]) .. ").")
            elseif event[1] == "peripheral" or event[1] == "peripheral_detach" then
                bootLog("PERIPHERAL " .. event[1] .. " " .. tostring(event[2]))
            elseif event[1] == "monitor_resize" or event[1] == "term_resize" then
                bootLog("DISPLAY " .. event[1])
            end
        end,
    },
}

-- Returns true when the event belonged to a service and should not reach apps.
local function serviceHandle(event)
    local now = nativeOs.clock()
    local name = event[1]
    local consumed = false
    if name == "key" or name == "char" or name == "mouse_click" or name == "mouse_scroll"
        or name == "mouse_drag" or name == "paste" then
        lastActivity = now
    end
    if name == "timer" and event[2] == serviceTick.timer then
        serviceTick.timer = nil
        consumed = true
    end
    if not serviceTick.timer or now > serviceTick.deadline + 5 then
        serviceTick.timer = nativeOs.startTimer(15)
        serviceTick.deadline = now + 15
    end
    if name == "rift_lock" then
        consumed = true
        bootLog("LOCK requested by " .. tostring(currentUser))
        if lockScreen and not lockScreen() then
            notifyUser("Set a password for this account to use the lock screen.")
        end
    elseif sessionMenuAllowed and currentUser and not screenLocked then
        local minutes = idleLockMinutes()
        if minutes > 0 and now - lastActivity >= minutes * 60 then
            if not (lockScreen and lockScreen()) then lastActivity = now end
        end
    end
    for _, service in ipairs(services) do
        if service.interval and now >= service.nextRun then
            service.nextRun = now + service.interval
            pcall(service.run)
        end
        if service.onEvent then
            local ok, result = pcall(service.onEvent, event)
            if ok and result then consumed = true end
        end
    end
    return consumed
end

local function drawStatusBar(target, statusWindow)
    local width = target.getSize()
    local isColor = target.isColor()
    if currentToast and nativeOs.clock() >= currentToast.expires then currentToast = nil end
    local clock = clockTime()
    local label = currentToast and currentToast.text
        or ("Rift Launcher" .. (currentUser and ("  " .. currentUser) or ""))
    local rightText = clock .. " "
    local available = math.max(0, width - 6 - #rightText)
    label = (" " .. label):sub(1, available)
    local line = label .. string.rep(" ", available - #label) .. rightText
    local previousBackground, previousText = target.getBackgroundColor(), target.getTextColor()
    target.setCursorPos(1, 1)
    target.setBackgroundColor(isColor and colors.gray or colors.black)
    target.setTextColor(colors.white)
    target.write(line)
    target.setBackgroundColor(isColor and colors.lightGray or colors.white)
    target.setTextColor(colors.black)
    target.write(" _ ")
    target.setBackgroundColor(isColor and colors.red or colors.white)
    target.setTextColor(isColor and colors.white or colors.black)
    target.write(" X ")
    target.setBackgroundColor(previousBackground)
    target.setTextColor(previousText)
    if statusWindow and statusWindow.restoreCursor then statusWindow.restoreCursor() end
end

local rawInputEvents = {
    key = true, key_up = true, char = true, paste = true, terminate = true,
    mouse_click = true, mouse_up = true, mouse_drag = true, mouse_scroll = true,
}
local tasks = {}
-- Headless background services (see the "Background services" section); state lives in one table.
local bgServices = { list = {}, restarts = {}, crashes = {}, status = {} }
local nextTaskId = 1
local foregroundTask
local pendingSwitchTask
local nextTaskName
local statusTimerId

local function removeTask(task)
    for index, candidate in ipairs(tasks) do
        if candidate == task then
            table.remove(tasks, index)
            return
        end
    end
end

local function findTask(id)
    for _, task in ipairs(tasks) do
        if task.id == id then return task end
    end
end

local function resumeTask(task, event, background)
    local previousTerm = term.current()
    local previousChain = inAppChain
    inAppChain = true
    term.redirect(task.term)
    local previousQuiet = bgServices.quiet
    local previousApp = bgServices.currentApp
    bgServices.currentApp = task.appPath or previousApp
    bgServices.quiet = background == true
    local packed = table.pack(coroutine.resume(task.co, table.unpack(event, 1, event.n)))
    bgServices.currentApp = previousApp
    bgServices.quiet = previousQuiet
    task.term = term.current()
    term.redirect(previousTerm)
    inAppChain = previousChain
    task.packed = packed
    task.filter = packed[2]
    if coroutine.status(task.co) == "dead" then task.finished = true end
end

-- Gives every background task the non-input events a foreground app would see.
local function pumpBackground(event)
    local name = event[1]
    if serviceHandle(event) then return true end
    if name == "term_resize" then
        local width, height = term.native().getSize()
        for _, task in ipairs(tasks) do
            pcall(task.window.reposition, 1, 2, width, height - 1)
        end
    end
    if rawInputEvents[name] or closeAppRequested or pendingSessionAction then return end
    if type(name) == "string" and (name:sub(1, 5) == "rift_" or name == "session_action"
        or name == "menu_closed") then
        return
    end
    if bgServices.pump then bgServices.pump(event) end
    for _, task in ipairs({ table.unpack(tasks) }) do
        if task ~= foregroundTask and not task.finished
            and (task.filter == nil or task.filter == name) then
            resumeTask(task, event, true)
            if task.finished then
                removeTask(task)
                if task.packed[1] == false then
                    notifyUser(task.name .. " crashed: " .. tostring(task.packed[2]))
                else
                    notifyUser(task.name .. " finished.")
                end
            end
        end
    end
end

local function showTask(task, savedTerm)
    foregroundTask = task
    local width, height = savedTerm.getSize()
    task.window.reposition(1, 2, width, height - 1, savedTerm)
    task.window.setVisible(true)
    term.redirect(task.term)
    statusBarRedraw = function() drawStatusBar(savedTerm, task.window) end
    statusBarRedraw()
end

local function runForeground(task, savedTerm)
    local parent = coroutine.running() or "main"
    driverDepth[parent] = (driverDepth[parent] or 0) + 1
    local previousDriver = driverThreads[parent]
    driverThreads[parent] = true
    closeAppRequested = false
    activeApps = activeApps + 1
    statusBarActive = true
    showTask(task, savedTerm)
    statusTimerId = nativeOs.startTimer(1)
    if not task.started then
        task.started = true
        resumeTask(task, task.startArgs)
    end

    local outcome
    while true do
        if pendingSwitchTask then
            local target = findTask(pendingSwitchTask)
            pendingSwitchTask = nil
            if target and target ~= task and not target.finished then
                task.window.setVisible(false)
                task = target
                showTask(task, savedTerm)
            end
        end
        if task.finished then
            outcome = "done"
            break
        end
        if pendingSessionAction or closeAppRequested then
            outcome = "killed"
            break
        end
        local event = table.pack(unfilteredPullEventRaw())
        local name = event[1]
        local deliver = true
        local width = savedTerm.getSize()
        if name == "rift_switch" then
            deliver = false
        elseif name == "timer" and event[2] == statusTimerId then
            statusBarRedraw()
            statusTimerId = nativeOs.startTimer(1)
            deliver = false
        elseif name == "term_resize" then
            task.window.reposition(1, 2, width, select(2, savedTerm.getSize()) - 1)
            statusBarRedraw()
        elseif name == "mouse_click" or name == "mouse_up" or name == "mouse_drag"
            or name == "mouse_scroll" then
            if event[4] == 1 then
                if name == "mouse_click" then
                    if event[3] > width - 3 then
                        outcome = "killed"
                        break
                    elseif event[3] > width - 6 then
                        outcome = "minimized"
                        break
                    end
                end
                deliver = false
            else
                event[4] = event[4] - 1
            end
        end
        if name == "terminate" and (driverDepth[task.co] or 0) == 0 then
            local menuOk, action = pcall(showSessionMenu, true)
            if not menuOk then action = "exit" end
            if action == "close_app" then
                outcome = "killed"
                break
            elseif action == "switch_user" or action == "logout" then
                pendingSessionAction = action
                outcome = "killed"
                break
            end
        else
            if pumpBackground(event) then deliver = false end
            if deliver and not task.finished
                and (task.filter == nil or task.filter == name or name == "terminate") then
                resumeTask(task, event)
            end
        end
    end

    driverDepth[parent] = driverDepth[parent] - 1
    activeApps = activeApps - 1
    driverThreads[parent] = previousDriver
    statusBarActive = false
    statusBarRedraw = nil
    foregroundTask = nil
    if closeAppRequested or pendingSessionAction then outcome = "killed" end
    term.redirect(savedTerm)
    if outcome == "minimized" then
        task.window.setVisible(false)
    else
        removeTask(task)
    end
    if outcome == "done" then
        return table.unpack(task.packed, 1, task.packed.n)
    end
    closeAppRequested = false
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorBlink(false)
    term.clear()
    term.setCursorPos(1, 1)
    return true, true
end

-- Nested programs (apps launched from inside an app) run in the parent's window.
local function runNested(fn, ...)
    local parent = coroutine.running() or "main"
    driverDepth[parent] = (driverDepth[parent] or 0) + 1
    local previousDriver = driverThreads[parent]
    driverThreads[parent] = true
    local savedTerm = term.current()
    closeAppRequested = false
    activeApps = activeApps + 1
    local co = coroutine.create(fn)
    local previousChain = inAppChain
    inAppChain = true
    local packed = table.pack(coroutine.resume(co, ...))
    inAppChain = previousChain
    local closed = false
    while coroutine.status(co) ~= "dead" do
        if pendingSessionAction or closeAppRequested then
            closed = true
            break
        end
        local event = table.pack(unfilteredPullEventRaw())
        local name = event[1]
        if name == "timer" and statusBarRedraw and event[2] == statusTimerId then
            statusBarRedraw()
            statusTimerId = nativeOs.startTimer(1)
        elseif name == "terminate" and (driverDepth[co] or 0) == 0 then
            local menuOk, action = pcall(showSessionMenu, true)
            if not menuOk then action = "exit" end
            if action == "close_app" then
                closed = true
                break
            elseif action == "switch_user" or action == "logout" then
                pendingSessionAction = action
                closed = true
                break
            end
        elseif name ~= "rift_switch" then
            pumpBackground(event)
            if packed[2] == nil or name == packed[2] or name == "terminate" then
                local resumeChain = inAppChain
                inAppChain = true
                packed = table.pack(coroutine.resume(co, table.unpack(event, 1, event.n)))
                inAppChain = resumeChain
            end
        end
    end
    driverDepth[parent] = driverDepth[parent] - 1
    activeApps = activeApps - 1
    driverThreads[parent] = previousDriver
    if closeAppRequested or pendingSessionAction then closed = true end
    if closed then
        closeAppRequested = false
        term.redirect(savedTerm)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.setCursorBlink(false)
        term.clear()
        term.setCursorPos(1, 1)
        return true, true
    end
    return table.unpack(packed, 1, packed.n)
end

-- Top-level programs become tasks: each has its own window under the status bar and can run in the background.
local function runClosable(fn, ...)
    local savedTerm = term.current()
    local width, height = savedTerm.getSize()
    if statusBarActive or height < 8 or not window or not window.create then
        return runNested(fn, ...)
    end
    local task = {
        id = nextTaskId,
        name = nextTaskName or "App",
        co = coroutine.create(fn),
        startArgs = table.pack(...),
        appPath = bgServices.nextPath,
    }
    bgServices.nextPath = nil
    nextTaskId = nextTaskId + 1
    nextTaskName = nil
    task.window = window.create(savedTerm, 1, 2, width, height - 1, false)
    if type(savedTerm.getPaletteColor) == "function" and type(task.window.setPaletteColor) == "function" then
        for index = 0, 15 do
            local color = 2 ^ index
            pcall(task.window.setPaletteColor, color, savedTerm.getPaletteColor(color))
        end
    end
    task.window.setBackgroundColor(colors.black)
    task.window.setTextColor(colors.white)
    task.window.clear()
    task.window.setCursorPos(1, 1)
    task.term = task.window
    tasks[#tasks + 1] = task
    return runForeground(task, savedTerm)
end

local USER_ROOT = "/users"
local SYSTEM_DIRECTORY = "/.launcher"
local SETTINGS_PATH = SYSTEM_DIRECTORY .. "/settings.json"
local PROFILE_PASSWORDS_PATH = SYSTEM_DIRECTORY .. "/profile-passwords.json"
local PROFILE_ADMINS_PATH = SYSTEM_DIRECTORY .. "/profile-admins.json"
local ENCRYPTION_KEY_PATH = SYSTEM_DIRECTORY .. "/.data-key"
local LEGACY_SETTINGS_PATH = "/.launcher-settings.json"
local STARTUP_PATH = "/startup.lua"
local STARTUP_TEMPORARY_PATH = SYSTEM_DIRECTORY .. "/startup.lua.tmp"

local function displayLauncherPath(path)
    local normalizedPath = tostring(path):gsub("^/+", "")
    local systemProgramsPath = SYSTEM_APP_DIRECTORY:gsub("^/+", "")
    if normalizedPath == systemProgramsPath then return "S://" end
    if normalizedPath:sub(1, #systemProgramsPath + 1) == systemProgramsPath .. "/" then
        return "S://" .. normalizedPath:sub(#systemProgramsPath + 1)
    end
    local launcherPath = LAUNCHER_PATH:gsub("^/+", "")
    if normalizedPath == launcherPath then return "S://" .. launcherPath end
    if normalizedPath:sub(1, #launcherPath + 1) == launcherPath .. "." then
        return "S://" .. normalizedPath
    end
    if homeDirectory then
        local normalizedHome = homeDirectory:gsub("^/+", ""):gsub("/+$", "")
        if normalizedPath == normalizedHome then return "H://" end
        if normalizedPath:sub(1, #normalizedHome + 1) == normalizedHome .. "/" then
            return "H://" .. normalizedPath:sub(#normalizedHome + 2)
        end
    end
    return tostring(path)
end

local function displayLauncherMessage(text)
    text = tostring(text)
    local systemProgramsPattern = SYSTEM_APP_DIRECTORY:gsub("^/+", ""):gsub("([^%w])", "%%%1")
    text = text:gsub("/" .. systemProgramsPattern .. "/", "S://")
        :gsub("/" .. systemProgramsPattern .. "%f[%W]", "S://")
    local launcherPattern = LAUNCHER_PATH:gsub("^/+", ""):gsub("([^%w])", "%%%1")
    text = text:gsub("/" .. launcherPattern .. "([%p%s])", "S://" .. LAUNCHER_PATH:gsub("^/+", "") .. "%1")
        :gsub("/" .. launcherPattern .. "$", "S://" .. LAUNCHER_PATH:gsub("^/+", ""))
    if homeDirectory then
        local homePattern = homeDirectory:gsub("^/+", ""):gsub("([^%w])", "%%%1")
        text = text:gsub("/" .. homePattern .. "/", "H://")
            :gsub("/" .. homePattern .. "%f[%W]", "H://")
    end
    text = text:gsub("/users/([%w_-]+)/", "H@%1://")
        :gsub("/users/([%w_-]+)%f[%W]", "H@%1://")
    return text
end

local THEMES = {
    { name = "Ocean", accent = colors.cyan, highlight = colors.blue },
    { name = "Forest", accent = colors.lime, highlight = colors.green },
    { name = "Sunset", accent = colors.orange, highlight = colors.red },
    { name = "Violet", accent = colors.purple, highlight = colors.magenta },
    { name = "Custom", accent = colors.cyan, highlight = colors.blue },
}
local DEFAULT_CYAN = { 0.298, 0.600, 0.698 }
local DEFAULT_BLUE = { 0.200, 0.400, 0.800 }

local bootStatus

local function drawBootScreen()
    if not bootLogoEnabled() and not bootStatus then
        term.setBackgroundColor(colors.black)
        term.clear()
        return
    end
    local width, height = term.getSize()
    local accent = term.isColor() and colors.cyan or colors.white
    local centerRow = math.max(1, math.floor(height / 2))
    local logo = {
        " RRRR   III  FFFF  TTTTT",
        "R   R   I   F       T",
        "RRRR    I   FFF     T",
        "R R     I   F       T",
        "R  RR  III  F       T",
    }
    local function writeCentered(row, text, color)
        text = tostring(text):sub(1, width)
        term.setCursorPos(math.max(1, math.floor((width - #text) / 2) + 1), row)
        term.setTextColor(color)
        term.write(text)
    end

    term.setBackgroundColor(colors.black)
    term.clear()
    if width >= 24 and height >= 12 then
        for index, line in ipairs(logo) do
            writeCentered(centerRow - 4 + index, line, accent)
        end
        writeCentered(math.min(height, centerRow + 1), "LAUNCHER", colors.lightGray)
    else
        writeCentered(math.max(1, centerRow - 1), "RIFT", accent)
        writeCentered(math.min(height, centerRow + 1), "LAUNCHER", colors.lightGray)
    end
    if bootStatus then writeCentered(height, bootStatus, colors.orange) end
end

local RECOVERY_DIRECTORY = "/.launcher/system"
local GOOD_LAUNCHER_PATH = RECOVERY_DIRECTORY .. "/launcher.good"
local BAD_LAUNCHER_PATH = RECOVERY_DIRECTORY .. "/launcher.bad"
local PENDING_BOOT_PATH = RECOVERY_DIRECTORY .. "/boot.pending"
local function viewBootLog()
    local contents = ""
    for _, path in ipairs({ BOOT_LOG_OLD_PATH, BOOT_LOG_PATH }) do
        if fs.exists(path) then
            local handle = fs.open(path, "r")
            if handle then contents = contents .. (handle.readAll() or ""); handle.close() end
        end
    end
    if contents == "" then contents = "The boot log is empty.\n" end
    local lines = {}
    for line in contents:gmatch("(.-)\n") do lines[#lines + 1] = line end
    local _, startHeight = term.getSize()
    local top = math.max(1, #lines - (startHeight - 3))
    while true do
        local width, height = term.getSize()
        local page = height - 2
        top = math.max(1, math.min(top, math.max(1, #lines - page + 1)))
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setTextColor(term.isColor() and colors.cyan or colors.white)
        term.setCursorPos(1, 1)
        term.write(("Black box " .. top .. "-" .. math.min(#lines, top + page - 1) .. "/" .. #lines
            .. " Up/Dn PgUp/PgDn End C=clear"):sub(1, width))
        term.setTextColor(colors.white)
        for row = 1, page do
            local line = lines[top + row - 1]
            if not line then break end
            term.setCursorPos(1, row + 1)
            term.write(line:sub(1, width))
        end
        local event, key = unfilteredPullEventRaw()
        if event == "key" then
            if key == keys.up then
                top = top - 1
            elseif key == keys.down then
                top = top + 1
            elseif key == keys.pageUp then
                top = top - page
            elseif key == keys.pageDown then
                top = top + page
            elseif key == keys.home then
                top = 1
            elseif key == keys["end"] then
                top = #lines
            elseif key == keys.c then
                pcall(fs.delete, BOOT_LOG_PATH)
                pcall(fs.delete, BOOT_LOG_OLD_PATH)
                lines, top = { "The boot log is empty." }, 1
            else
                return
            end
        elseif event == "mouse_scroll" then
            top = top + key * 3
        end
    end
end
local function startBootPhase()
    drawBootScreen()
    sleep(0.7)
end

-- Shows the boot logo and reports whether R was held while it was up.
local function bootRecoveryRequested()
    drawBootScreen()
    local timer = nativeOs.startTimer(0.7)
    local requested = false
    while true do
        local event, value = unfilteredPullEventRaw()
        if event == "timer" and value == timer then break end
        if event == "key" and value == keys.r then requested = true end
    end
    return requested
end

local function readWholeFile(path)
    local file = fs.exists(path) and fs.open(path, "r")
    if not file then return nil end
    local contents = file.readAll()
    file.close()
    return contents
end

local function restoreGoodLauncher()
    if not fs.exists(GOOD_LAUNCHER_PATH) then return false end
    if fs.exists(LAUNCHER_PATH) then
        if fs.exists(BAD_LAUNCHER_PATH) then fs.delete(BAD_LAUNCHER_PATH) end
        pcall(fs.copy, LAUNCHER_PATH, BAD_LAUNCHER_PATH)
        fs.delete(LAUNCHER_PATH)
    end
    local ok = pcall(fs.copy, GOOD_LAUNCHER_PATH, LAUNCHER_PATH)
    return ok and fs.exists(LAUNCHER_PATH)
end

-- A boot marker left over from a previous update means that update never reached the home screen.
-- "pending" is written by the updater just before rebooting; the new launcher promotes it to
-- "booting". Finding "booting" at startup means the new launcher never reached the home screen.
local function recoverFromFailedUpdate()
    if not fs.exists(PENDING_BOOT_PATH) then return false end
    local state = readWholeFile(PENDING_BOOT_PATH)
    if state ~= "booting" then
        local marker = fs.open(PENDING_BOOT_PATH, "w")
        if marker then marker.write("booting"); marker.close() end
        bootLog("First boot of an updated launcher")
        return false
    end
    fs.delete(PENDING_BOOT_PATH)
    bootLog("Previous update never reached the home screen; restoring last good launcher")
    if restoreGoodLauncher() and type(nativeOs.reboot) == "function" then
        nativeOs.reboot()
        while true do sleep(1) end
    end
    return true
end

local function recoveryMenu()
    local options = {
        { "Continue boot (skip update)", "continue" },
        { "Sign in as Recovery Account", "recovery" },
        { "Retry update", "retry" },
        { "View boot log", "log" },
        { "Restore last good launcher", "restore" },
        { "Reboot", "reboot" },
    }
    local choice, note = 1, ""
    while true do
        local width = term.getSize()
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setTextColor(term.isColor() and colors.cyan or colors.white)
        term.setCursorPos(2, 2)
        term.write("Rift Launcher Recovery")
        for index, option in ipairs(options) do
            term.setCursorPos(2, 3 + index)
            term.setTextColor(index == choice and colors.white or colors.lightGray)
            term.write((index == choice and "> " or "  ") .. option[1])
        end
        term.setCursorPos(2, 4 + #options + 1)
        term.setTextColor(colors.lightGray)
        term.write(note:sub(1, width - 2))
        local event, key = unfilteredPullEventRaw()
        if event == "key" then
            if key == keys.up then
                choice = math.max(1, choice - 1)
            elseif key == keys.down then
                choice = math.min(#options, choice + 1)
            elseif key == keys.enter then
                local action = options[choice][2]
                if action == "retry" and fs.exists(BAD_LAUNCHER_PATH) then fs.delete(BAD_LAUNCHER_PATH) end
                if action == "continue" or action == "retry" then
                    bootLog("Recovery menu: " .. action)
                    return action
                elseif action == "recovery" then
                    bootLog("Recovery menu: recovery account selected")
                    return action
                elseif action == "log" then
                    viewBootLog()
                elseif action == "restore" then
                    if restoreGoodLauncher() then
                        bootLog("Recovery menu: restored last good launcher")
                        nativeOs.reboot()
                        while true do sleep(1) end
                    end
                    note = "No backup is available."
                else
                    nativeOs.reboot()
                    while true do sleep(1) end
                end
            end
        end
    end
end

local skipLauncherUpdate = false
local recoveryLoginRequested = false

local function autoUpdateLauncher()
    drawBootScreen()
    if skipLauncherUpdate then
        bootStatus = "Update skipped: recovery mode"
        drawBootScreen()
        sleep(2.5)
        bootStatus = nil
        return
    end
    local function fail(reason)
        bootLog("Launcher update skipped: " .. tostring(reason))
        bootStatus = "Update skipped: " .. tostring(reason)
        drawBootScreen()
        sleep(2.5)
        bootStatus = nil
    end
    if not http or type(http.get) ~= "function" then
        return fail("HTTP is disabled")
    end

    local requested, response, requestError = pcall(http.get, HOST_BASE_URL .. "launcher.lua")
    if not requested or not response then
        return fail(requested and (response == nil and requestError) or response or "request failed")
    end

    local responseCode = response.getResponseCode and response.getResponseCode()
    if responseCode and responseCode ~= 200 then
        response.close()
        return fail("server returned " .. tostring(responseCode))
    end

    local readOk, contents = pcall(response.readAll)
    response.close()
    if not readOk or type(contents) ~= "string" or contents == "" then
        return fail("empty download")
    end

    contents = contents:gsub("^\239\187\191", "")
    contents = contents:gsub("\r\n", "\n"):gsub("\r", "\n")
    if fs.exists(LAUNCHER_PATH) then
        local currentFile = fs.open(LAUNCHER_PATH, "r")
        if currentFile then
            local currentContents = currentFile.readAll()
            currentFile.close()
            currentContents = currentContents:gsub("^\239\187\191", "")
            currentContents = currentContents:gsub("\r\n", "\n"):gsub("\r", "\n")
            if contents == currentContents then
                bootLog("Launcher is up to date")
                bootStatus = "Launcher is up to date"
                drawBootScreen()
                sleep(1)
                bootStatus = nil
                return
            end
        end
    end

    local compiled, compileError = (loadstring or load)(contents, "@launcher.lua")
    if not compiled then
        return fail("host file invalid: " .. tostring(compileError))
    end

    local knownBad = readWholeFile(BAD_LAUNCHER_PATH)
    if knownBad and (knownBad:gsub("\r\n", "\n"):gsub("\r", "\n")) == contents then
        return fail("host version previously failed")
    end

    drawBootScreen()
    fs.makeDir(RECOVERY_DIRECTORY)
    if fs.exists(LAUNCHER_PATH) then
        if fs.exists(GOOD_LAUNCHER_PATH) then fs.delete(GOOD_LAUNCHER_PATH) end
        pcall(fs.copy, LAUNCHER_PATH, GOOD_LAUNCHER_PATH)
    end
    local temporary = LAUNCHER_PATH .. ".update-tmp"
    local backup = LAUNCHER_PATH .. ".update-bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file = fs.open(temporary, "w")
    if not file then
        return fail("cannot write " .. temporary)
    end
    local wrote, writeError = pcall(file.write, contents)
    local closed, closeError = pcall(file.close)
    if not wrote or not closed then
        if fs.exists(temporary) then fs.delete(temporary) end
        return fail("write failed: " .. tostring(writeError or closeError))
    end

    if fs.exists(LAUNCHER_PATH) then
        local backedUp, backupError = pcall(fs.move, LAUNCHER_PATH, backup)
        if not backedUp then
            fs.delete(temporary)
            return fail("backup failed: " .. tostring(backupError))
        end
    end

    local moved, moveError = pcall(fs.move, temporary, LAUNCHER_PATH)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then pcall(fs.move, backup, LAUNCHER_PATH) end
        return fail("install failed: " .. tostring(moveError))
    end
    if fs.exists(backup) then fs.delete(backup) end

    bootLog("Launcher updated (" .. #contents .. " bytes); rebooting")
    local marker = fs.open(PENDING_BOOT_PATH, "w")
    if marker then
        marker.write("pending")
        marker.close()
    end
    drawBootScreen()
    if type(nativeOs.reboot) == "function" then nativeOs.reboot() end
end

local function validHexColor(value)
    return type(value) == "string" and value:match("^#?%x%x%x%x%x%x$") ~= nil
end

local function hexToRgb(value)
    value = value:gsub("^#", "")
    return tonumber(value:sub(1, 2), 16) / 255,
        tonumber(value:sub(3, 4), 16) / 255,
        tonumber(value:sub(5, 6), 16) / 255
end

local settings = {
    theme = 1,
    customAccent = "#4C99B2",
    customHighlight = "#3366CC",
    alphabetical = true,
    autoLoginUser = nil,
    autoLaunchPath = nil,
    rift = {},
}
local encryptionKey
local settingsNeedEncryption = false
local settingsProtectionError

local function xorByte(first, second)
    local result, bit = 0, 1
    while first > 0 or second > 0 do
        if first % 2 ~= second % 2 then result = result + bit end
        first = math.floor(first / 2)
        second = math.floor(second / 2)
        bit = bit * 2
    end
    return result
end

local function cryptData(contents)
    if type(encryptionKey) ~= "string" then
        return nil, "The local data key has not been loaded."
    end
    local keyBytes = {}
    for index = 1, #encryptionKey, 2 do
        keyBytes[#keyBytes + 1] = tonumber(encryptionKey:sub(index, index + 1), 16)
    end
    local state = 1
    for _, value in ipairs(keyBytes) do
        state = (state * 257 + value) % 2147483647
    end
    local output = {}
    for index = 1, #contents do
        state = (state * 48271) % 2147483647
        local mask = (state % 256 + keyBytes[(index - 1) % #keyBytes + 1]) % 256
        output[index] = string.char(xorByte(contents:byte(index), mask))
    end
    return table.concat(output)
end

local function encryptData(contents)
    local encrypted, encryptError = cryptData(contents)
    if not encrypted then return nil, encryptError end
    local encoded = {}
    for index = 1, #encrypted do
        encoded[index] = string.format("%02X", encrypted:byte(index))
    end
    return "CCLOCAL1:" .. table.concat(encoded)
end

local function decryptData(contents)
    local prefix = "CCLOCAL1:"
    if contents:sub(1, #prefix) ~= prefix then return contents, false end
    local encoded = contents:sub(#prefix + 1)
    if #encoded % 2 ~= 0 or encoded:find("[^%x]") then
        return nil, true, "Encrypted data is malformed."
    end
    local encrypted = {}
    for index = 1, #encoded, 2 do
        encrypted[#encrypted + 1] = string.char(tonumber(encoded:sub(index, index + 1), 16))
    end
    local plaintext, decryptError = cryptData(table.concat(encrypted))
    if not plaintext then return nil, true, decryptError end
    return plaintext, true
end

local function ensureEncryptionKey()
    if fs.exists(ENCRYPTION_KEY_PATH) then
        if fs.isDir(ENCRYPTION_KEY_PATH) then
            return false, "The local data key path is a directory."
        end
        local file = fs.open(ENCRYPTION_KEY_PATH, "r")
        if not file then return false, "Could not read the local data key." end
        local savedKey = file.readAll()
        file.close()
        if type(savedKey) ~= "string" or #savedKey ~= 64 or savedKey:find("[^%x]") then
            return false, "The local data key is invalid; refusing to overwrite it."
        end
        encryptionKey = savedKey:upper()
        return true
    end

    local function containsEncryptedData(path)
        if not fs.exists(path) then return false end
        if fs.isDir(path) then
            for _, name in ipairs(fs.list(path)) do
                if containsEncryptedData(fs.combine(path, name)) then return true end
            end
            return false
        end
        local file = fs.open(path, "r")
        if not file then return false end
        local contents = file.readAll()
        file.close()
        return type(contents) == "string" and contents:sub(1, 9) == "CCLOCAL1:"
    end
    if containsEncryptedData(SETTINGS_PATH)
        or containsEncryptedData(PROFILE_PASSWORDS_PATH)
        or containsEncryptedData("/.launcher/user-data") then
        return false, "Encrypted data exists but the local data key is missing. Restore /.launcher/.data-key."
    end

    local made, makeError = pcall(fs.makeDir, SYSTEM_DIRECTORY)
    if not made then return false, "Could not create the local data folder: " .. tostring(makeError) end
    local seedSource
    if type(nativeOs.epoch) == "function" then
        local ok, epoch = pcall(nativeOs.epoch, "utc")
        if ok and type(epoch) == "number" then seedSource = epoch end
    end
    if not seedSource then
        seedSource = (nativeOs.time() or 0) * 1000 + (nativeOs.clock() or 0) * 1000
    end
    local computerId = type(nativeOs.getComputerID) == "function" and nativeOs.getComputerID() or 0
    local state = (math.floor(seedSource) + computerId * 104729) % 2147483647
    if state < 1 then state = 1 end
    local generated = {}
    for index = 1, 32 do
        state = (state * 48271) % 2147483647
        generated[index] = string.format("%02X", state % 256)
    end
    local newKey = table.concat(generated)
    local temporary = ENCRYPTION_KEY_PATH .. ".tmp"
    if fs.exists(temporary) then
        if fs.isDir(temporary) then
            return false, "Cannot create the local data key: temporary path is a directory."
        end
        fs.delete(temporary)
    end
    local file = fs.open(temporary, "w")
    if not file then return false, "Could not create the temporary local data key." end
    local wrote, writeError = pcall(file.write, newKey)
    local closed, closeError = pcall(file.close)
    if not wrote or not closed then
        if fs.exists(temporary) then fs.delete(temporary) end
        return false, "Could not save the local data key: "
            .. tostring(not wrote and writeError or closeError)
    end
    if fs.exists(ENCRYPTION_KEY_PATH) then
        fs.delete(temporary)
        return ensureEncryptionKey()
    end
    local moved, moveError = pcall(fs.move, temporary, ENCRYPTION_KEY_PATH)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        return false, "Could not install the local data key: " .. tostring(moveError)
    end
    encryptionKey = newKey
    return true
end

local function applyTheme()
    if not term.isColor() then return true end
    if settings.theme == #THEMES then
        if type(term.setPaletteColor) ~= "function" then
            message = "Custom themes require a color terminal with palette support."
            return false
        end
        local accentRed, accentGreen, accentBlue = hexToRgb(settings.customAccent)
        local highlightRed, highlightGreen, highlightBlue = hexToRgb(settings.customHighlight)
        term.setPaletteColor(colors.cyan, accentRed, accentGreen, accentBlue)
        term.setPaletteColor(colors.blue, highlightRed, highlightGreen, highlightBlue)
    elseif type(term.setPaletteColor) == "function" then
        term.setPaletteColor(colors.cyan, table.unpack(DEFAULT_CYAN))
        term.setPaletteColor(colors.blue, table.unpack(DEFAULT_BLUE))
    end
    return true
end

local function getThemeInfo()
    local theme = THEMES[settings.theme] or THEMES[1]
    return {
        index = settings.theme,
        accent = theme.accent,
        highlight = theme.highlight,
        accentHex = settings.customAccent,
        highlightHex = settings.customHighlight,
    }
end

local function createSystemEnvironment()
    local environment = {}
    for name, value in pairs(_ENV) do environment[name] = value end
    environment.launcherTheme = getThemeInfo()
    return environment
end

local function readPassword()
    local originalPullEvent = nativeOs.pullEvent
    local originalPullEventRaw = nativeOs.pullEventRaw
    local function pullEventWithoutTerminate(filter)
        while true do
            local event = { originalPullEventRaw(filter) }
            if event[1] ~= "terminate" then return table.unpack(event) end
        end
    end
    nativeOs.pullEvent = pullEventWithoutTerminate
    nativeOs.pullEventRaw = pullEventWithoutTerminate
    local ok, password = pcall(read, "*")
    nativeOs.pullEvent = originalPullEvent
    nativeOs.pullEventRaw = originalPullEventRaw
    if not ok then error(password, 0) end
    return password
end

local function isLuaFile(path)
    return not fs.isDir(path) and path:lower():match("%.lua$") ~= nil
end

local function loadSettings()
    local path = fs.exists(SETTINGS_PATH) and SETTINGS_PATH or LEGACY_SETTINGS_PATH
    if not fs.exists(path) then return end
    local file = fs.open(path, "r")
    if not file then
        message = "Could not read launcher settings."
        return
    end
    local contents = file.readAll()
    file.close()
    local decrypted, wasEncrypted, decryptError = decryptData(contents)
    if not decrypted then
        message = "Could not decrypt launcher settings: " .. tostring(decryptError)
        settingsProtectionError = message
        return
    end
    contents = decrypted
    if path == SETTINGS_PATH and not wasEncrypted then
        settingsNeedEncryption = true
    end
    local ok, saved = pcall(textutils.unserializeJSON, contents)
    if not ok or type(saved) ~= "table" then
        message = "Launcher settings are invalid; using defaults."
        if wasEncrypted then settingsProtectionError = "Encrypted launcher settings could not be decoded." end
        return
    end
    if type(saved.theme) == "number" and THEMES[saved.theme] then
        settings.theme = saved.theme
    end
    if validHexColor(saved.customAccent) then
        settings.customAccent = "#" .. saved.customAccent:gsub("^#", ""):upper()
    end
    if validHexColor(saved.customHighlight) then
        settings.customHighlight = "#" .. saved.customHighlight:gsub("^#", ""):upper()
    end
    if type(saved.alphabetical) == "boolean" then settings.alphabetical = saved.alphabetical end
    settings.autoLoginUser = nil
    settings.autoLaunchPath = nil
    if type(saved.autoLoginUser) == "string" and saved.autoLoginUser:match("^[%w_-]+$") then
        settings.autoLoginUser = saved.autoLoginUser
    end
    if type(saved.autoLaunchPath) == "string" and #saved.autoLaunchPath <= 256
        and not saved.autoLaunchPath:find("..", 1, true) then
        settings.autoLaunchPath = saved.autoLaunchPath
    end
    if type(saved.rift) == "table" then
        settings.rift = {}
        for key, value in pairs(saved.rift) do
            local valueType = type(value)
            if type(key) == "string" and #key <= 64
                and (valueType == "string" or valueType == "number" or valueType == "boolean") then
                settings.rift[key] = value
            end
        end
    end
    applyTheme()
end

local function saveSettings()
    fs.makeDir(SYSTEM_DIRECTORY)
    local temporary = SETTINGS_PATH .. ".tmp"
    local backup = SETTINGS_PATH .. ".bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file = fs.open(temporary, "w")
    if not file then
        message = "Could not save launcher settings."
        return false
    end
    local serialized, json = pcall(textutils.serializeJSON, settings)
    if not serialized or type(json) ~= "string" then
        file.close()
        fs.delete(temporary)
        message = "Could not serialize launcher settings."
        return false
    end
    local protected, protectError = encryptData(json)
    if not protected then
        file.close()
        fs.delete(temporary)
        message = "Could not encrypt launcher settings: " .. tostring(protectError)
        return false
    end
    local wrote, writeError = pcall(file.write, protected)
    local closed, closeError = pcall(file.close)
    if not wrote or not closed then
        if fs.exists(temporary) then fs.delete(temporary) end
        message = "Could not write launcher settings: "
            .. tostring(not wrote and writeError or closeError)
        return false
    end
    if fs.exists(SETTINGS_PATH) then
        local backedUp, backupError = pcall(fs.move, SETTINGS_PATH, backup)
        if not backedUp then
            fs.delete(temporary)
            message = "Could not back up launcher settings: " .. tostring(backupError)
            return false
        end
    end
    local ok, err = pcall(fs.move, temporary, SETTINGS_PATH)
    if not ok then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then fs.move(backup, SETTINGS_PATH) end
        message = "Could not save launcher settings: " .. tostring(err)
        return false
    end
    if fs.exists(backup) then fs.delete(backup) end
    settingsNeedEncryption = false
    message = "Settings saved."
    return true
end

local riftApi = {
    version = "1",
    notify = notifyUser,
    user = function() return currentUser end,
    notifications = function()
        local copy = {}
        for index, entry in ipairs(notificationHistory) do copy[index] = entry.text end
        return copy
    end,
    settings = {
        get = function(key, default)
            if type(key) ~= "string" then error("Setting name must be a string.", 2) end
            local value = settings.rift[key]
            if value == nil then return default end
            return value
        end,
        set = function(key, value)
            if type(key) ~= "string" or #key > 64 then error("Invalid setting name.", 2) end
            local valueType = type(value)
            if value ~= nil and valueType ~= "string" and valueType ~= "number"
                and valueType ~= "boolean" then
                error("Setting values must be strings, numbers or booleans.", 2)
            end
            settings.rift[key] = value
            local previousMessage = message
            local saved = saveSettings()
            message = previousMessage
            return saved
        end,
    },
}
rawset(_ENV, "rift", riftApi)
rawset(_G, "rift", riftApi)

idleLockMinutes = function()
    local minutes = tonumber(settings.rift.idleLockMinutes)
    return minutes and minutes > 0 and minutes or 0
end
bootLogoEnabled = function() return settings.rift.bootLogo ~= false end
clockTime = function()
    local offset = tonumber(settings.rift.timeZone)
    if offset then
        return textutils.formatTime((nativeOs.time("utc") + offset) % 24, true)
    end
    return textutils.formatTime(nativeOs.time("local"), true)
end

local function ensureStartupProgram()
    if fs.exists(STARTUP_PATH) then
        if fs.isDir(STARTUP_PATH) then
            return false, "Cannot create startup program: /startup.lua is a directory."
        end
        return true
    end

    local made, makeError = pcall(fs.makeDir, SYSTEM_DIRECTORY)
    if not made then
        return false, "Could not create startup folder: " .. tostring(makeError)
    end
    if fs.exists(STARTUP_TEMPORARY_PATH) then
        if fs.isDir(STARTUP_TEMPORARY_PATH) then
            return false, "Cannot create startup program: temporary path is a directory."
        end
        fs.delete(STARTUP_TEMPORARY_PATH)
    end

    local file = fs.open(STARTUP_TEMPORARY_PATH, "w")
    if not file then
        return false, "Could not create the temporary startup program."
    end
    local wrote, writeError = pcall(file.write,
        'if not shell.run("/launcher.lua") then\n'
            .. '    printError("Could not start /launcher.lua.")\n'
            .. "end\n"
    )
    local closed, closeError = pcall(file.close)
    if not wrote or not closed then
        if fs.exists(STARTUP_TEMPORARY_PATH) then fs.delete(STARTUP_TEMPORARY_PATH) end
        return false, "Could not write the startup program: "
            .. tostring(not wrote and writeError or closeError)
    end
    if fs.exists(STARTUP_PATH) then
        fs.delete(STARTUP_TEMPORARY_PATH)
        return true
    end

    local moved, moveError = pcall(fs.move, STARTUP_TEMPORARY_PATH, STARTUP_PATH)
    if not moved then
        if fs.exists(STARTUP_TEMPORARY_PATH) then fs.delete(STARTUP_TEMPORARY_PATH) end
        return false, "Could not install the startup program: " .. tostring(moveError)
    end
    return true
end

local function loadProfilePasswords()
    if not fs.exists(PROFILE_PASSWORDS_PATH) then return {}, nil, true end
    local file = fs.open(PROFILE_PASSWORDS_PATH, "r")
    if not file then
        return nil, "Could not read profile passwords from " .. PROFILE_PASSWORDS_PATH .. "."
    end
    local contents = file.readAll()
    file.close()
    local decrypted, wasEncrypted, decryptError = decryptData(contents)
    if not decrypted then
        return nil, "Could not decrypt profile passwords: " .. tostring(decryptError)
    end
    contents = decrypted
    local ok, passwords = pcall(textutils.unserializeJSON, contents)
    if not ok or type(passwords) ~= "table" then
        return nil, "Profile password data is invalid. Refusing to bypass profile passwords."
    end
    for username, password in pairs(passwords) do
        if type(username) ~= "string" or not username:match("^[%w_-]+$")
            or type(password) ~= "string" then
            return nil, "Profile password data is invalid. Refusing to bypass profile passwords."
        end
    end
    return passwords, nil, wasEncrypted
end

local function saveProfilePasswords(passwords)
    fs.makeDir(SYSTEM_DIRECTORY)
    local temporary = PROFILE_PASSWORDS_PATH .. ".tmp"
    local backup = PROFILE_PASSWORDS_PATH .. ".bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file = fs.open(temporary, "w")
    if not file then return false, "Could not create " .. temporary .. "." end
    local serialized, json = pcall(textutils.serializeJSON, passwords)
    if not serialized or type(json) ~= "string" then
        file.close()
        fs.delete(temporary)
        return false, "Could not serialize profile passwords."
    end
    local protected, protectError = encryptData(json)
    if not protected then
        file.close()
        fs.delete(temporary)
        return false, "Could not encrypt profile passwords: " .. tostring(protectError)
    end
    local wrote, writeError = pcall(file.write, protected)
    local closed, closeError = pcall(file.close)
    if not wrote or not closed then
        if fs.exists(temporary) then fs.delete(temporary) end
        return false, "Could not write profile passwords: "
            .. tostring(not wrote and writeError or closeError)
    end

    if fs.exists(PROFILE_PASSWORDS_PATH) then
        local backedUp, backupError = pcall(fs.move, PROFILE_PASSWORDS_PATH, backup)
        if not backedUp then
            fs.delete(temporary)
            return false, "Could not back up profile passwords: " .. tostring(backupError)
        end
    end
    local moved, moveError = pcall(fs.move, temporary, PROFILE_PASSWORDS_PATH)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then fs.move(backup, PROFILE_PASSWORDS_PATH) end
        return false, "Could not save profile passwords: " .. tostring(moveError)
    end
    if fs.exists(backup) then fs.delete(backup) end
    return true
end

local function loadProfileAdmins()
    if not fs.exists(PROFILE_ADMINS_PATH) then return {} end
    local file = fs.open(PROFILE_ADMINS_PATH, "r")
    if not file then
        return nil, "Could not read profile admins from " .. PROFILE_ADMINS_PATH .. "."
    end
    local contents = file.readAll()
    file.close()
    local ok, admins = pcall(textutils.unserializeJSON, contents)
    if not ok or type(admins) ~= "table" then
        return nil, "Profile admin data is invalid. Refusing to grant sudo access."
    end
    for username, isAdmin in pairs(admins) do
        if type(username) ~= "string" or not username:match("^[%w_-]+$")
            or isAdmin ~= true then
            return nil, "Profile admin data is invalid. Refusing to grant sudo access."
        end
    end
    return admins
end

local function saveProfileAdmins(admins)
    fs.makeDir(SYSTEM_DIRECTORY)
    local temporary = PROFILE_ADMINS_PATH .. ".tmp"
    local backup = PROFILE_ADMINS_PATH .. ".bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file = fs.open(temporary, "w")
    if not file then return false, "Could not create " .. temporary .. "." end
    file.write(textutils.serializeJSON(admins))
    file.close()

    if fs.exists(PROFILE_ADMINS_PATH) then
        local backedUp, backupError = pcall(fs.move, PROFILE_ADMINS_PATH, backup)
        if not backedUp then
            fs.delete(temporary)
            return false, "Could not back up profile admins: " .. tostring(backupError)
        end
    end
    local moved, moveError = pcall(fs.move, temporary, PROFILE_ADMINS_PATH)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then fs.move(backup, PROFILE_ADMINS_PATH) end
        return false, "Could not save profile admins: " .. tostring(moveError)
    end
    if fs.exists(backup) then fs.delete(backup) end
    return true
end

local function installDownloader()
    if fs.exists(DOWNLOADER_PATH) and fs.exists(SYSTEM_FILE_BROWSER_PATH) then return true end
    if not http or not http.get then
        return false, "Enable the ComputerCraft HTTP API to download the app downloader."
    end

    local ok, response, requestError = pcall(
        http.get, HOST_BASE_URL .. "computercraft/system/app-downloader.lua"
    )
    if not ok then return false, "Downloader request failed: " .. tostring(response) end
    if not response then
        return false, "Downloader request failed: " .. tostring(requestError or "HTTP request failed.")
    end

    local responseCode = response.getResponseCode and response.getResponseCode()
    if responseCode and responseCode ~= 200 then
        response.close()
        return false, "Downloader request failed: host returned HTTP " .. responseCode .. "."
    end

    local contents = response.readAll()
    response.close()
    if not contents or contents == "" then
        return false, "Downloader download failed: the file was empty."
    end

    local temporary = DOWNLOADER_PATH .. ".download-tmp"
    local backup = DOWNLOADER_PATH .. ".download-bak"
    fs.makeDir(SYSTEM_APP_DIRECTORY)
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file = fs.open(temporary, "w")
    if not file then return false, "Could not create " .. temporary .. "." end
    file.write(contents)
    file.close()

    if fs.exists(DOWNLOADER_PATH) then
        local backedUp, backupError = pcall(fs.move, DOWNLOADER_PATH, backup)
        if not backedUp then
            fs.delete(temporary)
            return false, "Could not back up the app downloader: " .. tostring(backupError)
        end
    end
    local moved, moveError = pcall(fs.move, temporary, DOWNLOADER_PATH)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then fs.move(backup, DOWNLOADER_PATH) end
        return false, "Could not install the app downloader: " .. tostring(moveError)
    end
    if fs.exists(backup) then fs.delete(backup) end
    return true
end

local function displayName(path)
    local name = path:gsub("%.lua$", ""):gsub("[_%-]", " ")
    return name:gsub("(%a)([%w']*)", function(first, rest)
        return first:upper() .. rest
    end)
end

local function chooseUserPrompt(skipAutoLogin)
    fs.makeDir(USER_ROOT)
    local loadedPasswords, passwordError, passwordsEncrypted = loadProfilePasswords()
    if not loadedPasswords then error(passwordError, 0) end
    profilePasswords = loadedPasswords
    if not passwordsEncrypted then
        local migrated, migrationError = saveProfilePasswords(profilePasswords)
        if not migrated then
            error("Could not encrypt existing profile passwords: " .. tostring(migrationError), 0)
        end
    end
    local loadedAdmins, adminError = loadProfileAdmins()
    if not loadedAdmins then error(adminError, 0) end
    profileAdmins = loadedAdmins
    if not skipAutoLogin and settings.autoLoginUser ~= "default" and type(settings.autoLoginUser) == "string"
        and fs.isDir(fs.combine(USER_ROOT, settings.autoLoginUser)) then
        currentUser = settings.autoLoginUser
        homeDirectory = fs.combine(USER_ROOT, currentUser)
        authorizedProfiles = {}
        return true
    end
    local userSelected = 1
    local userFirstVisible = 1
    local profileMessage = ""

    local function authenticate(username)
        local expected = profilePasswords[username]
        if not expected then return true end
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        term.setTextColor(colors.cyan)
        print("PROFILE LOCKED")
        term.setTextColor(colors.white)
        write("Password for " .. username .. ": ")
        local entered = readPassword()
        if entered == expected then return true end
        profileMessage = "Incorrect password. Try again."
        return false
    end

    local function createInitialAccount()
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        term.setTextColor(colors.cyan)
        print("CREATE YOUR ADMIN ACCOUNT")
        term.setTextColor(colors.white)
        print("This is the first account on this computer.")
        print("A password is required.")
        print("Private data is obfuscated with a key stored on this computer.")
        if profileMessage ~= "" then
            term.setTextColor(colors.yellow)
            print(profileMessage)
            term.setTextColor(colors.white)
            profileMessage = ""
        end
        print("")
        write("New username: ")
        local username = read()
        if not username or not username:match("^[%w_-]+$") then
            profileMessage = "Use only letters, numbers, underscores, and hyphens."
            return false
        end
        local path = fs.combine(USER_ROOT, username)
        if fs.exists(path) then
            profileMessage = "That profile already exists. Choose another username."
            return false
        end
        write("Password: ")
        local password = readPassword()
        if password == "" then
            profileMessage = "Password cannot be empty."
            return false
        end
        write("Confirm password: ")
        if readPassword() ~= password then
            profileMessage = "Passwords did not match."
            return false
        end

        local created, createError = pcall(fs.makeDir, path)
        if not created then
            profileMessage = "Could not create profile: " .. tostring(createError)
            return false
        end
        profilePasswords[username] = password
        local saved, saveError = saveProfilePasswords(profilePasswords)
        if not saved then
            profilePasswords[username] = nil
            pcall(fs.delete, path)
            profileMessage = saveError
            return false
        end
        profileAdmins[username] = true
        local adminsSaved, adminsError = saveProfileAdmins(profileAdmins)
        if not adminsSaved then
            profilePasswords[username] = nil
            profileAdmins[username] = nil
            local rollbackSaved, rollbackError = saveProfilePasswords(profilePasswords)
            local rollbackAdminsSaved, rollbackAdminsError = saveProfileAdmins(profileAdmins)
            pcall(fs.delete, path)
            profileMessage = adminsError
            if not rollbackSaved then
                profileMessage = profileMessage .. " Password rollback also failed: " .. tostring(rollbackError)
            end
            if not rollbackAdminsSaved then
                profileMessage = profileMessage .. " Admin rollback also failed: "
                    .. tostring(rollbackAdminsError)
            end
            return false
        end
        currentUser = username
        homeDirectory = path
        authorizedProfiles = {}
        return true
    end

    while true do
        local users = {}
        for _, entry in ipairs(fs.list(USER_ROOT)) do
            if entry ~= "default" and fs.isDir(fs.combine(USER_ROOT, entry))
                and entry:match("^[%w_-]+$") then
                table.insert(users, entry)
            end
        end
        table.sort(users, function(first, second) return first:lower() < second:lower() end)
        if #users == 0 then
            if createInitialAccount() then return true end
        else
        local width, height = term.getSize()
        local visibleRows = math.max(1, height - 9)
        if userSelected < 1 or userSelected > #users then userSelected = 1 end
        if userSelected < userFirstVisible then userFirstVisible = userSelected end
        if userSelected >= userFirstVisible + visibleRows then
            userFirstVisible = userSelected - visibleRows + 1
        end

        local theme = THEMES[settings.theme]
        local accent = term.isColor() and theme.accent or colors.gray
        local highlight = term.isColor() and theme.highlight or colors.gray
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        term.setBackgroundColor(accent)
        term.write((" " .. "PROFILE SELECTOR"):sub(1, width))
        term.setBackgroundColor(colors.black)
        term.setCursorPos(2, 2)
        term.setTextColor(colors.lightGray)
        term.setCursorPos(2, 3)
        term.setTextColor(accent)
        term.write((#users .. (#users == 1 and " PROFILE" or " PROFILES")):sub(1, math.max(0, width - 2)))

        local lastVisible = math.min(#users, userFirstVisible + visibleRows - 1)
        for index = userFirstVisible, lastVisible do
            local row = index - userFirstVisible + 5
            term.setCursorPos(2, row)
            if index == userSelected then
                term.setBackgroundColor(highlight)
                term.setTextColor(colors.white)
                term.write(("  > " .. users[index]):sub(1, math.max(0, width - 2)))
                term.setBackgroundColor(colors.black)
            else
                term.setTextColor(colors.white)
                term.write(("    " .. users[index]):sub(1, math.max(0, width - 2)))
            end
        end
        if profileMessage ~= "" then
            term.setCursorPos(2, height - 3)
            term.setTextColor(colors.yellow)
            term.write(profileMessage:sub(1, math.max(0, width - 2)))
        end
        term.setCursorPos(2, height - 2)
        term.setTextColor(colors.yellow)
        term.write(("Launcher sandbox is best-effort; cross-profile access needs a password."):sub(1, math.max(0, width - 2)))

        local buttons = {}
        if currentUser then
            buttons = { { label = "CANCEL", action = "cancel" } }
        end
        if #buttons > 0 then
            local slotWidth = math.max(1, math.floor(width / #buttons))
            for index, profileButton in ipairs(buttons) do
                local left = (index - 1) * slotWidth + 1
                local buttonWidth = index == #buttons and width - left + 1 or slotWidth
                term.setCursorPos(left, height)
                term.setBackgroundColor(term.isColor() and colors.gray or colors.black)
                term.setTextColor(colors.white)
                term.write(("[" .. profileButton.label .. "]"):sub(1, buttonWidth))
                profileButton.left = left
                profileButton.right = left + buttonWidth - 1
            end
        end
        term.setBackgroundColor(colors.black)

        local event, button, x, y = os.pullEventRaw()
        if event == "key" and (button == keys.n or button == keys.v) then
            userSelected = math.max(1, math.min(#users,
                userSelected + (button == keys.n and visibleRows or -visibleRows)))
        elseif event == "mouse_scroll" and y >= 5 and y < 5 + visibleRows then
            userSelected = math.max(1, math.min(#users, userSelected + button))
        elseif event == "mouse_click" and button == 1 then
            local index = userFirstVisible + y - 5
            if y >= 5 and y < 5 + visibleRows and index >= userFirstVisible and index <= #users then
                local wasSelected = userSelected == index
                userSelected = index
                if wasSelected then
                    local username = users[userSelected]
                    if authenticate(username) then
                        currentUser = username
                        homeDirectory = fs.combine(USER_ROOT, currentUser)
                        authorizedProfiles = {}
                        return true
                    end
                end
            elseif y == height then
                for _, profileButton in ipairs(buttons) do
                    if x >= profileButton.left and x <= profileButton.right then
                        return false
                    end
                end
            end
        end
        end
    end
end

local function chooseUser(skipAutoLogin)
    local previous = sessionMenuAllowed
    sessionMenuAllowed = false
    local result = table.pack(pcall(chooseUserPrompt, skipAutoLogin))
    sessionMenuAllowed = previous
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
end

local function authorizeProfileAccess(username, profileContext)
    local accessingUser = profileContext and profileContext.user or currentUser
    local passwords = profileContext and profileContext.passwords or profilePasswords
    local admins = profileContext and profileContext.admins or profileAdmins
    local authorized = profileContext and profileContext.authorized or authorizedProfiles
    if type(username) ~= "string" or not username:match("^[%w_-]+$") then
        return false, "Invalid profile name."
    end
    if username == accessingUser or authorized[username] then return true end

    local profilePath = fs.combine(USER_ROOT, username)
    if not fs.isDir(profilePath) then return false, "That profile does not exist." end

    local expected = passwords[username]
    if type(expected) ~= "string" or expected == "" then
        return false, "This profile has no password. Set one before accessing it."
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("PROFILE ACCESS REQUIRED")
    term.setTextColor(colors.white)
    print("Enter " .. username .. "'s password, or type sudo as an admin.")
    write("Password: ")
    local entered = readPassword()
    if entered == expected then
        authorized[username] = true
        return true
    elseif entered == "sudo" and admins[accessingUser] == true then
        authorized[username] = true
        return true
    elseif entered == "sudo" then
        return false, "The current profile is not an admin."
    else
        term.setTextColor(colors.yellow)
        print("Incorrect password. Access denied.")
        sleep(1)
        return false, "Incorrect password for " .. username .. "."
    end
end

local function listOtherProfiles(excludingUser)
    excludingUser = excludingUser or currentUser
    local profiles = {}
    for _, username in ipairs(fs.list(USER_ROOT)) do
        if username ~= excludingUser and username ~= "default" and username:match("^[%w_-]+$")
            and fs.isDir(fs.combine(USER_ROOT, username)) then
            table.insert(profiles, username)
        end
    end
    table.sort(profiles, function(first, second) return first:lower() < second:lower() end)
    return profiles
end

local function loadCatalogNames()
    local path = SYSTEM_DIRECTORY .. "/app-catalog-names.json"
    local names = {}
    if fs.exists(path) then
        local file = fs.open(path, "r")
        if not file then
            message = "Could not read the system app catalog names."
            return names
        end
        local contents = file.readAll()
        file.close()
        local ok, saved = pcall(textutils.unserializeJSON, contents)
        if not ok or type(saved) ~= "table" then
            message = "System app catalog names are invalid."
            return names
        end
        names = saved
    end

    local legacyPath = fs.combine(homeDirectory, ".app-catalog-names.json")
    if fs.exists(legacyPath) then
        local file = fs.open(legacyPath, "r")
        if file then
            local contents = file.readAll()
            file.close()
            local ok, legacyNames = pcall(textutils.unserializeJSON, contents)
            if ok and type(legacyNames) == "table" then
                for fileName, appName in pairs(legacyNames) do
                    if type(fileName) == "string" and type(appName) == "string"
                        and names[fileName] == nil then
                        names[fileName] = appName
                    end
                end
                fs.makeDir(SYSTEM_DIRECTORY)
                local temporary = path .. ".tmp"
                local backup = path .. ".bak"
                if fs.exists(temporary) then fs.delete(temporary) end
                if fs.exists(backup) then fs.delete(backup) end
                local output = fs.open(temporary, "w")
                if output then
                    output.write(textutils.serializeJSON(names))
                    output.close()
                    if fs.exists(path) then
                        local backedUp = pcall(fs.move, path, backup)
                        if not backedUp then
                            fs.delete(temporary)
                            message = "Could not migrate old app catalog names."
                            return names
                        end
                    end
                    local moved = pcall(fs.move, temporary, path)
                    if moved then
                        if fs.exists(backup) then fs.delete(backup) end
                        fs.delete(legacyPath)
                    else
                        if fs.exists(backup) then fs.move(backup, path) end
                        message = "Could not migrate old app catalog names."
                    end
                else
                    message = "Could not create system app catalog names."
                end
            else
                message = "Old app catalog names could not be parsed."
            end
        end
    end

    local validNames = {}
    for fileName, appName in pairs(names) do
        if type(fileName) == "string" and type(appName) == "string" and appName ~= "" then
            validNames[fileName] = appName
        end
    end
    return validNames
end

local function refreshApps()
    local userFilesDirectory = fs.combine(homeDirectory, "Files")
    fs.makeDir(userFilesDirectory)
    local function moveProfileFolder(source, destination)
        if not fs.exists(source) then return true end
        if not fs.exists(destination) then return pcall(fs.move, source, destination) end
        if not fs.isDir(source) or not fs.isDir(destination) then
            return false, "the destination is not a folder"
        end
        for _, name in ipairs(fs.list(source)) do
            local base, extension = name:match("^(.*)(%.[^%.]+)$")
            if not base then base, extension = name, "" end
            local destinationName = name
            local suffix = 2
            while fs.exists(fs.combine(destination, destinationName)) do
                destinationName = base .. " (" .. suffix .. ")" .. extension
                suffix = suffix + 1
            end
            local moved, moveError = pcall(fs.move,
                fs.combine(source, name), fs.combine(destination, destinationName))
            if not moved then return false, moveError end
        end
        fs.delete(source)
        return true
    end
    for _, directory in ipairs({ "desktop", "Documents", "Downloads", "Audio" }) do
        local legacyDirectory = fs.combine(homeDirectory, directory)
        local destination = fs.combine(userFilesDirectory,
            directory == "desktop" and "Desktop" or directory)
        local moved, moveError = moveProfileFolder(legacyDirectory, destination)
        if not moved then
            message = "Could not move the old " .. directory .. " folder: " .. tostring(moveError)
        end
        if not fs.exists(destination) then fs.makeDir(destination) end
    end

    if recoverySession then
        apps = {}
        if fs.exists(SYSTEM_FILE_BROWSER_PATH) and not fs.isDir(SYSTEM_FILE_BROWSER_PATH) then
            apps[#apps + 1] = { path = SYSTEM_FILE_BROWSER_PATH, name = "File Browser" }
        end
        local recoveryConsole = fs.combine(homeDirectory, "apps", "lua-console.lua")
        if fs.exists(recoveryConsole) and not fs.isDir(recoveryConsole) then
            apps[#apps + 1] = { path = recoveryConsole, name = "Lua Console" }
        end
        apps[#apps + 1] = { path = RECOVERY_PROFILE_INSPECTOR_PATH, name = "Profile Inspector" }
        selected, firstVisible = 1, 1
        if #apps == 0 then message = "System File Browser is not installed." end
        return
    end

    local available = {}
    local catalogNames = loadCatalogNames()

    fs.makeDir(SYSTEM_APP_DIRECTORY)
    for _, name in ipairs(fs.list(SYSTEM_APP_DIRECTORY)) do
        local path = fs.combine(SYSTEM_APP_DIRECTORY, name)
        if isLuaFile(path) and not available[path] then
            table.insert(available, {
                path = path,
                name = catalogNames[name] or displayName(name),
            })
            available[path] = true
        end
    end

    local appDirectory = fs.combine(homeDirectory, "apps")
    fs.makeDir(appDirectory)
    local desktopDirectory = fs.combine(userFilesDirectory, "Desktop")

    local migrationErrors = {}
    for _, name in ipairs(fs.list(homeDirectory)) do
        local legacyPath = fs.combine(homeDirectory, name)
        if name ~= "apps" and name ~= "launcher.lua" and name ~= "app-downloader.lua"
            and isLuaFile(legacyPath) then
            local destination = fs.combine(appDirectory, name)
            if not fs.exists(destination) then
                local moved, moveError = pcall(fs.move, legacyPath, destination)
                if not moved then
                    table.insert(migrationErrors, name .. ": " .. tostring(moveError))
                end
            end
        end
    end

    local otherPaths = {}
    local function addAppsFrom(directory, includeLegacyRoot)
        for _, name in ipairs(fs.list(directory)) do
            local fullPath = fs.combine(directory, name)
            if isLuaFile(fullPath)
                and not available[fullPath]
                and (not includeLegacyRoot or name ~= "launcher.lua" and name ~= "app-downloader.lua"
                    and not fs.exists(fs.combine(appDirectory, name))) then
                table.insert(otherPaths, fullPath)
                available[fullPath] = true
            end
        end
    end
    addAppsFrom(appDirectory, false)
    addAppsFrom(desktopDirectory, false)
    addAppsFrom(homeDirectory, true)
    if settings.alphabetical then
        table.sort(otherPaths, function(first, second)
            return fs.getName(first):lower() < fs.getName(second):lower()
        end)
    end
    for _, path in ipairs(otherPaths) do
        local name = fs.getName(path)
        table.insert(available, {
            path = path,
            name = catalogNames[name] or displayName(name),
        })
    end
    if #migrationErrors > 0 then
        message = "Some old apps could not be moved: " .. table.concat(migrationErrors, "; ")
    end
    apps = available
    if #apps == 0 then
        selected = 1
        firstVisible = 1
        message = "No Lua programs found in " .. displayLauncherPath(homeDirectory) .. "."
        return
    end
    selected = math.min(selected, #apps)
end

local function drawButtons(buttons, row, width, isColor)
    local slotWidth = math.max(1, math.floor(width / #buttons))
    for index, button in ipairs(buttons) do
        local x = (index - 1) * slotWidth + 1
        local buttonWidth = index == #buttons and width - x + 1 or slotWidth
        term.setCursorPos(x, row)
        term.setBackgroundColor(isColor and colors.gray or colors.black)
        term.setTextColor(colors.white)
        term.write(("[" .. button.label .. "]"):sub(1, buttonWidth))
        button.left = x
        button.right = x + buttonWidth - 1
    end
end

local function buttonAt(buttons, x)
    for _, button in ipairs(buttons) do
        if x >= button.left and x <= button.right then return button.action end
    end
end

local function draw()
    local width, height = term.getSize()
    local isColor = term.isColor()
    local textColor = colors.white
    local backgroundColor = colors.black
    local theme = THEMES[settings.theme]
    local highlightColor = isColor and theme.highlight or colors.gray
    local mutedColor = isColor and colors.lightGray or colors.white
    local titleColor = isColor and theme.accent or colors.gray
    local visibleRows = math.max(1, height - 12)
    local firstButtons, secondButtons

    if selected < firstVisible then firstVisible = selected end
    if selected >= firstVisible + visibleRows then
        firstVisible = selected - visibleRows + 1
    end

    term.setBackgroundColor(backgroundColor)
    term.setTextColor(textColor)
    term.clear()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(titleColor)
    term.setTextColor(isColor and colors.black or colors.white)
    term.write(string.rep(" ", width))
    term.setCursorPos(2, 1)
    term.write(("RIFT LAUNCHER"):sub(1, width - 1))
    local rightText = tostring(currentUser) .. "  " .. clockTime()
    if #rightText + 17 <= width then
        term.setCursorPos(width - #rightText, 1)
        term.write(rightText)
    end
    term.setBackgroundColor(backgroundColor)
    term.setCursorPos(2, 2)
    term.setTextColor(mutedColor)
    local countText = "  (" .. #apps .. ")"
    term.write(("YOUR PROGRAMS" .. countText):sub(1, math.max(0, width - 2)))
    term.setCursorPos(1, 3)
    term.setTextColor(isColor and theme.accent or colors.gray)
    term.write(string.rep("-", width))

    local lastVisible = math.min(#apps, firstVisible + visibleRows - 1)
    for index = firstVisible, lastVisible do
        local row = index - firstVisible + 4
        term.setCursorPos(1, row)
        if index == selected then
            term.setBackgroundColor(highlightColor)
            term.setTextColor(textColor)
            term.write((" > " .. apps[index].name .. string.rep(" ", width)):sub(1, width))
            term.setBackgroundColor(backgroundColor)
        else
            term.setTextColor(textColor)
            term.write(("   " .. apps[index].name):sub(1, width))
        end
    end
    if #apps == 0 then
        term.setCursorPos(3, 4)
        term.setTextColor(mutedColor)
        term.write(("No programs yet. Open the App Downloader."):sub(1, math.max(0, width - 2)))
    end
    term.setTextColor(mutedColor)
    if firstVisible > 1 then
        term.setCursorPos(width, 4)
        term.write("^")
    end
    if lastVisible < #apps then
        term.setCursorPos(width, 3 + visibleRows)
        term.write("v")
    end
    if recoverySession then
        firstButtons = { { label = "OPEN FILES", action = "open" } }
        secondButtons = {
            { label = "RECOVERY TOOLS", action = "recovery-tools" },
            { label = "EXIT RECOVERY", action = "exit-recovery" },
        }
    else
        firstButtons = {
            { label = "UPDATE", action = "update" },
            { label = "SETTINGS", action = "settings" },
        }
        secondButtons = {
            { label = "REFRESH", action = "refresh" },
            { label = "ALERTS (" .. #notificationHistory .. ")", action = "alerts" },
        }
        if #tasks > 0 then
            table.insert(secondButtons, { label = "TASKS (" .. #tasks .. ")", action = "tasks" })
        end
    end
    term.setCursorPos(1, height - 5)
    term.setTextColor(isColor and theme.accent or colors.gray)
    term.write(string.rep("-", width))
    drawButtons(firstButtons, height - 2, width, isColor)
    drawButtons(secondButtons, height - 1, width, isColor)

    term.setCursorPos(2, height - 4)
    term.setTextColor(mutedColor)
    local footer = displayLauncherMessage(message)
    if footer == "" then footer = "Click twice or press Enter to open. Ctrl+T for the menu." end
    term.write(footer:sub(1, math.max(0, width - 2)))
    term.setBackgroundColor(backgroundColor)
    term.setTextColor(textColor)
    return firstButtons, secondButtons
end

local function showNotifications()
    local scroll = 0
    while true do
        local width, height = term.getSize()
        local isColor = term.isColor()
        local theme = THEMES[settings.theme]
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1, 1)
        term.setBackgroundColor(isColor and theme.accent or colors.gray)
        term.setTextColor(isColor and colors.black or colors.white)
        term.write((" NOTIFICATIONS" .. string.rep(" ", width)):sub(1, width))
        term.setBackgroundColor(colors.black)
        local rows = math.max(1, height - 3)
        local total = #notificationHistory
        scroll = math.max(0, math.min(scroll, math.max(0, total - rows)))
        if total == 0 then
            term.setCursorPos(2, 3)
            term.setTextColor(colors.lightGray)
            term.write("Nothing yet.")
        end
        for row = 1, math.min(rows, total) do
            local entry = notificationHistory[total - scroll - row + 1]
            if not entry then break end
            term.setCursorPos(2, row + 2)
            term.setTextColor(colors.lightGray)
            term.write(textutils.formatTime(entry.time, true) .. " ")
            term.setTextColor(colors.white)
            local used = #textutils.formatTime(entry.time, true) + 2
            term.write(entry.text:sub(1, math.max(0, width - used - 1)))
        end
        term.setCursorPos(2, height)
        term.setTextColor(colors.lightGray)
        term.write(("Up/Down scroll   C clear   any other key closes"):sub(1, width - 2))
        local event, button = os.pullEventRaw()
        if event == "key" then
            if button == keys.up then
                scroll = scroll + 1
            elseif button == keys.down then
                scroll = scroll - 1
            elseif button == keys.c then
                for index = #notificationHistory, 1, -1 do notificationHistory[index] = nil end
            else
                return
            end
        elseif event == "mouse_scroll" then
            scroll = scroll - button
        elseif event == "mouse_click" then
            return
        end
    end
end

local function waitForReturn(waitForKey)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    if waitForKey then
        print("")
        print("Press any key to return to Rift Launcher.")
        while true do
            local event = os.pullEventRaw()
            if event == "key" or event == "mouse_click" then return end
        end
    end
    sleep(.5)
end

local function updateSelected()
    local app = apps[selected]
    if not app then
        message = "Select an available program first."
        return
    end

    if not fs.exists(DOWNLOADER_PATH) then
        local downloaded, downloadError = installDownloader()
        if not downloaded then
            message = downloadError
            return
        end
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    nextTaskName = "Update"
    local ok, result = runClosable(os.run, _ENV, DOWNLOADER_PATH, "update", fs.getName(app.path), homeDirectory)
    if not ok then
        printError("Could not run the app downloader: " .. tostring(result))
    elseif result == false then
        printError("The app downloader did not complete successfully.")
    end
    waitForReturn(not ok or result == false)
    refreshApps()
    message = ""
end

local function isInHomeDirectory(path)
    local normalizedPath = path:gsub("^/+", ""):gsub("/+$", "")
    local normalizedHome = homeDirectory:gsub("^/+", ""):gsub("/+$", "")
    return normalizedPath == normalizedHome
        or normalizedPath:sub(1, #normalizedHome + 1) == normalizedHome .. "/"
end

-- os.run reports failures through the real global printError, so hook both it and ours.
local function capturePrintError(sink)
    local previousGlobal = _G.printError
    local previousLocal = printError
    local function hook(text)
        sink(tostring(text))
        previousGlobal(text)
    end
    _G.printError = hook
    printError = hook
    return function()
        _G.printError = previousGlobal
        printError = previousLocal
    end
end

local function runHomeProgram(programPath, profileContext, ...)
    local homeDirectory = profileContext.homeDirectory
    local currentUser = profileContext.user
    local recoveryRootAccess = profileContext.recovery == true
    local recoveryProtectedPaths = {
        ".launcher/profile-password.json",
        ".launcher/profile-passwords.json",
        ".launcher/.data-key",
    }
    local function isRecoveryProtectedPath(path)
        if not recoveryRootAccess then return false end
        local normalizedPath = tostring(path):gsub("^/+", ""):lower()
        for _, protectedPath in ipairs(recoveryProtectedPaths) do
            if normalizedPath == protectedPath
                or normalizedPath:sub(1, #protectedPath + 1) == protectedPath .. "."
                or normalizedPath:sub(1, #protectedPath + 1) == protectedPath .. "/" then
                return true
            end
        end
        return false
    end
    local function containsRecoveryProtectedPath(path)
        if not recoveryRootAccess then return false end
        local normalizedPath = tostring(path):gsub("^/+", ""):gsub("/+$", ""):lower()
        if normalizedPath == "" then return true end
        for _, protectedPath in ipairs(recoveryProtectedPaths) do
            if protectedPath:sub(1, #normalizedPath + 1) == normalizedPath .. "/" then
                return true
            end
        end
        return false
    end
    local function getDriveMounts()
        local mounts, driveNames = {}, {}
        if type(peripheral) ~= "table" or type(peripheral.getNames) ~= "function" then
            return mounts
        end
        for _, name in ipairs(peripheral.getNames()) do
            local typeOk, peripheralType = pcall(peripheral.getType, name)
            if typeOk and peripheralType == "drive" then driveNames[#driveNames + 1] = name end
        end
        if #driveNames == 0
            or not riftModules.check("peripheral:drive", "your drive", riftModules.appName()) then
            return mounts
        end
        for _, name in ipairs(driveNames) do
                local wrapOk, drive = pcall(peripheral.wrap, name)
                if wrapOk and drive and type(drive.getMountPath) == "function" then
                    local mountOk, mountPath = pcall(drive.getMountPath)
                    if mountOk and type(mountPath) == "string" then
                        mountPath = mountPath:gsub("^/+", ""):gsub("/+$", "")
                        if mountPath:match("^[%w_%-]+$") then
                            mounts[#mounts + 1] = mountPath
                        end
                    end
                end
        end
        table.sort(mounts, function(first, second) return first:lower() < second:lower() end)
        return mounts
    end

    local function resolveProfilePath(username, profilePath)
        if username == currentUser then
            return nativeFs.combine(homeDirectory, profilePath)
        end
        if not recoveryRootAccess
            and (type(profileContext.admins) ~= "table" or profileContext.admins[currentUser] ~= true) then
            return nil
        end
        if not recoveryRootAccess then
            local authorized, accessError = authorizeProfileAccess(username, profileContext)
            if not authorized then return nil, accessError end
        end
        return nativeFs.combine(USER_ROOT, username, profilePath)
    end

    local normalizedHome = homeDirectory:gsub("^/+", ""):gsub("/+$", "")
    local normalizedProgram = programPath:gsub("^/+", ""):gsub("/+$", "")
    local virtualProgram
    if normalizedProgram == normalizedHome then
        virtualProgram = ""
    elseif normalizedProgram:sub(1, #normalizedHome + 1) == normalizedHome .. "/" then
        virtualProgram = normalizedProgram:sub(#normalizedHome + 2)
    else
        error("The program is outside the active profile home.", 0)
    end

    local virtualDirectory = ""
    local locationDirectories = {
        desktop = "Files/Desktop",
        documents = "Files/Documents",
        downloads = "Files/Downloads",
        audio = "Files/Audio",
    }
    local function normalizeSegments(path, initialDirectory)
        local segments = {}
        for segment in (initialDirectory or ""):gmatch("[^/]+") do
            table.insert(segments, segment)
        end
        for segment in path:gmatch("[^/]+") do
            if segment == ".." then
                if #segments > 0 then table.remove(segments) end
            elseif segment ~= "." then
                table.insert(segments, segment)
            end
        end
        return table.concat(segments, "/")
    end

    local function normalizeVirtualPath(path)
        if type(path) ~= "string" then
            error("Filesystem paths must be strings.", 0)
        end
        path = path:gsub("%%([%w_]+)%%", function(location)
            local directory = locationDirectories[location:lower()]
            return directory and ("/" .. directory) or ("%" .. location .. "%")
        end)
        local alias, aliasPath = path:match("^([%w@#]+://)(.*)$")
        if alias then return alias .. normalizeSegments(aliasPath) end
        local initialDirectory = path:sub(1, 1) ~= "/" and virtualDirectory or ""
        return normalizeSegments(path, initialDirectory)
    end

    local function physicalPath(path)
        local normalizedPath = normalizeVirtualPath(path)
        local alias, aliasPath = normalizedPath:match("^([%w@#]+://)(.*)$")
        if alias == "H://" then
            return nativeFs.combine(homeDirectory, aliasPath)
        elseif alias == "ROOT://" then
            if not recoveryRootAccess then return nil end
            local target = aliasPath == "" and "/" or nativeFs.combine("/", aliasPath)
            if isRecoveryProtectedPath(target) then error("This path is unavailable in recovery mode.", 0) end
            return target
        elseif alias == "S://" then
            if not recoveryRootAccess then return nil end
            local target = nativeFs.combine(SYSTEM_APP_DIRECTORY, aliasPath)
            if isRecoveryProtectedPath(target) then error("This path is unavailable in recovery mode.", 0) end
            return target
        elseif alias then
            local otherUsername = alias:match("^H@([%w_-]+)://$")
            if otherUsername then
                return resolveProfilePath(otherUsername, aliasPath)
            end
            local driveNumber = tonumber(alias:match("^D(%d+)://$"))
            if driveNumber then
                local mounts = getDriveMounts()
                local mountPath = mounts[driveNumber]
                if not mountPath then return nil end
                return nativeFs.combine("/", mountPath, aliasPath)
            end
            return nil
        end
        if recoveryRootAccess then
            if type(path) == "string" and path:sub(1, 1) == "/"
                and (normalizedPath == "apps" or normalizedPath:sub(1, 5) == "apps/") then
                return nativeFs.combine(homeDirectory, normalizedPath)
            end
            local target = normalizedPath == "" and "/" or nativeFs.combine("/", normalizedPath)
            if isRecoveryProtectedPath(target) then
                error("This path is unavailable in recovery mode.", 0)
            end
            return target
        end
        if type(path) == "string" and path:sub(1, 1) == "/" then
            local username, profilePath = normalizedPath:match("^users/([%w_-]+)/*(.*)$")
            if username then
                return resolveProfilePath(username, profilePath)
            end
        end
        return nativeFs.combine(homeDirectory, normalizedPath)
    end

    local function virtualAbsolute(path)
        local normalized = normalizeVirtualPath(path)
        if normalized:match("^[%w@#]+://") then return normalized end
        return normalized == "" and "/" or "/" .. normalized
    end

    local function createStorageModule()
        local storageRoot = nativeFs.combine("/.launcher/user-data", currentUser)

        local function resolvePath(path)
            if type(path) ~= "string" or #path < 1 or #path > 160
                or path:sub(1, 1) == "/" or path:sub(-1) == "/"
                or path:find("//", 1, true) or path:find("\\", 1, true) then
                return nil, "Storage paths must be relative names."
            end
            local segments = {}
            for segment in path:gmatch("[^/]+") do
                if segment == "." or segment == ".." or not segment:match("^[%w_.%-]+$") then
                    return nil, "Storage paths may contain only letters, numbers, dots, underscores, and dashes."
                end
                table.insert(segments, segment)
            end
            if #segments == 0 then return nil, "A storage name is required." end
            return nativeFs.combine(storageRoot, table.concat(segments, "/"))
        end

        local api = {}
        function api.read(path)
            local target, pathError = resolvePath(path)
            if not target then return nil, pathError end
            if not nativeFs.exists(target) then return nil, "Stored data was not found." end
            if nativeFs.isDir(target) then return nil, "Stored data name refers to a folder." end
            local file = nativeFs.open(target, "r")
            if not file then return nil, "Could not open stored data." end
            local contents = file.readAll()
            file.close()
            local decrypted, wasEncrypted, decryptError = decryptData(contents)
            if not decrypted then
                return nil, "Could not decrypt stored data: " .. tostring(decryptError)
            end
            contents = decrypted
            local ok, value = pcall(textutils.unserializeJSON, contents)
            if not ok then return nil, "Stored data is not valid JSON." end
            if not wasEncrypted then
                local saved, saveError = api.write(path, value)
                if not saved then
                    return nil, "Stored data was read, but could not be encrypted: "
                        .. tostring(saveError)
                end
            end
            return value
        end

        function api.write(path, value)
            local target, pathError = resolvePath(path)
            if not target then return false, pathError end
            local serialized, contents = pcall(textutils.serializeJSON, value)
            if not serialized or type(contents) ~= "string" then
                return false, "Value must be serializable as JSON."
            end
            local protected, protectError = encryptData(contents)
            if not protected then
                return false, "Could not encrypt stored data: " .. tostring(protectError)
            end
            contents = protected
            if nativeFs.exists(target) and nativeFs.isDir(target) then
                return false, "Stored data name refers to a folder."
            end

            local directory = nativeFs.getDir(target)
            if directory ~= "" then
                local made, makeError = pcall(nativeFs.makeDir, directory)
                if not made then return false, "Could not create storage folder: " .. tostring(makeError) end
            end
            local temporary = target .. ".tmp"
            local backup = target .. ".bak"
            local file = nativeFs.open(temporary, "w")
            if not file then return false, "Could not create the storage staging file." end
            file.write(contents)
            file.close()

            if nativeFs.exists(backup) then nativeFs.delete(backup) end
            if nativeFs.exists(target) then
                local backedUp, backupError = pcall(nativeFs.move, target, backup)
                if not backedUp then
                    nativeFs.delete(temporary)
                    return false, "Could not back up stored data: " .. tostring(backupError)
                end
            end
            local moved, moveError = pcall(nativeFs.move, temporary, target)
            if not moved then
                if nativeFs.exists(temporary) then nativeFs.delete(temporary) end
                if nativeFs.exists(backup) then nativeFs.move(backup, target) end
                return false, "Could not save stored data: " .. tostring(moveError)
            end
            if nativeFs.exists(backup) then nativeFs.delete(backup) end
            return true
        end

        function api.delete(path)
            local target, pathError = resolvePath(path)
            if not target then return false, pathError end
            if not nativeFs.exists(target) then return false, "Stored data was not found." end
            if nativeFs.isDir(target) then return false, "Stored data name refers to a folder." end
            local ok, deleteError = pcall(nativeFs.delete, target)
            if not ok then return false, "Could not delete stored data: " .. tostring(deleteError) end
            return true
        end

        function api.list(path)
            local target = storageRoot
            if path ~= nil and path ~= "" then
                local pathError
                target, pathError = resolvePath(path)
                if not target then return nil, pathError end
            end
            if not nativeFs.exists(target) then return {} end
            if not nativeFs.isDir(target) then return nil, "Storage path is not a folder." end
            return nativeFs.list(target)
        end

        local function migrateLegacyDirectory(directory, relativeDirectory)
            if not nativeFs.exists(directory) then return end
            for _, name in ipairs(nativeFs.list(directory)) do
                local path = nativeFs.combine(directory, name)
                local relativePath = relativeDirectory == ""
                    and name or relativeDirectory .. "/" .. name
                if nativeFs.isDir(path) then
                    migrateLegacyDirectory(path, relativePath)
                else
                    local file = nativeFs.open(path, "r")
                    if not file then
                        error("Could not read existing private storage file " .. relativePath .. ".", 0)
                    end
                    local contents = file.readAll()
                    file.close()
                    local plaintext, wasEncrypted, decryptError = decryptData(contents)
                    if not plaintext then
                        error("Could not decrypt private storage file " .. relativePath .. ": "
                            .. tostring(decryptError), 0)
                    end
                    if not wasEncrypted then
                        local protected, protectError = encryptData(plaintext)
                        if not protected then
                            error("Could not encrypt private storage file " .. relativePath
                                .. ": " .. tostring(protectError), 0)
                        end
                        local temporary, backup = path .. ".enc-tmp", path .. ".enc-bak"
                        if nativeFs.exists(temporary) or nativeFs.exists(backup) then
                            error("Could not encrypt private storage file " .. relativePath
                                .. ": an encryption recovery file already exists.", 0)
                        end
                        local output = nativeFs.open(temporary, "w")
                        if not output then
                            error("Could not create encryption staging file for " .. relativePath .. ".", 0)
                        end
                        local wrote, writeError = pcall(output.write, protected)
                        local closed, closeError = pcall(output.close)
                        if not wrote or not closed then
                            if nativeFs.exists(temporary) then nativeFs.delete(temporary) end
                            error("Could not write encrypted storage file " .. relativePath .. ": "
                                .. tostring(not wrote and writeError or closeError), 0)
                        end
                        local backedUp, backupError = pcall(nativeFs.move, path, backup)
                        if not backedUp then
                            nativeFs.delete(temporary)
                            error("Could not back up private storage file " .. relativePath .. ": "
                                .. tostring(backupError), 0)
                        end
                        movedt, moveErrort = pcall(nativeFs.move, temporary, path)
                        if not movedt then
                            if nativeFs.exists(temporary) then nativeFs.delete(temporary) end
                            restoredt, restoreErrort = pcall(nativeFs.move, backup, path)
                            error("Could not install encrypted storage file " .. relativePath .. ": "
                                .. tostring(moveErrort)
                                .. (restoredt and "" or "; restoring the backup also failed: "
                                    .. tostring(restoreErrort)), 0)
                        end
                        nativeFs.delete(backup)
                    end
                end
            end
        end

        local migrated, migrationError = pcall(migrateLegacyDirectory, storageRoot, "")
        if not migrated then
            error("Could not migrate private storage: " .. tostring(migrationError), 0)
        end

        return api
    end

    local packageState = {
        loaded = {},
        preload = {},
    }

    local function createEnvironment(parent, runningProgram)
        term.clear()
        term.setCursorPos(1, 1)
        local environment = {}
        for name, value in pairs(_ENV) do environment[name] = value end
        if type(parent) == "table" then
            for name, value in pairs(parent) do environment[name] = value end
        end

        local sandboxFs = {}
        sandboxFs.combine = function(...)
            local parts = { ... }
            local joined = ""
            for index, part in ipairs(parts) do
                if type(part) ~= "string" then
                    error("Filesystem paths must be strings.", 0)
                end
                if index == 1 then
                    joined = part
                elseif joined == "" then
                    joined = part
                else
                    joined = joined .. "/" .. part
                end
            end
            return virtualAbsolute(joined)
        end
        sandboxFs.getName = function(path)
            if isRecoveryProtectedPath(path) then error("This path is unavailable in recovery mode.", 0) end
            local target = physicalPath(path)
            if not target then return nil end
            return nativeFs.getName(target)
        end
        sandboxFs.getDir = function(path)
            if isRecoveryProtectedPath(path) then error("This path is unavailable in recovery mode.", 0) end
            local normalized = normalizeVirtualPath(path)
            local alias, aliasPath = normalized:match("^([%w@#]+://)(.*)$")
            local target = physicalPath(path)
            if not target then return nil end
            if alias then return alias .. nativeFs.getDir(aliasPath) end
            local directory = nativeFs.getDir(normalized)
            return directory == "" and "/" or "/" .. directory
        end

        local pathFunctions = {
            "exists", "isDir", "list", "makeDir", "delete", "getSize",
            "getFreeSpace", "getDrive", "isDriveRoot", "isReadOnly",
            "getCapacity", "attributes", "open",
        }
        for _, name in ipairs(pathFunctions) do
            if type(nativeFs[name]) == "function" then
                local nativeFunction = nativeFs[name]
                if name == "list" then
                    sandboxFs[name] = function(path, ...)
                        local target = physicalPath(path)
                        if not target then return nil end
                        local entries = nativeFunction(target, ...)
                        if not recoveryRootAccess then return entries end
                        local visible = {}
                        for _, entry in ipairs(entries) do
                            if not isRecoveryProtectedPath(nativeFs.combine(target, entry)) then
                                visible[#visible + 1] = entry
                            end
                        end
                        return visible
                    end
                elseif name == "delete" then
                    sandboxFs[name] = function(path, ...)
                        local target = physicalPath(path)
                        if not target then return nil end
                        if containsRecoveryProtectedPath(target) then
                            error("This location is unavailable in recovery mode.", 0)
                        end
                        return nativeFunction(target, ...)
                    end
                else
                    sandboxFs[name] = function(path, ...)
                        local target = physicalPath(path)
                        if not target then return nil end
                        return nativeFunction(target, ...)
                    end
                end
            end
        end
        for _, name in ipairs({ "move", "copy" }) do
            if type(nativeFs[name]) == "function" then
                local nativeFunction = nativeFs[name]
                sandboxFs[name] = function(source, destination, ...)
                    local sourcePath = physicalPath(source)
                    local destinationPath = physicalPath(destination)
                    if not sourcePath or not destinationPath then return nil end
                    if containsRecoveryProtectedPath(sourcePath)
                        or containsRecoveryProtectedPath(destinationPath) then
                        error("This location is unavailable in recovery mode.", 0)
                    end
                    return nativeFunction(sourcePath, destinationPath, ...)
                end
            end
        end
        if type(nativeFs.find) == "function" then
            sandboxFs.find = function(pattern)
                local results = {}
                local physicalHome = nativeFs.combine(homeDirectory, "")
                local normalizedPattern = normalizeVirtualPath(pattern)
                local alias = normalizedPattern:match("^([%w@#]+://)")
                if alias then
                    local base = physicalPath(alias)
                    local target = physicalPath(pattern)
                    if not base or not target then return nil end
                    local normalizedBase = base:gsub("^/+", ""):gsub("/+$", "")
                    for _, found in ipairs(nativeFs.find(target)) do
                        local normalizedFound = found:gsub("^/+", "")
                        if not isRecoveryProtectedPath(found)
                            and (normalizedFound == normalizedBase
                                or normalizedFound:sub(1, #normalizedBase + 1) == normalizedBase .. "/") then
                            local suffix = normalizedFound == normalizedBase and ""
                                or normalizedFound:sub(#normalizedBase + 2)
                            results[#results + 1] = alias .. suffix
                        end
                    end
                    return results
                end
                if recoveryRootAccess then
                    local target = physicalPath(pattern)
                    if not target then return nil end
                    for _, found in ipairs(nativeFs.find(target)) do
                        if not isRecoveryProtectedPath(found) then
                            results[#results + 1] = "/" .. found:gsub("^/+", "")
                        end
                    end
                    return results
                end
                local targetUsername = normalizedPattern:match("^users/([%w_-]+)/")
                    or normalizedPattern:match("^users/([%w_-]+)$")
                local physicalProfileRoot = targetUsername
                    and nativeFs.combine(USER_ROOT, targetUsername)
                local target = physicalPath(pattern)
                if not target then return nil end
                for _, found in ipairs(nativeFs.find(target)) do
                    local normalizedFound = found:gsub("^/+", "")
                    if normalizedFound == physicalHome then
                        table.insert(results, "/")
                    elseif normalizedFound:sub(1, #physicalHome + 1) == physicalHome .. "/" then
                        table.insert(results, "/" .. normalizedFound:sub(#physicalHome + 2))
                    elseif physicalProfileRoot
                        and (normalizedFound == physicalProfileRoot
                            or normalizedFound:sub(1, #physicalProfileRoot + 1) == physicalProfileRoot .. "/") then
                        table.insert(results, "/" .. normalizedFound)
                    end
                end
                return results
            end
        end
        if type(nativeFs.complete) == "function" then
            sandboxFs.complete = function(path, location, includeFiles, includeDirs)
                local normalized = normalizeVirtualPath(path)
                local alias, aliasPath = normalized:match("^([%w@#]+://)(.*)$")
                local pathForParts = alias and aliasPath or path
                local pathDirectory = nativeFs.getDir(pathForParts)
                local name = nativeFs.getName(pathForParts)
                local baseDirectory
                if alias then
                    baseDirectory = alias .. pathDirectory
                else
                    baseDirectory = path:sub(1, 1) == "/" and "/" or (location or virtualDirectory)
                    baseDirectory = normalizeVirtualPath(
                        baseDirectory .. (pathDirectory ~= "" and "/" .. pathDirectory or "")
                    )
                end
                local physicalDirectory = physicalPath(baseDirectory)
                if not physicalDirectory then return nil end
                local completions = nativeFs.complete(
                    name,
                    physicalDirectory,
                    includeFiles,
                    includeDirs
                )
                local prefix = pathDirectory ~= "" and pathDirectory .. "/" or ""
                local result = {}
                for _, completion in ipairs(completions) do
                    local completedPhysical = nativeFs.combine(physicalDirectory, completion)
                    if not isRecoveryProtectedPath(completedPhysical) then
                        table.insert(result, (alias or "") .. prefix .. completion)
                    end
                end
                return result
            end
        end

        local sandboxOs = {}
        for name, value in pairs(nativeOs) do sandboxOs[name] = value end
        sandboxOs.loadAPI = nil
        sandboxOs.unloadAPI = nil
        local currentEnvironment = environment
        sandboxOs.run = function(parent, path, ...)
            local virtualPath = normalizeVirtualPath(path)
            local target = nativeFs.combine(homeDirectory, virtualPath)
            if not nativeFs.exists(target) or nativeFs.isDir(target) then return false end
            local parentEnvironment = type(parent) == "table" and parent or currentEnvironment
            local child = createEnvironment(parentEnvironment, virtualPath)
            return nativeOs.run(child, target, ...)
        end

        local sandboxShell
        sandboxShell = {
            dir = function() return virtualDirectory end,
            setDir = function(path)
                local target = physicalPath(path)
                if not nativeFs.isDir(target) then return false end
                virtualDirectory = normalizeVirtualPath(path)
                return true
            end,
            getRunningProgram = function() return virtualAbsolute(runningProgram) end,
            resolveProgram = function(path)
                if type(path) ~= "string" then return nil end
                local target = normalizeVirtualPath(path)
                local candidates = { target }
                if not path:find("/", 1, true) then
                    table.insert(candidates, normalizeVirtualPath("apps/" .. path))
                end
                for _, candidate in ipairs(candidates) do
                    local resolved = nativeFs.combine(homeDirectory, candidate)
                    if nativeFs.exists(resolved) and not nativeFs.isDir(resolved) then
                        return candidate == "" and "/" or "/" .. candidate
                    end
                end
                return nil
            end,
            run = function(path, ...)
                local resolved = sandboxShell.resolveProgram(path)
                if not resolved then return false end
                return sandboxOs.run(currentEnvironment, resolved, ...)
            end,
            execute = function(path, ...)
                return sandboxShell.run(path, ...)
            end,
            path = function() return "." end,
        }

        environment.fs = sandboxFs
        environment.os = sandboxOs
        environment.shell = sandboxShell
        environment.launcherTheme = getThemeInfo()
        local storageModule = createStorageModule()
        -- Each sandbox gets its own rift table so rift.storage is bound to this profile.
        local sandboxRift = {}
        for name, value in pairs(riftApi) do sandboxRift[name] = value end
        sandboxRift.storage = storageModule
        sandboxRift.notify = function(text, options)
            local merged = {}
            if type(options) == "table" then
                for key, value in pairs(options) do merged[key] = value end
            end
            merged.app = riftModules.appName()
            return notifyUser(text, merged)
        end
        sandboxRift.ui = riftModules.ui()
        sandboxRift.account = riftModules.account(storageModule, sandboxRift.ui)
        sandboxRift.permissions = {
            has = function(capability)
                local key = tostring(currentUser) .. ":cap:" .. tostring(capability)
                local saved = bgServices.permissions()[key]
                return saved == true or riftModules.sessionGrants[key] == true
            end,
            request = function(capability, label)
                return riftModules.check(tostring(capability), label, riftModules.appName())
            end,
            revoke = function(capability) riftModules.revoke(tostring(capability)) end,
            list = riftModules.list,
        }
        environment.peripheral = riftModules.peripheral()
        environment.rift = sandboxRift
        environment.storage = sandboxRift.storage
        environment._G = environment
        environment.debug = nil
        environment.package = packageState
        environment.commands = nil
        environment.require = function(moduleName)
            if type(moduleName) ~= "string" then
                error("Module name must be a string.", 2)
            end
            local loaded = packageState.loaded[moduleName]
            if loaded ~= nil then return loaded end

            local loader = packageState.preload[moduleName]
            if loader ~= nil then
                if type(loader) ~= "function" then
                    error("Preloaded module '" .. moduleName .. "' must be a function.", 2)
                end
                packageState.loaded[moduleName] = true
                local ok, result = pcall(loader, moduleName)
                if not ok then
                    packageState.loaded[moduleName] = nil
                    error(result, 2)
                end
                if result ~= nil and packageState.loaded[moduleName] == true then
                    packageState.loaded[moduleName] = result
                end
                return packageState.loaded[moduleName]
            end

            if moduleName == "package" then return packageState end
            if moduleName == "storage" or moduleName == "rift" then
                if moduleName == "rift" then
                    packageState.loaded.rift = sandboxRift
                    return sandboxRift
                end
                packageState.loaded.storage = storageModule
                return storageModule
            end
            if moduleName == "cc.pretty" and type(nativeRequire) == "function" then
                local ok, result = pcall(nativeRequire, moduleName)
                if not ok then error(result, 2) end
                packageState.loaded[moduleName] = result
                return result
            end
            error("Only preloaded modules, storage, and the built-in cc.pretty module are available to profile apps.", 2)
        end
        environment.loadfile = nil
        environment.dofile = nil
        environment.loadstring = nil
        environment.getfenv = nil
        environment.setfenv = nil
        environment.io = nil
        environment.help = nil
        environment.settings = nil
        environment.multishell = nil
        if type(environment.paintutils) == "table" then
            local safePaintutils = {}
            for name, value in pairs(environment.paintutils) do safePaintutils[name] = value end
            if type(environment.paintutils.loadImage) == "function" then
                local nativeLoadImage = environment.paintutils.loadImage
                safePaintutils.loadImage = function(path)
                    return nativeLoadImage(physicalPath(path))
                end
            end
            environment.paintutils = safePaintutils
        end
        if type(environment.cc) == "table" then
            local safeCc = {}
            for name, value in pairs(environment.cc) do
                if name ~= "require" and name ~= "internal" then safeCc[name] = value end
            end
            environment.cc = safeCc
        end
        if type(load) == "function" then
            local nativeLoad = load
            environment.load = function(chunk, chunkName, mode, chunkEnvironment)
                return nativeLoad(chunk, chunkName, mode, chunkEnvironment or environment)
            end
        end
        return environment
    end

    local environment = createEnvironment(_ENV, virtualProgram)
    local target = nativeFs.combine(homeDirectory, virtualProgram)
    return nativeOs.run(environment, target, ...)
end

-- Background services, modelled on Windows services: each is installed with a display name,
-- a startup type (automatic, manual or disabled) and a recovery action, then started and
-- stopped by name. They run headless with no window, focus or input events.
local START_TYPES = { automatic = true, manual = true, disabled = true }

bgServices.configPath = function()
    return homeDirectory and (homeDirectory .. "/.services.json")
end

bgServices.load = function()
    local path = bgServices.configPath()
    if not path or not fs.exists(path) then return {} end
    local handle = fs.open(path, "r")
    if not handle then return {} end
    local contents = handle.readAll()
    handle.close()
    local ok, data = pcall(textutils.unserializeJSON, contents)
    return ok and type(data) == "table" and data or {}
end

bgServices.save = function(config)
    local path = bgServices.configPath()
    if not path then return false end
    local handle = fs.open(path, "w")
    if not handle then return false end
    handle.write(textutils.serializeJSON(config))
    handle.close()
    return true
end

bgServices.find = function(name)
    for _, service in ipairs(bgServices.list) do
        if service.name == name then return service end
    end
end

bgServices.remove = function(service)
    for index, candidate in ipairs(bgServices.list) do
        if candidate == service then
            table.remove(bgServices.list, index)
            return
        end
    end
end

bgServices.resume = function(service, event)
    local previousTerm = term.current()
    local previousChain = inAppChain
    inAppChain = true
    term.redirect(service.window)
    local previousQuiet = bgServices.quiet
    local previousHosting = bgServices.hosting
    local previousApp = bgServices.currentApp
    bgServices.hosting = service.isHost and service or nil
    bgServices.currentApp = service.appPath or previousApp
    bgServices.quiet = true
    local packed = table.pack(coroutine.resume(service.co, table.unpack(event, 1, event.n)))
    bgServices.currentApp = previousApp
    bgServices.hosting = previousHosting
    bgServices.quiet = previousQuiet
    term.redirect(previousTerm)
    inAppChain = previousChain
    service.filter = packed[2]
    if coroutine.status(service.co) == "dead" then
        service.finished = true
        service.packed = packed
    end
end

-- Last non-blank line the service printed; its only way to say why it failed.
bgServices.lastOutput = function(service)
    local _, height = service.window.getSize()
    for row = height, 1, -1 do
        local ok, line = pcall(service.window.getLine, row)
        if ok and type(line) == "string" and line:match("%S") then
            return (line:gsub("%s+$", ""))
        end
    end
end

bgServices.finish = function(service)
    bgServices.remove(service)
    if service.stopping then return end
    local failed = service.packed[1] == false or service.packed[2] == false
    if not failed then
        bgServices.status[service.name] = "Stopped"
        bootLog("SERVICE " .. service.name .. " stopped by itself")
        return
    end
    local detail = tostring(service.packed[1] == false and service.packed[2] or bgServices.lastOutput(service) or "unknown error")
    bgServices.status[service.name] = "Failed: " .. detail
    bootLog("SERVICE " .. service.name .. " failed: " .. detail)
    notifyUser(service.display .. " service failed: " .. detail)
    local entry = bgServices.load()[service.name]
    local crashes = (bgServices.crashes[service.name] or 0) + 1
    bgServices.crashes[service.name] = crashes
    -- Recovery action "restart" retries with a growing delay, giving up after five failures.
    if entry and entry.recovery == "restart" and entry.startType ~= "disabled" and crashes <= 5 then
        local timer = nativeOs.startTimer(5 * 2 ^ (crashes - 1))
        bgServices.restarts[timer] = service.name
    end
end

bgServices.launch = function(name, entry)
    if bgServices.find(name) then return false, "Service is already running." end
    if not homeDirectory then return false, "Nobody is signed in." end
    if not window or not window.create then return false, "Windows are unavailable." end
    local physical = fs.combine(homeDirectory, entry.path)
    if not fs.exists(physical) or fs.isDir(physical) then
        bgServices.status[name] = "Failed: program not found"
        return false, "Program not found: " .. tostring(entry.path)
    end
    local width, height = term.native().getSize()
    local service = {
        name = name,
        display = entry.displayName or name,
        co = coroutine.create(runHomeProgram),
        window = window.create(term.native(), 1, 1, width, height, false),
    }
    local context = {
        user = currentUser,
        homeDirectory = homeDirectory,
        passwords = profilePasswords,
        admins = profileAdmins,
        authorized = authorizedProfiles,
        recovery = recoverySession,
    }
    bgServices.list[#bgServices.list + 1] = service
    bgServices.status[name] = "Running"
    bootLog("SERVICE " .. name .. " starting (" .. tostring(entry.path) .. ")")
    bgServices.resume(service, table.pack(physical, context, homeDirectory))
    if service.finished then bgServices.finish(service) end
    return true
end

-- Runs a Lua function as a headless service. It lives until it ends, is stopped, or the user signs out.
bgServices.spawn = function(name, fn, displayName)
    if bgServices.find(name) then return false, "Service is already running." end
    if not window or not window.create then return false, "Windows are unavailable." end
    local width, height = term.native().getSize()
    local service = {
        name = name,
        display = displayName or name,
        co = coroutine.create(fn),
        window = window.create(term.native(), 1, 1, width, height, false),
        spawned = true,
    }
    bgServices.list[#bgServices.list + 1] = service
    bgServices.status[name] = "Running"
    bootLog("SERVICE " .. name .. " spawned from function")
    bgServices.resume(service, table.pack())
    if service.finished then bgServices.finish(service) end
    return true
end

bgServices.stop = function(name, quiet)
    local service = bgServices.find(name)
    for timer, pendingName in pairs(bgServices.restarts) do
        if pendingName == name then bgServices.restarts[timer] = nil end
    end
    if not service then return false, "Service is not running." end
    service.stopping = true
    service.finished = true
    bgServices.remove(service)
    bgServices.status[name] = "Stopped"
    if not quiet then bootLog("SERVICE " .. name .. " stopped") end
    return true
end

bgServices.stopAll = function()
    for index = #bgServices.list, 1, -1 do
        bgServices.stop(bgServices.list[index].name, true)
    end
    bgServices.list = {}
    bgServices.restarts = {}
    bgServices.crashes = {}
    bgServices.status = {}
    bgServices.endpoints = {}
end

-- Persisted services cannot save their function, so the app that spawned them is re-run hidden
-- after sign-in. Once it spawns the service again, the hidden host is discarded.
bgServices.persistPrefix = function()
    return "persist:" .. tostring(currentUser) .. ":"
end

bgServices.launchHost = function(name, record)
    if bgServices.find(name) or bgServices.find("host:" .. name) then return end
    local path = type(record) == "table" and record.path
    if type(path) ~= "string" or not isInHomeDirectory(path) or not fs.exists(path) or fs.isDir(path) then
        bootLog("SERVICE " .. name .. " persisted app is missing; not restored")
        return
    end
    local width, height = term.native().getSize()
    local service = {
        name = "host:" .. name,
        hostFor = name,
        display = tostring(record.displayName or name),
        isHost = true,
        appPath = path,
        deadline = nativeOs.clock() + 30,
        co = coroutine.create(runHomeProgram),
        window = window.create(term.native(), 1, 1, width, height, false),
    }
    local context = {
        user = currentUser,
        homeDirectory = homeDirectory,
        passwords = profilePasswords,
        admins = profileAdmins,
        authorized = authorizedProfiles,
    }
    bgServices.list[#bgServices.list + 1] = service
    bootLog("SERVICE " .. name .. " restoring via " .. path)
    bgServices.resume(service, table.pack(path, context, homeDirectory))
    if service.finished then bgServices.finish(service) end
end

bgServices.startAutomatic = function()
    if not homeDirectory then return end
    local names = {}
    for name, entry in pairs(bgServices.load()) do
        if entry.startType == "automatic" then names[#names + 1] = name end
    end
    table.sort(names)
    local config = bgServices.load()
    for _, name in ipairs(names) do
        local ok, reason = bgServices.launch(name, config[name])
        if not ok then bootLog("SERVICE " .. name .. " did not start: " .. tostring(reason)) end
    end
    local prefix = bgServices.persistPrefix()
    local persisted = {}
    for key, value in pairs(bgServices.permissions()) do
        if key:sub(1, #prefix) == prefix and type(value) == "table" then
            persisted[#persisted + 1] = key:sub(#prefix + 1)
        end
    end
    table.sort(persisted)
    local permissions = bgServices.permissions()
    for _, name in ipairs(persisted) do
        bgServices.launchHost(name, permissions[prefix .. name])
    end
end

bgServices.pump = function(event)
    local name = event[1]
    if rawInputEvents[name] or (type(name) == "string" and (name:sub(1, 5) == "rift_"
        or name == "session_action" or name == "menu_closed")) then
        return
    end
    for _, service in ipairs({ table.unpack(bgServices.list) }) do
        if service.isHost and not service.finished and nativeOs.clock() > service.deadline then
            bootLog("SERVICE " .. tostring(service.hostFor) .. " restore timed out")
            bgServices.stop(service.name, true)
        end
    end
    if name == "timer" and bgServices.restarts[event[2]] then
        local serviceName = bgServices.restarts[event[2]]
        bgServices.restarts[event[2]] = nil
        local entry = bgServices.load()[serviceName]
        if entry and entry.startType ~= "disabled" then bgServices.launch(serviceName, entry) end
        return
    end
    for _, service in ipairs({ table.unpack(bgServices.list) }) do
        if not service.finished and (service.filter == nil or service.filter == name) then
            bgServices.resume(service, event)
            if service.finished then bgServices.finish(service) end
        end
    end
end

bgServices.permissionPath = SYSTEM_DIRECTORY .. "/system/service-permissions.json"

-- Permissions live outside the profile so apps cannot grant themselves access.
bgServices.permissions = function()
    if not fs.exists(bgServices.permissionPath) then return {} end
    local handle = fs.open(bgServices.permissionPath, "r")
    if not handle then return {} end
    local contents = handle.readAll()
    handle.close()
    local ok, data = pcall(textutils.unserializeJSON, contents)
    return ok and type(data) == "table" and data or {}
end

bgServices.remember = function(key, allowed)
    local data = bgServices.permissions()
    data[key] = allowed
    pcall(fs.makeDir, SYSTEM_DIRECTORY .. "/system")
    local handle = fs.open(bgServices.permissionPath, "w")
    if handle then
        handle.write(textutils.serializeJSON(data))
        handle.close()
    end
end

bgServices.clearUserServices = function(username)
    bgServices.stopAll()
    local serviceConfig = fs.combine(USER_ROOT, username, ".services.json")
    if fs.exists(serviceConfig) then pcall(fs.delete, serviceConfig) end

    local permissions = bgServices.permissions()
    local servicePrefix = username .. ":"
    local capabilityPrefix = servicePrefix .. "cap:"
    local persistPrefix = "persist:" .. username .. ":"
    local changed = false
    for key in pairs(permissions) do
        if key:sub(1, #persistPrefix) == persistPrefix
            or key:sub(1, #servicePrefix) == servicePrefix
                and key:sub(1, #capabilityPrefix) ~= capabilityPrefix then
            permissions[key] = nil
            changed = true
        end
    end
    if changed then
        pcall(fs.makeDir, SYSTEM_DIRECTORY .. "/system")
        local handle = fs.open(bgServices.permissionPath, "w")
        if handle then
            handle.write(textutils.serializeJSON(permissions))
            handle.close()
        end
    end
end

-- Draws a Y/A/N/D permission box over the screen and returns "once", "always", "no" or "never".
bgServices.prompt = function(lines)
    local screen = term.native()
    local deferred, answer = {}, nil
    local previousBlink = term.getCursorBlink()
    local function render()
        local width, height = screen.getSize()
        local boxWidth = math.min(width, 28)
        local boxHeight = math.min(height, #lines + 2)
        local left = math.floor((width - boxWidth) / 2) + 1
        local top = math.max(1, math.floor((height - boxHeight) / 2) + 1)
        screen.setCursorBlink(false)
        for row = 0, boxHeight - 1 do
            screen.setCursorPos(left, top + row)
            screen.setBackgroundColor(colors.gray)
            screen.setTextColor(colors.white)
            screen.write(string.rep(" ", boxWidth))
        end
        for index, text in ipairs(lines) do
            if top + index <= top + boxHeight - 1 then
                screen.setCursorPos(left + 1, top + index)
                screen.setTextColor(index == 1 and colors.yellow or colors.white)
                screen.write(text:sub(1, boxWidth - 2))
            end
        end
    end
    while answer == nil do
        render()
        local event = table.pack(unfilteredPullEventRaw())
        if event[1] == "key" then
            local code = event[2]
            if code == keys.y then answer = "once"
            elseif code == keys.a then answer = "always"
            elseif code == keys.n or code == keys.escape then answer = "no"
            elseif code == keys.d then answer = "never" end
        elseif event[1] == "terminate" then
            answer = "no"
        elseif not rawInputEvents[event[1]] and #deferred < 200 then
            deferred[#deferred + 1] = event
        end
    end
    screen.setCursorBlink(previousBlink)
    for _, event in ipairs(deferred) do
        nativeOs.queueEvent(table.unpack(event, 1, event.n))
    end
    nativeOs.queueEvent("term_resize")
    return answer
end

-- Asks the user to allow a background service. Returns true or false.
bgServices.ask = function(name, displayName, persist)
    if recoverySession then return false end
    local key = tostring(currentUser) .. ":" .. name
    local saved = bgServices.permissions()[key]
    if saved ~= nil then return saved == true end
    -- Background code has no input focus, so it can only use a stored decision.
    if bgServices.quiet or screenLocked or not sessionMenuAllowed then
        bootLog("SERVICE " .. name .. " denied: no stored permission and cannot ask")
        return false
    end
    local answer = bgServices.prompt({
        "BACKGROUND SERVICE",
        "",
        "An app wants to run",
        tostring(displayName),
        persist and "in the background, and" or "in the background.",
        persist and "restart it after reboot." or "",
        "Y Allow once   A Always",
        "N Deny         D Never",
    })
    bootLog("SERVICE permission for " .. name .. ": " .. answer)
    -- A persistent service only works after reboot with a stored decision, so "once" becomes "always".
    if persist and answer == "once" then answer = "always" end
    if answer == "always" then bgServices.remember(key, true) end
    if answer == "never" then bgServices.remember(key, false) end
    return answer == "once" or answer == "always"
end

-- Capability permissions (peripherals, notifications): stored per user, outside the profile.
riftModules.sessionGrants = {}
riftModules.check = function(capability, label, appName)
    local key = tostring(currentUser) .. ":cap:" .. capability
    local saved = bgServices.permissions()[key]
    if saved ~= nil then return saved == true end
    if riftModules.sessionGrants[key] ~= nil then return riftModules.sessionGrants[key] end
    if bgServices.quiet or screenLocked or not sessionMenuAllowed then
        bootLog("PERMISSION " .. capability .. " denied: no stored decision and cannot ask")
        return false
    end
    local answer = bgServices.prompt({
        "PERMISSION REQUEST",
        "",
        tostring(appName or "An app") .. " wants to use",
        tostring(label or capability),
        "",
        "Y Allow once   A Always",
        "N Deny         D Never",
    })
    bootLog("PERMISSION " .. capability .. " for " .. tostring(appName) .. ": " .. answer)
    if answer == "always" then bgServices.remember(key, true) end
    if answer == "never" then bgServices.remember(key, false) end
    local allowed = answer == "once" or answer == "always"
    -- "Once" lasts for the session so an app is not asked again on every call; "no" is asked again later.
    if allowed then riftModules.sessionGrants[key] = true end
    return allowed
end

riftModules.revoke = function(capability)
    local key = tostring(currentUser) .. ":cap:" .. capability
    riftModules.sessionGrants[key] = nil
    bgServices.remember(key, nil)
end

riftModules.list = function()
    local result, prefix = {}, tostring(currentUser) .. ":cap:"
    for key, value in pairs(bgServices.permissions()) do
        if key:sub(1, #prefix) == prefix then
            result[#result + 1] = { capability = key:sub(#prefix + 1), allowed = value == true }
        end
    end
    table.sort(result, function(a, b) return a.capability < b.capability end)
    return result
end

-- Shared Rift account client: one sign-in used by every app (per profile storage).
riftModules.account = function(store, ui)
    local ACCOUNT_FILE, LEGACY_FILE = "rift/account.json", "rift-jobs/login.json"
    local state = { user = nil }
    local api = {}
    local marketFields = { deliveryAddresses = true, providerAddress = true }

    local function load()
        for _, path in ipairs({ ACCOUNT_FILE, LEGACY_FILE }) do
            local ok, data = pcall(store.read, path)
            if ok and type(data) == "table" and type(data.username) == "string" then return data end
        end
        return nil
    end
    local function save(data)
        local ok, saved = pcall(store.write, ACCOUNT_FILE, data)
        return ok and saved and true or false
    end
    local function ensureRednet()
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "modem" and rednet.isOpen(name) then return true end
        end
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "modem" then
                rednet.open(name)
                return true
            end
        end
        return false
    end
    local function request(message)
        if not ensureRednet() then return nil, "Attach a modem to use your Rift account." end
        local protocol = "rift_account_v1"
        local serverId = rednet.lookup(protocol, "rift-server")
        if not serverId then
            protocol = "rift_jobs_v1"
            serverId = rednet.lookup(protocol, "rift-jobs")
        end
        if not serverId then return nil, "Rift account server not found." end
        rednet.send(serverId, message, protocol)
        local senderId, response = rednet.receive(protocol, 5, serverId)
        if senderId ~= serverId or type(response) ~= "table" then
            return nil, "No response from the Rift account server."
        end
        if response.type == "error" then return nil, response.message or "The request failed." end
        return response
    end
    local function authenticate(action, username, password)
        if type(username) ~= "string" or username == "" or type(password) ~= "string" or password == "" then
            return false, "Enter a username and password."
        end
        local response, err = request({ type = action, username = username, password = password })
        if not response then return false, err end
        if response.type ~= "authenticated" or type(response.username) ~= "string" then
            return false, "Unexpected response from the Rift account server."
        end
        local data = load()
        if not data or data.username:lower() ~= response.username:lower() then data = {} end
        data.username = response.username
        data.password = password
        save(data)
        state.user = response.username
        return true, response.username
    end

    api.saved = function()
        local data = load()
        return data and data.username or nil
    end
    api.current = function() return state.user end
    api.login = function(username, password) return authenticate("login", username, password) end
    api.register = function(username, password) return authenticate("register", username, password) end
    api.lookup = function(identifier)
        if not state.user then return nil, "Sign in to your Rift account first." end
        local response, err = request({ type = "lookup", identifier = identifier })
        if not response then return nil, err end
        if response.type ~= "account_lookup" or type(response.username) ~= "string"
            or type(response.uuid) ~= "string" then
            return nil, "Unexpected response from the Rift account server."
        end
        return { username = response.username, uuid = response.uuid }
    end
    api.auto = function()
        local data = load()
        if not data or type(data.password) ~= "string" then return false, "No saved Rift account." end
        return authenticate("login", data.username, data.password)
    end
    api.logout = function()
        local response, err = request({ type = "logout" })
        local data = load()
        if data then
            data.password = nil
            save(data)
        end
        state.user = nil
        if not response then return false, err end
        return true
    end
    -- Launcher-drawn account page shared by every app. Returns the username, or nil if cancelled.
    api.signIn = function(options)
        options = type(options) == "table" and options or {}
        options.app = options.app or riftModules.appName()
        if state.user then return state.user end
        local ok, result = api.auto()
        if ok then return result end
        local saved = api.saved()
        local status = saved and result ~= "No saved Rift account." and tostring(result) or nil
        local theme = getThemeInfo()
        local accent = term.isColor() and theme.accent or colors.gray
        local function page(title, hint)
            local screen = term.current()
            local width, height = screen.getSize()
            screen.setBackgroundColor(colors.black)
            screen.clear()
            screen.setCursorPos(1, 1)
            screen.setBackgroundColor(accent)
            screen.setTextColor(colors.white)
            screen.write(string.rep(" ", width))
            screen.setCursorPos(2, 1)
            screen.write("RIFT ACCOUNT" .. (options.app and ("  /  " .. tostring(options.app):upper()) or ""))
            screen.setBackgroundColor(colors.black)
            screen.setCursorPos(2, 3)
            screen.setTextColor(colors.white)
            screen.write(title)
            if hint then
                screen.setCursorPos(2, 4)
                screen.setTextColor(colors.lightGray)
                screen.write(hint:sub(1, width - 2))
            end
            if status then
                screen.setCursorPos(2, height)
                screen.setTextColor(colors.yellow)
                screen.write(status:sub(1, width - 2))
            end
            screen.setTextColor(colors.white)
        end
        local function field(label, hidden, default)
            page(label, "Enter to confirm, leave blank to go back")
            local _, height = term.getSize()
            local screen = term.current()
            screen.setCursorPos(2, 6)
            screen.setTextColor(accent)
            screen.write("> ")
            screen.setTextColor(colors.white)
            local value = read(hidden and "*" or nil, nil, nil, default)
            if value == nil or value == "" then return nil end
            return value
        end
        local function choose()
            local labels = { "Sign in", "Create account", "Cancel" }
            local selected = 1
            while true do
                page("Sign in with your Rift account", options.reason)
                local screen = term.current()
                for index, label in ipairs(labels) do
                    screen.setCursorPos(3, 5 + index)
                    screen.setBackgroundColor(index == selected and accent or colors.black)
                    screen.setTextColor(colors.white)
                    screen.write(" " .. label .. " ")
                end
                screen.setBackgroundColor(colors.black)
                local event, a, b, c = os.pullEvent()
                if event == "key" then
                    if a == keys.up and selected > 1 then selected = selected - 1
                    elseif a == keys.down and selected < #labels then selected = selected + 1
                    elseif a == keys.enter then return selected
                    elseif a == keys.escape then return 3 end
                elseif event == "mouse_click" then
                    local index = c - 5
                    if index >= 1 and index <= #labels and b >= 3 then return index end
                end
            end
        end
        while true do
            local choice = choose()
            if choice == 3 then
                os.queueEvent("term_resize")
                return nil
            end
            status = nil
            local username = field(choice == 1 and "Username or UUID" or "Username", false, saved)
            local password = username and field("Password", true)
            local confirmed = password
            if password and choice == 2 then
                confirmed = field("Confirm password", true)
                if confirmed ~= password then
                    status = "The passwords do not match."
                    password = nil
                end
            end
            if username and password and confirmed then
                local success, message = authenticate(choice == 2 and "register" or "login", username, password)
                if success then
                    os.queueEvent("term_resize")
                    return message
                end
                status = tostring(message)
            end
        end
    end
    api.get = function(key, subkey, ...)
        local default = ...
        if marketFields[key] and select("#", ...) == 0 then
            default, subkey, key = subkey, key, "market"
        end
        if not state.user then return nil, "Sign in to your Rift account first." end
        local response, err = request({ type = "get_data", key = key, subkey = subkey })
        if not response then return nil, err end
        if response.type ~= "account_data" then return nil, "Unexpected response from the Rift account server." end
        if response.found then return response.value end
        if key == "market" and marketFields[subkey] then
            local data = load()
            if data and data.username:lower() == state.user:lower() and data[subkey] ~= nil then
                local saved, saveError = request({ type = "set_data", key = key, subkey = subkey, value = data[subkey] })
                if not saved then return nil, saveError end
                if saved.type ~= "account_data_saved" then
                    return nil, "Unexpected response from the Rift account server."
                end
                local value = data[subkey]
                data[subkey] = nil
                if not save(data) then return nil, "Could not update local Rift account data." end
                return value
            end
        end
        return default
    end
    api.set = function(key, subkey, ...)
        local value = ...
        if marketFields[key] and select("#", ...) == 0 then
            value, subkey, key = subkey, key, "market"
        end
        if not state.user then return false, "Sign in to your Rift account first." end
        local response, err = request({ type = "set_data", key = key, subkey = subkey, value = value })
        if not response then return false, err end
        if response.type ~= "account_data_saved" then return false, "Unexpected response from the Rift account server." end
        if key == "market" and marketFields[subkey] then
            local data = load()
            if data and data.username:lower() == state.user:lower() and data[subkey] ~= nil then
                data[subkey] = nil
                if not save(data) then return false, "Could not update local Rift account data." end
            end
        end
        return true
    end
    return api
end

riftModules.appName = function()
    local path = bgServices.currentApp
    if type(path) ~= "string" then return "An app" end
    return (fs.getName(path):gsub("%.lua$", ""))
end

-- Peripherals are blocked until the user allows each type; modems always pass.
riftModules.peripheral = function()
    local real = peripheral
    local filtered = {}
    for name, value in pairs(real) do filtered[name] = value end
    local function typeOf(name)
        if type(name) ~= "string" then return nil end
        return (real.getType(name))
    end
    local function allowed(kind)
        if kind == "modem" then return true end
        return riftModules.check("peripheral:" .. kind, "your " .. kind, riftModules.appName())
    end
    filtered.wrap = function(name)
        local kind = typeOf(name)
        if not kind or not allowed(kind) then return nil end
        return real.wrap(name)
    end
    filtered.find = function(kind, filter)
        if type(kind) ~= "string" or not allowed(kind) then return nil end
        return real.find(kind, filter)
    end
    filtered.call = function(name, ...)
        local kind = typeOf(name)
        if kind and not allowed(kind) then
            error("Access to the " .. kind .. " peripheral was denied.", 2)
        end
        return real.call(name, ...)
    end
    return filtered
end

-- Themed dialogs drawn on the app's current terminal.
riftModules.ui = function()
    local ui = {}
    local function accent()
        local theme = getThemeInfo()
        return theme.accent or colors.blue
    end
    local function wrapText(text, width)
        local lines = {}
        for paragraph in (tostring(text) .. "\n"):gmatch("(.-)\n") do
            local line = ""
            for word in paragraph:gmatch("%S+") do
                if #line + #word + 1 > width and #line > 0 then
                    lines[#lines + 1] = line
                    line = word
                else
                    line = (#line > 0 and line .. " " or "") .. word
                end
            end
            lines[#lines + 1] = line
        end
        return lines
    end
    local function box(title, lines, footer, selected)
        local screen = term.current()
        local width, height = screen.getSize()
        local boxWidth = math.min(width, 34)
        local body = {}
        for _, line in ipairs(lines) do
            for _, part in ipairs(wrapText(line, boxWidth - 2)) do body[#body + 1] = part end
        end
        local boxHeight = math.min(height, #body + 4)
        local left = math.floor((width - boxWidth) / 2) + 1
        local top = math.max(1, math.floor((height - boxHeight) / 2) + 1)
        for row = 0, boxHeight - 1 do
            screen.setCursorPos(left, top + row)
            screen.setBackgroundColor(row == 0 and accent() or colors.gray)
            screen.setTextColor(colors.white)
            screen.write(string.rep(" ", boxWidth))
        end
        screen.setCursorPos(left + 1, top)
        screen.setBackgroundColor(accent())
        screen.write(tostring(title or ""):sub(1, boxWidth - 2))
        screen.setBackgroundColor(colors.gray)
        for index, line in ipairs(body) do
            if index + 1 <= boxHeight - 2 then
                screen.setCursorPos(left + 1, top + index)
                screen.setBackgroundColor(selected == index and accent() or colors.gray)
                screen.write(line:sub(1, boxWidth - 2))
            end
        end
        screen.setBackgroundColor(colors.gray)
        screen.setTextColor(colors.lightGray)
        screen.setCursorPos(left + 1, top + boxHeight - 1)
        screen.write((footer or ""):sub(1, boxWidth - 2))
        return { left = left, top = top, width = boxWidth, height = boxHeight, count = #body }
    end
    local function finish()
        os.queueEvent("term_resize")
    end

    ui.notice = function(message, title)
        box(title or "Notice", { tostring(message) }, "Press any key")
        while true do
            local event = os.pullEvent()
            if event == "key" or event == "mouse_click" then break end
        end
        finish()
    end

    ui.confirm = function(message, title)
        box(title or "Confirm", { tostring(message) }, "Y Yes   N No")
        local answer
        while answer == nil do
            local event, code = os.pullEvent()
            if event == "key" then
                if code == keys.y or code == keys.enter then answer = true
                elseif code == keys.n or code == keys.escape then answer = false end
            end
        end
        finish()
        return answer
    end

    ui.menu = function(title, items)
        if type(items) ~= "table" or #items == 0 then return nil end
        local selected = 1
        while true do
            local labels = {}
            for index, item in ipairs(items) do labels[index] = tostring(item) end
            local area = box(title or "Choose", labels, "Up/Down Enter Esc", selected)
            local event, a, b, c = os.pullEvent()
            if event == "key" then
                if a == keys.up and selected > 1 then selected = selected - 1
                elseif a == keys.down and selected < #items then selected = selected + 1
                elseif a == keys.enter then finish() return selected
                elseif a == keys.escape then finish() return nil end
            elseif event == "mouse_click" then
                local index = c - area.top
                if b >= area.left and b < area.left + area.width and index >= 1 and items[index] then
                    finish()
                    return index
                end
            end
        end
    end

    ui.input = function(prompt, options)
        options = type(options) == "table" and options or {}
        local area = box(options.title or "Input", { tostring(prompt), "" }, "Enter to confirm")
        local screen = term.current()
        screen.setCursorPos(area.left + 1, area.top + area.height - 2)
        screen.setBackgroundColor(colors.black)
        screen.setTextColor(colors.white)
        local value = read(options.hidden and "*" or nil, nil, nil, options.default)
        finish()
        return value
    end

    ui.theme = function()
        return getThemeInfo()
    end
    return ui
end

bgServices.endpoints = {}

bgServices.api = {
    -- persistInit("name", function() ... end): declare the persistent endpoint at the top of the app.
    -- It only registers the function. It starts nothing in a normal run (spawn does that). After a
    -- reboot the launcher runs the app hidden; when the run reaches this call the launcher starts the
    -- registered function as the service and discards the hidden run, so the rest never executes.
    persistInit = function(name, fn, options)
        if recoverySession then return false, "Background services are disabled in recovery mode." end
        if type(name) ~= "string" or not name:match("^[%w_.-]+$") or #name > 32 then
            error("Service names use letters, digits, _ . - and at most 32 characters.", 2)
        end
        if type(fn) ~= "function" then error("Service body must be a function.", 2) end
        if not currentUser then return false, "Nobody is signed in." end
        local displayName = type(options) == "table" and options.displayName and tostring(options.displayName):sub(1, 40)
        local appPath = bgServices.currentApp
        if not appPath then return false, "persistInit must be called from an app in the profile." end
        bgServices.endpoints[name] = { fn = fn, displayName = displayName or name, path = appPath }
        local host = bgServices.hosting
        if host and host.hostFor == name then
            if bgServices.permissions()[tostring(currentUser) .. ":" .. name] == true then
                bgServices.spawn(name, fn, displayName)
            end
            host.stopping = true
            host.finished = true
            bgServices.remove(host)
            -- The host is discarded here, so nothing after this call runs after a reboot.
            while true do coroutine.yield("rift_service_host_done") end
        end
        return true
    end,
    -- spawn("name" [, function() ... end] [, options]): the app registers and starts the service.
    -- With a persistInit endpoint for this name the service is also restored after every reboot.
    spawn = function(name, fn, options)
        if recoverySession then return false, "Background services are disabled in recovery mode." end
        if type(name) ~= "string" or not name:match("^[%w_.-]+$") or #name > 32 then
            error("Service names use letters, digits, _ . - and at most 32 characters.", 2)
        end
        if type(fn) ~= "function" then
            if options == nil then options = fn end
            fn = nil
        end
        local endpoint = bgServices.endpoints[name]
        fn = fn or (endpoint and endpoint.fn)
        if not fn then error("Service body must be a function, or declare it with persistInit first.", 2) end
        if not currentUser then return false, "Nobody is signed in." end
        if bgServices.find(name) then return false, "Service is already running." end
        local displayName = type(options) == "table" and options.displayName and tostring(options.displayName):sub(1, 40)
            or (endpoint and endpoint.displayName)
        local persist = endpoint ~= nil
        if not bgServices.ask(name, displayName or name, persist) then return false, "Permission denied." end
        local ok, reason = bgServices.spawn(name, fn, displayName)
        if ok and persist then
            bgServices.remember(bgServices.persistPrefix() .. name,
                { path = endpoint.path, displayName = displayName or name })
        end
        return ok, reason
    end,
    -- forget("name"): stops a persistent service from coming back after reboot.
    forget = function(name)
        if type(name) ~= "string" then error("Service name must be a string.", 2) end
        bgServices.remember(bgServices.persistPrefix() .. name, nil)
        return true
    end,
    -- install("name", "/apps/sync.lua", { displayName, description, startType, recovery })
    install = function(name, path, options)
        if recoverySession then return false, "Background services are disabled in recovery mode." end
        options = type(options) == "table" and options or {}
        if type(name) ~= "string" or not name:match("^[%w_.-]+$") or #name > 32 then
            error("Service names use letters, digits, _ . - and at most 32 characters.", 2)
        end
        if type(path) ~= "string" then error("Service path must be a string.", 2) end
        local segments = {}
        for segment in path:gmatch("[^/]+") do
            if segment == ".." then error("Service path cannot leave the profile.", 2) end
            if segment ~= "." then segments[#segments + 1] = segment end
        end
        local cleanPath = table.concat(segments, "/")
        if not homeDirectory then return false, "Nobody is signed in." end
        local physical = fs.combine(homeDirectory, cleanPath)
        if not fs.exists(physical) or fs.isDir(physical) then return false, "Program not found." end
        local startType = options.startType or "manual"
        if not START_TYPES[startType] then error("startType must be automatic, manual or disabled.", 2) end
        local recovery = options.recovery == "restart" and "restart" or "none"
        local config = bgServices.load()
        config[name] = {
            path = cleanPath,
            displayName = tostring(options.displayName or name):sub(1, 40),
            description = tostring(options.description or ""):sub(1, 200),
            startType = startType,
            recovery = recovery,
        }
        return bgServices.save(config)
    end,
    uninstall = function(name)
        bgServices.stop(name)
        local config = bgServices.load()
        if not config[name] then return false, "No such service." end
        config[name] = nil
        bgServices.status[name] = nil
        bgServices.crashes[name] = nil
        return bgServices.save(config)
    end,
    start = function(name)
        if recoverySession then return false, "Background services are disabled in recovery mode." end
        local entry = bgServices.load()[name]
        if not entry then return false, "No such service." end
        if entry.startType == "disabled" then return false, "Service is disabled." end
        bgServices.crashes[name] = 0
        return bgServices.launch(name, entry)
    end,
    stop = function(name) return bgServices.stop(name) end,
    restart = function(name)
        bgServices.stop(name)
        return bgServices.api.start(name)
    end,
    setStartType = function(name, startType)
        if not START_TYPES[startType] then error("startType must be automatic, manual or disabled.", 2) end
        local config = bgServices.load()
        if not config[name] then return false, "No such service." end
        config[name].startType = startType
        if startType == "disabled" then bgServices.stop(name) end
        return bgServices.save(config)
    end,
    -- Returns "Running", "Stopped" or "Failed: reason".
    status = function(name)
        if recoverySession then return nil end
        if bgServices.find(name) then return "Running" end
        if not bgServices.load()[name] and not bgServices.status[name] then return nil end
        return bgServices.status[name] or "Stopped"
    end,
    list = function()
        if recoverySession then return {} end
        local result = {}
        for name, entry in pairs(bgServices.load()) do
            result[#result + 1] = {
                name = name,
                displayName = entry.displayName or name,
                description = entry.description or "",
                path = entry.path,
                startType = entry.startType or "manual",
                recovery = entry.recovery or "none",
                status = bgServices.find(name) and "Running" or (bgServices.status[name] or "Stopped"),
            }
        end
        table.sort(result, function(a, b) return a.name < b.name end)
        return result
    end,
}
riftApi.service = bgServices.api

local inputEvents = {
    key = true, key_up = true, char = true, paste = true, terminate = true,
    mouse_click = true, mouse_up = true, mouse_drag = true, mouse_scroll = true,
}

lockScreen = function()
    local expected = currentUser and profilePasswords[currentUser]
    if not expected or screenLocked then return false end
    screenLocked = true
    bootLog("LOCK screen engaged for " .. tostring(currentUser))
    local screen = term.native()
    local accent = screen.isColor() and colors.cyan or colors.white
    local previousBlink = term.getCursorBlink()
    local typed, status, deferred = "", "", {}

    local function render()
        local width, height = screen.getSize()
        screen.setBackgroundColor(colors.black)
        screen.clear()
        local function center(row, text, color)
            text = tostring(text):sub(1, width)
            screen.setCursorPos(math.max(1, math.floor((width - #text) / 2) + 1), row)
            screen.setTextColor(color)
            screen.write(text)
        end
        local row = math.max(1, math.floor(height / 2) - 2)
        center(row, "LOCKED", accent)
        center(row + 1, currentUser, colors.lightGray)
        local field = "Password: " .. string.rep("*", math.min(#typed, 24))
        center(row + 3, field, colors.white)
        center(row + 5, status, colors.red)
        screen.setCursorPos(math.max(1, math.floor((width - #field) / 2) + 1) + #field, row + 3)
        screen.setCursorBlink(true)
    end

    while screenLocked do
        render()
        local event = table.pack(unfilteredPullEventRaw())
        local name = event[1]
        bgServices.pump(event)
        if name == "char" or name == "paste" then
            typed = typed .. tostring(event[2])
            status = ""
        elseif name == "key" then
            if event[2] == keys.backspace then
                typed = typed:sub(1, -2)
            elseif event[2] == keys.enter or event[2] == keys.numPadEnter then
                if typed == expected then
                    screenLocked = false
                    bootLog("LOCK unlocked by " .. tostring(currentUser))
                else
                    bootLog("LOCK wrong password for " .. tostring(currentUser))
                    status = "Incorrect password."
                    typed = ""
                end
            end
        elseif not inputEvents[name] and name ~= "terminate" and #deferred < 200 then
            deferred[#deferred + 1] = event
        end
    end

    screen.setCursorBlink(previousBlink)
    lastActivity = nativeOs.clock()
    for _, event in ipairs(deferred) do
        nativeOs.queueEvent(table.unpack(event, 1, event.n))
    end
    nativeOs.queueEvent("term_resize")
    return true
end

showSessionMenu = function(inProgram)
    local level = "main"
    local options
    -- Services appear while Alt is held; see the event loop below.
    local showServices = altState.left or altState.right
    local function buildOptions()
        options = {}
        if level == "main" then
            for _, task in ipairs(tasks) do
                local label = task.name .. (task == foregroundTask and " (current)" or "")
                options[#options + 1] = { label, "task", task = task }
            end
            options[#options + 1] = { "Session  >", "session_menu" }
            if showServices and not recoverySession then
                options[#options + 1] = { "Services  >", "services_menu" }
            end
            options[#options + 1] = { "Exit Menu", "exit" }
        elseif level == "services" then
            local list = bgServices.api.list()
            local running = {}
            for _, service in ipairs(list) do running[service.name] = true end
            for _, service in ipairs(bgServices.list) do
                if not running[service.name] and not service.isHost then
                    list[#list + 1] = { name = service.name, displayName = service.display, status = "Running" }
                end
            end
            for _, service in ipairs(list) do
                local mark = service.status == "Running" and "[on] " or "[off] "
                options[#options + 1] = { mark .. service.displayName, "service", service = service }
            end
            if #list == 0 then options[#options + 1] = { "(no services)", "none" } end
            options[#options + 1] = { "< Back", "back" }
        else
            options[#options + 1] = { "Lock", "lock" }
            options[#options + 1] = { "Switch User", "switch_user" }
            options[#options + 1] = { "Logout", "logout" }
            options[#options + 1] = { "Reboot", "reboot" }
            options[#options + 1] = { "Shutdown", "shutdown" }
            options[#options + 1] = { "< Back", "back" }
        end
    end
    buildOptions()

    local width, height = term.getSize()
    local boxWidth = math.min(width, 30)
    local boxHeight = math.min(height, math.max(#tasks, #bgServices.list, 6) + 6)
    local left = math.floor((width - boxWidth) / 2) + 1
    local top = math.max(1, math.floor((height - boxHeight) / 2) + 1)
    local previousBackground, previousText = term.getBackgroundColor(), term.getTextColor()
    local previousX, previousY = term.getCursorPos()
    local previousBlink = term.getCursorBlink()
    term.setCursorBlink(false)

    local highlighted = 1
    local scrollTop = 0
    local deferred = {}
    local choice

    local function render()
        local visibleRows = boxHeight - 1
        if highlighted <= scrollTop then scrollTop = highlighted - 1 end
        if highlighted > scrollTop + visibleRows then scrollTop = highlighted - visibleRows end
        scrollTop = math.max(0, math.min(scrollTop, math.max(0, #options - visibleRows)))
        for row = 0, boxHeight - 1 do
            term.setCursorPos(left, top + row)
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.white)
            term.write(string.rep(" ", boxWidth))
        end
        local title = level == "main" and "RIFT LAUNCHER" or (level == "services" and "SERVICES" or "SESSION")
        term.setCursorPos(left + math.floor((boxWidth - #title) / 2), top)
        term.write(title)
        for row = 1, visibleRows do
            local index = scrollTop + row
            local option = options[index]
            if not option then break end
            term.setCursorPos(left, top + row)
            if index == highlighted then
                term.setBackgroundColor(colors.white)
                term.setTextColor(colors.black)
            else
                term.setBackgroundColor(colors.gray)
                term.setTextColor(colors.white)
            end
            local labelWidth = option.task and boxWidth - 3 or boxWidth
            term.write((" " .. option[1] .. string.rep(" ", boxWidth)):sub(1, labelWidth))
            if option.task then
                term.setBackgroundColor(colors.red)
                term.setTextColor(colors.white)
                term.write(" X ")
            end
        end
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.lightGray)
        if scrollTop > 0 then
            term.setCursorPos(left + boxWidth - 1, top)
            term.write("^")
        end
        if scrollTop + visibleRows < #options then
            term.setCursorPos(left + boxWidth - 1, top + boxHeight - 1)
            term.write("v")
        end
    end

    -- Closes a task from the list. Closing the current app ends the menu so the driver can drop it.
    local function closeTask(option)
        bootLog("TASK close " .. tostring(option.task and option.task.name))
        if option.task == foregroundTask then
            choice = "close_app"
            return
        end
        removeTask(option.task)
        buildOptions()
        highlighted = math.min(highlighted, #options)
    end

    local function chooseOption(option)
        if option[2] == "task" then
            if option.task == foregroundTask then
                choice = "exit"
            else
                pendingSwitchTask = option.task.id
                choice = "switch_task"
            end
        elseif option[2] == "session_menu" then
            level = "session"
            buildOptions()
            highlighted = 1
        elseif option[2] == "services_menu" then
            level = "services"
            buildOptions()
            highlighted = 1
        elseif option[2] == "service" then
            -- Selecting a service toggles it: running services stop, stopped installed ones start.
            local service = option.service
            if service.status == "Running" then
                bgServices.stop(service.name)
            elseif service.path then
                bgServices.api.start(service.name)
            end
            local keep = highlighted
            buildOptions()
            highlighted = math.min(keep, #options)
        elseif option[2] == "none" then
            return
        elseif option[2] == "back" then
            level = "main"
            buildOptions()
            highlighted = 1
        else
            choice = option[2]
        end
    end

    while not choice do
        render()
        local event = table.pack(unfilteredPullEventRaw())
        local name = event[1]
        -- Holding Alt reveals Services; once inside the submenu it stays until you go back.
        local altHeld = altState.left or altState.right
        if altHeld ~= showServices then
            showServices = altHeld
            if level == "main" then
                buildOptions()
                highlighted = math.min(highlighted, #options)
            end
        end
        if name == "key" then
            if event[2] == keys.up then
                highlighted = highlighted == 1 and #options or highlighted - 1
            elseif event[2] == keys.down then
                highlighted = highlighted == #options and 1 or highlighted + 1
            elseif event[2] == keys.enter or event[2] == keys.numPadEnter then
                chooseOption(options[highlighted])
            elseif (event[2] == keys.delete or event[2] == keys.x) and options[highlighted].task then
                closeTask(options[highlighted])
            elseif event[2] == keys.escape then
                if level == "main" then
                    choice = "exit"
                else
                    level = "main"
                    buildOptions()
                    highlighted = 1
                end
            end
        elseif name == "mouse_click" then
            -- Events from the driver or pump are absolute; events inside the app chain were already shifted.
            local rowOffset = (statusBarActive and not inAppChain) and 1 or 0
            local option = options[event[4] - rowOffset - top + scrollTop]
            if option and event[4] - rowOffset > top and event[3] >= left and event[3] < left + boxWidth then
                if option.task and event[3] >= left + boxWidth - 3 then
                    closeTask(option)
                else
                    chooseOption(option)
                end
            end
        elseif name == "mouse_scroll" then
            highlighted = math.max(1, math.min(#options, highlighted + event[2]))
        elseif not inputEvents[name] then
            deferred[#deferred + 1] = event
        end
    end

    term.setBackgroundColor(previousBackground)
    term.setTextColor(previousText)
    term.setCursorPos(previousX, previousY)
    term.setCursorBlink(previousBlink)
    for _, event in ipairs(deferred) do
        nativeOs.queueEvent(table.unpack(event, 1, event.n))
    end

    if choice == "lock" then
        nativeOs.queueEvent("rift_lock")
        choice = "exit"
    end
    bootLog("SESSION menu choice: " .. tostring(choice))
    if choice == "shutdown" then
        nativeOs.shutdown()
    elseif choice == "reboot" then
        nativeOs.reboot()
    end
    if choice == "exit" then nativeOs.queueEvent("term_resize") end
    return choice
end

local function launchSelected()
    local app = apps[selected]
    if not app then
        message = "Select an available program first."
        return
    end
    local profileContext = {
        user = currentUser,
        homeDirectory = homeDirectory,
        passwords = profilePasswords,
        admins = profileAdmins,
        authorized = authorizedProfiles,
    }
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    local previousDirectory = shell.dir()
    shell.setDir(homeDirectory)
    local ok, result
    local profileProgramError
    local programErrors = {}
    local restorePrintError = capturePrintError(function(text)
        programErrors[#programErrors + 1] = text
    end)
    local function protectedRun(fn, ...)
        nextTaskName = app.name
        bgServices.nextPath = app.path
        bootLog("APP start " .. tostring(app.name) .. " (" .. tostring(app.path) .. ") user=" .. tostring(currentUser))
        local results = table.pack(pcall(runClosable, fn, ...))
        if not results[1] then
            bootLog("APP crash " .. tostring(app.name) .. ": " .. tostring(results[2]))
            error(results[2], 0)
        end
        bootLog("APP end " .. tostring(app.name) .. " ok=" .. tostring(results[2]) .. " result=" .. tostring(results[3]))
        return table.unpack(results, 2, results.n)
    end
    if app.path == RECOVERY_PROFILE_INSPECTOR_PATH then
        ok, result = protectedRun(showRecoveryProfileInspector)
    elseif isInHomeDirectory(app.path) then
        ok, result = protectedRun(runHomeProgram, app.path, profileContext, profileContext.homeDirectory)
    elseif app.path:gsub("^/+", "") == SYSTEM_FILE_BROWSER_PATH:gsub("^/+", "") then
        local function runProfileProgram(path, ...)
            local normalizedPath = type(path) == "string" and path:gsub("^/+", ""):gsub("/+$", "")
            local normalizedHome = profileContext.homeDirectory:gsub("^/+", ""):gsub("/+$", "")
            if not normalizedPath or (normalizedPath ~= normalizedHome
                and normalizedPath:sub(1, #normalizedHome + 1) ~= normalizedHome .. "/") then
                error("Only programs in the active profile home can be run here.", 0)
            end
            local runtimeError
            local restoreRuntimePrint = capturePrintError(function(text)
                runtimeError = text
            end)
            local ran, result = runClosable(runHomeProgram, path, profileContext, ...)
            restoreRuntimePrint()
            if not ran then
                profileProgramError = tostring(result)
                error(result, 0)
            end
            if result == false and runtimeError then
                profileProgramError = runtimeError
                return false, runtimeError
            end
            return result
        end
        local function listLaunchProfiles()
            return listOtherProfiles(profileContext.user)
        end
        local function authorizeLaunchProfile(username)
            return authorizeProfileAccess(username, profileContext)
        end
        ok, result = protectedRun(nativeOs.run, createSystemEnvironment(), app.path, profileContext.homeDirectory,
            runProfileProgram, listLaunchProfiles, authorizeLaunchProfile, recoverySession)
    elseif app.path:gsub("^/+", "") == SETTINGS_PROGRAM_PATH:gsub("^/+", "") then
        local environment = createSystemEnvironment()
        environment.profileHomeDirectory = homeDirectory
        ok, result = protectedRun(nativeOs.run, environment, app.path, homeDirectory, currentUser, getThemeInfo())
    else
        ok, result = protectedRun(nativeOs.run, createSystemEnvironment(), app.path, homeDirectory)
    end
    restorePrintError()
    shell.setDir(previousDirectory)
    term.clear()
    term.setCursorPos(1, 1)
    if not ok then
        bootLog("APP error " .. tostring(app.name) .. ": " .. tostring(result))
        printError("Program error: " .. tostring(result))
    elseif profileProgramError and #programErrors == 0 then
        bootLog("APP profile error " .. tostring(app.name) .. ": " .. profileProgramError)
        printError("Profile program error: " .. profileProgramError)
    elseif result == false and #programErrors == 0 then
        bootLog("APP " .. tostring(app.name) .. " reported failure")
        printError("The program reported that it did not complete successfully.")
    end
    for _, programError in ipairs(programErrors) do
        bootLog("APP printed error " .. tostring(app.name) .. ": " .. tostring(programError))
        printError("Program error: " .. programError)
    end
    local programFailed = not ok or result == false or profileProgramError ~= nil or #programErrors > 0
    if programFailed then waitForReturn(true) end
    if autoLaunchSession then
        autoLaunchSession = false
        currentUser = nil
        homeDirectory = nil
        authorizedProfiles = {}
        bgServices.stopAll()
        chooseUser(true)
        selected = 1
        firstVisible = 1
        refreshApps()
        bgServices.startAutomatic()
        if not ok then
            message = "Signed out after " .. app.name .. " exited with an error: " .. tostring(result)
        elseif result == false then
            message = "Signed out after " .. app.name .. " did not complete successfully."
        else
            message = ""
        end
        return
    end
    if not programFailed then waitForReturn(false) end
    message = ""
    if app.path:gsub("^/+", "") == SETTINGS_PROGRAM_PATH:gsub("^/+", "") then
        loadSettings()
    end
    refreshApps()
end

local function openSystemSettings()
    if not fs.exists(SETTINGS_PROGRAM_PATH) then
        message = "System Settings is not installed. Refresh system apps and try again."
        return
    end

    local previousDirectory = shell.dir()
    shell.setDir(homeDirectory)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    local environment = createSystemEnvironment()
    environment.profileHomeDirectory = homeDirectory
    nextTaskName = "Settings"
    local ok, result = runClosable(nativeOs.run, environment, SETTINGS_PROGRAM_PATH,
        homeDirectory, currentUser, getThemeInfo())
    shell.setDir(previousDirectory)
    loadSettings()
    local reloadedPasswords = loadProfilePasswords()
    if reloadedPasswords then profilePasswords = reloadedPasswords end
    refreshApps()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    if not ok then
        message = "System Settings error: " .. tostring(result)
    elseif result == false then
        message = "System Settings did not complete successfully."
    end
end

local function killAllTasks()
    bgServices.stopAll()
    for index = #tasks, 1, -1 do table.remove(tasks, index) end
end

local function applySessionAction(action)
    bootLog("SESSION action " .. tostring(action) .. " user=" .. tostring(currentUser))
    if action == "switch_task" then
        local task = pendingSwitchTask and findTask(pendingSwitchTask)
        pendingSwitchTask = nil
        if task and not task.finished then
            local ok, result = runForeground(task, term.current())
            if ok == false then message = "Program error: " .. tostring(result) end
        end
    elseif action == "switch_user" then
        if chooseUser() then
            recoverySession = false
            killAllTasks()
            selected = 1
            firstVisible = 1
            refreshApps()
            bgServices.startAutomatic()
            message = ""
        end
    elseif action == "logout" then
        killAllTasks()
        recoverySession = false
        currentUser = nil
        homeDirectory = nil
        authorizedProfiles = {}
        chooseUser(true)
        selected = 1
        firstVisible = 1
        refreshApps()
        bgServices.startAutomatic()
        message = ""
    end
end

local bootFlow = {}

bootFlow.handleRecovery = function()
    bootLog("---- BOOT launcher " .. tostring(fs.exists(LAUNCHER_PATH) and fs.getSize(LAUNCHER_PATH))
        .. " bytes; free=" .. tostring(fs.getFreeSpace("/")) .. "; http=" .. tostring(http ~= nil)
        .. "; pending=" .. tostring(fs.exists(PENDING_BOOT_PATH)) .. "; good=" .. tostring(fs.exists(GOOD_LAUNCHER_PATH))
        .. "; bad=" .. tostring(fs.exists(BAD_LAUNCHER_PATH)))
    local recoveryRequested = bootRecoveryRequested()
    if recoveryRequested then bootLog("Recovery menu opened (R held)") end
    if recoverFromFailedUpdate() then skipLauncherUpdate = true end
    if recoveryRequested then
        local choice = recoveryMenu()
        skipLauncherUpdate = choice == "continue" or choice == "recovery"
        recoveryLoginRequested = choice == "recovery"
    end
    startBootPhase()
end

bootFlow.loadSettings = function()
    local migrateLegacySettings = not fs.exists(SETTINGS_PATH) and fs.exists(LEGACY_SETTINGS_PATH)
    local keyReady, keyError = ensureEncryptionKey()
    if not keyReady then error(keyError, 0) end
    loadSettings()
    if settingsProtectionError then error(settingsProtectionError, 0) end
    applyTheme()
    local _, startupError = ensureStartupProgram()
    if migrateLegacySettings or settingsNeedEncryption then
        if not saveSettings() then
            error("Could not encrypt existing launcher settings: " .. message, 0)
        end
        if migrateLegacySettings then fs.delete(LEGACY_SETTINGS_PATH) end
    end
    return startupError
end

bootFlow.prepareLauncherUpdate = function()
    local downloaderReady, downloaderError = installDownloader()
    bootLog("Downloader ready=" .. tostring(downloaderReady) .. (downloaderError and (" error=" .. tostring(downloaderError)) or ""))
    if fs.exists(LEGACY_CLOUD_PATH) then pcall(fs.delete, LEGACY_CLOUD_PATH) end
    startBootPhase()
    autoUpdateLauncher()

    startBootPhase()
    return downloaderReady, downloaderError
end

bootFlow.signIn = function()
    if recoveryLoginRequested then
        local passwords, passwordError = loadProfilePasswords()
        if not passwords then error(passwordError, 0) end
        profilePasswords = passwords
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        term.setTextColor(colors.cyan)
        print("RECOVERY ACCOUNT")
        term.setTextColor(colors.white)
        local existingPassword = passwords.default
        local authenticated
        if existingPassword == nil then
            print("Set a password for the recovery account.")
            write("New password: ")
            local newPassword = readPassword()
            if newPassword == "" then
                message = "Recovery password cannot be empty."
            else
                write("Confirm password: ")
                if readPassword() ~= newPassword then
                    message = "Recovery passwords did not match."
                else
                    passwords.default = newPassword
                    local saved, saveError = saveProfilePasswords(passwords)
                    if saved then
                        profilePasswords = passwords
                        authenticated = true
                    else
                        passwords.default = nil
                        message = "Could not save recovery password: " .. tostring(saveError)
                    end
                end
            end
        elseif existingPassword ~= "" then
            write("Password: ")
            authenticated = readPassword() == existingPassword
            if not authenticated then message = "Recovery authentication failed. Sign in with a user account." end
        else
            message = "The recovery password is invalid. Sign in with a user account."
        end
        if authenticated then
            local admins, adminError = loadProfileAdmins()
            if not admins then error(adminError, 0) end
            profileAdmins = admins
            profileAdmins.default = true
            currentUser = "default"
            homeDirectory = fs.combine(USER_ROOT, currentUser)
            local made, makeError = pcall(fs.makeDir, homeDirectory)
            if not made then error("Could not prepare the recovery profile: " .. tostring(makeError), 0) end
            local recoveryAppsDirectory = fs.combine(homeDirectory, "apps")
            local appsMade = pcall(fs.makeDir, recoveryAppsDirectory)
            local recoveryConsole = fs.combine(recoveryAppsDirectory, "lua-console.lua")
            if appsMade and not fs.exists(recoveryConsole) and fs.exists(LUA_CONSOLE_PATH) then
                pcall(fs.copy, LUA_CONSOLE_PATH, recoveryConsole)
            end
            authorizedProfiles = {}
            for _, username in ipairs(fs.list(USER_ROOT)) do
                if username ~= "default" and username:match("^[%w_-]+$")
                    and fs.isDir(fs.combine(USER_ROOT, username)) then
                    authorizedProfiles[username] = true
                end
            end
            recoverySession = true
            bgServices.clearUserServices(currentUser)
            bootLog("Signed in: default (recovery)")
            return
        end
    end
    chooseUser()
    bootLog("Signed in: " .. tostring(currentUser))
end

bootFlow.installSystemApps = function(downloaderReady, downloaderError)
    local systemAppInstallMessage
    if downloaderReady then
        local installer, loadError = loadfile(DOWNLOADER_PATH, "t", _ENV)
        if not installer then
            systemAppInstallMessage = "System app installer is broken: " .. tostring(loadError)
        else
            local ok, result = pcall(installer, "install-system")
            if not ok then
                systemAppInstallMessage = "System app install failed: " .. tostring(result)
            end
        end
    else
        systemAppInstallMessage = "Could not prepare the system app installer: " .. tostring(downloaderError)
    end
    return systemAppInstallMessage
end

bootFlow.completeBoot = function(systemAppInstallMessage)
    if fs.exists(PENDING_BOOT_PATH) then fs.delete(PENDING_BOOT_PATH) end
    bootLog("Boot complete; update marker cleared")
    if not recoverySession then bgServices.startAutomatic() end
    if systemAppInstallMessage then bootLog(systemAppInstallMessage) end
end

showRecoveryProfileInspector = function()
    if not recoverySession then error("Profile Inspector is only available to the recovery account.", 0) end
    local selectedProfile = 1
    local status = ""

    local function listProfiles()
        local profiles = {}
        for _, name in ipairs(fs.list(USER_ROOT)) do
            if name ~= "default" and name:match("^[%w_-]+$")
                and fs.isDir(fs.combine(USER_ROOT, name)) then
                profiles[#profiles + 1] = name
            end
        end
        table.sort(profiles, function(first, second) return first:lower() < second:lower() end)
        return profiles
    end

    local function countProfileAdmins()
        local count = 0
        for name, isAdmin in pairs(profileAdmins) do
            if name ~= "default" and isAdmin == true and fs.isDir(fs.combine(USER_ROOT, name)) then
                count = count + 1
            end
        end
        return count
    end

    local function copyMap(source)
        local result = {}
        for key, value in pairs(source) do result[key] = value end
        return result
    end

    local function drawInspector(profiles)
        local width, height = term.getSize()
        local visibleRows = math.max(1, height - 8)
        selectedProfile = math.max(1, math.min(selectedProfile, math.max(1, #profiles)))
        local first = math.max(1, math.min(selectedProfile, math.max(1, #profiles - visibleRows + 1)))
        local last = math.min(#profiles, first + visibleRows - 1)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        term.setBackgroundColor(term.isColor() and colors.cyan or colors.gray)
        term.write((" PROFILE INSPECTOR" .. string.rep(" ", width)):sub(1, width))
        term.setBackgroundColor(colors.black)
        term.setCursorPos(2, 2)
        term.setTextColor(colors.lightGray)
        term.write((#profiles .. (#profiles == 1 and " profile" or " profiles")):sub(1, width - 2))

        for index = first, last do
            local name = profiles[index]
            local role = profileAdmins[name] and "ADMIN" or "STANDARD"
            local password = profilePasswords[name] and "PASSWORD SET" or "NO PASSWORD"
            local row = index - first + 4
            term.setCursorPos(2, row)
            if index == selectedProfile then
                term.setBackgroundColor(colors.blue)
                term.setTextColor(colors.white)
            else
                term.setTextColor(colors.white)
            end
            term.write(("  " .. name .. "  [" .. role .. "]  [" .. password .. "]")
                :sub(1, math.max(0, width - 2)))
            term.setBackgroundColor(colors.black)
        end
        if #profiles == 0 then
            term.setCursorPos(2, 4)
            term.setTextColor(colors.lightGray)
            term.write("No user profiles found.")
        end

        local selectedName = profiles[selectedProfile]
        if selectedName then
            term.setCursorPos(2, height - 3)
            term.setTextColor(colors.lightGray)
            term.write(("Home: H@" .. selectedName .. "://")
                :sub(1, math.max(0, width - 2)))
        end
        term.setCursorPos(2, height - 2)
        term.setTextColor(colors.yellow)
        term.write(tostring(status):sub(1, math.max(0, width - 2)))
        local buttons = {
            { label = "RESET PW", action = "password" },
            { label = "ROLE", action = "role" },
            { label = "DELETE", action = "delete" },
            { label = "BACK", action = "back" },
        }
        local buttonRow = height
        drawButtons(buttons, buttonRow, width, term.isColor())
        return buttons, first, last, visibleRows, buttonRow
    end

    local function resetPassword(username)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        print("RESET PASSWORD FOR " .. username)
        write("New password: ")
        local password = readPassword()
        if password == "" then
            status = "Password cannot be empty."
            return
        end
        write("Confirm password: ")
        if readPassword() ~= password then
            status = "Passwords did not match."
            return
        end
        local passwords = copyMap(profilePasswords)
        passwords[username] = password
        local ok, saved, saveError = pcall(saveProfilePasswords, passwords)
        if not ok or not saved then
            status = "Could not save the new password: " .. tostring(ok and saveError or saved)
            return
        end
        profilePasswords = passwords
        status = "Password reset for " .. username .. "."
    end

    local function toggleRole(username)
        local admins = copyMap(profileAdmins)
        if admins[username] then
            if countProfileAdmins() <= 1 then
                status = "The last regular admin cannot be demoted."
                return
            end
            admins[username] = nil
        else
            admins[username] = true
        end
        local ok, saved, saveError = pcall(saveProfileAdmins, admins)
        if not ok or not saved then
            status = "Could not save the role change: " .. tostring(ok and saveError or saved)
            return
        end
        profileAdmins = admins
        status = username .. " is now " .. (admins[username] and "an admin." or "a standard user.")
    end

    local function confirmDelete(username)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        term.setTextColor(colors.red)
        print("DELETE PROFILE")
        term.setTextColor(colors.white)
        print("This permanently removes " .. username .. " and their private data.")
        print("Type the username to confirm: ")
        return read() == username
    end

    local function deleteProfile(username)
        if profileAdmins[username] and countProfileAdmins() <= 1 then
            status = "The last regular admin cannot be deleted."
            return
        end
        if not confirmDelete(username) then
            status = "Profile deletion cancelled."
            return
        end

        local trashDirectory = SYSTEM_DIRECTORY .. "/account-trash"
        local profilePath = fs.combine(USER_ROOT, username)
        local privatePath = fs.combine(SYSTEM_DIRECTORY, "user-data", username)
        local trashedProfile = fs.combine(trashDirectory, username)
        local trashedPrivate = fs.combine(trashDirectory, username .. "-private")
        if fs.exists(trashedProfile) or fs.exists(trashedPrivate) then
            status = "A previous deletion archive exists; profile was not changed."
            return
        end
        local made, makeError = pcall(fs.makeDir, trashDirectory)
        if not made then
            status = "Could not prepare profile deletion: " .. tostring(makeError)
            return
        end

        local movedProfile, profileError = pcall(fs.move, profilePath, trashedProfile)
        if not movedProfile then
            status = "Could not stage profile: " .. tostring(profileError)
            return
        end
        local hasPrivateData = fs.exists(privatePath)
        if hasPrivateData then
            local movedPrivate, privateError = pcall(fs.move, privatePath, trashedPrivate)
            if not movedPrivate then
                local restored, restoreError = pcall(fs.move, trashedProfile, profilePath)
                status = "Could not stage private data: " .. tostring(privateError)
                    .. (restored and "" or "; profile restore failed: " .. tostring(restoreError))
                return
            end
        end

        local passwords, admins = copyMap(profilePasswords), copyMap(profileAdmins)
        passwords[username], admins[username] = nil, nil
        local passwordsSaved, passwordError = saveProfilePasswords(passwords)
        if not passwordsSaved then
            local rollbackErrors = {}
            local restoredProfile, restoreProfileError = pcall(fs.move, trashedProfile, profilePath)
            if not restoredProfile then rollbackErrors[#rollbackErrors + 1] = tostring(restoreProfileError) end
            if hasPrivateData then
                local restoredPrivate, restorePrivateError = pcall(fs.move, trashedPrivate, privatePath)
                if not restoredPrivate then rollbackErrors[#rollbackErrors + 1] = tostring(restorePrivateError) end
            end
            status = tostring(passwordError)
                .. (#rollbackErrors > 0 and ("; rollback failed: " .. table.concat(rollbackErrors, "; ")) or "")
            return
        end

        local adminsCallOk, adminsSaved, adminError = pcall(saveProfileAdmins, admins)
        if not adminsCallOk or not adminsSaved then
            local restoredPasswords, restorePasswordError = saveProfilePasswords(profilePasswords)
            local rollbackErrors = {}
            if not restoredPasswords then rollbackErrors[#rollbackErrors + 1] = tostring(restorePasswordError) end
            local restoredProfile, restoreProfileError = pcall(fs.move, trashedProfile, profilePath)
            if not restoredProfile then rollbackErrors[#rollbackErrors + 1] = tostring(restoreProfileError) end
            if hasPrivateData then
                local restoredPrivate, restorePrivateError = pcall(fs.move, trashedPrivate, privatePath)
                if not restoredPrivate then rollbackErrors[#rollbackErrors + 1] = tostring(restorePrivateError) end
            end
            status = "Could not save account roles: " .. tostring(adminsCallOk and adminError or adminsSaved)
                .. (#rollbackErrors > 0 and ("; rollback failed: " .. table.concat(rollbackErrors, "; ")) or "")
            return
        end

        profilePasswords, profileAdmins = passwords, admins
        authorizedProfiles[username] = nil
        bgServices.clearUserServices(username)
        local cleanupErrors = {}
        for _, path in ipairs({ trashedProfile, trashedPrivate }) do
            if fs.exists(path) then
                local removed, removeError = pcall(fs.delete, path)
                if not removed or fs.exists(path) then
                    cleanupErrors[#cleanupErrors + 1] = path .. ": " .. tostring(removeError or "could not remove")
                end
            end
        end
        local preferencesChanged = false
        if settings.autoLoginUser == username then
            settings.autoLoginUser = nil
            preferencesChanged = true
        end
        local profilePrefix = fs.combine(USER_ROOT, username) .. "/"
        if type(settings.autoLaunchPath) == "string"
            and settings.autoLaunchPath:sub(1, #profilePrefix) == profilePrefix then
            settings.autoLaunchPath = nil
            preferencesChanged = true
        end
        if preferencesChanged and not saveSettings() then
            status = "Profile deleted, but automatic login/launch preferences could not be cleared."
        elseif #cleanupErrors > 0 then
            status = "Profile deleted, but staged data remains: " .. table.concat(cleanupErrors, "; ")
        else
            status = "Deleted profile " .. username .. "."
        end
    end

    while true do
        local profiles = listProfiles()
        if selectedProfile > #profiles then selectedProfile = math.max(1, #profiles) end
        local buttons, firstVisible, lastVisible, visibleRows, buttonRow = drawInspector(profiles)
        local event, key, x, y = os.pullEventRaw()
        if event == "key" then
            if key == keys.up then
                selectedProfile = math.max(1, selectedProfile - 1)
            elseif key == keys.down then
                selectedProfile = math.min(#profiles, selectedProfile + 1)
            elseif key == keys.enter and profiles[selectedProfile] then
                resetPassword(profiles[selectedProfile])
            elseif key == keys.p and profiles[selectedProfile] then
                resetPassword(profiles[selectedProfile])
            elseif key == keys.r and profiles[selectedProfile] then
                toggleRole(profiles[selectedProfile])
            elseif key == keys.delete and profiles[selectedProfile] then
                deleteProfile(profiles[selectedProfile])
            elseif key == keys.escape then
                return true
            end
        elseif event == "mouse_scroll" then
            selectedProfile = math.max(1, math.min(#profiles, selectedProfile + key))
        elseif event == "mouse_click" and key == 1 then
            local clickedProfile = firstVisible + y - 4
            if y >= 4 and y <= 3 + visibleRows and clickedProfile <= lastVisible then
                selectedProfile = clickedProfile
            elseif y == buttonRow then
                local action = buttonAt(buttons, x)
                local username = profiles[selectedProfile]
                if action == "back" then return true end
                if username and action == "password" then resetPassword(username) end
                if username and action == "role" then toggleRole(username) end
                if username and action == "delete" then deleteProfile(username) end
            end
        end
    end
end

local function recoveryToolsMenu()
    local options = {
        { label = "Update launcher", action = "update" },
        { label = "Wipe computer", action = "wipe" },
        { label = "Back", action = "back" },
    }
    local selected = 1
    while true do
        local width, height = term.getSize()
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(2, 2)
        term.setTextColor(term.isColor() and colors.cyan or colors.white)
        term.write("RECOVERY TOOLS")
        for index, option in ipairs(options) do
            term.setCursorPos(2, index + 4)
            term.setTextColor(index == selected and colors.white or colors.lightGray)
            term.write((index == selected and "> " or "  ") .. option.label)
        end
        term.setCursorPos(2, height)
        term.setTextColor(colors.lightGray)
        term.write("Up/Down Enter   Esc Back")
        local event, button, x, y = nativePullEventRaw()
        if event == "key" then
            if button == keys.up then
                selected = selected == 1 and #options or selected - 1
            elseif button == keys.down then
                selected = selected == #options and 1 or selected + 1
            elseif button == keys.enter or button == keys.numPadEnter then
                return options[selected].action
            elseif button == keys.escape then
                return "back"
            end
        elseif event == "mouse_click" and button == 1 then
            local index = y - 4
            if x >= 2 and x <= math.min(width, 30) and options[index] then
                return options[index].action
            end
        end
    end
end

local function wipeRecoveryComputer()
    local width, height = term.getSize()
    local buttons = {
        { label = "CANCEL", action = false },
        { label = "WIPE COMPUTER", action = true },
    }
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.red)
    print("WIPE COMPUTER")
    term.setTextColor(colors.white)
    print("This permanently deletes every file and folder")
    print("on this computer, except the ROM folder.")
    print("Confirm only if you intend to erase this computer.")
    drawButtons(buttons, height - 1, width, term.isColor())

    local confirmed
    while confirmed == nil do
        local event, key, x, y = nativePullEventRaw()
        if event == "key" and (key == keys.escape or key == keys.n) then
            confirmed = false
        elseif event == "key" and key == keys.y then
            confirmed = true
        elseif event == "mouse_click" and key == 1 and y == height - 1 then
            confirmed = buttonAt(buttons, x)
        end
    end
    if not confirmed then
        message = "Computer wipe cancelled."
        return
    end

    local failures = {}
    for _, entry in ipairs(fs.list("/")) do
        if entry:lower() ~= "rom" then
            local path = fs.combine("/", entry)
            local removed, removeError = pcall(fs.delete, path)
            if not removed or fs.exists(path) then
                failures[#failures + 1] = path .. ": " .. tostring(removeError or "could not remove")
            end
        end
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    if #failures > 0 then
        term.setTextColor(colors.red)
        print("Computer wipe was incomplete:")
        for _, failure in ipairs(failures) do print(failure) end
        print("Press any key to return to recovery.")
        nativePullEventRaw()
        message = "Computer wipe was incomplete; see the error list."
        return
    end

    term.setTextColor(colors.lime)
    print("Computer filesystem wiped.")
    print("The ROM folder was preserved. Turn off or reboot the computer.")
    while true do nativePullEventRaw() end
end

local function launcherMain()
bootFlow.handleRecovery()
local startupError = bootFlow.loadSettings()
local downloaderReady, downloaderError = bootFlow.prepareLauncherUpdate()
local systemAppInstallMessage = bootFlow.installSystemApps(downloaderReady, downloaderError)
bootFlow.signIn()
bootFlow.completeBoot(systemAppInstallMessage)

refreshApps()
if startupError and systemAppInstallMessage then
    message = startupError .. " " .. systemAppInstallMessage
elseif startupError then
    message = startupError
elseif systemAppInstallMessage then
    message = systemAppInstallMessage
end

if settings.autoLaunchPath and not recoverySession then
    local autoLaunchIndex
    for index, app in ipairs(apps) do
        if app.path == settings.autoLaunchPath then
            autoLaunchIndex = index
            break
        end
    end
    if autoLaunchIndex then
        selected = autoLaunchIndex
        firstVisible = math.max(1, selected - math.max(1, select(2, term.getSize()) - 12) + 1)
        autoLaunchSession = true
        launchSelected()
    else
        message = "The automatic launch program is unavailable. Choose another in System Settings."
    end
end

sessionMenuAllowed = true
lastActivity = nativeOs.clock()
while true do
    if pendingSessionAction then
        local action = pendingSessionAction
        pendingSessionAction = nil
        applySessionAction(action)
    end
    local firstButtons, secondButtons = draw()
    local pulled = table.pack(os.pullEventRaw())
    pumpBackground(pulled)
    local event, button, x, y = table.unpack(pulled, 1, pulled.n)
    if event == "session_action" then
        applySessionAction(button)
    elseif event == "key" and (button == keys.n or button == keys.v) then
        local _, height = term.getSize()
        local visibleRows = math.max(1, height - 12)
        selected = math.max(1, math.min(#apps,
            selected + (button == keys.n and visibleRows or -visibleRows)))
    elseif event == "mouse_scroll" then
        local _, height = term.getSize()
        if y >= 4 and y < 4 + math.max(1, height - 12) then
            selected = math.max(1, math.min(#apps, selected + button))
        end
    elseif event == "mouse_click" and button == 1 then
        local _, height = term.getSize()
        local visibleRows = math.max(1, height - 12)
        local clickedIndex = firstVisible + y - 4
        if y >= 4 and y < 4 + visibleRows
            and clickedIndex >= firstVisible and clickedIndex <= #apps then
            local wasSelected = selected == clickedIndex
            selected = clickedIndex
            if wasSelected then launchSelected() end
        elseif y == height - 2 then
            local action = buttonAt(firstButtons, x)
            if action == "open" then
                launchSelected()
            elseif action == "update" then
                updateSelected()
            elseif action == "settings" then
                openSystemSettings()
            end
        elseif y == height - 1 then
            local action = buttonAt(secondButtons, x)
            if action == "refresh" then
                refreshApps()
                message = ""
            elseif action == "alerts" then
                showNotifications()
            elseif action == "tasks" then
                local choice = showSessionMenu(false)
                if choice == "switch_task" or choice == "switch_user" or choice == "logout" then
                    applySessionAction(choice)
                end
            elseif action == "exit-recovery" then
                killAllTasks()
                recoverySession = false
                currentUser = nil
                homeDirectory = nil
                authorizedProfiles = {}
                chooseUser(true)
                selected, firstVisible = 1, 1
                refreshApps()
            elseif action == "recovery-tools" then
                local choice = recoveryToolsMenu()
                if choice == "update" then
                    local previousSkip = skipLauncherUpdate
                    skipLauncherUpdate = false
                    autoUpdateLauncher()
                    skipLauncherUpdate = previousSkip
                elseif choice == "wipe" then
                    wipeRecoveryComputer()
                end
            end
        end
    end
end

end

local crashed, crashError = xpcall(launcherMain, function(err)
    local trace = type(debug) == "table" and type(debug.traceback) == "function"
        and debug.traceback(tostring(err), 2) or tostring(err)
    bootLog("CRASH " .. tostring(err))
    for line in tostring(trace):gmatch("[^\n]+") do bootLog("  " .. line) end
    return err
end)
if not crashed then error(crashError, 0) end