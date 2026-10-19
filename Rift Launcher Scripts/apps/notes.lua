local NOTES_FILE = "notes.txt"

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

local function readNotes()
    if not fs.exists(NOTES_FILE) then return "" end
    local file = fs.open(NOTES_FILE, "r")
    if not file then error("Could not open " .. NOTES_FILE .. " for reading.") end
    local contents = file.readAll()
    file.close()
    return contents
end

local function showNotes()
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(term.isColor() and accent or colors.white)
    print("Notes")
    term.setTextColor(colors.white)
    local width = term.getSize()
    print(string.rep("-", math.min(width, 32)))
    local contents = readNotes()
    if contents == "" then print("No notes yet.") else print(contents) end
    print("")
    print("Press any key to return to the menu.")
    os.pullEventRaw("key")
end

while true do
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(term.isColor() and accent or colors.white)
    print("Notes")
    term.setTextColor(colors.white)
    print("1. Read notes")
    print("2. Add a note")
    print("3. Clear all notes")
    print("4. Return to launcher")
    write("> ")
    local choice = read()

    if choice == "1" then
        showNotes()
    elseif choice == "2" then
        write("Note: ")
        local note = read()
        if note ~= "" then
            local file = fs.open(NOTES_FILE, "a")
            if not file then error("Could not open " .. NOTES_FILE .. " for writing.") end
            file.writeLine(os.date("[%Y-%m-%d %H:%M] ") .. note)
            file.close()
            print("Note saved.")
            sleep(1)
        end
    elseif choice == "3" then
        write("Delete all notes? Type yes to confirm: ")
        if read():lower() == "yes" then
            local file = fs.open(NOTES_FILE, "w")
            if not file then error("Could not clear " .. NOTES_FILE .. ".") end
            file.close()
            print("Notes cleared.")
            sleep(1)
        end
    elseif choice == "4" then
        return
    end
end
