
local REDNET_PROTOCOL = "zerofusion"
local rednetModem = peripheral.find("modem")
if not rednetModem then
    error("No modem found for rednet")
end
rednet.open(peripheral.getName(rednetModem))

local monitor = peripheral.find("monitor")
if not monitor then
    error("No monitor found")
end

local energy = 0
local cap = 0
local nenergy = 0
local ncap = 0
local plasmaTemp = 0
local DeuteriumAmt = 0
local TritiumAmt = 0
local SleepMode = false
local AlertMode = false
local connected = false
local OverclockMode = false

local width, height = monitor.getSize()

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
        return string.format("%.2f", value / 1000000000000) .. " Tk"
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

local function receivedata()
    while true do
        local _, message = rednet.receive(REDNET_PROTOCOL, 2)
        if type(message) == "table"
            and type(message.energy) == "number"
            and type(message.cap) == "number"
            and type(message.netenergy) == "number"
            and type(message.netcap) == "number"
            and type(message.plasmaTemp) == "number"
            and type(message.DeuteriumAmt) == "number"
            and type(message.TritiumAmt) == "number" then
            connected = true
            energy = message.energy
            cap = message.cap
            nenergy = message.netenergy
            ncap = message.netcap
            plasmaTemp = message.plasmaTemp
            DeuteriumAmt = message.DeuteriumAmt
            TritiumAmt = message.TritiumAmt
            SleepMode = message.SleepMode
            OverclockMode = message.OverclockMode
            AlertMode = message.AlertMode
        else
            connected = false
        end
    end
end

local lineNumber = 0
local function monprint(text)
    lineNumber = lineNumber + 1
    monitor.setCursorPos(1, lineNumber)
    monitor.write(text)
end

local function percent(value, maximum)
    if maximum <= 0 then
        return 0
    end
    return math.max(0, math.min(1, value / maximum))
end

local function printdata()
    while true do
        width, height = monitor.getSize()
        lineNumber = 0
        monitor.clear()

        monitor.setTextColor(connected and colors.green or colors.red)
        monprint(connected and "Server Online" or "Server Dead")
        monitor.setTextColor(colors.lightGray)
        monprint(string.rep("=", width))

        monitor.setTextColor(colors.blue)
        monprint("Hello Welcome To ZeroFusion")
        monprint("In Store Mode")
        monitor.setTextColor(colors.lightGray)
        monprint(string.rep("=", width))

        local heldPercent = percent(energy, cap)
        local networkPercent = percent(nenergy, ncap)
        monitor.setTextColor(colors.blue)
        monprint("Power Held Percentage:")
        monitor.setTextColor(colors.magenta)
        local barWidth = math.max(0, width - 2)
        monprint(" " .. string.rep("\143", math.floor(barWidth * heldPercent)) .. " ")
        monitor.setTextColor(colors.blue)
        monprint("Network Power Percentage:")
        monitor.setTextColor(colors.magenta)
        monprint(" " .. string.rep("\143", math.floor(barWidth * networkPercent)) .. " ")

        monitor.setTextColor(colors.lightBlue)
        monprint("Power Held: " .. prettyEnergy(energy))
        monprint("Network Power: " .. prettyEnergy(nenergy))
        monitor.setTextColor(colors.lightGray)
        monprint(string.rep("=", width))

        if OverclockMode then
            monitor.setTextColor(colors.pink)
            monprint("Core Temp: " .. prettyTemp(plasmaTemp) .. " (Overclocking)")
        elseif SleepMode then
            monitor.setTextColor(colors.cyan)
            monprint("Core Temp: " .. prettyTemp(plasmaTemp) .. " (Sleep Mode)")
        else
            monitor.setTextColor(colors.pink)
            monprint("Core Temp: " .. prettyTemp(plasmaTemp))
        end

        monitor.setTextColor(colors.orange)
        monprint("Deuterium: " .. DeuteriumAmt .. " mB")
        monitor.setTextColor(colors.green)
        monprint("Tritium: " .. TritiumAmt .. " mB")
        monitor.setTextColor(colors.lightGray)
        monprint(string.rep("=", width))

        monitor.setTextColor(colors.gray)
        monitor.setCursorPos(1, height)
        monitor.write("Zero Drones Inc.")
        sleep(0.1)
    end
end

local function alert()
    local redstoneIntegrator = peripheral.find("redstoneIntegrator")
    while true do
        if redstoneIntegrator then
            redstoneIntegrator.setOutput("back", AlertMode or not connected)
        end
        sleep(0.1)
    end
end

print("Client Loaded")
parallel.waitForAll(receivedata, printdata, alert)