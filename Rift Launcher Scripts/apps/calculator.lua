local function applyTheme()
    if type(launcherTheme) == "table" and type(launcherTheme.accent) == "number" then
        return term.isColor() and launcherTheme.accent or colors.gray
    end
    local path = "/.launcher/settings.json"
    if not fs.exists(path) then return colors.cyan end
    local file = fs.open(path, "r")
    if not file then return colors.cyan end
    local contents = file.readAll()
    file.close()
    local ok, saved = pcall(textutils.unserializeJSON, contents)
    local accents = { colors.cyan, colors.lime, colors.orange, colors.purple }
    if ok and type(saved) == "table" and accents[saved.theme] then
        return term.isColor() and accents[saved.theme] or colors.gray
    end
    return term.isColor() and colors.cyan or colors.gray
end

local function evaluate(expression, answer)
    local position = 1
    local parseExpression

    local function skipSpaces()
        while expression:sub(position, position):match("%s") do
            position = position + 1
        end
    end

    local function readNumber()
        local remaining = expression:sub(position)
        local number = remaining:match("^(%d+%.?%d*)") or remaining:match("^(%.%d+)")
        if not number then error("Expected a number.", 0) end
        position = position + #number

        local exponent = expression:sub(position, position)
        if exponent == "e" or exponent == "E" then
            local exponentStart = position
            position = position + 1
            local sign = expression:sub(position, position)
            if sign == "+" or sign == "-" then position = position + 1 end
            local digits = expression:sub(position):match("^(%d+)")
            if not digits then
                error("Invalid exponent near position " .. exponentStart .. ".", 0)
            end
            position = position + #digits
            number = number .. expression:sub(exponentStart, position - 1)
        end

        local value = tonumber(number)
        if not value or value ~= value or value == math.huge or value == -math.huge then
            error("Number is outside the supported range.", 0)
        end
        return value
    end

    local function parsePrimary()
        skipSpaces()
        local character = expression:sub(position, position)
        if character == "(" then
            position = position + 1
            local value = parseExpression()
            skipSpaces()
            if expression:sub(position, position) ~= ")" then
                error("Expected a closing parenthesis.", 0)
            end
            position = position + 1
            return value
        end
        if character:match("[%d%.]") then return readNumber() end

        local name = expression:sub(position):match("^(%a+)")
        if name then
            position = position + #name
            name = name:lower()
            if name == "ans" then return answer end
            if name == "pi" then return math.pi end
            if name == "e" then return math.exp(1) end
            error("Unknown value '" .. name .. "'.", 0)
        end
        error("Expected a number or parenthesis.", 0)
    end

    local parseUnary
    local function parsePower()
        local value = parsePrimary()
        skipSpaces()
        if expression:sub(position, position) == "^" then
            position = position + 1
            value = value ^ parseUnary()
        end
        return value
    end

    parseUnary = function()
        skipSpaces()
        local operator = expression:sub(position, position)
        if operator == "+" or operator == "-" then
            position = position + 1
            local value = parseUnary()
            return operator == "-" and -value or value
        end
        return parsePower()
    end

    local function parseTerm()
        local value = parseUnary()
        while true do
            skipSpaces()
            local operator = expression:sub(position, position)
            if operator ~= "*" and operator ~= "/" and operator ~= "%" then break end
            position = position + 1
            local nextValue = parseUnary()
            if (operator == "/" or operator == "%") and nextValue == 0 then
                error("Cannot divide by zero.", 0)
            end
            if operator == "*" then
                value = value * nextValue
            elseif operator == "/" then
                value = value / nextValue
            else
                value = value % nextValue
            end
        end
        return value
    end

    parseExpression = function()
        local value = parseTerm()
        while true do
            skipSpaces()
            local operator = expression:sub(position, position)
            if operator ~= "+" and operator ~= "-" then break end
            position = position + 1
            local nextValue = parseTerm()
            value = operator == "+" and value + nextValue or value - nextValue
        end
        return value
    end

    local value = parseExpression()
    skipSpaces()
    if position <= #expression then
        error("Unexpected input near position " .. position .. ".", 0)
    end
    if value ~= value or value == math.huge or value == -math.huge then
        error("Result is outside the supported range.", 0)
    end
    return value
end

local accent = applyTheme()
local inputHistory = {}
local calculations = {}
local answer = 0
local message

local function draw()
    local width, height = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(accent)
    term.write((" CALCULATOR"):sub(1, width))
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.setCursorPos(2, 2)
    term.write(("Use + - * / % ^ and parentheses. Ans, pi, and e are supported."):sub(1, width - 1))
    term.setCursorPos(2, 3)
    term.write(("Commands: help, clear, quit"):sub(1, width - 1))

    local visibleCount = math.max(0, math.min(#calculations, height - 7))
    local first = #calculations - visibleCount + 1
    for index = first, #calculations do
        local row = 4 + index - first
        local entry = calculations[index]
        term.setCursorPos(2, row)
        term.setTextColor(colors.lightGray)
        term.write(("> " .. entry.expression):sub(1, width - 1))
        term.setCursorPos(4, row + 1)
        term.setTextColor(colors.lime)
        term.write(("= " .. tostring(entry.result)):sub(1, width - 3))
    end

    if message then
        term.setCursorPos(2, height - 2)
        term.setTextColor(colors.red)
        term.write(tostring(message):sub(1, width - 1))
    end
    term.setCursorPos(2, height)
    term.setTextColor(accent)
    write("> ")
    term.setTextColor(colors.white)
end

while true do
    draw()
    local input = read(nil, inputHistory)
    if input:match("%S") and inputHistory[#inputHistory] ~= input then
        table.insert(inputHistory, input)
    end
    local command = input:lower():match("^%s*(.-)%s*$")
    message = nil

    if command == "q" or command == "quit" or command == "exit" then
        return
    elseif command == "clear" or command == "cls" then
        calculations = {}
    elseif command == "help" then
        message = "Examples: (12 + 3) * 4, 2^8, Ans / 2, 17 % 5"
    elseif input:match("%S") then
        local ok, result = pcall(evaluate, input, answer)
        if ok then
            answer = result
            table.insert(calculations, { expression = input, result = result })
            message = nil
        else
            message = result
        end
    end
end
