
local REDNET_PROTOCOL = "zerofusion"
local rednetModem = peripheral.find("modem")
if not rednetModem then
    error("No modem found for rednet")
end
rednet.open(peripheral.getName(rednetModem))

local monitor = peripheral.find("monitor")
local energy = 0
local cap = 0
local percent =0
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

local w,h = monitor.getSize()
local function prettyEnergy(energy)
    if energy > 1000000000000 then
        return string.format("%.2f", energy/1000000000000).." TFE"
    elseif energy > 1000000000 then
        return string.format("%.2f", energy/1000000000).." GFE"
    elseif energy > 1000000 then
        return string.format("%.2f", energy/1000000).." MFE"
    elseif energy > 1000 then
        return string.format("%.2f", energy/1000).." kFE"
    else
        return string.format("%.2f", energy).." FE"
    end
end
local function prettyTemp(energy)
    if energy > 1000000000000 then
        return string.format("%.2f", energy/1000000000000).." Tk"
    elseif energy > 1000000000 then
        return string.format("%.2f", energy/1000000000).." GK"
    elseif energy > 1000000 then
        return string.format("%.2f", energy/1000000).." MK"
    elseif energy > 1000 then
        return string.format("%.2f", energy/1000).." kK"
    else
        return string.format("%.2f", energy).." K"
    end
end

function receivedata()
	while true do
        local _, message = rednet.receive(REDNET_PROTOCOL, 2)
        if message and message.energy then
            connected = true
            energy = message.energy
            cap = message.cap
            percent =message.percent
            nenergy = message.netenergy
            ncap = message.netcap
            npercent = message.netpercent
            plasmaTemp = message.plasmaTemp
            DeuteriumAmt = message.DeuteriumAmt
            TritiumAmt = message.TritiumAmt
            SleepMode = message.SleepMode
            OverclockMode = message.OverclockMode
		    local per = energy/cap
		    percent =  per
		    local nper = nenergy/ncap
		    npercent =  nper
            AlertMode = message.AlertMode
        else
		    connected = false
        end
    end
end
local linenu = 0
local function monprint(text)

    linenu = linenu + 1
    monitor.setCursorPos(1,linenu)
    monitor.write(text)
end
local function printdata()
    while true do
            linenu = 0
            monitor.clear()
            if (connected) then
                monitor.setTextColor(colors.green)
                monprint("Server Online")
            else
                monitor.setTextColor(colors.red)
                monprint("Server Dead")
            end
            monitor.setTextColor(colors.green)
		    monitor.setTextColor(colors.lightGray)
            monprint("===========================================================================") 
		    monitor.setTextColor(colors.blue)
            monprint("Hello Welcome To ZeroFusion")
            monprint("In Store Mode")
		    monitor.setTextColor(colors.lightGray)
            monprint("===========================================================================") 
            monprint("===========================================================================")
		    monitor.setTextColor(colors.blue)
            monprint("Power Held Percentage : ")
		    monitor.setTextColor(colors.magenta)
            monprint(" "..string.rep("\143",(w-2)*percent).." ")
            
		    monitor.setTextColor(colors.blue)
            monprint("Network Power Percentage :")
		    monitor.setTextColor(colors.magenta)
            monprint(" "..string.rep("\143",(w-2)*npercent).." ")
            monitor.setTextColor(colors.lightBlue)
            monprint("Power Held : "..prettyEnergy(energy).."")

            monprint("Network Power : "..prettyEnergy(nenergy).."")

		    monitor.setTextColor(colors.lightGray)
            monprint("===========================================================================")
			if OverclockMode == true then
                monitor.setTextColor(colors.pink)
				monprint("Core Temp : "..prettyTemp(plasmaTemp).."(OverClocking)")
            elseif SleepMode == false then
                monitor.setTextColor(colors.pink)
				monprint("Core Temp : "..prettyTemp(plasmaTemp).."")
            else
                monitor.setTextColor(colors.cyan)
				monprint("IN SLEEP MODE CORE HEAT REDUSED")
			end
		    monitor.setTextColor(colors.orange)
			monprint("Deuterium : "..DeuteriumAmt.."mB")
		    monitor.setTextColor(colors.green)
			monprint("Tritium : "..TritiumAmt.."mB")
		    monitor.setTextColor(colors.lightGray)
            monprint("===========================================================================")
		    monitor.setTextColor(colors.gray)
            monitor.setCursorPos(1,h)
            monitor.write("Zero Drones Inc.")
            sleep(.1)
    end
end
function alert()
    local ri = peripheral.find("redstoneIntegrator")
    while true do
        if AlertMode == true or connected == false then
            if ri then
                ri.setOutput("back",true)
            end
        else
            if ri then
                ri.setOutput("back",false)
            end
        end
        sleep(.1)
    end
end
print("Client Loaded")
parallel.waitForAll(receivedata,printdata,alert)