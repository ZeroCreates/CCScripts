local REDNET_PROTOCOL = "zerofusion"
local rednetModem = peripheral.find("modem")
if not rednetModem then
    error("No modem found for rednet")
end
rednet.open(peripheral.getName(rednetModem))

local energy = 0
local cap = 0
local percent = 0
local nenergy = 0
local ncap = 0
local npercent = 0
local plasmaTemp = 0
local DeuteriumAmt = 0
local TritiumAmt = 0
local SleepMode = false
local AlertMode = false
local connected = false
local OverclockMode = false

local w, h = term.getSize()
local line = 0

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
        if message and message.energy then
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
            percent = cap > 0 and energy / cap or 0
            npercent = ncap > 0 and nenergy / ncap or 0
            AlertMode = message.AlertMode
        else
            connected = false
        end
    end
end

local function writeLine(text, color)
    if color then
        term.setTextColor(color)
    end
    line = line + 1
    term.setCursorPos(1, line)
    term.write(text)
end

local function bar(value)
    local width = math.max(0, w - 4)
    local filled = math.floor(width * math.max(0, math.min(1, value)))
    line = line + 1
    term.setTextColor(colors.magenta)
    term.setCursorPos(2, line)
    term.write("[" .. string.rep("#", filled) .. string.rep("-", width - filled) .. "]")
end

local function printdata()
    while true do
        w, h = term.getSize()
        term.clear()
        line = 0
        writeLine(connected and "Server Online" or "Server Dead",
            connected and colors.green or colors.red)
        writeLine(string.rep("=", w), colors.lightGray)
        writeLine("ZeroFusion - Terminal Mode", colors.blue)
        writeLine(string.rep("=", w), colors.lightGray)
        writeLine(string.format("Power Held: %.2f%%", percent * 100), colors.blue)
        bar(percent)
        writeLine(string.format("Network Power: %.2f%%", npercent * 100), colors.blue)
        bar(npercent)
        writeLine("Power: " .. prettyEnergy(energy), colors.lightBlue)
        writeLine("Network: " .. prettyEnergy(nenergy), colors.lightBlue)
        writeLine(string.rep("=", w), colors.lightGray)

        if OverclockMode then
            writeLine("Core Temp: " .. prettyTemp(plasmaTemp) .. " (Overclocking)", colors.pink)
        elseif SleepMode then
            writeLine("Core Temp: " .. prettyTemp(plasmaTemp) .. " (Sleep Mode)", colors.cyan)
        else
            writeLine("Core Temp: " .. prettyTemp(plasmaTemp), colors.pink)
        end

        writeLine("Deuterium: " .. DeuteriumAmt .. " mB", colors.orange)
        writeLine("Tritium: " .. TritiumAmt .. " mB", colors.green)
        writeLine(string.rep("=", w), colors.lightGray)

        term.setTextColor(colors.gray)
        term.setCursorPos(1, h)
        term.write("Zero Drones Inc.")
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
