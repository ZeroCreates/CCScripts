local SYSTEM_DIRECTORY = "/.launcher"
local USER_ROOT = "/users"
local SETTINGS_PATH = SYSTEM_DIRECTORY .. "/settings.json"
local PROFILE_PASSWORDS_PATH = SYSTEM_DIRECTORY .. "/profile-passwords.json"
local PROFILE_ADMINS_PATH = SYSTEM_DIRECTORY .. "/profile-admins.json"
local ENCRYPTION_KEY_PATH = SYSTEM_DIRECTORY .. "/.data-key"
local LAUNCHER_PATH = "/launcher.lua"
local CLOUD_PROGRAM_PATH = SYSTEM_DIRECTORY .. "/apps/cloud.lua"
local HOST_BASE_URL = "https://rift.zerocreates.org/"
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

local homeDirectory, currentUser = ...
local normalizedHome = type(homeDirectory) == "string" and homeDirectory:gsub("^/+", "")
local homeUser = normalizedHome and normalizedHome:match("^users/([%w_-]+)$")

if type(currentUser) ~= "string" or not currentUser:match("^[%w_-]+$")
    or homeUser ~= currentUser or not fs.isDir(fs.combine(USER_ROOT, currentUser)) then
    error("System Settings must be opened from an active user profile.", 0)
end

local keyFile = fs.open(ENCRYPTION_KEY_PATH, "r")
if not keyFile then error("Could not read the local data key.", 0) end
local encryptionKey = keyFile.readAll()
keyFile.close()
if type(encryptionKey) ~= "string" or #encryptionKey ~= 64 or encryptionKey:find("[^%x]") then
    error("The local data key is invalid.", 0)
end
encryptionKey = encryptionKey:upper()

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
    local encrypted = cryptData(contents)
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
    return cryptData(table.concat(encrypted)), true
end

local function isSensitiveDataPath(path)
    return path == SETTINGS_PATH or path == PROFILE_PASSWORDS_PATH
end

local saveJSON
local function readJSON(path, default)
    if not fs.exists(path) then return default end
    if fs.isDir(path) then return nil, path .. " is a directory." end
    local file = fs.open(path, "r")
    if not file then return nil, "Could not read " .. path .. "." end
    local contents = file.readAll()
    file.close()
    local decrypted, wasEncrypted, decryptError = decryptData(contents)
    if not decrypted then
        return nil, "Could not decrypt " .. path .. ": " .. tostring(decryptError)
    end
    contents = decrypted
    local ok, value = pcall(textutils.unserializeJSON, contents)
    if not ok or type(value) ~= "table" then
        return nil, "Invalid JSON data in " .. path .. "."
    end
    if isSensitiveDataPath(path) and not wasEncrypted then
        local saved, saveError = saveJSON(path, value)
        if not saved then
            return nil, "Could not encrypt existing data in " .. path .. ": " .. tostring(saveError)
        end
    end
    return value
end

saveJSON = function(path, value)
    local serialized, contents = pcall(textutils.serializeJSON, value)
    if not serialized or type(contents) ~= "string" then
        return false, "Could not serialize " .. path .. "."
    end
    if isSensitiveDataPath(path) then contents = encryptData(contents) end
    local made, makeError = pcall(fs.makeDir, SYSTEM_DIRECTORY)
    if not made then return false, "Could not create system settings folder: " .. tostring(makeError) end

    local temporary, backup = path .. ".tmp", path .. ".bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file, openError = fs.open(temporary, "w")
    if not file then return false, "Could not create " .. temporary .. ": " .. tostring(openError) end
    local wrote, writeError = pcall(file.write, contents)
    local closed, closeError = pcall(file.close)
    if not wrote or not closed then
        if fs.exists(temporary) then fs.delete(temporary) end
        return false, "Could not write " .. path .. ": "
            .. tostring(not wrote and writeError or closeError)
    end

    if fs.exists(path) then
        local backedUp, backupError = pcall(fs.move, path, backup)
        if not backedUp then
            fs.delete(temporary)
            return false, "Could not back up " .. path .. ": " .. tostring(backupError)
        end
    end
    local moved, moveError = pcall(fs.move, temporary, path)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then
            local restored, restoreError = pcall(fs.move, backup, path)
            if not restored then
                return false, "Could not save " .. path .. ": " .. tostring(moveError)
                    .. "; restoring the previous file also failed: " .. tostring(restoreError)
            end
        end
        return false, "Could not save " .. path .. ": " .. tostring(moveError)
    end
    if fs.exists(backup) then fs.delete(backup) end
    return true
end

local function validateMap(map, valueType, path)
    for username, value in pairs(map) do
        if type(username) ~= "string" or not username:match("^[%w_-]+$")
            or type(value) ~= valueType then
            return false, "Invalid account data in " .. path .. "."
        end
    end
    return true
end

local profilePasswords, passwordError = readJSON(PROFILE_PASSWORDS_PATH, {})
if not profilePasswords then error(passwordError, 0) end
local validPasswords, passwordValidationError = validateMap(
    profilePasswords, "string", PROFILE_PASSWORDS_PATH
)
if not validPasswords then error(passwordValidationError, 0) end

local profileAdmins, adminError = readJSON(PROFILE_ADMINS_PATH, {})
if not profileAdmins then error(adminError, 0) end
for username, isAdmin in pairs(profileAdmins) do
    if type(username) ~= "string" or not username:match("^[%w_-]+$") or isAdmin ~= true then
        error("Invalid account role data in " .. PROFILE_ADMINS_PATH .. ".", 0)
    end
end

local savedSettings, settingsError = readJSON(SETTINGS_PATH, {})
if not savedSettings then error(settingsError, 0) end
local settings = {
    theme = type(savedSettings.theme) == "number" and THEMES[savedSettings.theme]
        and savedSettings.theme or 1,
    customAccent = validHexColor(savedSettings.customAccent)
        and ("#" .. savedSettings.customAccent:gsub("^#", ""):upper()) or "#4C99B2",
    customHighlight = validHexColor(savedSettings.customHighlight)
        and ("#" .. savedSettings.customHighlight:gsub("^#", ""):upper()) or "#3366CC",
    alphabetical = true,
    autoLoginUser = type(savedSettings.autoLoginUser) == "string"
        and savedSettings.autoLoginUser:match("^[%w_-]+$") and savedSettings.autoLoginUser or nil,
    autoLaunchPath = type(savedSettings.autoLaunchPath) == "string"
        and #savedSettings.autoLaunchPath <= 256
        and not savedSettings.autoLaunchPath:find("..", 1, true)
        and savedSettings.autoLaunchPath or nil,
}
if type(savedSettings.alphabetical) == "boolean" then
    settings.alphabetical = savedSettings.alphabetical
end
local isAdmin = profileAdmins[currentUser] == true
local page = "settings"
local selectedUser = 1
local firstVisible = 1
local message = "Local data obfuscation is not secure against filesystem access."

local function countAdmins(admins)
    local count = 0
    for username, isProfileAdmin in pairs(admins) do
        if isProfileAdmin == true and fs.isDir(fs.combine(USER_ROOT, username)) then
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

local function listUsers()
    local users = {}
    fs.makeDir(USER_ROOT)
    for _, username in ipairs(fs.list(USER_ROOT)) do
        if username:match("^[%w_-]+$") and fs.isDir(fs.combine(USER_ROOT, username)) then
            table.insert(users, username)
        end
    end
    table.sort(users, function(first, second) return first:lower() < second:lower() end)
    return users
end

local function displayProgramName(path)
    return fs.getName(path):gsub("%.lua$", ""):gsub("[_%-]", " ")
end

local function listLaunchPrograms()
    local programs = {}
    local directories = {
        SYSTEM_DIRECTORY .. "/apps",
        fs.combine(homeDirectory, "apps"),
        fs.combine(homeDirectory, "desktop"),
    }
    for _, directory in ipairs(directories) do
        if fs.isDir(directory) then
            for _, name in ipairs(fs.list(directory)) do
                local path = fs.combine(directory, name)
                if not fs.isDir(path) and name:lower():match("%.lua$")
                    and name ~= "settings.lua" and name ~= "launcher.lua"
                    and name ~= "app-downloader.lua" then
                    table.insert(programs, { path = path, name = displayProgramName(path) })
                end
            end
        end
    end
    table.sort(programs, function(first, second)
        return first.name:lower() < second.name:lower()
    end)
    return programs
end

local function saveAccountData(passwords, admins)
    local savedPasswords, savePasswordError = saveJSON(PROFILE_PASSWORDS_PATH, passwords)
    if not savedPasswords then return false, savePasswordError end
    local savedAdmins, saveAdminError = saveJSON(PROFILE_ADMINS_PATH, admins)
    if not savedAdmins then
        local restored, restoreError = saveJSON(PROFILE_PASSWORDS_PATH, profilePasswords)
        if not restored then
            return false, saveAdminError .. " Password rollback failed: " .. tostring(restoreError)
        end
        return false, saveAdminError
    end
    profilePasswords, profileAdmins = passwords, admins
    return true
end

local function createAccount()
    term.clear()
    term.setCursorPos(1, 1)
    print("CREATE USER")
    write("Username (letters, numbers, _ or -): ")
    local username = read()
    if type(username) ~= "string" or not username:match("^[%w_-]+$") then
        return false, "Use only letters, numbers, underscores, and hyphens."
    end
    local profilePath = fs.combine(USER_ROOT, username)
    if fs.exists(profilePath) then return false, "That user already exists." end

    print("")
    print("A password is required for new accounts.")
    print("Private data is obfuscated with a key stored on this computer.")
    write("Password: ")
    local password = read("*")
    if type(password) ~= "string" or password == "" then
        return false, "Password cannot be empty."
    end
    write("Confirm password: ")
    if read("*") ~= password then return false, "Passwords did not match." end

    local created, createError = pcall(fs.makeDir, profilePath)
    if not created then return false, "Could not create user: " .. tostring(createError) end
    local passwords = copyMap(profilePasswords)
    passwords[username] = password
    local saved, saveError = saveJSON(PROFILE_PASSWORDS_PATH, passwords)
    if not saved then
        pcall(fs.delete, profilePath)
        return false, saveError
    end
    profilePasswords = passwords
    return true, "Created standard user " .. username .. ". Change their role if needed.", username
end

local function changeRole(users)
    local username = users[selectedUser]
    if not username then return "Select a user first." end
    if username == currentUser then return "Your own role cannot be changed while signed in." end
    local admins = copyMap(profileAdmins)
    if admins[username] then
        if countAdmins(admins) <= 1 then return "The last admin cannot be demoted." end
        admins[username] = nil
    else
        admins[username] = true
    end
    local saved, saveError = saveJSON(PROFILE_ADMINS_PATH, admins)
    if not saved then return saveError end
    profileAdmins = admins
    return username .. " is now " .. (admins[username] and "an admin." or "a standard user.")
end

local function confirmDeletion(username)
    local width, height = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.red)
    print("DELETE USER")
    term.setTextColor(colors.white)
    print("Delete " .. username .. " and their profile data?")
    print("This cannot be undone.")
    local buttons = {
        { label = "CANCEL", action = false },
        { label = "DELETE USER", action = true },
    }
    local slotWidth = math.max(1, math.floor(width / #buttons))
    for index, button in ipairs(buttons) do
        local left = (index - 1) * slotWidth + 1
        local buttonWidth = index == #buttons and width - left + 1 or slotWidth
        term.setCursorPos(left, height)
        term.setBackgroundColor(colors.gray)
        term.write(("[" .. button.label .. "]"):sub(1, buttonWidth))
        button.left = left
        button.right = left + buttonWidth - 1
    end
    while true do
        local event, button, x, y = os.pullEventRaw()
        if event == "mouse_click" and button == 1 and y == height then
            for _, choice in ipairs(buttons) do
                if x >= choice.left and x <= choice.right then return choice.action end
            end
        end
    end
end

local function deleteAccount(users)
    local username = users[selectedUser]
    if not username then return "Select a user first." end
    if username == currentUser then return "You cannot delete the active account." end
    if profileAdmins[username] and countAdmins(profileAdmins) <= 1 then
        return "The last admin cannot be deleted."
    end
    if not confirmDeletion(username) then return "Account deletion cancelled." end

    local trashDirectory = SYSTEM_DIRECTORY .. "/account-trash"
    local trashedProfile = fs.combine(trashDirectory, username)
    local privatePath = fs.combine(SYSTEM_DIRECTORY, "user-data/" .. username)
    local trashedPrivate = fs.combine(trashDirectory, username .. "-private")
    if fs.exists(trashedProfile) or fs.exists(trashedPrivate) then
        return "A previous deletion archive already exists; contact an administrator."
    end
    local made, makeError = pcall(fs.makeDir, trashDirectory)
    if not made then return "Could not prepare account deletion: " .. tostring(makeError) end

    local movedProfile, profileMoveError = pcall(fs.move, fs.combine(USER_ROOT, username), trashedProfile)
    if not movedProfile then
        return "Could not stage user profile for deletion: " .. tostring(profileMoveError)
    end
    local hasPrivateData = fs.exists(privatePath)
    if hasPrivateData then
        local movedPrivate, privateMoveError = pcall(fs.move, privatePath, trashedPrivate)
        if not movedPrivate then
            local restored, restoreError = pcall(fs.move, trashedProfile, fs.combine(USER_ROOT, username))
            return "Could not stage private account data: " .. tostring(privateMoveError)
                .. (restored and "" or "; profile restore failed: " .. tostring(restoreError))
        end
    end

    local passwords, admins = copyMap(profilePasswords), copyMap(profileAdmins)
    passwords[username], admins[username] = nil, nil
    local saved, saveError = saveAccountData(passwords, admins)
    if not saved then
        local restoreErrors = {}
        local restoredProfile, restoreProfileError = pcall(
            fs.move, trashedProfile, fs.combine(USER_ROOT, username)
        )
        if not restoredProfile then table.insert(restoreErrors, tostring(restoreProfileError)) end
        if hasPrivateData then
            local restoredPrivate, restorePrivateError = pcall(fs.move, trashedPrivate, privatePath)
            if not restoredPrivate then table.insert(restoreErrors, tostring(restorePrivateError)) end
        end
        if #restoreErrors > 0 then
            return saveError .. " Account data rollback failed: " .. table.concat(restoreErrors, "; ")
        end
        return saveError
    end

    local cleanupErrors = {}
    for _, path in ipairs({ trashedProfile, trashedPrivate }) do
        if fs.exists(path) then
            local removed, removeError = pcall(fs.delete, path)
            if not removed then table.insert(cleanupErrors, path .. ": " .. tostring(removeError)) end
        end
    end
    if #cleanupErrors > 0 then
        return "Account deleted, but staged data could not be removed: " .. table.concat(cleanupErrors, "; ")
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
    if preferencesChanged then
        local savedPreferences, preferencesError = saveJSON(SETTINGS_PATH, settings)
        if not savedPreferences then
            return "Deleted user " .. username
                .. ", but could not clear their automatic login/launch preferences: "
                .. tostring(preferencesError)
        end
    end
    return "Deleted user " .. username .. "."
end

local function savePreferences()
    local saved, saveError = saveJSON(SETTINGS_PATH, settings)
    if not saved then
        message = saveError
        return false
    end
    if not term.isColor() then
        message = "Launcher preferences saved."
        return true
    elseif settings.theme == #THEMES then
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
    message = "Launcher preferences saved."
    return true
end

local function editCustomColor(field, label)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("CUSTOM " .. label:upper())
    print("Enter a six-digit hex color, with or without #.")
    write("Hex color (current " .. settings[field] .. "): ")
    local value = read()
    if not validHexColor(value) then
        message = "Enter exactly six hexadecimal digits, optionally prefixed with #."
        return
    end
    settings[field] = "#" .. value:gsub("^#", ""):upper()
    savePreferences()
end

local function updateLauncher()
    if not http or type(http.get) ~= "function" then
        message = "Enable the ComputerCraft HTTP API to update the launcher."
        return
    end

    local temporary = LAUNCHER_PATH .. ".update-tmp"
    local backup = LAUNCHER_PATH .. ".update-bak"
    local requested, response, requestError = pcall(
        http.get, HOST_BASE_URL .. "launcher.lua"
    )
    if not requested then
        message = "Launcher update request failed: " .. tostring(response)
        return
    end
    if not response then
        message = "Launcher update request failed: "
            .. tostring(requestError or "HTTP request failed.")
        return
    end

    local responseCode = response.getResponseCode and response.getResponseCode()
    if responseCode and responseCode ~= 200 then
        response.close()
        message = "Launcher update failed: host returned HTTP " .. responseCode .. "."
        return
    end

    local contents = response.readAll()
    response.close()
    if not contents or contents == "" then
        message = "Launcher update failed: the downloaded file was empty."
        return
    end

    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file = fs.open(temporary, "w")
    if not file then
        message = "Could not create " .. temporary .. "."
        return
    end
    local wrote, writeError = pcall(file.write, contents)
    local closed, closeError = pcall(file.close)
    if not wrote or not closed then
        if fs.exists(temporary) then fs.delete(temporary) end
        message = "Could not write the launcher update: "
            .. tostring(not wrote and writeError or closeError)
        return
    end

    if fs.exists(LAUNCHER_PATH) then
        local backedUp, backupError = pcall(fs.move, LAUNCHER_PATH, backup)
        if not backedUp then
            fs.delete(temporary)
            message = "Could not back up the current launcher: " .. tostring(backupError)
            return
        end
    end

    local moved, moveError = pcall(fs.move, temporary, LAUNCHER_PATH)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then fs.move(backup, LAUNCHER_PATH) end
        message = "Could not install the launcher update: " .. tostring(moveError)
        return
    end
    if fs.exists(backup) then fs.delete(backup) end
    message = "Launcher updated. Restart to use the new version."
end

local function startCloud()
    if not fs.exists(CLOUD_PROGRAM_PATH) then
        message = "Cloud Catcher is not installed. Refresh system apps and try again."
        return
    end
    if not http or type(http.websocket) ~= "function" then
        message = "Enable the ComputerCraft HTTP API and allow the Cloud Catcher host."
        return
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("CLOUD CATCHER")
    print("Enter the 32-character connection code.")
    write("Code: ")
    local code = read("*")
    if not code or code == "" then
        message = "Cloud Catcher was not started."
        return
    end
    if #code ~= 32 or code:find("[^%a%d]") then
        message = "Cloud Catcher code must be 32 letters or numbers."
        return false
    end
    if type(cloudStartService) ~= "function" then
        message = "The launcher cannot start Cloud Catcher in screen-mirror mode."
        return false
    end
    local started, startError = cloudStartService(code)
    if not started then
        message = "Cloud Catcher error: " .. tostring(startError)
        return false
    end
    message = "Cloud Catcher is running. Returning to the launcher."
    return true
end

local function drawButtons(buttons, width, row, isColor)
    local slotWidth = math.max(1, math.floor(width / #buttons))
    term.setCursorPos(1, row)
    term.setBackgroundColor(colors.black)
    term.write(string.rep(" ", width))
    for index, button in ipairs(buttons) do
        local slotLeft = (index - 1) * slotWidth + 1
        local slotRight = index == #buttons and width or slotLeft + slotWidth - 1
        local slotSize = slotRight - slotLeft + 1
        local label = ("[" .. button.label .. "]"):sub(1, slotSize)
        local left = slotLeft + math.floor((slotSize - #label) / 2)
        term.setCursorPos(left, row)
        term.setBackgroundColor(isColor and colors.gray or colors.black)
        term.setTextColor(colors.white)
        term.write(label)
        button.left = left
        button.right = left + #label - 1
    end
end

local function buttonAt(buttons, x)
    for _, button in ipairs(buttons) do
        if x >= button.left and x <= button.right then return button.action end
    end
end

local function wipeComputer()
    local width, height = term.getSize()
    local confirmationButtons = {
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
    print("")
    print("Click WIPE COMPUTER below to confirm.")
    drawButtons(confirmationButtons, width, height - 1, term.isColor())

    local confirmed = false
    while true do
        local event, button, x, y = os.pullEventRaw()
        if event == "mouse_click" and button == 1 and y == height - 1 then
            for _, choice in ipairs(confirmationButtons) do
                if x >= choice.left and x <= choice.right then
                    confirmed = choice.action
                    break
                end
            end
            break
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
                table.insert(failures, path .. ": " .. tostring(removeError or "could not remove"))
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
        print("Press any key to return to Settings.")
        os.pullEventRaw()
        message = "Computer wipe was incomplete; see the error list."
        return
    end

    term.setTextColor(colors.lime)
    print("Computer filesystem wiped.")
    term.setTextColor(colors.white)
    print("The ROM folder was preserved.")
    print("Turn off or reboot the computer.")
    while true do os.pullEventRaw() end
end

local function draw()
    local width, height = term.getSize()
    local isColor = term.isColor()
    local theme = THEMES[settings.theme]
    local accent = isColor and theme.accent or colors.gray
    local highlight = isColor and theme.highlight or colors.gray
    local buttons
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(accent)
    term.write((" SYSTEM SETTINGS"):sub(1, width))
    term.setBackgroundColor(colors.black)
    term.setCursorPos(2, 2)
    term.setTextColor(colors.lightGray)
    local pageTitle = page == "settings" and "LAUNCHER PREFERENCES"
        or page == "accounts" and "USER ACCOUNTS" or "SYSTEM MAINTENANCE"
    term.write(pageTitle:sub(1, math.max(0, width - 2)))

    if page == "settings" then
        local autoLaunchLabel = "Off"
        if settings.autoLaunchPath then
            autoLaunchLabel = "Unavailable"
            for _, program in ipairs(listLaunchPrograms()) do
                if program.path == settings.autoLaunchPath then
                    autoLaunchLabel = program.name
                    break
                end
            end
        end
        local options = {
            "Accent theme: " .. theme.name,
            "Custom accent: " .. settings.customAccent,
            "Custom highlight: " .. settings.customHighlight,
            "Sort programs alphabetically: " .. (settings.alphabetical and "On" or "Off"),
            "Auto-login this profile: " .. (settings.autoLoginUser == currentUser and "On" or "Off"),
            "Auto-launch program: " .. autoLaunchLabel,
        }
        for index, option in ipairs(options) do
            term.setCursorPos(2, index + 4)
            if index == selectedUser then
                term.setBackgroundColor(highlight)
                term.write(("  > " .. option):sub(1, math.max(0, width - 2)))
                term.setBackgroundColor(colors.black)
            else
                term.write(("    " .. option):sub(1, math.max(0, width - 2)))
            end
        end
        term.setCursorPos(2, height - 2)
        term.setTextColor(colors.lightGray)
        term.write(message:sub(1, math.max(0, width - 2)))
        buttons = {
            { label = isAdmin and "ACCOUNTS" or "NO ADMIN ACCESS", action = "accounts" },
            { label = "CLOUD", action = "cloud" },
            { label = "MAINTENANCE", action = "maintenance" },
            { label = "EXIT", action = "exit" },
        }
    elseif page == "maintenance" then
        local options = {
            "Update launcher",
            "Wipe entire computer",
        }
        selectedUser = math.max(1, math.min(selectedUser, #options))
        for index, option in ipairs(options) do
            term.setCursorPos(2, index + 4)
            if index == selectedUser then
                term.setBackgroundColor(highlight)
                term.write(("  > " .. option):sub(1, math.max(0, width - 2)))
                term.setBackgroundColor(colors.black)
            else
                term.write(("    " .. option):sub(1, math.max(0, width - 2)))
            end
        end
        term.setCursorPos(2, height - 2)
        term.setTextColor(colors.lightGray)
        term.write(message:sub(1, math.max(0, width - 2)))
        buttons = {
            { label = "BACK", action = "preferences" },
            { label = "EXIT", action = "exit" },
        }
    else
        local users = listUsers()
        local visibleRows = math.max(1, height - 8)
        if #users == 0 then
            selectedUser, firstVisible = 1, 1
        else
            selectedUser = math.max(1, math.min(selectedUser, #users))
            firstVisible = math.max(1, math.min(firstVisible, selectedUser))
            if selectedUser >= firstVisible + visibleRows then
                firstVisible = selectedUser - visibleRows + 1
            end
        end
        local lastVisible = math.min(#users, firstVisible + visibleRows - 1)
        for index = firstVisible, lastVisible do
            local username = users[index]
            local role = profileAdmins[username] and "ADMIN" or "STANDARD"
            term.setCursorPos(2, index - firstVisible + 4)
            if index == selectedUser then
                term.setBackgroundColor(highlight)
                term.write(("  > " .. username .. " [" .. role .. "]")
                    :sub(1, math.max(0, width - 2)))
                term.setBackgroundColor(colors.black)
            else
                term.write(("    " .. username .. " [" .. role .. "]")
                    :sub(1, math.max(0, width - 2)))
            end
        end
        if #users == 0 then
            term.setCursorPos(2, 5)
            term.setTextColor(colors.lightGray)
            term.write("No user accounts exist.")
        end
        term.setCursorPos(2, height - 3)
        term.setTextColor(colors.lightGray)
        term.write(("N/V: PAGE THROUGH USERS"):sub(1, math.max(0, width - 2)))
        term.setCursorPos(2, height - 2)
        term.setTextColor(colors.lightGray)
        term.write(message:sub(1, math.max(0, width - 2)))
        buttons = {
            { label = "CREATE", action = "create" },
            { label = "ROLE", action = "role" },
            { label = "DELETE", action = "delete" },
            { label = "PREFERENCES", action = "preferences" },
        }
        drawButtons(buttons, width, height, isColor)
        return buttons, users, firstVisible, visibleRows
    end

    drawButtons(buttons, width, height, isColor)
    return buttons
end

while true do
    local buttons, users, firstUserRow, visibleRows = draw()
    local event, button, x, y = os.pullEventRaw()
    if event == "key" and page == "accounts" and (button == keys.n or button == keys.v) then
        local direction = button == keys.n and 1 or -1
        selectedUser = math.max(1, math.min(#users, selectedUser + direction * visibleRows))
        if selectedUser < firstUserRow then firstVisible = selectedUser end
        if selectedUser >= firstUserRow + visibleRows then
            firstVisible = selectedUser - visibleRows + 1
        end
    elseif event == "mouse_scroll" and page == "accounts" then
        selectedUser = math.max(1, math.min(#users, selectedUser + button))
        if selectedUser < firstUserRow then firstVisible = selectedUser end
        if selectedUser >= firstUserRow + visibleRows then
            firstVisible = selectedUser - visibleRows + 1
        end
    elseif event == "mouse_click" and button == 1 then
        local _, height = term.getSize()
        if page == "settings" and y == 5 then
            selectedUser = 1
            settings.theme = ((settings.theme - 1 + (x <= math.floor(select(1, term.getSize()) / 2) and -1 or 1))
                % #THEMES) + 1
            savePreferences()
        elseif page == "settings" and y == 6 then
            selectedUser = 2
            editCustomColor("customAccent", "Accent color")
        elseif page == "settings" and y == 7 then
            selectedUser = 3
            editCustomColor("customHighlight", "Highlight color")
        elseif page == "settings" and y == 8 then
            selectedUser = 4
            settings.alphabetical = not settings.alphabetical
            savePreferences()
        elseif page == "settings" and y == 9 then
            selectedUser = 5
            if settings.autoLoginUser == currentUser then
                settings.autoLoginUser = nil
            else
                settings.autoLoginUser = currentUser
            end
            local saved = savePreferences()
            if saved and settings.autoLoginUser == currentUser then
                message = "Auto-login enabled for " .. currentUser .. ". This bypasses that profile's startup password prompt."
            elseif saved then
                message = "Auto-login disabled."
            end
        elseif page == "settings" and y == 10 then
            selectedUser = 6
            local programs = listLaunchPrograms()
            local currentIndex = 1
            for index, program in ipairs(programs) do
                if program.path == settings.autoLaunchPath then
                    currentIndex = index + 1
                    break
                end
            end
            local direction = x <= math.floor(select(1, term.getSize()) / 2) and -1 or 1
            currentIndex = (currentIndex - 1 + direction) % (#programs + 1) + 1
            if currentIndex == 1 then
                settings.autoLaunchPath = nil
            else
                settings.autoLaunchPath = programs[currentIndex - 1].path
            end
            local saved = savePreferences()
            if saved then
                message = settings.autoLaunchPath
                    and "Selected " .. displayProgramName(settings.autoLaunchPath) .. " for automatic launch."
                    or "Automatic program launch disabled."
            end
        elseif page == "maintenance" and y == 5 then
            selectedUser = 1
            updateLauncher()
        elseif page == "maintenance" and y == 6 then
            selectedUser = 2
            wipeComputer()
        elseif y == height then
            local action = buttonAt(buttons, x)
            if action == "exit" then return end
            if action == "accounts" then
                if isAdmin then
                    page = "accounts"
                    selectedUser, firstVisible = 1, 1
                    message = "Select a user to change their role or delete them."
                else
                    message = "Only an administrator can manage user accounts."
                end
            elseif action == "cloud" then
                if startCloud() then return end
            elseif action == "preferences" then
                page = "settings"
                message = "Theme row: click left/right; choose Custom to use the hex colors."
            elseif action == "maintenance" then
                page = "maintenance"
                selectedUser = 1
                message = "Launcher update and computer wipe controls."
            elseif action == "create" then
                local created, result, createdUsername = createAccount()
                message = result
                if created then
                    local updatedUsers = listUsers()
                    for index, username in ipairs(updatedUsers) do
                        if username == createdUsername then
                            selectedUser = index
                            break
                        end
                    end
                    firstVisible = math.min(firstVisible, selectedUser)
                end
            elseif action == "role" then
                message = changeRole(users)
            elseif action == "delete" then
                message = deleteAccount(users)
                selectedUser = math.max(1, selectedUser - 1)
            end
        elseif page == "accounts" and y >= 4 and y < 4 + visibleRows then
            local clickedIndex = firstUserRow + y - 4
            if clickedIndex >= 1 and clickedIndex <= #users then selectedUser = clickedIndex end
        end
    end
end
