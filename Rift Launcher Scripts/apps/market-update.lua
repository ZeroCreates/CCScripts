local HOST_BASE_URL = "https://rift.zerocreates.org/"
local CONFIG_NAME = "order-system.cfg"
local ROLE_FILES = {
    server = {
        name = "rift-server.lua",
        source = "computercraft/server/rift-server.lua",
    },
    provider = {
        name = "market-provider.lua",
        source = "computercraft/apps/market-provider.lua",
    },
    client = {
        name = "market-client.lua",
        source = "computercraft/apps/market-client.lua",
    },
}
local UPDATER = {
    name = "market-update.lua",
    source = "computercraft/apps/market-update.lua",
}

local function absolute(path)
    return fs.combine("/", path)
end

local function addUniquePath(paths, seen, path)
    path = absolute(path)
    if not seen[path] then
        seen[path] = true
        table.insert(paths, path)
    end
end

local function readConfig()
    local paths, seen = {}, {}
    local runningProgram = shell.getRunningProgram()
    local programDirectory = fs.getDir(runningProgram)
    local workingDirectory = shell.dir()
    addUniquePath(paths, seen, fs.combine(programDirectory, CONFIG_NAME))
    addUniquePath(paths, seen, fs.combine(workingDirectory, CONFIG_NAME))
    addUniquePath(paths, seen, fs.combine(workingDirectory, "apps/" .. CONFIG_NAME))

    for _, path in ipairs(paths) do
        if fs.exists(path) then
            local file = fs.open(path, "r")
            if not file then return nil, nil, "Could not read " .. path .. "." end
            local contents = file.readAll()
            file.close()
            local ok, config = pcall(textutils.unserialize, contents)
            if not ok or type(config) ~= "table" or not ROLE_FILES[config.role] then
                return nil, nil, "The installed role configuration is invalid: " .. path
            end
            return config, path
        end
    end
    return nil, nil, "No installed role found. Expected " .. CONFIG_NAME .. " beside the updater or in the current folder."
end

local function fetch(url)
    local ok, response, requestError = pcall(http.get, url)
    if not ok then return nil, tostring(response) end
    if not response then return nil, tostring(requestError or "HTTP request failed.") end
    local code = response.getResponseCode and response.getResponseCode()
    if code and code ~= 200 then
        response.close()
        return nil, "Script host returned HTTP " .. code .. "."
    end
    local contents = response.readAll()
    response.close()
    if not contents or contents == "" then return nil, "The script host returned an empty file." end
    return contents
end

if not http or not http.get then
    error("Enable the ComputerCraft HTTP API, then run market-update.lua again.")
end

local config, configPath, configError = readConfig()
if not config then error(configError, 0) end

local installDirectory = fs.getDir(shell.getRunningProgram())
local roleFile = ROLE_FILES[config.role]
local files = {
    {
        name = roleFile.name,
        source = roleFile.source,
        destination = fs.combine(installDirectory, roleFile.name),
    },
    {
        name = UPDATER.name,
        source = UPDATER.source,
        destination = fs.combine(installDirectory, UPDATER.name),
    },
}
if config.role == "server" then
    table.insert(files, {
        name = "rift-server-jobs.lua",
        source = "computercraft/server/rift-server-jobs.lua",
        destination = fs.combine(installDirectory, "rift-server-jobs.lua"),
    })
    table.insert(files, {
        name = "rift-server-market.lua",
        source = "computercraft/server/rift-server-market.lua",
        destination = fs.combine(installDirectory, "rift-server-market.lua"),
    })
    table.insert(files, {
        name = "rift-server-email.lua",
        source = "computercraft/server/rift-server-email.lua",
        destination = fs.combine(installDirectory, "rift-server-email.lua"),
    })
    table.insert(files, {
        name = "rift-server-casino.lua",
        source = "computercraft/server/rift-server-casino.lua",
        destination = fs.combine(installDirectory, "rift-server-casino.lua"),
    })
end

local staged = {}
print("Checking the script host for " .. config.role .. " and updater updates")
for _, entry in ipairs(files) do
    local url = HOST_BASE_URL .. entry.source
    local contents, err = fetch(url)
    if not contents then
        for _, temporary in pairs(staged) do
            if fs.exists(temporary) then fs.delete(temporary) end
        end
        error("Update stopped before changing installed files. Could not download "
            .. entry.source .. ": " .. err, 0)
    end

    local temporary = entry.destination .. ".update-tmp"
    if fs.exists(temporary) then fs.delete(temporary) end
    local file = fs.open(temporary, "w")
    if not file then
        for _, stagedPath in pairs(staged) do
            if fs.exists(stagedPath) then fs.delete(stagedPath) end
        end
        error("Could not create " .. temporary .. ".", 0)
    end
    file.write(contents)
    file.close()
    staged[entry.destination] = temporary
    print("Downloaded " .. entry.name)
end

local installed = {}
for _, entry in ipairs(files) do
    local destination = entry.destination
    local backup = destination .. ".bak"
    if fs.exists(backup) then fs.delete(backup) end
    if fs.exists(destination) then
        local backedUp, backupError = pcall(fs.move, destination, backup)
        if not backedUp then
            for _, temporary in pairs(staged) do
                if fs.exists(temporary) then fs.delete(temporary) end
            end
            for index = #installed, 1, -1 do
                local previous = installed[index]
                if fs.exists(previous.destination) then fs.delete(previous.destination) end
                if fs.exists(previous.backup) then fs.move(previous.backup, previous.destination) end
            end
            error("Could not back up " .. destination .. ": " .. tostring(backupError), 0)
        end
    end

    local moved, moveError = pcall(fs.move, staged[destination], destination)
    if not moved then
        if fs.exists(staged[destination]) then fs.delete(staged[destination]) end
        if fs.exists(destination) then fs.delete(destination) end
        if fs.exists(backup) then fs.move(backup, destination) end
        for index = #installed, 1, -1 do
            local previous = installed[index]
            if fs.exists(previous.destination) then fs.delete(previous.destination) end
            if fs.exists(previous.backup) then fs.move(previous.backup, previous.destination) end
        end
        error("Update failed and previous files were restored: " .. tostring(moveError), 0)
    end
    table.insert(installed, { destination = destination, backup = backup })
end

for _, entry in ipairs(installed) do
    if fs.exists(entry.backup) then fs.delete(entry.backup) end
end

if config.role == "server" then
    print("The combined Rift server is updated.")
    print("Stop old Jobs, Market, email, and Casino servers, then run rift-server.lua.")
    print("Back up and keep jobs.db, accounts.db, orders.db, and products.db in the server's working folder.")
    print("Existing accounts are moved from jobs.db into accounts.db on first startup.")
    print("Copy the existing Jobs and Market database files there before first startup.")
else
    print("The " .. config.role .. " system and market-update.lua are updated.")
end
print("Restart running scripts to use the new version.")
