local function loadTheme()
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
    if ok and type(saved) == "table" and accents[saved.theme] then return accents[saved.theme] end
    return colors.cyan
end

local accent = loadTheme()

local function draw()
    local width, height = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(term.isColor() and accent or colors.gray)
    term.write((" " .. "CLOCK"):sub(1, width))
    term.setBackgroundColor(colors.black)

    local date = os.date("%A, %B %d, %Y")
    local time = os.date("%I:%M:%S %p")
    term.setCursorPos(math.max(1, math.floor((width - #date) / 2)), math.max(2, math.floor(height / 2) - 1))
    term.setTextColor(term.isColor() and accent or colors.white)
    term.write(date)
    term.setCursorPos(math.max(1, math.floor((width - #time) / 2)), math.max(3, math.floor(height / 2)))
    term.setTextColor(colors.white)
    term.write(time)
    term.setCursorPos(2, height)
    term.setTextColor(colors.lightGray)
    term.write("Press Q to return to the launcher.")
end

while true do
    draw()
    local timer = os.startTimer(1)
    while true do
        local event, value = os.pullEventRaw()
        if event == "key" and value == keys.q then return end
        if event == "timer" and value == timer then break end
    end
end
