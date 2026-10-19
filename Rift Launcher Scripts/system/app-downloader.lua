local HOST_BASE_URL = "https://rift.zerocreates.org/"
local CATALOG_PATH = "app-catalog.json"
local USER_ROOT = "/users/"
local SYSTEM_DIRECTORY = "/.launcher"
local SYSTEM_APP_DIRECTORY = SYSTEM_DIRECTORY .. "/apps"
local CACHE_DIRECTORY = SYSTEM_DIRECTORY .. "/cache"
local INSTALLED_VERSIONS_PATH = SYSTEM_DIRECTORY .. "/app-versions.json"
local homeDirectory = USER_ROOT .. "default"
local appDirectory = homeDirectory .. "/apps"
local username = "default"
local APP_NAMES_PATH = SYSTEM_DIRECTORY .. "/app-catalog-names.json"
local apps = {}
local selected = 1
local firstVisible = 1
local message = "Loading app catalog from the script host..."
local installedVersions = {}
local themeIndex = 1
local themes = {
    { accent = colors.cyan, highlight = colors.blue },
    { accent = colors.lime, highlight = colors.green },
    { accent = colors.orange, highlight = colors.red },
    { accent = colors.purple, highlight = colors.magenta },
}

local function versionParts(version)
    if type(version) ~= "string" then return nil end
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)$")
    if not major then return nil end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
end

local function isVersionNewer(first, second)
    local firstParts, secondParts = versionParts(first), versionParts(second)
    if not firstParts or not secondParts then return false end
    for index = 1, 3 do
        if firstParts[index] ~= secondParts[index] then
            return firstParts[index] > secondParts[index]
        end
    end
    return false
end

local function versionKey(app)
    if app.scope == "system" then return "system/" .. app.file end
    return "user/" .. username .. "/" .. app.file
end

local function loadInstalledVersions()
    if not fs.exists(INSTALLED_VERSIONS_PATH) then return {} end
    local file = fs.open(INSTALLED_VERSIONS_PATH, "r")
    if not file then return {} end
    local contents = file.readAll()
    file.close()
    local ok, saved = pcall(textutils.unserializeJSON, contents)
    if not ok or type(saved) ~= "table" then return {} end

    local versions = {}
    for key, version in pairs(saved) do
        if type(key) == "string" and versionParts(version) then
            versions[key] = version
        end
    end
    return versions
end

local function saveInstalledVersions()
    local serialized, contents = pcall(textutils.serializeJSON, installedVersions)
    if not serialized or type(contents) ~= "string" then
        return false, "Could not serialize installed app versions."
    end
    local made, makeError = pcall(fs.makeDir, SYSTEM_DIRECTORY)
    if not made then return false, "Could not create version metadata folder: " .. tostring(makeError) end

    local temporary = INSTALLED_VERSIONS_PATH .. ".tmp"
    local backup = INSTALLED_VERSIONS_PATH .. ".bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file = fs.open(temporary, "w")
    if not file then return false, "Could not create installed app version metadata." end
    file.write(contents)
    file.close()

    if fs.exists(INSTALLED_VERSIONS_PATH) then
        local backedUp, backupError = pcall(fs.move, INSTALLED_VERSIONS_PATH, backup)
        if not backedUp then
            fs.delete(temporary)
            return false, "Could not back up installed app versions: " .. tostring(backupError)
        end
    end
    local moved, moveError = pcall(fs.move, temporary, INSTALLED_VERSIONS_PATH)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then fs.move(backup, INSTALLED_VERSIONS_PATH) end
        return false, "Could not save installed app versions: " .. tostring(moveError)
    end
    if fs.exists(backup) then fs.delete(backup) end
    return true
end

local function appVersionStatus(app)
    local destinationDirectory = app.scope == "system" and SYSTEM_APP_DIRECTORY or appDirectory
    if not fs.exists(fs.combine(destinationDirectory, app.file)) then return "NEW" end

    local installedVersion = installedVersions[versionKey(app)]
    if not versionParts(installedVersion) then return "UNKNOWN" end
    if isVersionNewer(app.version, installedVersion) then return "UPDATE", installedVersion end
    if isVersionNewer(installedVersion, app.version) then return "AHEAD", installedVersion end
    return "CURRENT", installedVersion
end

local function loadTheme()
    if type(launcherTheme) == "table" and type(launcherTheme.index) == "number"
        and themes[launcherTheme.index] then
        themeIndex = launcherTheme.index
        return
    end
    local path = SYSTEM_DIRECTORY .. "/settings.json"
    if not fs.exists(path) then return end
    local file = fs.open(path, "r")
    if not file then return end
    local contents = file.readAll()
    file.close()
    local ok, saved = pcall(textutils.unserializeJSON, contents)
    if ok and type(saved) == "table"
        and type(saved.theme) == "number" and themes[saved.theme] then
        themeIndex = saved.theme
    end
end

local function request(url)
    local ok, response, requestError = pcall(http.get, url, {
        ["Accept"] = "application/json, text/plain",
        ["User-Agent"] = "ComputerCraft-App-Downloader",
    })
    if not ok then return nil, tostring(response) end
    if not response then return nil, tostring(requestError or "HTTP request failed.") end
    local responseCode = response.getResponseCode and response.getResponseCode()
    if responseCode and responseCode ~= 200 then
        response.close()
        return nil, "Script host returned HTTP " .. responseCode .. "."
    end
    local contents = response.readAll()
    response.close()
    if not contents or contents == "" then return nil, "The script host returned an empty response." end
    return contents
end

local function loadCatalog()
    if not http or not http.get then
        return nil, "Enable the ComputerCraft HTTP API to load apps from the script host."
    end

    local contents, err = request(HOST_BASE_URL .. CATALOG_PATH)
    if not contents then return nil, err end
    contents = contents:gsub("^\239\187\191", "")
    if not textutils or type(textutils.unserializeJSON) ~= "function" then
        return nil, "This ComputerCraft version does not support JSON parsing."
    end
    local ok, entries = pcall(textutils.unserializeJSON, contents)
    if not ok then
        return nil, "Could not parse " .. CATALOG_PATH .. ": " .. tostring(entries)
    end
    if type(entries) ~= "table" then
        return nil, CATALOG_PATH .. " must contain a JSON array of apps."
    end

    local catalog, seenFiles = {}, {}
    for _, entry in ipairs(entries) do
        if type(entry) ~= "table" or type(entry.name) ~= "string"
            or type(entry.source) ~= "string" or type(entry.file) ~= "string"
            or type(entry.version) ~= "string" or not entry.version:match("^%d+%.%d+%.%d+$")
            or type(entry.description) ~= "string"
            or entry.name == "" or entry.description == ""
            or not entry.file:match("^[%w][%w_.%-]*%.lua$")
            or not entry.source:match("^[%w_./%-]+%.lua$")
            or entry.source:find("..", 1, true)
            or entry.scope ~= nil and entry.scope ~= "system"
            or seenFiles[entry.file] then
            return nil, "Invalid app entry in " .. CATALOG_PATH .. "."
        end
        table.insert(catalog, entry)
        seenFiles[entry.file] = true
    end
    for key in pairs(entries) do
        if type(key) ~= "number" or key < 1 or key > #catalog or key % 1 ~= 0 then
            return nil, CATALOG_PATH .. " must contain a JSON array of apps."
        end
    end

    table.sort(catalog, function(first, second)
        return first.name:lower() < second.name:lower()
    end)
    return catalog
end

local function visibleAppRows(height)
    return math.max(1, height - 6)
end

local function drawButtons(buttons, row, width)
    local slotWidth = math.max(1, math.floor(width / #buttons))
    for index, button in ipairs(buttons) do
        local left = (index - 1) * slotWidth + 1
        local buttonWidth = index == #buttons and width - left + 1 or slotWidth
        term.setCursorPos(left, row)
        term.setBackgroundColor(term.isColor() and colors.gray or colors.black)
        term.setTextColor(colors.white)
        term.write(("[" .. button.label .. "]"):sub(1, buttonWidth))
        button.left = left
        button.right = left + buttonWidth - 1
    end
end

local function buttonAt(buttons, x)
    for _, button in ipairs(buttons) do
        if x >= button.left and x <= button.right then return button.action end
    end
end

local function draw()
    local width, height = term.getSize()
    local theme = themes[themeIndex]
    local accent = term.isColor() and theme.accent or colors.gray
    local highlight = term.isColor() and theme.highlight or colors.gray
    local visibleRows = visibleAppRows(height)
    if selected < firstVisible then firstVisible = selected end
    if selected >= firstVisible + visibleRows then
        firstVisible = selected - visibleRows + 1
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(accent)
    term.write((" " .. "COMPUTERCRAFT APP DOWNLOADER"):sub(1, width))
    term.setBackgroundColor(colors.black)
    term.setCursorPos(2, 2)
    term.setTextColor(colors.lightGray)
    term.write(("Apps from self-hosted library  |  N/V: PAGE")
        :sub(1, math.max(0, width - 2)))

    local lastVisible = math.min(#apps, firstVisible + visibleRows - 1)
    for index = firstVisible, lastVisible do
        local row = index - firstVisible + 3
        local status = appVersionStatus(apps[index])
        local statusColors = {
            NEW = colors.lightGray,
            UNKNOWN = colors.orange,
            UPDATE = colors.yellow,
            CURRENT = colors.lime,
            AHEAD = colors.cyan,
        }
        term.setCursorPos(2, row)
        term.setTextColor(index == selected and colors.white or statusColors[status])
        if index == selected then
            term.setBackgroundColor(highlight)
            term.write(("> " .. apps[index].name .. " [" .. status .. "]")
                :sub(1, math.max(0, width - 2)))
            term.setBackgroundColor(colors.black)
        else
            term.write(("  " .. apps[index].name .. " [" .. status .. "]")
                :sub(1, math.max(0, width - 2)))
        end
    end

    term.setCursorPos(2, height - 3)
    term.setTextColor(colors.lightGray)
    local selectedApp = apps[selected]
    local versionSummary = "No apps available."
    if selectedApp then
        local status, installedVersion = appVersionStatus(selectedApp)
        if status == "NEW" then
            versionSummary = "Not installed | Latest v" .. selectedApp.version
        elseif status == "UNKNOWN" then
            versionSummary = "Installed version unknown | Latest v" .. selectedApp.version
        elseif status == "UPDATE" then
            versionSummary = "Update: v" .. installedVersion .. " -> v" .. selectedApp.version
        elseif status == "AHEAD" then
            versionSummary = "Installed v" .. installedVersion .. " is newer than catalog v" .. selectedApp.version
        else
            versionSummary = "Up to date: v" .. installedVersion
        end
        versionSummary = versionSummary .. " | " .. selectedApp.description
    end
    term.write(versionSummary:sub(1, math.max(0, width - 2)))
    term.setCursorPos(2, height - 2)
    term.setTextColor(colors.yellow)
    term.write(message:sub(1, math.max(0, width - 2)))
    local buttons = {
        { label = "UPDATE/GET", action = "update" },
        { label = "REMOVE", action = "uninstall" },
        { label = "REFRESH", action = "refresh" },
        { label = "QUIT", action = "quit" },
    }
    drawButtons(buttons, height - 1, width)
    term.setBackgroundColor(colors.black)
    return buttons
end

local function confirmOverwrite(file)
    if not fs.exists(file) then return true end
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.yellow)
    print(file .. " already exists.")
    print("Replace it with the repository version? [y/N]")
    while true do
        local event, value = os.pullEventRaw()
        if event == "char" then
            local answer = value:lower()
            if answer == "y" then return true end
            if answer == "n" then return false end
        elseif event == "key" and (value == keys.enter or value == keys.escape) then
            return false
        end
    end
end

local function saveCatalogName(fileName, appName)
    local names = {}
    if fs.exists(APP_NAMES_PATH) then
        local file = fs.open(APP_NAMES_PATH, "r")
        if not file then return false, "Could not read " .. APP_NAMES_PATH .. "." end
        local contents = file.readAll()
        file.close()
        local ok, storedNames = pcall(textutils.unserializeJSON, contents)
        if not ok or type(storedNames) ~= "table" then
            return false, "Could not parse " .. APP_NAMES_PATH .. "."
        end
        names = storedNames
    end
    names[fileName] = appName

    local temporary = APP_NAMES_PATH .. ".tmp"
    local backup = APP_NAMES_PATH .. ".bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file = fs.open(temporary, "w")
    if not file then return false, "Could not create " .. temporary .. "." end
    file.write(textutils.serializeJSON(names))
    file.close()

    if fs.exists(APP_NAMES_PATH) then fs.move(APP_NAMES_PATH, backup) end
    local ok, moveError = pcall(fs.move, temporary, APP_NAMES_PATH)
    if not ok then
        if fs.exists(APP_NAMES_PATH) then fs.delete(APP_NAMES_PATH) end
        if fs.exists(backup) then fs.move(backup, APP_NAMES_PATH) end
        return false, tostring(moveError)
    end
    if fs.exists(backup) then fs.delete(backup) end
    return true
end

local function removeCatalogName(fileName)
    if not fs.exists(APP_NAMES_PATH) then return true end
    local file = fs.open(APP_NAMES_PATH, "r")
    if not file then return false, "Could not read " .. APP_NAMES_PATH .. "." end
    local contents = file.readAll()
    file.close()
    local ok, names = pcall(textutils.unserializeJSON, contents)
    if not ok or type(names) ~= "table" then
        return false, "Could not parse " .. APP_NAMES_PATH .. "."
    end
    if names[fileName] == nil then return true end
    names[fileName] = nil

    local temporary = APP_NAMES_PATH .. ".tmp"
    local backup = APP_NAMES_PATH .. ".bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local output = fs.open(temporary, "w")
    if not output then return false, "Could not create " .. temporary .. "." end
    local wrote, writeError = pcall(output.write, textutils.serializeJSON(names))
    local closed, closeError = pcall(output.close)
    if not wrote or not closed then
        if fs.exists(temporary) then fs.delete(temporary) end
        return false, "Could not write app catalog names: "
            .. tostring(not wrote and writeError or closeError)
    end

    if fs.exists(APP_NAMES_PATH) then
        local backedUp, backupError = pcall(fs.move, APP_NAMES_PATH, backup)
        if not backedUp then
            fs.delete(temporary)
            return false, "Could not back up app catalog names: " .. tostring(backupError)
        end
    end
    local moved, moveError = pcall(fs.move, temporary, APP_NAMES_PATH)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then
            local restored, restoreError = pcall(fs.move, backup, APP_NAMES_PATH)
            if not restored then
                return false, "Could not save app catalog names: " .. tostring(moveError)
                    .. "; restoring the backup also failed: " .. tostring(restoreError)
            end
        end
        return false, "Could not save app catalog names: " .. tostring(moveError)
    end
    if fs.exists(backup) then fs.delete(backup) end
    return true
end

local function setHomeDirectory(path)
    if path == nil then path = USER_ROOT .. "default" end
    if type(path) ~= "string" then
        return false, "Invalid user directory. Expected /users/<username>."
    end
    local normalizedPath = path:gsub("^/+", "")
    username = normalizedPath:match("^users/([%w_-]+)$")
    if not username then
        return false, "Invalid user directory. Expected /users/<username>."
    end
    homeDirectory = "/users/" .. username
    appDirectory = homeDirectory .. "/apps"
    APP_NAMES_PATH = SYSTEM_DIRECTORY .. "/app-catalog-names.json"
    fs.makeDir(SYSTEM_DIRECTORY)
    fs.makeDir(SYSTEM_APP_DIRECTORY)
    fs.makeDir(CACHE_DIRECTORY)
    local legacyNamesPath = homeDirectory .. "/.app-catalog-names.json"
    if fs.exists(legacyNamesPath) then
        local legacyFile = fs.open(legacyNamesPath, "r")
        if legacyFile then
            local contents = legacyFile.readAll()
            legacyFile.close()
            local ok, legacyNames = pcall(textutils.unserializeJSON, contents)
            if ok and type(legacyNames) == "table" then
                local currentNames = {}
                if fs.exists(APP_NAMES_PATH) then
                    local currentFile = fs.open(APP_NAMES_PATH, "r")
                    if currentFile then
                        local currentContents = currentFile.readAll()
                        currentFile.close()
                        local currentOk, decoded = pcall(textutils.unserializeJSON, currentContents)
                        if currentOk and type(decoded) == "table" then currentNames = decoded end
                    end
                end
                for fileName, appName in pairs(legacyNames) do
                    if type(fileName) == "string" and type(appName) == "string"
                        and currentNames[fileName] == nil then
                        currentNames[fileName] = appName
                    end
                end
                local temporary = APP_NAMES_PATH .. ".tmp"
                local backup = APP_NAMES_PATH .. ".bak"
                if fs.exists(temporary) then fs.delete(temporary) end
                if fs.exists(backup) then fs.delete(backup) end
                local output = fs.open(temporary, "w")
                if output then
                    output.write(textutils.serializeJSON(currentNames))
                    output.close()
                    if fs.exists(APP_NAMES_PATH) then
                        local backedUp = pcall(fs.move, APP_NAMES_PATH, backup)
                        if not backedUp then
                            fs.delete(temporary)
                            return true
                        end
                    end
                    local moved = pcall(fs.move, temporary, APP_NAMES_PATH)
                    if moved then
                        if fs.exists(backup) then fs.delete(backup) end
                        fs.delete(legacyNamesPath)
                    else
                        if fs.exists(backup) then fs.move(backup, APP_NAMES_PATH) end
                    end
                end
            end
        end
    end
    fs.makeDir(homeDirectory)
    fs.makeDir(appDirectory)
    return true
end

local function downloadApp(app, skipOverwriteConfirmation)
    if not app then
        message = "There are no apps available to download."
        return
    end
    if not http or not http.get then
        message = "Enable the ComputerCraft HTTP API to download apps."
        return
    end

    local contents, err = request(HOST_BASE_URL .. app.source)
    if not contents then
        message = "Download failed: " .. err
        return
    end

    local destinationDirectory = app.scope == "system" and SYSTEM_APP_DIRECTORY or appDirectory
    fs.makeDir(destinationDirectory)
    local destination = fs.combine(destinationDirectory, app.file)
    if not skipOverwriteConfirmation and not confirmOverwrite(destination) then
        message = "Download cancelled."
        return
    end

    local cacheUserDirectory = fs.combine(CACHE_DIRECTORY, username)
    fs.makeDir(cacheUserDirectory)
    local temporary = fs.combine(cacheUserDirectory, app.file .. ".download-tmp")
    local backup = fs.combine(cacheUserDirectory, app.file .. ".download-bak")
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file = fs.open(temporary, "w")
    if not file then
        message = "Download failed: could not create " .. temporary .. "."
        return
    end
    file.write(contents)
    file.close()

    if fs.exists(destination) then fs.move(destination, backup) end
    local ok, moveError = pcall(fs.move, temporary, destination)
    if not ok then
        if fs.exists(destination) then fs.delete(destination) end
        if fs.exists(backup) then fs.move(backup, destination) end
        message = "Install failed: " .. tostring(moveError)
        return
    end
    if fs.exists(backup) then fs.delete(backup) end
    local nameSaved, nameError = saveCatalogName(fs.getName(destination), app.name)
    if not nameSaved then
        message = app.name .. " installed, but its catalog name could not be saved: " .. nameError
        return
    end
    local key = versionKey(app)
    local previousVersion = installedVersions[key]
    installedVersions[key] = app.version
    local versionSaved, versionError = saveInstalledVersions()
    if not versionSaved then
        installedVersions[key] = previousVersion
        message = app.name .. " installed, but its version could not be saved: " .. versionError
        return
    end
    message = app.name .. " v" .. app.version .. " installed as " .. destination .. "."
end

local function updateApp(app)
    if not app then
        message = "Select an app to update."
        return
    end
    local destinationDirectory = app.scope == "system" and SYSTEM_APP_DIRECTORY or appDirectory
    local installedPath = fs.combine(destinationDirectory, app.file)
    if not fs.exists(installedPath) then
        downloadApp(app, true)
        return
    end
    local installedVersion = installedVersions[versionKey(app)]
    if installedVersion == app.version then
        message = app.name .. " is already up to date (v" .. app.version .. ")."
        return
    end
    if isVersionNewer(installedVersion, app.version) then
        message = app.name .. " v" .. installedVersion .. " is newer than catalog v" .. app.version .. "."
        return
    end
    downloadApp(app, true)
end

local function uninstallApp(app)
    if not app then
        message = "Select an app to uninstall."
        return
    end
    if app.scope == "system" then
        message = app.name .. " is a system app and is restored automatically at startup."
        return
    end

    local destination = fs.combine(appDirectory, app.file)
    if not fs.exists(destination) then
        message = app.name .. " is not installed for " .. username .. "."
        return
    end
    if fs.isDir(destination) then
        message = "Could not uninstall " .. app.name .. ": its install path is a directory."
        return
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.yellow)
    print("UNINSTALL " .. app.name)
    term.setTextColor(colors.white)
    print("This removes the app from " .. username .. "'s profile:")
    print(destination)
    print("Press Y to confirm or N/Escape to cancel.")
    while true do
        local event, key = os.pullEventRaw()
        if event == "char" then
            if key:lower() == "y" then break end
            if key:lower() == "n" then
                message = "Uninstall cancelled."
                return
            end
        elseif event == "key" and key == keys.escape then
            message = "Uninstall cancelled."
            return
        end
    end

    local removed, removeError = pcall(fs.delete, destination)
    if not removed or fs.exists(destination) then
        message = "Could not uninstall " .. app.name .. ": "
            .. tostring(removeError or "the app file still exists.")
        return
    end

    local key = versionKey(app)
    local previousVersion = installedVersions[key]
    installedVersions[key] = nil
    local versionSaved, versionError = saveInstalledVersions()
    if not versionSaved then
        installedVersions[key] = previousVersion
        message = app.name .. " was removed, but installed-version data could not be updated: "
            .. versionError
        return
    end

    local nameSaved, nameError = removeCatalogName(app.file)
    if not nameSaved then
        message = app.name .. " was removed, but its saved catalog name could not be cleared: "
            .. nameError
        return
    end
    message = app.name .. " was uninstalled from " .. username .. "'s profile."
end

local mode, target, requestedHome = ...
if mode == "install-system" then
    requestedHome = target
    target = nil
elseif mode ~= "update" then
    requestedHome = mode
    mode = nil
end
local homeOk, homeError = setHomeDirectory(requestedHome)
if not homeOk then
    printError(homeError)
    return
end
installedVersions = loadInstalledVersions()
loadTheme()
local catalog, catalogError = loadCatalog()
if not catalog then
    if mode == "update" then
        printError(catalogError)
        return
    end
    if mode == "install-system" then error(catalogError, 0) end
    apps = {}
    message = catalogError
else
    apps = catalog
    message = "Loaded " .. #apps .. " app(s) from the script host."
end

if mode == "install-system" then
    local installed, failures = 0, {}
    for _, app in ipairs(apps) do
        if app.scope == "system" then
            local destination = fs.combine(SYSTEM_APP_DIRECTORY, app.file)
            if not fs.exists(destination) then
                downloadApp(app)
                if fs.exists(destination) then
                    installed = installed + 1
                else
                    table.insert(failures, message)
                end
            end
        end
    end
    if #failures > 0 then
        error("Some system apps could not be installed: " .. table.concat(failures, " "), 0)
    end

    local migrationFailures = {}
    for _, profile in ipairs(fs.list(USER_ROOT)) do
        if profile:match("^[%w_-]+$") then
            local profileHome = fs.combine(USER_ROOT, profile)
            local profileApps = fs.combine(profileHome, "apps")
            if fs.isDir(profileHome) then
                for _, app in ipairs(apps) do
                    if app.scope == "system" then
                        local systemPath = fs.combine(SYSTEM_APP_DIRECTORY, app.file)
                        local legacyCopies = {
                            { path = fs.combine(profileApps, app.file), suffix = "" },
                            { path = fs.combine(profileHome, app.file), suffix = ".root.bak" },
                        }
                        if fs.exists(systemPath) then
                            for _, legacy in ipairs(legacyCopies) do
                                local legacyPath = legacy.path
                                if fs.exists(legacyPath) then
                                    local backupDirectory = fs.combine(
                                        fs.combine(SYSTEM_DIRECTORY, "legacy-apps"), profile
                                    )
                                    local backupPath = fs.combine(backupDirectory, app.file .. legacy.suffix)
                                    if fs.exists(backupPath) then
                                        table.insert(migrationFailures, profile .. "/" .. app.file
                                            .. " was left in place because a backup already exists.")
                                    else
                                        fs.makeDir(backupDirectory)
                                        local moved, moveError = pcall(fs.move, legacyPath, backupPath)
                                        if not moved then
                                            table.insert(migrationFailures, profile .. "/" .. app.file
                                                .. ": " .. tostring(moveError))
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if #migrationFailures > 0 then
        error("Some old system-app copies could not be moved: "
            .. table.concat(migrationFailures, " "), 0)
    end
    local legacyRootDownloader = "/app-downloader.lua"
    if fs.exists(legacyRootDownloader) then
        local legacyDirectory = fs.combine(SYSTEM_DIRECTORY, "legacy-apps")
        local legacyPath = fs.combine(legacyDirectory, "app-downloader.root.lua")
        if not fs.exists(legacyPath) then
            fs.makeDir(legacyDirectory)
            local moved, moveError = pcall(fs.move, legacyRootDownloader, legacyPath)
            if not moved then
                error("Could not move old root app-downloader.lua: " .. tostring(moveError), 0)
            end
        end
    end
    print("Installed " .. installed .. " system app(s).")
    return
end

if mode == "update" then
    for _, app in ipairs(apps) do
        if app.file == target then
            updateApp(app)
            print(message)
            return
        end
    end
    printError("This app is not in the online app catalog: " .. tostring(target))
    return
end

while true do
    local buttons = draw()
    local event, key, x, y = os.pullEventRaw()
    if event == "key" then
        if key == keys.up then
            selected = math.max(1, selected - 1)
        elseif key == keys.down then
            selected = math.min(#apps, selected + 1)
        elseif key == keys.n or key == keys.v then
            local _, height = term.getSize()
            local direction = key == keys.n and 1 or -1
            selected = math.max(1, math.min(#apps,
                selected + direction * visibleAppRows(height)))
        elseif key == keys.enter then
            downloadApp(apps[selected])
        elseif key == keys.u then
            updateApp(apps[selected])
        elseif key == keys.r then
            local refreshed, refreshError = loadCatalog()
            if refreshed then
                apps = refreshed
                selected = math.min(selected, math.max(1, #apps))
                firstVisible = 1
                message = "Loaded " .. #apps .. " app(s) from the script host."
            else
                message = refreshError
            end
        elseif key == keys.q or key == keys.escape then
            return
        end
    elseif event == "mouse_scroll" then
        local _, height = term.getSize()
        if y >= 3 and y < 3 + visibleAppRows(height) then
            selected = math.max(1, math.min(#apps, selected + key))
        end
    elseif event == "mouse_click" then
        local _, height = term.getSize()
        local index = firstVisible + y - 3
        if key == 1 and y >= 3 and y < 3 + visibleAppRows(height)
            and index >= firstVisible and index <= #apps then
            local wasSelected = selected == index
            selected = index
            if wasSelected then downloadApp(apps[selected]) end
        elseif key == 1 and y == height - 1 then
            local action = buttonAt(buttons, x)
            if action == "uninstall" then
                uninstallApp(apps[selected])
            elseif action == "update" then
                updateApp(apps[selected])
            elseif action == "refresh" then
                local refreshed, refreshError = loadCatalog()
                if refreshed then
                    apps = refreshed
                    selected = math.min(selected, math.max(1, #apps))
                    firstVisible = 1
                    message = "Loaded " .. #apps .. " app(s) from the script host."
                else
                    message = refreshError
                end
            elseif action == "quit" then
                return
            end
        end
    end
end
