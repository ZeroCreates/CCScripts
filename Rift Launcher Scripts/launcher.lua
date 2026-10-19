local SYSTEM_APP_DIRECTORY = "/.launcher/apps"
local DOWNLOADER_PATH = SYSTEM_APP_DIRECTORY .. "/app-downloader.lua"
local SYSTEM_FILE_BROWSER_PATH = SYSTEM_APP_DIRECTORY .. "/file-browser.lua"
local SYSTEM_CLOUD_PATH = SYSTEM_APP_DIRECTORY .. "/cloud.lua"
local SETTINGS_PROGRAM_PATH = SYSTEM_APP_DIRECTORY .. "/settings.lua"
local HOST_BASE_URL = "https://rift.zerocreates.org/"
local nativeFs = fs
local nativeOs = os
local nativeRequire = require
local nativeMultishell = multishell
local nativeLoadfile = loadfile
local nativePrintError = printError
local nativeSettingsApi = _G.settings
local nativePullEvent = nativeOs.pullEvent
local nativePullEventRaw = nativeOs.pullEventRaw
local apps = {}
local selected = 1
local firstVisible = 1
local message = "Select a program to launch."
local shiftDown = false
local currentUser
local homeDirectory
local profilePasswords = {}
local profileAdmins = {}
local authorizedProfiles = {}
local launchHomeProgramInTab = false
local autoLaunchSession = false
local cloudService
local cloudServiceFilter
local cloudServicePreviousTerm
local cloudServiceTerminal
local cloudServiceStatus
local cloudServiceErrorPath
local cloudServiceCode

local function createCloudMirrorTerminal(parent, mirror)
    local terminal = {}
    local methods = {
        "write", "blit", "clear", "clearLine", "getCursorPos", "setCursorPos",
        "getCursorBlink", "setCursorBlink", "getSize", "scroll",
        "getTextColor", "getTextColour", "setTextColor", "setTextColour",
        "getBackgroundColor", "getBackgroundColour", "setBackgroundColor", "setBackgroundColour",
        "isColor", "isColour", "getPaletteColor", "getPaletteColour",
        "setPaletteColor", "setPaletteColour",
    }
    local aliases = {
        getTextColor = "getTextColour",
        getTextColour = "getTextColor",
        setTextColor = "setTextColour",
        setTextColour = "setTextColor",
        getBackgroundColor = "getBackgroundColour",
        getBackgroundColour = "getBackgroundColor",
        setBackgroundColor = "setBackgroundColour",
        setBackgroundColour = "setBackgroundColor",
        isColor = "isColour",
        isColour = "isColor",
        getPaletteColor = "getPaletteColour",
        getPaletteColour = "getPaletteColor",
        setPaletteColor = "setPaletteColour",
        setPaletteColour = "setPaletteColor",
    }
    local readOnly = {
        getCursorPos = true,
        getCursorBlink = true,
        getSize = true,
        getTextColor = true,
        getTextColour = true,
        getBackgroundColor = true,
        getBackgroundColour = true,
        isColor = true,
        isColour = true,
        getPaletteColor = true,
        getPaletteColour = true,
    }
    for _, name in ipairs(methods) do
        local methodName = name
        terminal[methodName] = function(...)
            local parentMethod = parent[methodName] or parent[aliases[methodName] or ""]
            if readOnly[methodName] then
                return parentMethod(...)
            end
            local result = table.pack(parentMethod(...))
            local mirrorMethod = mirror[methodName] or mirror[aliases[methodName] or ""]
            if mirrorMethod then mirrorMethod(...) end
            return table.unpack(result, 1, result.n)
        end
    end
    return terminal
end

local function restoreCloudMirrorTerminal()
    if cloudServiceTerminal then term.redirect(cloudServiceTerminal) end
end

local function saveCloudServiceError(err)
    if not cloudServiceErrorPath then return false, "Cloud error log path is unavailable." end
    local contents = tostring(err)
    if cloudServiceCode then contents = contents:gsub(cloudServiceCode, "[redacted]") end
    local file, openError = nativeFs.open(cloudServiceErrorPath, "w")
    if not file then return false, tostring(openError or "Could not create the error log.") end
    local wrote, writeError = pcall(file.write, contents)
    local closed, closeError = pcall(file.close)
    if not wrote then return false, tostring(writeError) end
    if not closed then return false, tostring(closeError) end
    return true
end

local function reportCloudServiceError(err)
    local saved, saveError = saveCloudServiceError(err)
    if saved then
        cloudServiceStatus = "Failed; details in " .. nativeFs.getName(cloudServiceErrorPath)
        message = "Cloud Catcher: " .. cloudServiceStatus
    else
        cloudServiceStatus = "Failed: " .. tostring(saveError)
        message = "Cloud Catcher: " .. cloudServiceStatus
    end
    nativePrintError("Cloud Catcher stopped: " .. tostring(err))
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
local THEMES = {
    { name = "Ocean", accent = colors.cyan, highlight = colors.blue },
    { name = "Forest", accent = colors.lime, highlight = colors.green },
    { name = "Sunset", accent = colors.orange, highlight = colors.red },
    { name = "Violet", accent = colors.purple, highlight = colors.magenta },
    { name = "Custom", accent = colors.cyan, highlight = colors.blue },
}
local DEFAULT_CYAN = { 0.298, 0.600, 0.698 }
local DEFAULT_BLUE = { 0.200, 0.400, 0.800 }
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

local function chooseUser(skipAutoLogin)
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
    if not skipAutoLogin and type(settings.autoLoginUser) == "string"
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
            profileMessage = "That profile already exists. Select it from the list."
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
            if fs.isDir(fs.combine(USER_ROOT, entry)) and entry:match("^[%w_-]+$") then
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
        term.write(("Welcome back. Choose a profile to continue."):sub(1, math.max(0, width - 2)))
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
        else
            term.setCursorPos(2, height - 3)
            term.setTextColor(colors.lightGray)
            term.write(("N/V: change profile page  |  Click a profile twice to open.")
                :sub(1, math.max(0, width - 2)))
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
        if username ~= excludingUser and username:match("^[%w_-]+$")
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
    local available = {}
    local catalogNames = loadCatalogNames()

    fs.makeDir(SYSTEM_APP_DIRECTORY)
    for _, name in ipairs(fs.list(SYSTEM_APP_DIRECTORY)) do
        local path = fs.combine(SYSTEM_APP_DIRECTORY, name)
        if isLuaFile(path) and path ~= SYSTEM_CLOUD_PATH
            and fs.getName(path):lower() ~= "cloud.lua" and not available[path] then
            table.insert(available, {
                path = path,
                name = catalogNames[name] or displayName(name),
            })
            available[path] = true
        end
    end

    local appDirectory = fs.combine(homeDirectory, "apps")
    fs.makeDir(appDirectory)
    local desktopDirectory = fs.combine(homeDirectory, "desktop")
    fs.makeDir(desktopDirectory)

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
            if isLuaFile(fullPath) and fs.getName(fullPath):lower() ~= "cloud.lua"
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
        message = "No Lua programs found in " .. homeDirectory .. "."
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
    term.write((" " .. "COMPUTERCRAFT LAUNCHER - " .. tostring(currentUser)):sub(1, width))
    term.setBackgroundColor(backgroundColor)
    term.setCursorPos(2, 2)
    term.setTextColor(mutedColor)
    term.write(("YOUR PROGRAMS  |  N/V: PAGE"):sub(1, math.max(0, width - 2)))

    local lastVisible = math.min(#apps, firstVisible + visibleRows - 1)
    for index = firstVisible, lastVisible do
        local row = index - firstVisible + 4
        term.setCursorPos(2, row)
        if index == selected then
            term.setBackgroundColor(highlightColor)
            term.setTextColor(textColor)
            term.write(("  > " .. apps[index].name):sub(1, math.max(0, width - 2)))
            term.setBackgroundColor(backgroundColor)
        else
            term.setTextColor(textColor)
            term.write(("    " .. apps[index].name):sub(1, math.max(0, width - 2)))
        end
    end
    term.setCursorPos(2, height - 6)
    term.setTextColor(titleColor)
    local selectedApp = apps[selected]
    local detail = selectedApp and "Ready to launch" or "No programs found"
    term.write(detail:sub(1, math.max(0, width - 2)))
    firstButtons = {
        { label = "UPDATE", action = "update" },
        { label = "OPEN TAB", action = "tab" },
        { label = "SETTINGS", action = "settings" },
    }
    secondButtons = {
        { label = "SWITCH USER", action = "user" },
        { label = "REFRESH", action = "refresh" },
    }
    drawButtons(firstButtons, height - 2, width, isColor)
    drawButtons(secondButtons, height - 1, width, isColor)

    term.setCursorPos(2, height - 4)
    term.setTextColor(mutedColor)
    term.write(message:sub(1, math.max(0, width - 2)))
    term.setBackgroundColor(backgroundColor)
    term.setTextColor(textColor)
    return firstButtons, secondButtons
end

local function waitForReturn()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    print("")
    print("Exiting the program and returning to the launcher.")
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
    print("Opening the app downloader to update " .. app.name .. "...")
    local ok, result = pcall(os.run, _ENV, DOWNLOADER_PATH, "update", fs.getName(app.path), homeDirectory)
    if not ok then
        printError("Could not run the app downloader: " .. tostring(result))
    elseif result == false then
        printError("The app downloader did not complete successfully.")
    end
    waitForReturn()
    shiftDown = false
    refreshApps()
    message = "Returned from the app downloader."
end

local function isInHomeDirectory(path)
    local normalizedPath = path:gsub("^/+", ""):gsub("/+$", "")
    local normalizedHome = homeDirectory:gsub("^/+", ""):gsub("/+$", "")
    return normalizedPath == normalizedHome
        or normalizedPath:sub(1, #normalizedHome + 1) == normalizedHome .. "/"
end

local function runHomeProgram(programPath, profileContext, ...)
    local homeDirectory = profileContext.homeDirectory
    local currentUser = profileContext.user
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
    local function normalizeVirtualPath(path)
        if type(path) ~= "string" then
            error("Filesystem paths must be strings.", 0)
        end

        local segments = {}
        if path:sub(1, 1) ~= "/" and virtualDirectory ~= "" then
            for segment in virtualDirectory:gmatch("[^/]+") do
                table.insert(segments, segment)
            end
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

    local function physicalPath(path)
        local normalizedPath = normalizeVirtualPath(path)
        if type(path) == "string" and path:sub(1, 1) == "/" then
            local username, profilePath = normalizedPath:match("^users/([%w_-]+)/*(.*)$")
            if username then
                local authorized, accessError = authorizeProfileAccess(username, profileContext)
                if not authorized then error(accessError, 0) end
                return nativeFs.combine(USER_ROOT, username, profilePath)
            end
        end
        return nativeFs.combine(homeDirectory, normalizedPath)
    end

    local function virtualAbsolute(path)
        local normalized = normalizeVirtualPath(path)
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
                        local moved, moveError = pcall(nativeFs.move, temporary, path)
                        if not moved then
                            if nativeFs.exists(temporary) then nativeFs.delete(temporary) end
                            local restored, restoreError = pcall(nativeFs.move, backup, path)
                            error("Could not install encrypted storage file " .. relativePath .. ": "
                                .. tostring(moveError)
                                .. (restored and "" or "; restoring the backup also failed: "
                                    .. tostring(restoreError)), 0)
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
            return nativeFs.getName(normalizeVirtualPath(path))
        end
        sandboxFs.getDir = function(path)
            local directory = nativeFs.getDir(normalizeVirtualPath(path))
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
                sandboxFs[name] = function(path, ...)
                    return nativeFunction(physicalPath(path), ...)
                end
            end
        end
        for _, name in ipairs({ "move", "copy" }) do
            if type(nativeFs[name]) == "function" then
                local nativeFunction = nativeFs[name]
                sandboxFs[name] = function(source, destination, ...)
                    return nativeFunction(physicalPath(source), physicalPath(destination), ...)
                end
            end
        end
        if type(nativeFs.find) == "function" then
            sandboxFs.find = function(pattern)
                local results = {}
                local physicalHome = nativeFs.combine(homeDirectory, "")
                local normalizedPattern = normalizeVirtualPath(pattern)
                local targetUsername = normalizedPattern:match("^users/([%w_-]+)/")
                    or normalizedPattern:match("^users/([%w_-]+)$")
                local physicalProfileRoot = targetUsername
                    and nativeFs.combine(USER_ROOT, targetUsername)
                for _, found in ipairs(nativeFs.find(physicalPath(pattern))) do
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
                local pathDirectory = nativeFs.getDir(path)
                local name = nativeFs.getName(path)
                local baseDirectory = path:sub(1, 1) == "/" and "/" or (location or virtualDirectory)
                local completionDirectory = normalizeVirtualPath(
                    baseDirectory .. (pathDirectory ~= "" and "/" .. pathDirectory or "")
                )
                local physicalDirectory = physicalPath("/" .. completionDirectory)
                local completions = nativeFs.complete(
                    name,
                    physicalDirectory,
                    includeFiles,
                    includeDirs
                )
                local prefix = pathDirectory ~= "" and pathDirectory .. "/" or ""
                local result = {}
                for _, completion in ipairs(completions) do
                    table.insert(result, prefix .. completion)
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
        environment.storage = storageModule
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
            if moduleName == "storage" then
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
    if launchHomeProgramInTab then
        return nativeMultishell.launch(environment, target, ...)
    end
    return nativeOs.run(environment, target, ...)
end

local function createProfileCloudRunner(profileContext)
    return function(command, ...)
        if type(command) ~= "string" or command:find("[%c:]") then
            return false, "Invalid program path."
        end
        local normalized = command:gsub("\\", "/"):gsub("^/+", "")
        local candidates = {}
        local function addCandidate(path)
            local candidate = nativeFs.combine(profileContext.homeDirectory, path)
            if isInHomeDirectory(candidate) then
                candidates[#candidates + 1] = candidate
                if not candidate:lower():match("%.lua$") then
                    candidates[#candidates + 1] = candidate .. ".lua"
                end
            end
        end
        addCandidate(normalized)
        if not normalized:find("/", 1, true) then
            addCandidate("apps/" .. normalized)
            addCandidate("shell/" .. normalized)
        end
        for _, candidate in ipairs(candidates) do
            if nativeFs.exists(candidate) and not nativeFs.isDir(candidate)
                and candidate:lower():match("%.lua$") then
                local ok, result = pcall(runHomeProgram, candidate, profileContext, ...)
                if not ok then return false, tostring(result) end
                return result
            end
        end
        return false, "Program not found in the active profile home."
    end
end

local function resumeCloudService(...)
    if not cloudService then return end
    local ok, yielded = coroutine.resume(cloudService, ...)
    if not ok then
        reportCloudServiceError(yielded)
        cloudService = nil
        cloudServiceFilter = nil
        if cloudServicePreviousTerm then term.redirect(cloudServicePreviousTerm) end
        cloudServicePreviousTerm = nil
        cloudServiceTerminal = nil
        cloudServiceCode = nil
        cloudServiceErrorPath = nil
    elseif coroutine.status(cloudService) == "dead" then
        cloudService = nil
        cloudServiceFilter = nil
        if cloudServicePreviousTerm then term.redirect(cloudServicePreviousTerm) end
        cloudServicePreviousTerm = nil
        cloudServiceTerminal = nil
        if yielded == false then
            cloudServiceStatus = cloudServiceStatus or "Stopped with an error; check the terminal output."
        else
            cloudServiceStatus = "Connection ended."
        end
        message = "Cloud Catcher: " .. cloudServiceStatus
        cloudServiceCode = nil
        cloudServiceErrorPath = nil
    else
        cloudServiceFilter = yielded
    end
end

local function pullEventWithCloud(filter, raw)
    while true do
        local event = table.pack(nativePullEventRaw())
        if cloudService and coroutine.running() ~= cloudService
            and (cloudServiceFilter == nil or cloudServiceFilter == event[1] or event[1] == "terminate") then
            resumeCloudService(table.unpack(event, 1, event.n))
        end
        if filter == nil or event[1] == filter then
            if event[1] == "terminate" and not raw then error("Terminated", 0) end
            return table.unpack(event, 1, event.n)
        end
        if event[1] == "terminate" and not raw then error("Terminated", 0) end
    end
end

nativeOs.pullEvent = function(filter)
    return pullEventWithCloud(filter, false)
end
nativeOs.pullEventRaw = function(filter)
    return pullEventWithCloud(filter, true)
end

local function startCloudService(code, profileContext)
    if cloudService then return false, "Cloud Catcher is already running." end
    cloudServiceStatus = nil
    cloudServiceCode = code
    local errorPath = nativeFs.combine(profileContext.homeDirectory, "cloud-catcher-error.txt")
    local suffix = 1
    while nativeFs.exists(errorPath) do
        errorPath = nativeFs.combine(profileContext.homeDirectory,
            "cloud-catcher-error-" .. suffix .. ".txt")
        suffix = suffix + 1
    end
    cloudServiceErrorPath = errorPath
    cloudServicePreviousTerm = term.current()
    local environment = createSystemEnvironment()
    environment.profileHomeDirectory = profileContext.homeDirectory
    environment.cloudMirrorParentTerm = cloudServicePreviousTerm
    environment.cloudMirrorMode = true
    environment.cloudMirrorStatus = function(status)
        cloudServiceStatus = status
        message = "Cloud Catcher: " .. status
    end
    local cloudOs = {}
    for name, value in pairs(nativeOs) do cloudOs[name] = value end
    cloudOs.pullEvent = nativePullEvent
    cloudOs.pullEventRaw = nativePullEventRaw
    environment.os = cloudOs
    environment.cloudRunProgram = createProfileCloudRunner(profileContext)
    environment.cloudRemoteEvent = function(...)
        nativeOs.queueEvent(...)
    end
    local cloudShell = {}
    for name, value in pairs(shell) do cloudShell[name] = value end
    cloudShell.run = nil
    cloudShell.execute = nil
    environment.shell = cloudShell

    local previousDirectory = shell.dir()
    shell.setDir(profileContext.homeDirectory)
    cloudService = coroutine.create(function()
        setmetatable(environment, { __index = _G })
        if nativeSettingsApi and nativeSettingsApi.get
            and nativeSettingsApi.get("bios.strict_globals", false) then
            environment._ENV = environment
            getmetatable(environment).__newindex = function(_, name)
                error("Attempt to create global " .. tostring(name), 2)
            end
        end
        local program, loadError = nativeLoadfile(SYSTEM_CLOUD_PATH, nil, environment)
        if not program then
            reportCloudServiceError(loadError)
            return false
        end
        local ok, result = pcall(program, code)
        if not ok then
            reportCloudServiceError(result)
            return false
        end
        return true, result
    end)
    local started = table.pack(coroutine.resume(cloudService))
    shell.setDir(previousDirectory)
    if not started[1] then
        reportCloudServiceError(started[2])
        cloudService = nil
        cloudServicePreviousTerm = nil
        cloudServiceTerminal = nil
        cloudServiceCode = nil
        cloudServiceErrorPath = nil
        return false, tostring(started[2])
    end
    if started[2] ~= "cloud_mirror_terminal" or type(started[3]) ~= "table" then
        local startError = cloudServiceStatus or "Cloud Catcher did not provide its screen-mirror terminal."
        cloudService = nil
        cloudServicePreviousTerm = nil
        cloudServiceTerminal = nil
        cloudServiceCode = nil
        cloudServiceErrorPath = nil
        return false, startError
    end
    cloudServiceTerminal = createCloudMirrorTerminal(cloudServicePreviousTerm, started[3])
    restoreCloudMirrorTerminal()
    cloudServiceFilter = "cloud_catcher_start"
    nativeOs.queueEvent(cloudServiceFilter)
    return true
end

local function launchSelected(openInTab)
    local app = apps[selected]
    if not app then
        message = "Select an available program first."
        return
    end
    if openInTab and (not nativeMultishell or type(nativeMultishell.launch) ~= "function") then
        message = "This computer does not support program tabs."
        return
    end
    if openInTab and app.path:gsub("^/+", "") == SETTINGS_PROGRAM_PATH:gsub("^/+", "") then
        message = "System Settings must be opened directly."
        return
    end
    local profileContext = {
        user = currentUser,
        homeDirectory = homeDirectory,
        passwords = profilePasswords,
        admins = profileAdmins,
        authorized = authorizedProfiles,
    }
    restoreCloudMirrorTerminal()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("Launching " .. app.name .. "...")

    local previousDirectory = shell.dir()
    shell.setDir(homeDirectory)
    local ok, result
    local profileProgramError
    if isInHomeDirectory(app.path) then
        launchHomeProgramInTab = openInTab == true
        ok, result = pcall(runHomeProgram, app.path, profileContext, profileContext.homeDirectory)
        launchHomeProgramInTab = false
    elseif app.path:gsub("^/+", "") == SYSTEM_FILE_BROWSER_PATH:gsub("^/+", "") then
        local function runProfileProgram(path, ...)
            local normalizedPath = type(path) == "string" and path:gsub("^/+", ""):gsub("/+$", "")
            local normalizedHome = profileContext.homeDirectory:gsub("^/+", ""):gsub("/+$", "")
            if not normalizedPath or (normalizedPath ~= normalizedHome
                and normalizedPath:sub(1, #normalizedHome + 1) ~= normalizedHome .. "/") then
                error("Only programs in the active profile home can be run here.", 0)
            end
            local originalPrintError = printError
            local runtimeError
            printError = function(text)
                runtimeError = tostring(text)
                originalPrintError(text)
            end
            local ran, result = pcall(runHomeProgram, path, profileContext, ...)
            printError = originalPrintError
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
        local runner = openInTab and nativeMultishell.launch or nativeOs.run
        ok, result = pcall(runner, createSystemEnvironment(), app.path, profileContext.homeDirectory,
            runProfileProgram, listLaunchProfiles, authorizeLaunchProfile)
    elseif app.path:gsub("^/+", "") == SYSTEM_CLOUD_PATH:gsub("^/+", "") then
        local environment = createSystemEnvironment()
        environment.profileHomeDirectory = homeDirectory
        environment.cloudRunProgram = createProfileCloudRunner(profileContext)
        local cloudShell = {}
        for name, value in pairs(shell) do cloudShell[name] = value end
        cloudShell.run = nil
        cloudShell.execute = nil
        environment.shell = cloudShell
        local runner = openInTab and nativeMultishell.launch or nativeOs.run
        ok, result = pcall(runner, environment, app.path)
    elseif app.path:gsub("^/+", "") == SETTINGS_PROGRAM_PATH:gsub("^/+", "") then
        local environment = createSystemEnvironment()
        environment.profileHomeDirectory = homeDirectory
        environment.cloudRunProgram = createProfileCloudRunner(profileContext)
        environment.cloudStartService = function(code)
            return startCloudService(code, profileContext)
        end
        local runner = openInTab and nativeMultishell.launch or nativeOs.run
        ok, result = pcall(runner, environment, app.path, homeDirectory, currentUser, getThemeInfo())
    else
        local runner = openInTab and nativeMultishell.launch or nativeOs.run
        ok, result = pcall(runner, createSystemEnvironment(), app.path, homeDirectory)
    end
    shell.setDir(previousDirectory)
    restoreCloudMirrorTerminal()
    if app.path:gsub("^/+", "") == SETTINGS_PROGRAM_PATH:gsub("^/+", "")
        and cloudServiceStatus then
        message = "Cloud Catcher: " .. cloudServiceStatus
    end
    if openInTab then
        if not ok then
            message = "Could not open " .. app.name .. " in a tab: " .. tostring(result)
        elseif not result then
            message = "Could not open " .. app.name .. " in a tab."
        else
            if type(nativeMultishell.setTitle) == "function" then
                pcall(nativeMultishell.setTitle, result, app.name)
            end
            if type(nativeMultishell.setFocus) == "function" then
                pcall(nativeMultishell.setFocus, result)
            end
            message = "Opened " .. app.name .. " in a new tab."
        end
        refreshApps()
        return
    end
    term.clear()
    term.setCursorPos(1, 1)
    if not ok then
        printError("Program error: " .. tostring(result))
    elseif result == false then
        printError("The program reported that it did not complete successfully.")
    elseif profileProgramError then
        printError("Profile program error: " .. profileProgramError)
    end
    if autoLaunchSession then
        autoLaunchSession = false
        currentUser = nil
        homeDirectory = nil
        authorizedProfiles = {}
        chooseUser(true)
        selected = 1
        firstVisible = 1
        refreshApps()
        if not ok then
            message = "Signed out after " .. app.name .. " exited with an error: " .. tostring(result)
        elseif result == false then
            message = "Signed out after " .. app.name .. " did not complete successfully."
        else
            message = "Signed out after " .. app.name .. " was closed."
        end
        return
    end
    waitForReturn()
    if app.path:gsub("^/+", "") == SETTINGS_PROGRAM_PATH:gsub("^/+", "")
        and cloudServiceStatus then
        message = "Cloud Catcher: " .. cloudServiceStatus
    else
        message = "Returned from " .. app.name .. "."
    end
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
    restoreCloudMirrorTerminal()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    local profileContext = {
        user = currentUser,
        homeDirectory = homeDirectory,
        passwords = profilePasswords,
        admins = profileAdmins,
        authorized = authorizedProfiles,
    }
    local environment = createSystemEnvironment()
    environment.profileHomeDirectory = homeDirectory
    environment.cloudRunProgram = createProfileCloudRunner(profileContext)
    environment.cloudStartService = function(code)
        return startCloudService(code, profileContext)
    end
    local ok, result = pcall(nativeOs.run, environment, SETTINGS_PROGRAM_PATH,
        homeDirectory, currentUser, getThemeInfo())
    shell.setDir(previousDirectory)
    restoreCloudMirrorTerminal()
    loadSettings()
    refreshApps()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    if not ok then
        message = "System Settings error: " .. tostring(result)
    elseif cloudServiceStatus then
        message = "Cloud Catcher: " .. cloudServiceStatus
    elseif result == false then
        message = "System Settings did not complete successfully."
    else
        message = "Returned from System Settings."
    end
end

local function launcherMain()
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

chooseUser()
local systemAppsInstalled = false
local systemAppInstallMessage
local downloaderReady, downloaderError = installDownloader()
if downloaderReady then
    local ok, result = pcall(nativeOs.run, _ENV, DOWNLOADER_PATH, "install-system", homeDirectory)
    if ok and result ~= false then
        systemAppsInstalled = true
    else
        systemAppInstallMessage = ok
            and "Could not automatically install system apps: the downloader did not complete successfully."
            or "Could not run system app installation: " .. tostring(result)
    end
else
    systemAppInstallMessage = "Could not prepare the system app installer: " .. tostring(downloaderError)
end

refreshApps()
if startupError and systemAppInstallMessage then
    message = startupError .. " " .. systemAppInstallMessage
elseif startupError then
    message = startupError
elseif systemAppInstallMessage then
    message = systemAppInstallMessage
elseif systemAppsInstalled then
    message = "System apps are ready."
else
    message = "Select a program to launch."
end

if settings.autoLaunchPath then
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

while true do
    restoreCloudMirrorTerminal()
    local firstButtons, secondButtons = draw()
    local event, button, x, y = os.pullEventRaw()
    if event == "key" and (button == keys.n or button == keys.v) then
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
            elseif action == "tab" then
                launchSelected(true)
            end
        elseif y == height - 1 then
            local action = buttonAt(secondButtons, x)
            if action == "user" then
                if chooseUser() then
                    selected = 1
                    firstVisible = 1
                    refreshApps()
                    message = "Switched to " .. currentUser .. "."
                else
                    message = "Profile switch cancelled."
                end
            elseif action == "refresh" then
                refreshApps()
                message = "Program list refreshed."
            end
        end
    end
end

end

launcherMain()
