local LAUNCHER_URL = "https://rift.zerocreates.org/launcher.lua"
local LAUNCHER_STARTUP = 'if not shell.run("/launcher.lua") then\n'
    .. '    printError("Could not start /launcher.lua.")\n'
    .. 'end\n'
local STARTUP = 'local ok, err = pcall(fs.delete, "/startup.lua")\n'
    .. 'if not ok or fs.exists("/startup.lua") then\n'
    .. '    printError("Could not remove installer startup: " .. tostring(err))\n'
    .. '    return\n'
    .. 'end\n'
    .. LAUNCHER_STARTUP

local pending = {}
local queued = {}

local function enqueue(name)
    if not queued[name] then
        queued[name] = true
        pending[#pending + 1] = name
    end
end

local function sound(success)
    local speaker = peripheral.find("speaker")
    if speaker then
        pcall(speaker.playNote, success and "pling" or "bass", 1, success and 18 or 3)
    end
end

local function uniquePath(base)
    local candidate = base
    local index = 0
    while fs.exists(candidate) do
        index = index + 1
        candidate = base .. "." .. index
    end
    return candidate
end

local function readFile(path)
    local file, err = fs.open(path, "r")
    if not file then error(err or "Could not read " .. path, 0) end
    local ok, contents = pcall(file.readAll)
    local closed, closeError = pcall(file.close)
    if not ok or not closed then error(tostring(ok and closeError or contents), 0) end
    return contents
end

local function writeFile(path, contents)
    local file, err = fs.open(path, "w")
    if not file then error(err or "Could not write " .. path, 0) end
    local ok, writeError = pcall(file.write, contents)
    local closed, closeError = pcall(file.close)
    if not ok or not closed then error(tostring(ok and closeError or writeError), 0) end
end

local function downloadLauncher()
    if not http or not http.get then error("HTTP is disabled on this computer.", 0) end
    local response, err, failedResponse = http.get(LAUNCHER_URL)
    if not response then
        if failedResponse then pcall(failedResponse.close) end
        error("Download failed: " .. tostring(err), 0)
    end
    local ok, contents = pcall(response.readAll)
    local closed, closeError = pcall(response.close)
    if not ok or not closed then error("Download failed: " .. tostring(ok and closeError or contents), 0) end
    if type(contents) ~= "string" or contents == "" then error("The launcher download was empty.", 0) end
    local compiled, compileError = (loadstring or load)(contents, "@launcher.lua")
    if not compiled then error("The downloaded launcher is invalid: " .. tostring(compileError), 0) end
    return contents
end

local function install(name)
    if peripheral.getType(name) ~= "drive" or not disk.isPresent(name) then
        error("The drive is no longer available.", 0)
    end
    local mount = disk.getMountPath(name)
    if not mount or disk.getID(name) ~= nil then
        error("Insert a computer or turtle, not a floppy disk or record.", 0)
    end
    if fs.isReadOnly(mount) then error("The inserted computer is read-only.", 0) end

    local launcher = fs.combine(mount, "launcher.lua")
    local startup = fs.combine(mount, "startup.lua")
    if fs.exists(fs.combine(mount, "startup")) then
        error("An existing startup program was left unchanged.", 0)
    end
    if fs.exists(startup) then
        if fs.isDir(startup) then error("An existing startup.lua was left unchanged.", 0) end
        local existingStartup = readFile(startup)
        if existingStartup ~= STARTUP and existingStartup ~= LAUNCHER_STARTUP then
            error("An existing startup.lua was left unchanged.", 0)
        end
    end
    if fs.exists(launcher) and fs.isDir(launcher) then error("launcher.lua is a directory.", 0) end

    local contents = downloadLauncher()
    if disk.getMountPath(name) ~= mount then error("The computer was removed during download.", 0) end
    local launcherTemp = uniquePath(fs.combine(mount, ".rift-launcher-install.tmp"))
    local startupTemp = uniquePath(fs.combine(mount, ".rift-startup-install.tmp"))
    local backup
    local startupBackup
    local placedLauncher = false
    local ok, err = pcall(function()
        writeFile(launcherTemp, contents)
        writeFile(startupTemp, STARTUP)
        if fs.exists(launcher) then
            backup = uniquePath(launcher .. ".rift-backup")
            fs.move(launcher, backup)
        end
        fs.move(launcherTemp, launcher)
        placedLauncher = true
        if fs.exists(startup) then
            startupBackup = uniquePath(startup .. ".rift-backup")
            fs.move(startup, startupBackup)
        end
        fs.move(startupTemp, startup)
    end)
    if not ok then
        if startupBackup and fs.exists(startupBackup) and not fs.exists(startup) then
            pcall(fs.move, startupBackup, startup)
        end
        if placedLauncher and fs.exists(launcher) then pcall(fs.delete, launcher) end
        if backup and fs.exists(backup) and not fs.exists(launcher) then pcall(fs.move, backup, launcher) end
        if fs.exists(launcherTemp) then pcall(fs.delete, launcherTemp) end
        if fs.exists(startupTemp) then pcall(fs.delete, startupTemp) end
        error("Installation failed: " .. tostring(err), 0)
    end
    return backup
end

local function processDrive(name)
    local finished, succeeded, result, removed
    parallel.waitForAny(function()
        succeeded, result = pcall(install, name)
        finished = true
    end, function()
        while true do
            local event, drive = os.pullEvent()
            if event == "disk" and drive ~= name then
                enqueue(drive)
            elseif event == "disk_eject" and drive == name then
                removed = true
                return
            end
        end
    end)
    if removed and not finished then
        succeeded, result = false, "The computer was removed during installation."
    end
    if succeeded then
        print("Installed Rift Launcher on " .. name .. ".")
        if result then print("Previous launcher backed up to " .. result .. ".") end
    else
        printError("Could not install on " .. name .. ": " .. tostring(result))
    end
    sound(succeeded)
end

print("Rift install station: insert a computer or turtle into a disk drive.")
if not peripheral.find("speaker") then print("No speaker attached; sounds are unavailable.") end
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" and disk.isPresent(name) then enqueue(name) end
end

while true do
    if #pending > 0 then
        local name = table.remove(pending, 1)
        queued[name] = nil
        processDrive(name)
    else
        local event, name = os.pullEvent()
        if event == "disk" then enqueue(name) end
    end
end