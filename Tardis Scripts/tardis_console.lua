
-- ==========================================
-- NEXUS TARDIS CONTROL SYSTEM
-- Mouse-controlled terminal interface
-- CC:Tweaked / The Time Vortex
-- ==========================================

local tardis = peripheral.find("tardis_console")

if not tardis then
    print("ERROR: TARDIS console not found!")
    return
end

local buttons = {}
local page = "home"
local running = true
local selectedAxis = "x"
local destination = {
    x = 0,
    y = 65,
    z = 0,
    dimension = "minecraft:overworld",
    land = true,
    direction = 0
}
local dimensions = {
    "minecraft:overworld",
    "minecraft:the_nether",
    "minecraft:the_end"
}
local message = "SYSTEM READY"
local placeToDelete
local savePlaceId = 1
local deleteMode = false

term.setCursorBlink(false)

local width, height = term.getSize()

-- ==========================================
-- PERIPHERAL FUNCTIONS
-- ==========================================

local function call(method, ...)
    if not tardis[method] then
        return nil, "Unknown method: " .. method
    end

    local ok, result = pcall(tardis[method], ...)

    if not ok then
        return nil, tostring(result)
    end

    return result
end

local function status()
    local result, err = call("getStatus")

    if type(result) ~= "table" then
        return nil, err or "Invalid status response"
    end

    return result
end

-- ==========================================
-- TERMINAL DRAWING
-- ==========================================

local function clear()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    buttons = {}
end

local function center(y, text)
    local x = math.max(1, math.floor((width - #text) / 2) + 1)
    term.setCursorPos(x, y)
    term.write(text)
end

local function line(y)
    term.setCursorPos(1, y)
    term.setTextColor(colors.gray)
    term.write(string.rep("-", width))
    term.setTextColor(colors.white)
end

local function button(x, y, w, label, id, action, color)
    if y < 1 or y > height or x > width then
        return
    end

    w = math.max(0, math.min(w, width - x + 1))
    if w == 0 then
        return
    end

    local text = " " .. label .. " "
    text = text:sub(1, w)

    term.setCursorPos(x, y)
    term.setBackgroundColor(color or colors.blue)
    term.setTextColor(colors.white)
    term.write(text .. string.rep(" ", math.max(0, w - #text)))

    buttons[#buttons + 1] = {
        x1 = x,
        x2 = x + w - 1,
        y1 = y,
        y2 = y,
        id = id,
        action = action
    }

    term.setBackgroundColor(colors.black)
end

local function addButton(y, label, id, action, column)
    local gap = 2
    local w = math.floor((width - gap - 2) / 2)
    local x = column == 2 and (w + gap + 1) or 2

    button(x, y, w, label, id, action)
end

local function header(title)
    clear()
    center(1, "NEXUS TARDIS // " .. title)
    line(2)
end

local function footer()
    if height < 1 then
        return
    end

    term.setCursorPos(1, height)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.write(string.rep(" ", width))
    term.setCursorPos(2, height)
    term.setTextColor(colors.lime)
    term.write(message:sub(1, math.max(0, width - 2)))
    term.setTextColor(colors.white)
end

local function printAt(x, y, text, color)
    if y > height then return end
    term.setCursorPos(x, y)
    term.setTextColor(color or colors.white)
    term.write(tostring(text):sub(1, math.max(0, width - x + 1)))
    term.setTextColor(colors.white)
end

-- ==========================================
-- STATUS DISPLAY
-- ==========================================

local function displayStatus(startY, compact)
    local s, err = status()

    if not s then
        printAt(2, startY, "STATUS ERROR: " .. tostring(err), colors.red)
        return
    end

    local lines = {
        {"OWNER", s.owner},
        {"STATE", s.state},
        {"POSITION", tostring(s.x) .. ", " .. tostring(s.y) .. ", " .. tostring(s.z)},
        {"DIMENSION", s.dimension},
        {"HEADING", s.heading},
        {"THROTTLE", s.throttle},
        {"FUEL", tostring(s.fuel) .. " / " .. tostring(s.capacity)},
        {"HULL", tostring(s.hull) .. " / " .. tostring(s.hullMax)}
    }

    if not compact then
        lines[#lines + 1] = {"CAN FLY", s.canFly}
        lines[#lines + 1] = {"SIZE", s.size}
        lines[#lines + 1] = {"PRECISION", s.precision}
    end

    for i, entry in ipairs(lines) do
        local color = colors.white

        if entry[1] == "HULL" and tonumber(s.hull) and tonumber(s.hullMax) then
            if s.hull / s.hullMax < 0.25 then
                color = colors.red
            elseif s.hull / s.hullMax < 0.5 then
                color = colors.orange
            end
        end

        printAt(2, startY + i - 1,
            entry[1] .. ": " .. tostring(entry[2]), color)
    end
end

local function notify(messageText)
    message = tostring(messageText)
end

local function execute(method, ...)
    local result, err = call(method, ...)
    notify(err or "Command executed.")
end

-- ==========================================
-- HOME
-- ==========================================

local function drawHome()
    header("MAIN SYSTEM")

    displayStatus(3, true)

    line(12)

    addButton(14, "NAVIGATION", "navigation", function()
        page = "navigation"
    end, 1)

    addButton(14, "FLIGHT CONTROLS", "flight", function()
        page = "flight"
    end, 2)

    addButton(16, "MEMORY SYSTEM", "memory", function()
        page = "memory"
    end, 1)

    addButton(16, "SCANNER", "scanner", function()
        page = "scanner"
    end, 2)

    addButton(18, "DIAGNOSTICS", "diagnostics", function()
        page = "diagnostics"
    end, 1)

    addButton(18, "SHUTDOWN", "shutdown", function()
        running = false
    end, 2)

    footer()
end

-- ==========================================
-- NAVIGATION
-- ==========================================

local function drawNavigation()
    header("NAVIGATION")

    local course = call("getCourse")

    if type(course) == "table" then
        printAt(2, 4, "DESTINATION")
        printAt(2, 5, "X: " .. tostring(course.x))
        printAt(2, 6, "Y: " .. tostring(course.y))
        printAt(2, 7, "Z: " .. tostring(course.z))
        printAt(2, 8, "DIM: " .. tostring(course.dimension))
        printAt(2, 9, "LAND: " .. tostring(course.land))
        printAt(2, 10, "FACING: " .. tostring(course.facing))
    else
        printAt(2, 4, "No course information available.")
    end

    line(12)

    addButton(14, "SET DESTINATION", "destination", function()
        page = "destination"
    end, 1)

    addButton(14, "CURRENT POSITION", "position", function()
        page = "position"
    end, 2)

    addButton(18, "BACK", "back", function()
        page = "home"
    end, 1)

    footer()
end

local function drawDestination()
    header("SET DESTINATION")

    printAt(2, 4, "SELECT AN AXIS, THEN ADJUST IT")
    printAt(2, 6, "X: " .. tostring(destination.x), colors.white)
    printAt(2, 7, "Y: " .. tostring(destination.y), colors.white)
    printAt(2, 8, "Z: " .. tostring(destination.z), colors.white)

    button(2, 10, 8, "X", "axis_x", function()
        selectedAxis = "x"
    end,
        selectedAxis == "x" and colors.green or colors.blue)
    button(13, 10, 8, "Y", "axis_y", function()
        selectedAxis = "y"
    end,
        selectedAxis == "y" and colors.green or colors.blue)
    button(24, 10, 8, "Z", "axis_z", function()
        selectedAxis = "z"
    end,
        selectedAxis == "z" and colors.green or colors.blue)

    local steps = {
        {-100, "-100"},
        {-10, "-10"},
        {-1, "-1"},
        {1, "+1"},
        {10, "+10"},
        {100, "+100"}
    }

    for index, step in ipairs(steps) do
        local x = 2 + (index - 1) * 8
        local amount = step[1]
        button(x, 12, 7, step[2], "adjust_" .. step[1], function()
            destination[selectedAxis] = destination[selectedAxis] + amount
        end)
    end

    button(2, 14, math.min(30, width - 3),
        "DIM: " .. destination.dimension, "next_dimension", function()
            for index, dimension in ipairs(dimensions) do
                if dimension == destination.dimension then
                    destination.dimension =
                        dimensions[index % #dimensions + 1]
                    return
                end
            end
            destination.dimension = dimensions[1]
        end)
    button(2, 16, 18,
        "LAND: " .. tostring(destination.land), "toggle_land", function()
            destination.land = not destination.land
        end)
    button(22, 16, 18,
        "DIR: " .. tostring(destination.direction), "next_direction",
        function()
            destination.direction = (destination.direction + 90) % 360
        end)

    addButton(19, "SET COURSE", "apply_destination", function()
        execute(
            "setCourse",
            destination.x,
            destination.y,
            destination.z,
            destination.dimension,
            destination.land,
            destination.direction
        )
    end, 1)
    addButton(19, "BACK", "navigation", function()
        page = "navigation"
    end, 2)

    footer()
end

local function drawPosition()
    header("CURRENT POSITION")
    displayStatus(4, false)

    addButton(18, "BACK", "navigation", function()
        page = "navigation"
    end, 1)

    footer()
end

-- ==========================================
-- FLIGHT CONTROLS
-- ==========================================

local function drawFlight()
    header("FLIGHT CONTROL")

    displayStatus(3, true)

    line(12)

    addButton(14, "LIFT OFF", "liftoff", function()
        execute("liftOff")
    end, 1)

    addButton(14, "DEMATERIALIZE", "demat", function()
        execute("demat")
    end, 2)

    addButton(16, "CANCEL DEMAT", "cancel", function()
        execute("cancelDemat")
    end, 1)

    addButton(16, "STOP", "stop", function()
        execute("stop")
    end, 2)

    addButton(18, "FAST RETURN", "return", function()
        execute("fastReturn")
    end, 1)

    addButton(18, "PARK", "park", function()
        execute("park")
    end, 2)

    addButton(20, "UNPARK", "unpark", function()
        execute("unpark")
    end, 1)

    addButton(20, "BACK", "back", function()
        page = "home"
    end, 2)

    footer()
end

-- ==========================================
-- MEMORY SYSTEM
-- ==========================================

local function drawMemory()
    header("MEMORY SYSTEM")

    local places, err = call("getPlaces")

    printAt(2, 4, "SAVED LOCATIONS")
    printAt(
        2,
        5,
        deleteMode and "Select a location to delete."
            or "Select a location to travel there.",
        deleteMode and colors.orange or colors.white
    )

    if type(places) == "table" then
        local savedPlaces = {}
        for id, value in pairs(places) do
            if type(value) == "table" and type(value.name) == "string" then
                savedPlaces[#savedPlaces + 1] = {
                    id = id,
                    name = value.name
                }
            end
        end

        table.sort(savedPlaces, function(a, b)
            return a.name < b.name
        end)

        if #savedPlaces == 0 then
            printAt(2, 7, "No saved locations.")
        else
            local y = 7
            for _, place in ipairs(savedPlaces) do
                if y >= height - 5 then
                    break
                end

                local selectedPlace = place
                button(2, y, width - 3, selectedPlace.name, "place", function()
                    local placeId = tonumber(selectedPlace.id) or selectedPlace.id
                    if deleteMode then
                        placeToDelete = {
                            id = placeId,
                            name = selectedPlace.name
                        }
                        page = "confirm_delete"
                    else
                        local _, commandError = call("goPlace", placeId)
                        notify(commandError or ("Going to " .. selectedPlace.name))
                    end
                end, deleteMode and colors.red or colors.blue)
                y = y + 1
            end
        end
    else
        printAt(2, 7, "Unable to load locations.")
        printAt(2, 8, tostring(err))
    end

    if not deleteMode then
        addButton(height - 4, "SAVE LOCATION", "save", function()
            local currentPlaces, placesError = call("getPlaces")
            if type(currentPlaces) ~= "table" then
                notify(placesError or "Unable to load locations.")
                return
            end

            savePlaceId = 1
            while currentPlaces[savePlaceId]
                or currentPlaces[tostring(savePlaceId)] do
                savePlaceId = savePlaceId + 1
            end
            page = "save_place"
        end, 1)
    end

    addButton(height - 4, deleteMode and "CANCEL DELETE" or "DELETE LOCATION",
        "toggle_delete", function()
            deleteMode = not deleteMode
            placeToDelete = nil
            notify(deleteMode and "Select a location to delete."
                or "Delete mode cancelled.")
        end, 2)

    addButton(height - 2, "BACK", "back", function()
        deleteMode = false
        placeToDelete = nil
        page = "home"
    end, 1)

    footer()
end

local function drawSavePlace()
    header("SAVE LOCATION")
    printAt(2, 5, "Select a location ID to save.")
    savePlaceId = read()
    printAt(2, 7, "LOCATION ID: " .. tostring(savePlaceId), colors.cyan)
    course = call("getCourse")
    x= course.x
    y= course.y
    z= course.z
    printAt(2, 9, "Current Position: " .. tostring(x) .. ", " .. tostring(y) .. ", " .. tostring(z), colors.white)
    printAt(2, 10, "Enter a rotation value (0-360): ", colors.white)
    rotation = read()
    execute(
            "setCourse",
            x,
            y,
            z,
            course.dimension,
            true,
            rotation
        )
    local currentPlaces, placesError = call("getPlaces")
    if type(currentPlaces) ~= "table" then
        notify(placesError or "Unable to load locations.")
        return
    end
    if currentPlaces[savePlaceId] or currentPlaces[tostring(savePlaceId)] then
        notify("That location ID is already in use.")
        return
    end

    execute("savePlace", savePlaceId)
    page = "memory"

    footer()
end

local function drawDeleteConfirmation()
    header("CONFIRM DELETION")
    center(6, "Delete this saved location?")
    center(8, placeToDelete.name)

    addButton(12, "YES, DELETE", "delete_confirm", function()
        local _, commandError = call("deletePlace", placeToDelete.id)
        notify(commandError or "Location deleted.")
        if not commandError then
            deleteMode = false
        end
        placeToDelete = nil
        page = "memory"
    end, 1)
    addButton(12, "CANCEL", "delete_cancel", function()
        placeToDelete = nil
        page = "memory"
        notify("Location was not deleted.")
    end, 2)

    footer()
end

-- ==========================================
-- SCANNER
-- ==========================================

local function drawScanner()
    header("SCANNER")

    local data, err = call("getScan")

    printAt(2, 4, "LATEST SCAN")

    if type(data) == "table" then
        local y = 7
        for key, value in pairs(data) do
            if y < height - 4 then
                if key == "finds" and type(value) == "table" then
                    for _, find in ipairs(value) do
                        if y < height - 4 then
                            if type(find) == "table" then
                                printAt(
                                    2,
                                    y,
                                    "Find: " .. tostring(find.kind) .. " "
                                        .. tostring(find.name) .. " at "
                                        .. tostring(find.x) .. ", "
                                        .. tostring(find.y) .. ", "
                                        .. tostring(find.z)
                                )
                            else
                                printAt(2, y, "Find: " .. tostring(find))
                            end
                            y = y + 1
                        else
                            break
                        end
                    end
                else
                    printAt(2, y, tostring(key) .. ": " .. tostring(value))
                    y = y + 1
                end
            end
        end
    else
        printAt(2, 7, "No scan data available.", colors.orange)
    end

    line(math.max(1, height - 3))

    addButton(height - 2, "START SCAN", "scan", function()
        execute("scan")
    end, 1)

    addButton(height - 2, "BACK", "back", function()
        page = "home"
    end, 2)

    footer()
end

-- ==========================================
-- DIAGNOSTICS
-- ==========================================

local function drawDiagnostics()
    header("DIAGNOSTICS")

    displayStatus(3, false)

    line(16)

    addButton(18, "REFRESH", "refresh", function()
        page = "diagnostics"
    end, 1)

    addButton(18, "BACK", "back", function()
        page = "home"
    end, 2)

    footer()
end

-- ==========================================
-- PAGE ROUTER
-- ==========================================

local function draw()
    width, height = term.getSize()

    if page == "home" then
        drawHome()
    elseif page == "navigation" then
        drawNavigation()
    elseif page == "destination" then
        drawDestination()
    elseif page == "position" then
        drawPosition()
    elseif page == "flight" then
        drawFlight()
    elseif page == "memory" then
        drawMemory()
    elseif page == "save_place" then
        drawSavePlace()
    elseif page == "confirm_delete" then
        drawDeleteConfirmation()
    elseif page == "scanner" then
        drawScanner()
    elseif page == "diagnostics" then
        drawDiagnostics()
    end
end

-- ==========================================
-- MOUSE EVENT HANDLER
-- ==========================================

draw()

while running do
    local event, buttonCode, x, y = os.pullEvent()

    if event == "mouse_click" and buttonCode == 1 then
        for _, b in ipairs(buttons) do
            if x >= b.x1 and x <= b.x2
                and y >= b.y1 and y <= b.y2 then

                if b.action then
                    b.action()
                end

                break
            end
        end

        if running then
            draw()
        end

    elseif event == "term_resize" then
        draw()
    end
end

clear()
print("NEXUS TARDIS SYSTEM OFFLINE")
