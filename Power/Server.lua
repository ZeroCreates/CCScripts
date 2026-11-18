
local REDNET_PROTOCOL = "zerofusion"
local reassignArgument = (...)
local reassign = type(reassignArgument) == "string"
    and (reassignArgument:lower() == "reassign"
        or reassignArgument:lower() == "--reassign")

local discordHookPath = "/DiscordHook.lua"
if not fs.exists(discordHookPath) then
    local response, err = http.get(
        "https://raw.githubusercontent.com/Wendelstein7/DiscordHook-CC/master/DiscordHook.lua"
    )
    if not response then
        error("Unable to download DiscordHook: " .. tostring(err))
    end

    local hookSource = response.readAll()
    response.close()

    local file = fs.open(discordHookPath, "w")
    if not file then
        error("Unable to save DiscordHook.")
    end
    file.write(hookSource)
    file.close()
end

local discord = require("DiscordHook")
local success, discordHook = discord.createWebhook(
    "https://discord.com/api/webhooks/1354695613115007006/ZjsQOGmVl9bnhccAtjYWjiSmDbaTYD8s0_8QhNMLGIYd2v4CKZlnPM4BFDmsnMbAFsJH"
)
if not success then
    error(discordHook)
end

local monitors = {peripheral.find("monitor")}
local reactor = peripheral.find("fusionReactorLogicAdapter")
if not reactor then error("Fusion reactor peripheral not found.") end

local CONFIG_PATH = "/zerofusion-server.cfg"
local config = {}
if fs.exists(CONFIG_PATH) then
    local file = fs.open(CONFIG_PATH, "r")
    if file then
        local contents = file.readAll()
        file.close()
        local ok, savedConfig = pcall(textutils.unserialize, contents)
        if ok and type(savedConfig) == "table" then
            config = savedConfig
        else
            print("Peripheral configuration is invalid; it will be recreated.")
        end
    end
end

local function peripheralTypes(name)
    local values = {peripheral.getType(name)}
    local result = {}
    for _, value in ipairs(values) do
        if type(value) == "string" then
            table.insert(result, value:lower())
        end
    end
    return table.concat(result, " ")
end

local function isChemicalTank(name)
    local types = peripheralTypes(name)
    local wrapped = peripheral.wrap(name)
    return types:find("chemical", 1, true) ~= nil
        and types:find("tank", 1, true) ~= nil
        and wrapped and type(wrapped.getStored) == "function"
end

local function isEnergyStorage(name)
    local wrapped = peripheral.wrap(name)
    return wrapped and type(wrapped.getEnergy) == "function"
        and type(wrapped.getMaxEnergy) == "function"
end

local function isModem(name)
    return peripheralTypes(name):find("modem", 1, true) ~= nil
end

local chemicalTanks, energyStorages, modems = {}, {}, {}
for _, name in ipairs(peripheral.getNames()) do
    if isChemicalTank(name) then table.insert(chemicalTanks, name) end
    if isEnergyStorage(name) then table.insert(energyStorages, name) end
    if isModem(name) then table.insert(modems, name) end
end
table.sort(chemicalTanks)
table.sort(energyStorages)
table.sort(modems)

local function getChemicalIdentifier(name)
    local tank = peripheral.wrap(name)
    local ok, stored = pcall(tank.getStored)
    if not ok or type(stored) ~= "table" then return "" end

    local identifiers = {}
    for _, field in ipairs({"name", "id", "chemical", "chemicalName", "registryName", "type"}) do
        local value = stored[field]
        if type(value) == "string" then
            table.insert(identifiers, value:lower())
        elseif type(value) == "table" then
            for _, nestedField in ipairs({"name", "id", "registryName"}) do
                if type(value[nestedField]) == "string" then
                    table.insert(identifiers, value[nestedField]:lower())
                end
            end
        end
    end
    return table.concat(identifiers, " ")
end

local function findChemicalTank(keyword)
    local matches = {}
    for _, name in ipairs(chemicalTanks) do
        if getChemicalIdentifier(name):find(keyword, 1, true) then
            table.insert(matches, name)
        end
    end
    if #matches == 1 then return matches[1] end
    return nil
end

local function choosePeripheral(label, candidates, suggested)
    if #candidates == 0 then error("No peripherals available for " .. label .. ".") end
    print(label .. " peripherals:")
    for index, name in ipairs(candidates) do
        print(string.format("  %d) %s%s", index, name,
            name == suggested and " [detected/current]" or ""))
    end
    while true do
        write(label .. " [number/name" .. (suggested and ", Enter=" .. suggested or "") .. "]: ")
        local choice = read()
        if choice == "" and suggested then return suggested end
        local index = tonumber(choice)
        if index and candidates[index] then return candidates[index] end
        for _, name in ipairs(candidates) do
            if choice == name then return name end
        end
        print("Choose a listed peripheral.")
    end
end

local function isCandidate(name, candidates)
    for _, candidate in ipairs(candidates) do
        if name == candidate then return true end
    end
    return false
end

local autoDeuterium = findChemicalTank("deuterium")
local autoTritium = findChemicalTank("tritium")
local deuteriumDefault = autoDeuterium or config.deuteriumTank
local tritiumDefault = autoTritium or config.tritiumTank
if not isCandidate(deuteriumDefault, chemicalTanks) then deuteriumDefault = nil end
if not isCandidate(tritiumDefault, chemicalTanks) then tritiumDefault = nil end

local energyDefault = isCandidate(config.energyStorage, energyStorages)
    and config.energyStorage or nil
local networkDefault = isCandidate(config.networkEnergyStorage, energyStorages)
    and config.networkEnergyStorage or nil
local modemDefault = isCandidate(config.modem, modems) and config.modem or nil

local deuteriumTankName, tritiumTankName
if reassign or not deuteriumDefault then
    deuteriumTankName = choosePeripheral("Deuterium tank", chemicalTanks, deuteriumDefault)
else
    deuteriumTankName = deuteriumDefault
end
if reassign or not tritiumDefault or tritiumDefault == deuteriumTankName then
    local remainingTanks = {}
    for _, name in ipairs(chemicalTanks) do
        if name ~= deuteriumTankName then table.insert(remainingTanks, name) end
    end
    tritiumTankName = choosePeripheral("Tritium tank", remainingTanks, tritiumDefault)
else
    tritiumTankName = tritiumDefault
end

local energyStorageName, networkEnergyStorageName
if reassign or not energyDefault or energyDefault == networkDefault then
    energyStorageName = choosePeripheral("Energy storage", energyStorages, energyDefault)
else
    energyStorageName = energyDefault
end
if reassign or not networkDefault or networkDefault == energyStorageName then
    local remainingStorages = {}
    for _, name in ipairs(energyStorages) do
        if name ~= energyStorageName then table.insert(remainingStorages, name) end
    end
    networkEnergyStorageName = choosePeripheral(
        "Network storage", remainingStorages, networkDefault
    )
else
    networkEnergyStorageName = networkDefault
end

local modemName
if reassign or not modemDefault then
    modemName = choosePeripheral("Rednet modem", modems, modemDefault)
else
    modemName = modemDefault
end

config.deuteriumTank = deuteriumTankName
config.tritiumTank = tritiumTankName
config.energyStorage = energyStorageName
config.networkEnergyStorage = networkEnergyStorageName
config.modem = modemName
local configFile = fs.open(CONFIG_PATH, "w")
if not configFile then error("Could not save peripheral configuration.") end
configFile.write(textutils.serialize(config))
configFile.close()

local rednetModem = peripheral.wrap(modemName)
if not rednetModem then error("Could not open the selected modem: " .. modemName) end
rednet.open(modemName)

local deuteriumTank = peripheral.wrap(deuteriumTankName)
local tritiumTank = peripheral.wrap(tritiumTankName)
local energyStorage = peripheral.wrap(energyStorageName)
local networkEnergyStorage = peripheral.wrap(networkEnergyStorageName)
print("Rednet modem: " .. modemName)
print("Deuterium: " .. deuteriumTankName .. " | Tritium: " .. tritiumTankName)
print("Energy storage: " .. energyStorageName
    .. " | Network storage: " .. networkEnergyStorageName)

local energy = 10000000000
local cap = 10000000000
local percent = 100
local nenergy = 10000000000
local ncap = 10000000000
local npercent = 100
local plasmaTemp = 1000000000000
local DeuteriumAmt = 1000000000000
local TritiumAmt = 1000000000000
local SleepMode = false
local OverclockMode = false
local AlertMode = false
local alertLocations = {
    one = false,
    two = false,
    three = false,
    four = false,
    five = false
}
local alertLocationNames = {"one", "two", "three", "four", "five"}

local function prettyEnergy(value)
    if value > 1000000000000 then
        return string.format("%.2f", value / 1000000000000) .. " TFE"
    elseif value > 1000000000 then
        return string.format("%.2f", value / 1000000000) .. " GFE"
    elseif value > 1000000 then
        return string.format("%.2f", value / 1000000) .. " MFE"
    elseif value > 1000 then
        return string.format("%.2f", value / 1000) .. " kFE"
    else
        return string.format("%.2f", value) .. " FE"
    end
end

local function prettyTemp(value)
    if value > 1000000000000 then
        return string.format("%.2f", value / 1000000000000) .. " TK"
    elseif value > 1000000000 then
        return string.format("%.2f", value / 1000000000) .. " GK"
    elseif value > 1000000 then
        return string.format("%.2f", value / 1000000) .. " MK"
    elseif value > 1000 then
        return string.format("%.2f", value / 1000) .. " kK"
    else
        return string.format("%.2f", value) .. " K"
    end
end


local init = 0
local function testAlert(location, alternate)
    local active
    local normalColor
    local alternateColor

    if location == 1 then
        active = DeuteriumAmt <= 500000
        normalColor = colors.orange
    elseif location == 2 then
        active = TritiumAmt <= 500000
        normalColor = colors.green
    elseif location == 3 then
        active = percent <= 30
        normalColor = colors.blue
        alternateColor = colors.lightBlue
    elseif location == 4 then
        active = npercent <= 50
        normalColor = colors.blue
        alternateColor = colors.lightBlue
    elseif location == 5 then
        active = plasmaTemp <= 200000000
        normalColor = colors.pink
        alternateColor = colors.cyan
    else
        return nil
    end

    local locationName = alertLocationNames[location]
    alertLocations[locationName] = active

    if active and init ~= 0 then
        return colors.red
    elseif alternate == 1 and alternateColor then
        return alternateColor
    end
    return normalColor
end

local function buildTelemetry()
    return {
        energy = energy,
        netenergy = nenergy,
        netcap = ncap,
        cap = cap,
        percent = percent,
        netpercent = npercent,
        plasmaTemp = plasmaTemp,
        DeuteriumAmt = DeuteriumAmt,
        TritiumAmt = TritiumAmt,
        SleepMode = SleepMode,
        AlertMode = AlertMode,
        OverclockMode = OverclockMode,
        debug = {
            alert = {
                locations = alertLocations
            }
        }
    }
end

local function forceSendRednet()
    rednet.broadcast(buildTelemetry(), REDNET_PROTOCOL)
end

print("Loading Visual And Background Processes")
local function rednetControl()
    while true do
        rednet.broadcast(buildTelemetry(), REDNET_PROTOCOL)
        sleep(0.5)
    end
end

local lineNumber = 0
local function monprint(text, targetMonitor)
    lineNumber = lineNumber + 1
    targetMonitor.setCursorPos(1, lineNumber)
    targetMonitor.write(text)
end

local function findEnergy()
    while true do
        for _, targetMonitor in ipairs(monitors) do
            local width, height = targetMonitor.getSize()
            local separator = string.rep("=", width)
            lineNumber = 0
            targetMonitor.clear()
            targetMonitor.setTextColor(colors.lightGray)
            monprint(separator, targetMonitor)
            targetMonitor.setTextColor(colors.red)
            monprint("Hello Welcome To ZeroFusion", targetMonitor)
            monprint("Server Mode", targetMonitor)
            targetMonitor.setTextColor(colors.lightGray)
            monprint(separator, targetMonitor)
            monprint(separator, targetMonitor)
            targetMonitor.setTextColor(testAlert(3, 0))
            monprint(
                "Power Held Percentage: " .. string.format("%.2f", percent) .. "%",
                targetMonitor
            )
            targetMonitor.setTextColor(testAlert(4, 0))
            monprint(
                "Network Power Percentage: " .. string.format("%.2f", npercent) .. "%",
                targetMonitor
            )
            targetMonitor.setTextColor(colors.lightGray)
            monprint(separator, targetMonitor)
            targetMonitor.setTextColor(testAlert(3, 1))
            monprint("Power Held: " .. prettyEnergy(energy), targetMonitor)
            targetMonitor.setTextColor(testAlert(4, 1))
            monprint("Network Power: " .. prettyEnergy(nenergy), targetMonitor)
            targetMonitor.setTextColor(colors.lightGray)
            monprint(separator, targetMonitor)

            if SleepMode then
                targetMonitor.setTextColor(testAlert(5, 1))
                monprint("Core Temp: " .. prettyTemp(plasmaTemp) .. " (Sleep Mode)", targetMonitor)
            else
                targetMonitor.setTextColor(testAlert(5, 0))
                monprint("Core Temp: " .. prettyTemp(plasmaTemp), targetMonitor)
            end

            targetMonitor.setTextColor(testAlert(1, 0))
            monprint("Deuterium: " .. DeuteriumAmt .. " mB", targetMonitor)
            targetMonitor.setTextColor(testAlert(2, 0))
            monprint("Tritium: " .. TritiumAmt .. " mB", targetMonitor)
            targetMonitor.setTextColor(colors.lightGray)
            monprint(separator, targetMonitor)

            targetMonitor.setTextColor(colors.gray)
            targetMonitor.setCursorPos(1, height)
            targetMonitor.write("Zero Drones Inc.")
        end

        sleep()
    end
end
local function energyLoad()
    reactor.setInjectionRate(60)
    while true do
        energy = energyStorage.getEnergy() / 2.5
        cap = energyStorage.getMaxEnergy() / 2.5
        nenergy = (networkEnergyStorage.getEnergy() / 2.5)
        ncap = (networkEnergyStorage.getMaxEnergy() / 2.5)
        plasmaTemp = reactor.getPlasmaTemperature()
        DeuteriumAmt = reactor.getDeuterium().amount + deuteriumTank.getStored().amount
        TritiumAmt = reactor.getTritium().amount + tritiumTank.getStored().amount
        percent = cap > 0 and energy / cap * 100 or 0
        npercent = ncap > 0 and nenergy / ncap * 100 or 0

        if percent >= 100 and not SleepMode then
            reactor.setInjectionRate(60)
            SleepMode = true
            OverclockMode = false
            print("Sleep Mode Activated Due To Power Full")
        elseif percent <= 90 and SleepMode then
            reactor.setInjectionRate(80)
            SleepMode = false
            print("Sleep Mode Deactivated Due To Power Going Below 90%")
        elseif percent <= 40 and not SleepMode and not OverclockMode then
            reactor.setInjectionRate(100)
            OverclockMode = true
            print("Overclock Mode Activated Due To Power Going Below 40%")
        elseif SleepMode and not OverclockMode
            and reactor.getInjectionRate() ~= 60 then
            reactor.setInjectionRate(60)
        end

        sleep()
    end
end

local function hasAlert()
    return DeuteriumAmt <= 500000
        or TritiumAmt <= 500000
        or percent <= 30
        or npercent <= 50
        or plasmaTemp <= 200000000
end

local function alert()
    local redstoneIntegrators = {peripheral.find("redstoneIntegrator")}
    local alertSent = false

    while true do
        local active = hasAlert()
        AlertMode = active

        for _, redstoneIntegrator in ipairs(redstoneIntegrators) do
            redstoneIntegrator.setOutput("back", active)
        end

        if active and not alertSent then
            if DeuteriumAmt <= 500000 then
                discordHook.send("Deuterium Depleting", "ZeroFusion: Alert")
            end
            if TritiumAmt <= 500000 then
                discordHook.send("Tritium Depleting", "ZeroFusion: Alert")
            end
            if percent <= 30 then
                discordHook.send(
                    "Power In Storage Has Dropped Below 30%",
                    "ZeroFusion: Alert"
                )
            end
            if npercent <= 50 then
                discordHook.send(
                    "Power In Network Has Dropped Below 50%",
                    "ZeroFusion: Alert"
                )
            end
            if plasmaTemp <= 200000000 then
                discordHook.send("Core Heat Below Natural Level", "ZeroFusion: Alert")
            end

            alertSent = true
            forceSendRednet()
        elseif not active then
            alertSent = false
        end

        sleep(0.1)
    end
end

local function alertLoop()
    while true do
        init = init == 0 and 1 or 0
        sleep(0.1)
    end
end

print("Loaded, Launching")
parallel.waitForAll(energyLoad, findEnergy, rednetControl, alert, alertLoop)