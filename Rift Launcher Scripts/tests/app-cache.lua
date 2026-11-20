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

local root = "Rift Launcher Scripts/"
local launcher = readSource(root .. "launcher.lua")
local start = assert(launcher:find("riftModules.cache = function(ttl)", 1, true))
local finish = assert(launcher:find("-- Shared Rift account client", start, true))
local now = 0
local env = setmetatable({ riftModules = {}, os = { clock = function() return now end } }, { __index = _G })
assert(load(launcher:sub(start, finish - 1), "@cache", "t", env))()
local newCache = env.riftModules.cache

local cache = newCache(300)
local calls = 0
local function loadValue()
    calls = calls + 1
    return calls
end
assert(cache.get("a", loadValue) == 1)
now = 299
assert(cache.get("a", loadValue) == 1 and calls == 1)
now = 300
assert(cache.get("a", loadValue) == 2 and calls == 2)
cache.invalidate("a")
assert(cache.get("a", loadValue) == 3)
cache.clear()
assert(cache.get("a", loadValue) == 4)
cache.invalidate("a")
local value, err = cache.get("a", function() return nil, "offline" end)
assert(value == nil and err == "offline")
assert(cache.get("a", loadValue) == 5)
cache.invalidate("a")
cache.get("a", function()
    cache.clear()
    return "old account"
end)
assert(cache.get("a", loadValue) == 6, "Invalidated in-flight data must not be cached")
env.riftModules.accountRevision = 1
assert(cache.get("a", loadValue) == 7, "Account changes must invalidate existing app caches")
cache.invalidate("a")
cache.get("a", function()
    env.riftModules.accountRevision = 2
    return "previous account"
end)
assert(cache.get("a", loadValue) == 8, "An account change during a load must prevent caching")

local accountStart = assert(launcher:find("riftModules.account = function(store, ui)", 1, true))
local accountEnd = assert(launcher:find("riftModules.appName = function()", accountStart, true))
local sent
env.riftWifiState = {
    session = "test",
    isConnected = function() return true end,
    api = {
        send = function(_, message) sent = message; return true end,
        receive = function()
            return { message = {
                riftService = "rift_account_v1", riftSession = "test",
                type = sent.type == "logout" and "logged_out" or "authenticated",
                username = sent.username,
            } }
        end,
    },
}
assert(load(launcher:sub(accountStart, accountEnd - 1), "@account", "t", env))()
local stored
local store = {
    read = function() return stored end,
    write = function(_, data) stored = data; return true end,
}
local alice = env.riftModules.account(store, {})
local bob = env.riftModules.account(store, {})
assert(alice.login("alice", "password"))
assert(alice.sessionUser() == "alice")
local revision = env.riftModules.accountRevision
assert(bob.login("alice", "password") and env.riftModules.accountRevision == revision,
    "Signing in to the same account must not invalidate caches")
assert(bob.login("bob", "password") and alice.sessionUser() == "bob")
assert(env.riftModules.accountRevision == revision + 1)
assert(bob.logout() and alice.sessionUser() == nil)
assert(env.riftModules.accountRevision == revision + 2)

local function requestHarness(path, nextFunction)
    local source = readSource(root .. "apps/" .. path)
    local first = assert(source:find("local function request(", 1, true))
    local last = assert(source:find("local function " .. nextFunction, first, true))
    local count, fail, invalid, during = 0, false, false, nil
    local appCache = newCache(300)
    local state = {
        cache = appCache,
        requestServer = function(message)
            count = count + 1
            if fail then return nil, "offline" end
            local fields = {
                get_catalog = "products", my_orders = "orders",
                provider_list = "orders", get_provider_products = "products",
                list_jobs = "jobs", my_jobs = "jobs",
                list = "messages", list_categories = "categories",
            }
            local response = { serial = count }
            local field = fields[message.type]
            if field and not invalid then response[field] = {} end
            if not field and during then during() end
            return response
        end,
    }
    setmetatable(state, { __index = _G })
    local request = assert(load(source:sub(first, last - 1) .. "\nreturn request", "@" .. path, "t", state))()
    return request, appCache, function() return count end,
        function(value) fail = value end, function(value) invalid = value end,
        function(value) during = value end
end

local function exercise(path, nextFunction, list, mutation)
    now = 0
    local request, appCache, count, setFail, setInvalid, setDuring = requestHarness(path, nextFunction)
    local first = assert(request(list))
    assert(request(list) == first and count() == 1, path .. " should reuse list data")
    now = 300
    assert(request(list) ~= first and count() == 2, path .. " should expire list data")
    assert(request(mutation))
    assert(request(list).serial == 4, path .. " should invalidate after a mutation")
    appCache.clear()
    setFail(true)
    local response, errorMessage = request(list)
    assert(not response and errorMessage == "offline")
    setFail(false)
    setInvalid(true)
    response, errorMessage = request(list)
    assert(not response and errorMessage:find("invalid", 1, true))
    setInvalid(false)
    assert(request(list), path .. " must retry after failures")
    setDuring(function() assert(request(list)) end)
    assert(request(mutation))
    setDuring(nil)
    local beforeRaceCheck = count()
    assert(request(list) and count() == beforeRaceCheck + 1,
        path .. " must invalidate a list loaded while a mutation was in flight")
    appCache.clear()
    local before = count()
    assert(request(list) and count() == before + 1, path .. " must not reuse a previous account's data")
end

exercise("market-client.lua", "loadRiftAccount", { type = "my_orders" }, { type = "place_order" })
exercise("market-provider.lua", "loadRiftAccount", { type = "provider_list" }, { type = "set_status" })
exercise("jobs.lua", "signOut", { type = "list_jobs" }, { type = "claim_job" })
exercise("email-client.lua", "choose", { type = "list", category = "Inbox" }, { type = "delete" })

local mail, _, mailCount = requestHarness("email-client.lua", "choose")
assert(mail({ type = "list", category = "Inbox" }))
assert(mail({ type = "list", category = "Other" }))
assert(mail({ type = "list", category = "Inbox" }) and mailCount() == 2,
    "Mail folders must have independent cache entries")

local function exerciseNotifications(path, functionName, list, dataField, firstItem, changedItem)
    now = 0
    local request, appCache, count, setFail = requestHarness(
        path, path == "email-client.lua" and "choose" or "loadRiftAccount")
    local source = readSource(root .. "apps/" .. path)
    local first = assert(source:find("local function " .. functionName .. "()", 1, true))
    local last = assert(source:find("-- Persistent endpoint:", first, true))
    local notifications, sessionUser = {}, "alice"
    local currentItem = firstItem
    local state = {
        cache = appCache,
        account = { username = "alice" },
        rift = {
            notify = function(text) notifications[#notifications + 1] = text end,
            account = { current = function() return "alice" end, sessionUser = function() return sessionUser end },
        },
        request = function(payload)
            local response, requestError = request(payload)
            if response then response[dataField] = { currentItem } end
            return response, requestError
        end,
    }
    setmetatable(state, { __index = _G })
    local code = "local polling, pollError\nlocal seenMail, knownStatus, firstPoll = {}, {}, true\n"
        .. source:sub(first, last - 1) .. "\nreturn " .. functionName
    local check = assert(load(code, "@" .. functionName, "t", state))()
    assert(request(list))
    check()
    assert(count() == 1, path .. " initial check should reuse cached data")
    currentItem = changedItem
    check()
    assert(count() == 2 and #notifications > 0, path .. " later checks must fetch updates")
    sessionUser = "bob"
    check()
    assert(count() == 2, path .. " must not poll under another account's session")
    sessionUser = "alice"
    local previousNotifications = #notifications
    setFail(true)
    check()
    check()
    assert(#notifications == previousNotifications + 1,
        path .. " should report a failed notification check once until it recovers")
    setFail(false)
    check()
end

exerciseNotifications("market-client.lua", "checkOrders", { type = "my_orders" }, "orders",
    { id = 1, status = "waiting" }, { id = 1, status = "preparing" })
exerciseNotifications("email-client.lua", "checkMail", { type = "list", category = "Inbox" }, "messages",
    { id = 1, read = true }, { id = 2, read = false, from = "bob", subject = "hello" })

print("App cache tests passed")
