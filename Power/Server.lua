
local REDNET_PROTOCOL = "zerofusion"
local rednetModem = peripheral.find("modem")
if not rednetModem then
    error("No modem found for rednet")
end
rednet.open(peripheral.getName(rednetModem))

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

local energyStorage = peripheral.wrap("back")
local monitors = {peripheral.find("monitor")}
local networkEnergyStorage = peripheral.wrap("ultimateEnergyCube_0")
local reactor = peripheral.find("fusionReactorLogicAdapter")
local deuteriumTank = peripheral.wrap("ultimateChemicalTank_0")
local tritiumTank = peripheral.wrap("ultimateChemicalTank_1")
if not energyStorage or not networkEnergyStorage or not reactor
    or not deuteriumTank or not tritiumTank then
    error("Required power, reactor, or chemical-tank peripheral not found.")
end

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