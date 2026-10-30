
-- =====================================================
-- NEXUS TARDIS OS - TOUCH EDITION
-- The Time Vortex 1.2.0-beta
-- Minecraft 1.21.1 / CC:Tweaked
-- =====================================================

local tardis = peripheral.find("tardis_console")
local monitor = peripheral.find("monitor")

local permissions = {
    SkylerNexus = true,
    Quinnexe = true,
    IRONSOLDIER123 = true
}

if not tardis then
    error("TARDIS CONSOLE NOT FOUND")
end

if not monitor then
    error("MONITOR NOT FOUND")
end

monitor.setTextScale(0.5)

local C = colors
local width, height = monitor.getSize()

local page = "home"
local buttons = {}
local deleteMode = false
local placeToDelete

local course = {}
local selected = "x"
local destination = {
    x = 0, y = 65, z = 0,
    dimension = "minecraft:overworld",
    land = true,
    facing = 0
}

local dimensions = {
    "minecraft:overworld",
    "minecraft:the_nether",
    "minecraft:the_end"
}

local dimensionIndex = 1

local message = "SYSTEM READY"
local messageColor = C.lime

local playerDetector = peripheral.find("player_detector")

local function call(method, ...)
    if type(tardis[method]) ~= "function" then
        return nil, "METHOD UNAVAILABLE"
    end

    local ok, result = pcall(tardis[method], ...)

    if not ok then
        return nil, tostring(result)
    end

    return result
end

local function notify(text, color)
    message = tostring(text)
    messageColor = color or C.lime
end

local function center(y, text, color)
    text = tostring(text)
    local x = math.max(1, math.floor((width - #text) / 2) + 1)

    monitor.setCursorPos(x, y)
    monitor.setTextColor(color or C.white)
    monitor.write(text)
end

local function text(x, y, value, color)
    monitor.setCursorPos(x, y)
    monitor.setTextColor(color or C.white)
    monitor.write(tostring(value))
end

local function clear()
    monitor.setBackgroundColor(C.black)
    monitor.setTextColor(C.white)
    monitor.clear()
    width, height = monitor.getSize()
    buttons = {}
end

local function button(x, y, buttonWidth, label, id, color)
    if y < 1 or y > height or x > width then
        return
    end

    buttonWidth = math.max(0, math.min(buttonWidth, width - x + 1))
    if buttonWidth == 0 then
        return
    end

    color = color or C.blue

    monitor.setBackgroundColor(color)
    monitor.setTextColor(C.white)
    monitor.setCursorPos(x, y)

    local content = " " .. label .. " "
    content = content:sub(1, buttonWidth)

    monitor.write(content .. string.rep(" ", math.max(0, buttonWidth - #content)))

    buttons[#buttons + 1] = {
        x = x,
        y = y,
        width = buttonWidth,
        height = 1,
        id = id
    }

    monitor.setBackgroundColor(C.black)
end

local function header(title)
    clear()

    center(1, "N E X U S   T A R D I S   O S", C.cyan)
    center(2, title, C.lightBlue)

    monitor.setTextColor(C.gray)
    monitor.setCursorPos(1, 3)
    monitor.write(string.rep("-", width))
end

local function footer()
    monitor.setCursorPos(2, height)
    monitor.setTextColor(messageColor)
    monitor.write(message:sub(1, width - 2))
end

local function getCourse()
    local result = call("getCourse")
    if type(result) == "table" then
        course = result
    end
    return course
end

local function drawHome()
    header("TARDIS SYSTEMS")

    local s = call("getStatus")

    if type(s) ~= "table" then
        text(2, 5, "STATUS DATA UNAVAILABLE", C.red)
        footer()
        return
    end

    local function percent(value, maximum)
        value = tonumber(value)
        maximum = tonumber(maximum)

        if not value or not maximum or maximum <= 0 then
            return 0
        end

        return math.max(0, math.min(100, math.floor(value / maximum * 100)))
    end

    local function meter(x, y, meterWidth, value, maximum, color)
        local pct = percent(value, maximum)
        local filled = math.floor(meterWidth * pct / 100)

        monitor.setCursorPos(x, y)
        monitor.setTextColor(C.gray)
        monitor.write("[")

        monitor.setTextColor(color)
        monitor.write(string.rep("#", filled))

        monitor.setTextColor(C.gray)
        monitor.write(string.rep("-", meterWidth - filled))
        monitor.write("] " .. pct .. "%")
    end

    -- Owner and state
    text(2, 4, "OWNER: " .. tostring(s.owner), C.cyan)
    text(2, 5, "STATE: " .. tostring(s.state),
        s.state == "parked" and C.lime or C.yellow)

    -- Coordinates
    text(2, 7, "LOCATION", C.cyan)
    text(2, 8, "X: " .. tostring(s.x))
    text(2, 9, "Y: " .. tostring(s.y))
    text(2, 10, "Z: " .. tostring(s.z))

    text(2, 11, "DIM: " .. tostring(s.dimension))

    -- Flight
    text(2, 13, "FLIGHT SYSTEMS", C.cyan)
    text(2, 14, "Heading: " .. tostring(s.heading) .. " deg")
    text(2, 15, "Throttle: " .. tostring(s.throttle))
    text(2, 16, "Can Fly: " .. tostring(s.canFly))

    -- Fuel and hull
    text(2, 18, "ARTRON FUEL", C.cyan)
    text(2, 19, tostring(s.fuel) .. " / " ..
        tostring(s.capacity))

    meter(2, 20, 18, s.fuel, s.capacity, C.lime)

    text(2, 22, "HULL INTEGRITY", C.cyan)

    text(2, 23, tostring(s.hull) .. " / " ..
        tostring(s.hullMax))

    local hullPct = percent(s.hull, s.hullMax)
    local hullColor = hullPct <= 25 and C.red or
        hullPct <= 50 and C.orange or C.lime

    meter(2, 24, 18, s.hull, s.hullMax, hullColor)

    -- Navigation
    button(2, 26, 12, "NAVIGATION", "nav", C.blue)
    button(16, 26, 12, "FLIGHT", "flight", C.blue)
    button(30, 26, 12, "MEMORY", "memory", C.purple)

    if height >= 29 then
        button(2, 28, 12, "SCANNER", "scanner", C.purple)
        button(16, 28, 12, "SYSTEMS", "diagnostics", C.gray)
        button(30, 28, 12, "REFRESH", "refresh", C.green)
    end

    footer()
end


local function drawNavigation()
    header("NAVIGATION COMPUTER")

    local c = getCourse()

    text(2, 4, "CURRENT COURSE", C.cyan)
    text(2, 5, "X: " .. tostring(c.x or "?"))
    text(2, 6, "Y: " .. tostring(c.y or "?"))
    text(2, 7, "Z: " .. tostring(c.z or "?"))

    text(2, 9, "PROGRAM DESTINATION", C.lightBlue)

    local fields = {
        {"X", destination.x, 2},
        {"Y", destination.y, 14},
        {"Z", destination.z, 26}
    }

    for _, field in ipairs(fields) do
        local label, value, x = table.unpack(field)
        local color = selected == string.lower(label) and C.yellow or C.white

        button(x, 10, 10, label .. ": " .. value,
            "select_" .. string.lower(label), color)

        button(x, 11, 4, "-10", "dec10_" .. string.lower(label), C.red)
        button(x + 4, 11, 3, "-1", "dec1_" .. string.lower(label), C.red)
        button(x + 7, 11, 3, "+1", "inc1_" .. string.lower(label), C.green)
    end

    text(2, 13, "DIMENSION: " .. destination.dimension, C.cyan)

    button(2, 14, 10, "NEXT DIM", "dimension", C.purple)
    button(14, 14, 12,
        "LAND: " .. tostring(destination.land),
        "land", C.blue)

    button(28, 14, 10,
        "DIR: " .. destination.facing,
        "direction", C.purple)

    button(2, 16, 15, "SET COURSE", "setcourse", C.green)
    button(20, 16, 15, "RANDOMIZE", "random", C.purple)

    button(2, 18, 12, "MAIN MENU", "home", C.gray)

    footer()
end

local function drawFlight()
    header("FLIGHT CONTROL")
    local event = call("getFlightEvent")

    text(2, 5, "FLIGHT SYSTEM", C.cyan)
    text(2, 8, "Event: " .. tostring(event or "NONE"))

    button(2, 11, 18, "LIFT OFF", "liftoff", C.green)
    button(23, 11, 18, "DEMATERIALIZE", "demat", C.purple)

    button(2, 13, 18, "CANCEL DEMAT", "cancel", C.red)
    button(23, 13, 18, "STOP", "stop", C.red)

    button(2, 15, 18, "FAST RETURN", "return", C.blue)
    button(23, 15, 18, "PARK", "park", C.gray)

    button(2, 17, 18, "UNPARK", "unpark", C.blue)
    button(23, 17, 18, "MAIN MENU", "home", C.gray)

    footer()
end

local function drawMemory()
    header("TARDIS MEMORY BANK")

    local places = call("getPlaces")

    text(2, 5, "SAVED DESTINATIONS", C.cyan)
    text(
        2,
        6,
        deleteMode and "Select a destination to delete."
            or "Select a destination to travel there.",
        deleteMode and C.orange or C.white
    )

    if type(places) == "table" then
        local savedPlaces = {}

        for id, place in pairs(places) do
            if type(place) == "table" and type(place.name) == "string" then
                savedPlaces[#savedPlaces + 1] = {
                    id = id,
                    name = place.name
                }
            end
        end

        table.sort(savedPlaces, function(a, b)
            return a.name < b.name
        end)

        local y = 7
        for _, place in ipairs(savedPlaces) do
            if y >= height - 5 then
                break
            end

            button(
                2,
                y,
                math.min(22, width - 4),
                place.name:sub(1, 20),
                "place_" .. place.id,
                deleteMode and C.red or C.blue
            )
            y = y + 2
        end

        if #savedPlaces == 0 then
            text(2, 7, "No saved destinations.", C.orange)
        end
    else
        text(2, 7, "Unable to read Memory Bank.", C.orange)
    end

    if not deleteMode then
        button(2, height - 4, 16, "SAVE CURRENT", "save", C.green)
    end
    button(
        20,
        height - 4,
        18,
        deleteMode and "CANCEL DELETE" or "DELETE PLACE",
        deleteMode and "cancel_delete" or "delete",
        C.red
    )
    button(2, height - 2, 16, "MAIN MENU", "home", C.gray)

    footer()
end

local function drawDeleteConfirmation()
    header("CONFIRM DELETION")

    center(6, "Delete this saved destination?", C.orange)
    center(8, placeToDelete.name, C.white)

    button(5, 11, 16, "YES, DELETE", "confirm_delete", C.red)
    button(25, 11, 16, "CANCEL", "cancel_delete_confirmation", C.gray)

    footer()
end

local function drawScanner()
    header("EXTERIOR SCANNER")

    local scan = call("getScan")

    text(2, 5, "LAST SCAN RESULTS", C.cyan)

    if type(scan) == "table" then
        local y = 7
        for key, value in pairs(scan) do
            if y < height - 4 then
                if key == "finds" and type(value) == "table" then
                    for _, find in ipairs(value) do
                        if y < height - 4 then
                            if type(find) == "table" then
                                text(
                                    2,
                                    y,
                                    "Find: " .. tostring(find.kind) .. " "
                                        .. tostring(find.name) .. " at "
                                        .. tostring(find.x) .. ", "
                                        .. tostring(find.y) .. ", "
                                        .. tostring(find.z)
                                )
                            else
                                text(2, y, "Find: " .. tostring(find))
                            end
                            y = y + 1
                        else
                            break
                        end
                    end
                else
                    text(2, y, tostring(key) .. ": " .. tostring(value))
                    y = y + 1
                end
            end
        end
    else
        text(2, 7, "No scan data available.", C.orange)
    end

    button(2, height - 4, 16, "START SCAN", "scan", C.purple)
    button(2, height - 2, 16, "MAIN MENU", "home", C.gray)

    footer()
end

local function drawDiagnostics()
    header("SYSTEM DIAGNOSTICS")

    local methods = peripheral.getMethods(
        peripheral.getName(tardis)
    )

    table.sort(methods)

    local y = 5
    for _, method in ipairs(methods) do
        if y >= height - 2 then break end
        text(2, y, method, C.lightBlue)
        y = y + 1
    end

    button(2, height - 1, 16, "MAIN MENU", "home", C.gray)
end

local function draw()
    if page == "home" then
        drawHome()
    elseif page == "nav" then
        drawNavigation()
    elseif page == "flight" then
        drawFlight()
    elseif page == "memory" then
        drawMemory()
    elseif page == "confirm_delete" then
        drawDeleteConfirmation()
    elseif page == "scanner" then
        drawScanner()
    elseif page == "diagnostics" then
        drawDiagnostics()
    end
end

local function askName(prompt)
    -- Keyboard entry through the attached computer.
    term.redirect(term.native())
    term.setBackgroundColor(C.black)
    term.setTextColor(C.white)
    term.clear()
    term.setCursorPos(1, 1)
    print(prompt)
    local name = read()
    term.redirect(monitor)
    return name
end

local function runCommand(method, successMessage, ...)
    local _, err = call(method, ...)
    notify(err or successMessage, err and C.red or C.lime)
    return err == nil
end

local pageByButton = {
    home = "home",
    nav = "nav",
    flight = "flight",
    memory = "memory",
    scanner = "scanner",
    diagnostics = "diagnostics"
}

local function execute(id)
    if pageByButton[id] then
        page = pageByButton[id]
        if page ~= "memory" then
            deleteMode = false
            placeToDelete = nil
        end

    elseif id == "refresh" then
        notify("SYSTEM REFRESHED")

    elseif id:match("^select_") then
        selected = id:sub(8)

    elseif id:match("^inc1_") then
        local axis = id:sub(6)
        destination[axis] = destination[axis] + 1

    elseif id:match("^dec1_") then
        local axis = id:sub(6)
        destination[axis] = destination[axis] - 1

    elseif id:match("^dec10_") then
        local axis = id:sub(7)
        destination[axis] = destination[axis] - 10

    elseif id == "dimension" then
        dimensionIndex = dimensionIndex % #dimensions + 1
        destination.dimension = dimensions[dimensionIndex]

    elseif id == "land" then
        destination.land = not destination.land

    elseif id == "direction" then
        destination.facing = (destination.facing + 90) % 360

    elseif id == "setcourse" then
        runCommand(
            "setCourse",
            "COURSE PROGRAMMED",
            destination.x,
            destination.y,
            destination.z,
            destination.dimension,
            destination.land,
            destination.facing
        )

    elseif id == "random" then
        runCommand("randomise", "DESTINATION RANDOMIZED")

    elseif id == "liftoff" then
        runCommand("liftOff", "LIFT OFF COMMAND SENT")

    elseif id == "demat" then
        runCommand("demat", "DEMATERIALIZATION COMMAND SENT")

    elseif id == "cancel" then
        runCommand("cancelDemat", "CANCEL COMMAND SENT")

    elseif id == "stop" then
        runCommand("stop", "STOP COMMAND SENT")

    elseif id == "return" then
        runCommand("fastReturn", "RETURN COMMAND SENT")

    elseif id == "park" then
        runCommand("park", "PARK COMMAND SENT")

    elseif id == "unpark" then
        runCommand("unpark", "UNPARK COMMAND SENT")

    elseif id == "scan" then
        runCommand("scan", "SCANNER ACTIVATED")

    elseif id == "save" then
        local name = askName("Enter destination name:")
        if name ~= "" then
            local _, err = call("savePlace", name)
            notify(err or "PLACE SAVED", err and C.red or C.lime)
        end

    elseif id == "delete" then
        deleteMode = true
        placeToDelete = nil
        notify("SELECT A DESTINATION TO DELETE", C.orange)

    elseif id == "cancel_delete" then
        deleteMode = false
        placeToDelete = nil
        page = "memory"
        notify("DELETE MODE CANCELLED", C.white)

    elseif id == "confirm_delete" and placeToDelete then
        local _, err = call("deletePlace", placeToDelete.id)
        notify(err or "PLACE DELETED", err and C.red or C.lime)
        if not err then
            deleteMode = false
        end
        placeToDelete = nil
        page = "memory"

    elseif id == "cancel_delete_confirmation" then
        placeToDelete = nil
        page = "memory"
        notify("PLACE NOT DELETED", C.white)

    elseif id:match("^place_") then
        local placeKey = id:sub(7)
        local placeId = tonumber(placeKey) or placeKey
        if deleteMode then
            placeToDelete = {
                id = placeId,
                name = placeKey
            }
            local places = call("getPlaces")
            if type(places) == "table" then
                local place = places[placeId] or places[placeKey]
                if type(place) == "table" then
                    placeToDelete.name = place.name or placeKey
                end
            end
            page = "confirm_delete"
        elseif placeId ~= "" then
            local _, err = call("goPlace", placeId)
            notify(err or ("DESTINATION SELECTED: " .. placeId),
                err and C.red or C.lime)
        else
            notify("INVALID DESTINATION ID", C.red)
        end
    end
end

local function main()
    while true do
        draw()

        local event, _, x, y = os.pullEvent()

        if event == "monitor_touch" then
            for _, b in ipairs(buttons) do
                if x >= b.x and x < b.x + b.width
                    and y >= b.y and y < b.y + b.height then

                    execute(b.id)
                    break
                end
            end
        end
    end
end

local function chatHandler()
    while true do
        local _, _, username, chatMessage = os.pullEvent("chat")
        if permissions[username] then
            local command = string.lower(chatMessage)
            if command == "tardis come" then
                if not playerDetector then
                    notify("PLAYER DETECTOR NOT FOUND", C.red)
                else
                    local player = playerDetector.getPlayer(username, true)
                    if type(player) ~= "table" then
                        notify("PLAYER NOT FOUND", C.red)
                    elseif type(player.dimension) ~= "string" then
                        notify("PLAYER LOCATION UNAVAILABLE", C.red)
                    elseif not string.find(
                        player.dimension,
                        "timevortex",
                        1,
                        true
                    ) then
                        if runCommand(
                            "setCourse",
                            "COURSE PROGRAMMED",
                            player.x,
                            player.y,
                            player.z,
                            player.dimension,
                            true,
                            player.pitch
                        ) then
                            runCommand("demat", "DEMATERIALIZATION COMMAND SENT")
                        end
                    end
                end
            elseif command == "tardis go home" then
                if runCommand(
                    "setCourse",
                    "COURSE PROGRAMMED",
                    -601,
                    65,
                    -229,
                    "minecraft:overworld",
                    true,
                    180
                ) then
                    runCommand("demat", "DEMATERIALIZATION COMMAND SENT")
                end
            end
        end
    end
end
parallel.waitForAny(chatHandler, main)
monitor.setBackgroundColor(C.black)
monitor.clear()
term.redirect(term.native())
term.clear()
term.setCursorPos(1, 1)
print("NEXUS TARDIS OS OFFLINE")
