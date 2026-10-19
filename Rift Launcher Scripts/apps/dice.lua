local function loadTheme()
    if type(launcherTheme) == "table" and type(launcherTheme.accent) == "number" then
        return term.isColor() and launcherTheme.accent or colors.gray
    end
    local path = "/.launcher/settings.json"
    if not fs.exists(path) then return term.isColor() and colors.cyan or colors.gray end
    local file = fs.open(path, "r")
    if not file then return term.isColor() and colors.cyan or colors.gray end
    local contents = file.readAll()
    file.close()
    local ok, saved = pcall(textutils.unserializeJSON, contents)
    local accents = { colors.cyan, colors.lime, colors.orange, colors.purple }
    if ok and type(saved) == "table" and accents[saved.theme] then
        return term.isColor() and accents[saved.theme] or colors.gray
    end
    return term.isColor() and colors.cyan or colors.gray
end

local function parseDice(notation)
    local cleaned = notation:lower():gsub("%s+", "")
    local count, sides, modifier = cleaned:match("^(%d*)d(%d+)([+-]%d+)$")
    if not sides then
        count, sides = cleaned:match("^(%d*)d(%d+)$")
        modifier = "0"
    end
    if not sides then return nil, "Use dice notation like d20, 4d6, or 2d8+3." end
    count = count == "" and 1 or tonumber(count)
    sides = tonumber(sides)
    modifier = tonumber(modifier) or 0
    if not count or count % 1 ~= 0 or count < 1 or count > 100 then
        return nil, "Choose from 1 to 100 dice."
    end
    if not sides or sides % 1 ~= 0 or sides < 2 or sides > 1000 then
        return nil, "Choose dice with 2 to 1000 sides."
    end
    if math.abs(modifier) > 1000000 then
        return nil, "The modifier must be between -1000000 and 1000000."
    end
    return count, sides, modifier
end

local accent = loadTheme()
local history = {}
local MAX_HISTORY = 10
local lastNotation

local function showHistory()
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(accent)
    print("Recent Rolls")
    term.setTextColor(colors.white)
    if #history == 0 then
        print("No rolls yet.")
    else
        for index = #history, 1, -1 do
            local roll = history[index]
            print(roll.notation .. " = " .. roll.total
                .. "  [" .. table.concat(roll.dice, ", ") .. "]")
        end
    end
    print("")
    print("Press any key to return.")
    os.pullEventRaw("key")
end

local function showResult(notation, dice, sides, modifier)
    local subtotal = 0
    local lowest, highest = sides, 1
    for _, value in ipairs(dice) do
        subtotal = subtotal + value
        lowest = math.min(lowest, value)
        highest = math.max(highest, value)
    end
    local total = subtotal + modifier
    local result = { notation = notation, dice = dice, total = total }
    table.insert(history, result)
    if #history > MAX_HISTORY then table.remove(history, 1) end

    term.setTextColor(colors.lightGray)
    print("")
    print("Dice: " .. table.concat(dice, ", "))
    print("Subtotal: " .. subtotal)
    if modifier ~= 0 then
        print("Modifier: " .. (modifier > 0 and "+" or "") .. modifier)
    end
    term.setTextColor(accent)
    print("TOTAL: " .. total)
    term.setTextColor(colors.lightGray)
    print("Range: " .. lowest .. "-" .. highest .. "  Average: "
        .. string.format("%.2f", subtotal / #dice))
end

while true do
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(accent)
    print("Dice Roller")
    term.setTextColor(colors.lightGray)
    print("Roll up to 100 dice with 2-1000 sides.")
    print("Examples: d20, 4d6, 2d8+3, 1d100-5")
    print("Press Enter to repeat the last roll.")
    print("Commands: history, clear, help, quit")
    print("")
    term.setTextColor(accent)
    write("Roll: ")
    term.setTextColor(colors.white)
    local input = read()
    if input == "" and lastNotation then input = lastNotation end
    local command = input:lower():match("^%s*(.-)%s*$")

    if command == "q" or command == "quit" or command == "exit" then
        return
    elseif command == "history" then
        showHistory()
    elseif command == "clear" then
        history = {}
        lastNotation = nil
    elseif command == "help" then
        term.setTextColor(colors.white)
        print("")
        print("Notation is [count]d[sides][+/-modifier].")
        print("For example, 4d6+2 rolls four six-sided dice and adds 2.")
        print("Press Enter to roll again, or type quit to return.")
        os.pullEventRaw("key")
    elseif command ~= "" then
        local count, sides, modifierOrError = parseDice(input)
        if not count then
            term.setTextColor(colors.red)
            print(modifierOrError)
            sleep(1)
        else
            local modifier = modifierOrError
            local dice = {}
            for index = 1, count do
                dice[index] = math.random(1, sides)
            end
            lastNotation = input
            showResult(input, dice, sides, modifier)
        end
    end
end
