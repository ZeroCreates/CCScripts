local pretty
local prettyLoaded, prettyModule = pcall(require, "cc.pretty")
if prettyLoaded and type(prettyModule) == "table" then
    pretty = prettyModule
end

local function formatValue(value, indent, ancestors)
    local valueType = type(value)
    if valueType == "string" then return string.format("%q", value) end
    if valueType ~= "table" then return tostring(value) end
    if ancestors[value] then return "{ <cycle> }" end
    if indent >= 8 then return "{ ... }" end

    ancestors[value] = true
    local keys = {}
    for key in pairs(value) do
        table.insert(keys, key)
    end
    table.sort(keys, function(first, second)
        local firstType, secondType = type(first), type(second)
        if firstType ~= secondType then return firstType < secondType end
        if firstType == "number" then return first < second end
        return tostring(first) < tostring(second)
    end)

    local entries = {}
    for _, key in ipairs(keys) do
        local child = value[key]
        local formattedKey
        if type(key) == "string" and key:match("^[%a_][%w_]*$") then
            formattedKey = key
        else
            formattedKey = "[" .. formatValue(key, indent + 1, ancestors) .. "]"
        end
        table.insert(entries, string.rep(" ", (indent + 1) * 2)
            .. formattedKey .. " = " .. formatValue(child, indent + 1, ancestors))
    end
    ancestors[value] = nil

    if #entries == 0 then return "{}" end
    return "{\n" .. table.concat(entries, ",\n") .. "\n" .. string.rep(" ", indent * 2) .. "}"
end

local function printResults(results)
    for index = 2, results.n do
        local value = results[index]
        if pretty then
            local ok, formatted = pcall(pretty.pretty, value, {
                function_args = true,
                function_source = true,
            })
            if ok then ok = pcall(pretty.print, formatted) end
            if not ok then print(formatValue(value, 0, {})) end
        else
            print(formatValue(value, 0, {}))
        end
    end
end

local function pack(...)
    return { n = select("#", ...), ... }
end

local function compile(source)
    local chunk, compileError = load("return " .. source, "lua-console")
    if chunk then return chunk end
    return load(source, "lua-console")
end

local themes = {
    { accent = colors.cyan, highlight = colors.blue },
    { accent = colors.lime, highlight = colors.green },
    { accent = colors.orange, highlight = colors.red },
    { accent = colors.purple, highlight = colors.magenta },
    { accent = colors.cyan, highlight = colors.blue },
}
local themeAccent, themeHighlight = colors.cyan, colors.blue
local function loadTheme()
    if type(launcherTheme) == "table"
        and type(launcherTheme.accent) == "number"
        and type(launcherTheme.highlight) == "number" then
        themeAccent = term.isColor() and launcherTheme.accent or colors.gray
        themeHighlight = term.isColor() and launcherTheme.highlight or colors.gray
        return
    end
    local themeIndex = type(launcherTheme) == "number" and launcherTheme or nil
    local saved
    if type(themeIndex) ~= "number" or not themes[themeIndex] or themeIndex == #themes then
        local path = "/.launcher/settings.json"
        if fs.exists(path) then
            local file = fs.open(path, "r")
            if file then
                local contents = file.readAll()
                file.close()
                local ok, parsed = pcall(textutils.unserializeJSON, contents)
                if ok and type(parsed) == "table"
                    and type(parsed.theme) == "number" and themes[parsed.theme] then
                    themeIndex = parsed.theme
                    saved = parsed
                end
            end
        end
    end
    if themeIndex == #themes and type(saved) == "table"
        and term.isColor() and type(term.setPaletteColor) == "function"
        and type(saved.customAccent) == "string" and saved.customAccent:match("^#?%x%x%x%x%x%x$")
        and type(saved.customHighlight) == "string" and saved.customHighlight:match("^#?%x%x%x%x%x%x$") then
        local function applyHex(slot, hex)
            hex = hex:gsub("^#", "")
            term.setPaletteColor(slot, tonumber(hex:sub(1, 2), 16) / 255,
                tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255)
        end
        applyHex(colors.cyan, saved.customAccent)
        applyHex(colors.blue, saved.customHighlight)
    end
    local theme = themes[themeIndex] or themes[1]
    themeAccent = term.isColor() and theme.accent or colors.gray
    themeHighlight = term.isColor() and theme.highlight or colors.gray
end

loadTheme()
local commandHistory = {}
term.setBackgroundColor(colors.black)
term.setTextColor(term.isColor() and themeAccent or colors.gray)
term.clear()
term.setCursorPos(1, 1)
local width = term.getSize()
term.setBackgroundColor(term.isColor() and themeHighlight or colors.gray)
term.write((" Lua Console" .. string.rep(" ", math.max(0, width - 12))):sub(1, width))
term.setBackgroundColor(colors.black)
term.setCursorPos(1, 2)
term.setTextColor(colors.lightGray)
print("Type help for commands, or exit to return to the launcher.")
print("")

while true do
    term.setTextColor(term.isColor() and themeAccent or colors.white)
    write("> ")
    term.setTextColor(colors.white)
    local input = read(nil, commandHistory, function(line)
        local startPosition = line:find("[a-zA-Z0-9_%.:]+$")
        if not startPosition then return nil end
        local prefix = line:sub(startPosition)
        if prefix == "" then return nil end
        return textutils.complete(prefix, _ENV)
    end)
    if input:match("%S") and commandHistory[#commandHistory] ~= input then
        table.insert(commandHistory, input)
    end
    local command = input:lower()

    if command == "exit" or command == "quit" then
        return
    elseif command == "help" then
        print("Enter Lua expressions or statements to run them.")
        print("Variables assigned globally remain available between commands.")
        print("Commands: help, clear, exit")
    elseif command == "clear" then
        term.clear()
        term.setCursorPos(1, 1)
    elseif input ~= "" then
        local chunk, compileError = compile(input)
        if not chunk then
            printError(compileError)
        else
            local results = pack(pcall(chunk))
            if not results[1] then
                printError(results[2])
            else
                printResults(results)
            end
        end
    end
end
