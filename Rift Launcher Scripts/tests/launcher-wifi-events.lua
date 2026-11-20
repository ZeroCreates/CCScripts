local function readSource(path)
    if fs then
        local file = assert(fs.open(path, "r"))
        local contents = file.readAll()
        file.close()
        return contents
    end
    local file = assert(io.open(path, "r"))
    local contents = file:read("*a")
    file:close()
    return contents
end
local source = readSource("Rift Launcher Scripts/launcher.lua")
assert(load(source, "@launcher.lua", "t"))

local start = assert(source:find("local sessionMenuAllowed = false", 1, true))
local finish = assert(source:find("local apps = {}", start, true))
local eventCode = source:sub(start, finish - 1)
local realRaw = function(filter) return coroutine.yield(filter) end
local environment = setmetatable({
    os = { pullEventRaw = realRaw },
    keys = { leftAlt = 1, rightAlt = 2 },
    textutils = {},
}, { __index = _G })
local routing, setAppChain
local menus = 0
local launcher = coroutine.create(function()
    local code = [[
        local nativeOs = os
        local nativePullEventRaw = os.pullEventRaw
        local launcherThread = coroutine.running()
    ]] .. eventCode .. [[
        return function(menu)
            sessionMenuAllowed = true
            showSessionMenu = menu
        end, function(value) inAppChain = value end
    ]]
    routing, setAppChain = assert(load(code, "@launcher-events", "t", environment))()
    routing(function()
        menus = menus + 1
        local event, value = environment.os.pullEvent("rednet_message")
        assert(event == "rednet_message" and value == "router reply")
        return "exit"
    end)
    assert(environment.os.pullEventRaw() == "menu_closed")
end)
local ok, filter = coroutine.resume(launcher)
assert(ok and filter == nil, filter)

local scheduler = coroutine.create(function()
    assert(environment.os.pullEventRaw() == "terminate")
end)
assert(coroutine.resume(scheduler))
assert(coroutine.resume(scheduler, "terminate"))
assert(coroutine.status(scheduler) == "dead" and menus == 0,
    "The host scheduler must not open the launcher session menu")

local daemon = coroutine.create(function()
    assert(environment.os.pullEventRaw() == "terminate")
    assert(environment.os.pullEventRaw() == "modem_message")
end)
assert(coroutine.resume(daemon))
assert(coroutine.resume(daemon, "terminate"))
assert(coroutine.status(daemon) == "suspended" and menus == 0,
    "The rednet daemon must not open the launcher session menu")

ok, filter = coroutine.resume(launcher, "terminate")
assert(ok and filter == "rednet_message" and menus == 1, filter)
assert(coroutine.resume(daemon, "modem_message"))
assert(coroutine.status(daemon) == "dead")
assert(coroutine.resume(launcher, "rednet_message", "router reply"))
assert(coroutine.status(launcher) == "dead",
    "The session menu must receive a reply while the rednet daemon runs")

local app = coroutine.create(function()
    assert(environment.os.pullEventRaw() == "menu_closed")
end)
setAppChain(true)
assert(coroutine.resume(app))
ok, filter = coroutine.resume(app, "terminate")
assert(ok and filter == "rednet_message" and menus == 2, filter)
assert(coroutine.resume(app, "rednet_message", "router reply"))
setAppChain(false)
assert(coroutine.status(app) == "dead", "Managed apps must still open the session menu")

local stateStart = assert(source:find("local riftWifiState = {", 1, true))
local stateEnd = assert(source:find("riftWifiState.disconnect = function()", stateStart, true))
local address
local wifi = { getIP = function() return address end }
local stateEnv = setmetatable({
    os = { getComputerID = function() return 1 end, epoch = function() return 1 end },
    nativeRequire = function() return wifi end,
}, { __index = _G })
local state = assert(load(source:sub(stateStart, stateEnd - 1) ..
    "\nreturn riftWifiState", "@launcher-wifi", "t", stateEnv))()
assert(not state.isConnected())
address = ""
assert(not state.isConnected(), "An empty router IP means disconnected")
address = "192.168.1.100"
assert(state.isConnected())

for _, name in ipairs({ "jobs", "email-client", "market-client", "market-provider", "casino" }) do
    local appSource = readSource("Rift Launcher Scripts/apps/" .. name .. ".lua")
    assert(load(appSource, "@" .. name .. ".lua", "t"))
    local appStart = assert(appSource:find("local function openModems()", 1, true))
    local appEnd = assert(appSource:find("\nlocal function ", appStart + 1, true))
    local appEnv = setmetatable({
        wifi = wifi,
        peripheral = { getNames = function() return {} end },
        term = { isColor = function() return true end },
    }, { __index = _G })
    local check = assert(load(appSource:sub(appStart, appEnd - 1) ..
        "\nreturn openModems", "@" .. name .. "-wifi", "t", appEnv))()
    address = ""
    local opened, result = pcall(check)
    if name == "casino" then
        assert(opened and result == false, "Casino must reject an empty IP")
    else
        assert(not opened and tostring(result):find("Connect the launcher", 1, true),
            name .. " must reject an empty IP")
    end
    address = "192.168.1.100"
    assert(pcall(check), name .. " must accept a connected IP")
end
print("Launcher Wi-Fi event routing and connection-state tests passed")
