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
local maximumDuration = 86400

local function parseDuration(input)
    input = input:match("^%s*(.-)%s*$")
    local seconds = tonumber(input)
    if seconds and seconds % 1 == 0 then
        if seconds >= 1 and seconds <= maximumDuration then return seconds end
        return nil
    end

    local hours, minutes, remainder = input:match("^(%d+):(%d%d):(%d%d)$")
    if hours then
        hours, minutes, remainder = tonumber(hours), tonumber(minutes), tonumber(remainder)
        if minutes > 59 or remainder > 59 then return nil end
        seconds = hours * 3600 + minutes * 60 + remainder
        if seconds >= 1 and seconds <= maximumDuration then return seconds end
        return nil
    end

    minutes, remainder = input:match("^(%d+):(%d%d)$")
    if minutes then
        minutes, remainder = tonumber(minutes), tonumber(remainder)
        if remainder > 59 then return nil end
        seconds = minutes * 60 + remainder
        if seconds >= 1 and seconds <= maximumDuration then return seconds end
        return nil
    end

    local total, position, lastUnit = 0, 1, 0
    local unitValues = { h = 3600, m = 60, s = 1 }
    local unitRanks = { h = 1, m = 2, s = 3 }
    local found = false
    while position <= #input do
        local startAt, endAt, amount, unit = input:find("(%d+)%s*([hms])", position)
        if not startAt then
            if input:sub(position):match("^%s*$") then break end
            return nil
        end
        if not input:sub(position, startAt - 1):match("^%s*$") then return nil end
        if unitRanks[unit] <= lastUnit then return nil end
        total = total + tonumber(amount) * unitValues[unit]
        lastUnit = unitRanks[unit]
        position = endAt + 1
        found = true
    end
    if found and total >= 1 and total <= maximumDuration then return total end
    return nil
end

local function formatDuration(seconds)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor(seconds % 3600 / 60)
    local remainder = seconds % 60
    return string.format("%02d:%02d:%02d", hours, minutes, remainder)
end

local function drawHeader(title)
    local width = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(term.isColor() and accent or colors.gray)
    term.write((" " .. title):sub(1, width))
    term.setBackgroundColor(colors.black)
end

local function drawTimer(remaining, duration, paused)
    local width, height = term.getSize()
    drawHeader("COUNTDOWN")

    local label = paused and "PAUSED" or "TIME REMAINING"
    term.setCursorPos(math.max(1, math.floor((width - #label) / 2)), math.max(2, math.floor(height / 2) - 2))
    term.setTextColor(term.isColor() and accent or colors.white)
    term.write(label)

    local formatted = formatDuration(remaining)
    term.setCursorPos(math.max(1, math.floor((width - #formatted) / 2)), math.max(3, math.floor(height / 2) - 1))
    term.setTextColor(colors.white)
    term.write(formatted)

    local barWidth = math.max(1, width - 4)
    local filled = math.floor(barWidth * (duration - remaining) / duration)
    term.setCursorPos(3, math.max(4, math.floor(height / 2) + 1))
    term.setTextColor(colors.lightGray)
    term.write("[")
    term.setTextColor(term.isColor() and accent or colors.white)
    term.write(string.rep("#", filled))
    term.setTextColor(colors.gray)
    term.write(string.rep("-", barWidth - filled))
    term.setTextColor(colors.lightGray)
    term.write("]")

    local controls = "SPACE pause/resume   R restart   Q quit"
    term.setCursorPos(math.max(1, math.floor((width - #controls) / 2)), height)
    term.setTextColor(colors.lightGray)
    term.write(controls:sub(1, width))
end

drawHeader("COUNTDOWN TIMER")
term.setCursorPos(2, 3)
term.setTextColor(colors.white)
print("Enter a duration: seconds, M:SS, H:MM:SS, or 1h 20m 5s")
print("Maximum duration: 24 hours. Type Q to return.")

local duration
while not duration do
    term.setCursorPos(2, 6)
    term.setTextColor(term.isColor() and accent or colors.white)
    write("Duration: ")
    term.setTextColor(colors.white)
    local input = read()
    if input:lower() == "q" then return end
    duration = parseDuration(input)
    if not duration then
        term.setCursorPos(2, 8)
        term.setTextColor(colors.red)
        print("Invalid duration. Try 90, 1:30, or 1m 30s.")
        term.setTextColor(colors.white)
    end
end

local remaining = duration
local paused = false
local deadline = os.clock() + remaining
local timer = os.startTimer(0.2)
drawTimer(remaining, duration, paused)

while remaining > 0 do
    local event, value = os.pullEventRaw()
    if event == "timer" and value == timer and not paused then
        remaining = math.max(0, math.ceil(deadline - os.clock()))
        drawTimer(remaining, duration, paused)
        if remaining > 0 then timer = os.startTimer(0.2) end
    elseif event == "key" then
        if value == keys.q then return
        elseif value == keys.space then
            if paused then
                paused = false
                deadline = os.clock() + remaining
                timer = os.startTimer(0.2)
            else
                remaining = math.max(0, math.ceil(deadline - os.clock()))
                paused = true
            end
            drawTimer(remaining, duration, paused)
        elseif value == keys.r then
            remaining = duration
            paused = false
            deadline = os.clock() + remaining
            timer = os.startTimer(0.2)
            drawTimer(remaining, duration, paused)
        end
    end
end

drawHeader("COUNTDOWN COMPLETE")
term.setCursorPos(2, 3)
term.setTextColor(term.isColor() and accent or colors.white)
print("Time's up!")
term.setTextColor(colors.white)
local speaker = peripheral.find("speaker")
if speaker then speaker.playSound("minecraft:block.note_block.pling") end
print("Press any key to return.")
os.pullEventRaw("key")
