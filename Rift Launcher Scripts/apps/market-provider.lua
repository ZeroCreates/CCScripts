local PROTOCOL = "order_system_v1"
local SERVER_NAME = "rift-market"
local TIMEOUT = 5
local ADDRESS_FILE = "provider-address.cfg"
local providerAddress
local providerAddressRegistered = false
local riftAccount = {}
if type(rift) ~= "table" or type(rift.account) ~= "table" then
    error("This version of Rift Launcher does not support Rift accounts. Update the launcher.")
end

local NEXT_STATUSES = {
    waiting = { "preparing", "cancelled" },
    preparing = { "completed", "cancelled" },
}
local orderMonitor

local function clearScreen()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
end

local function writeAt(x, y, text, foreground, background)
    local width, height = term.getSize()
    if y < 1 or y > height or x > width then return end
    term.setCursorPos(x, y)
    term.setTextColor(foreground or colors.white)
    term.setBackgroundColor(background or colors.black)
    term.write(tostring(text):sub(1, width - x + 1))
    term.setBackgroundColor(colors.black)
end

local function drawHeader(title, subtitle)
    local width = term.getSize()
    clearScreen()
    writeAt(1, 1, string.rep(" ", width), colors.white, colors.cyan)
    writeAt(2, 1, title, colors.white, colors.cyan)
    writeAt(2, 2, subtitle, colors.lightGray)
end

local function sectionTitle(y, title)
    local width = term.getSize()
    writeAt(1, y, string.rep(" ", width), colors.white, colors.blue)
    writeAt(2, y, title, colors.white, colors.blue)
end

local function drawChoices(help)
    local width, height = term.getSize()
    local options = {}
    for part in help:gmatch("[^|]+") do
        local key, label = part:match("^%s*([%w/]+)%s*(.-)%s*$")
        if key then
            if key:find("/") then
                local first, second = key:match("([^/]+)/([^/]+)")
                table.insert(options, { key = first, label = "NEXT " .. label })
                table.insert(options, { key = second, label = "PREV " .. label })
            else
                table.insert(options, { key = key, label = label ~= "" and label or key })
            end
        end
    end

    if #options == 0 then return {} end
    local columns = math.min(3, #options)
    local rows = math.ceil(#options / columns)
    local firstRow = height - rows + 1
    local buttons = {}
    for index, option in ipairs(options) do
        local row = firstRow + math.floor((index - 1) / columns)
        local column = (index - 1) % columns
        local left = math.floor(column * width / columns) + 1
        local right = math.floor((column + 1) * width / columns)
        local label = ("[" .. option.label .. "]"):sub(1, right - left + 1)
        writeAt(left, row, label, colors.black, colors.lightBlue)
        table.insert(buttons, { key = option.key, row = row, left = left, right = right })
    end
    return buttons
end

local function readChoice(help)
    local buttons = drawChoices(help)
    while true do
        local event, button, x, y = os.pullEvent()
        if event == "mouse_click" and button == 1 then
            for _, choice in ipairs(buttons) do
                if y == choice.row and x >= choice.left and x <= choice.right then
                    return choice.key
                end
            end
        end
    end
end

local function showNotice(title, message)
    drawHeader(title, "PROVIDER CONSOLE  /  REDNET ORDER SYSTEM")
    writeAt(2, 5, message, colors.white)
    readChoice("ok continue")
end

local function openModems()
    local found = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            found = true
        elseif peripheral.getType(name) == "monitor" and not orderMonitor then
            orderMonitor = peripheral.wrap(name)
            if orderMonitor then orderMonitor.setTextScale(0.5) end
        end
    end
    if not found then error("Attach a modem before starting the provider page.") end
    if not term.isColor() then
        error("Run the provider on an advanced computer with a mouse attached.")
    end
end

local function request(message)
    local serverId = rednet.lookup(PROTOCOL, SERVER_NAME)
    if not serverId then
        return nil, "Order server not found. Check that it is running and connected."
    end
    rednet.send(serverId, message, PROTOCOL)
    local _, response = rednet.receive(PROTOCOL, TIMEOUT)
    if type(response) ~= "table" then return nil, "No response from the order server." end
    if response.type == "error" then
        return nil, response.message or "The server rejected the request."
    end
    return response
end

local function loadRiftAccount(username)
    local address, err = rift.account.get("market", "providerAddress")
    if err then return false, err end
    riftAccount = { username = username, providerAddress = address }
    return true
end

local function authenticateRiftAccount()
    local name = rift.account.signIn()
    if not name then return false, "Sign-in cancelled." end
    return loadRiftAccount(name)
end

local function registerProviderAddress()
    if not providerAddress or providerAddress == "" then
        return nil, "Set your payment address first."
    end
    local response, err = request({ type = "set_provider_address", address = providerAddress })
    if not response then return nil, err end
    providerAddressRegistered = true
    return true
end

local function money(cents)
    return string.format("$%.2f", cents / 100)
end

local function appendReceiptText(lines, text, width)
    text = tostring(text)
    for start = 1, #text, width do
        table.insert(lines, text:sub(start, start + width - 1))
    end
end

local function printReceipt(order)
    local printer = peripheral.find("printer")
    if not printer then return false, "No printer is attached to this provider computer." end

    local ok, err = pcall(function()
        if printer.getPaperLevel() < 1 then error("The printer needs paper.") end
        if printer.getInkLevel() < 1 then error("The printer needs ink.") end
        if not printer.newPage() then error("The printer could not start a page; check paper and ink.") end

        local width, height = printer.getPageSize()
        local lines = {
            "ORDER RECEIPT #" .. order.id,
            "PAYMENT REF: " .. (order.reference or string.format("ORD-%06d", order.id)),
            "STATUS: " .. order.status:upper(),
            "",
            "DELIVERY ADDRESS",
        }
        appendReceiptText(lines, order.deliveryAddress or "ADDRESS NOT SAVED", width)
        table.insert(lines, "")
        table.insert(lines, "ITEMS")
        for _, item in ipairs(order.items) do
            appendReceiptText(lines, item.quantity .. " x " .. item.name
                .. "  " .. money(item.lineTotal), width)
        end
        table.insert(lines, "")
        appendReceiptText(lines, "TOTAL: " .. money(order.total), width)

        local lineIndex = 1
        while lineIndex <= #lines do
            printer.setPageTitle("Order " .. (order.reference or order.id))
            for row = 1, height do
                if lineIndex > #lines then break end
                printer.setCursorPos(1, row)
                printer.write(lines[lineIndex]:sub(1, width))
                lineIndex = lineIndex + 1
            end
            if not printer.endPage() then error("The printer could not finish the receipt page.") end
            if lineIndex <= #lines and not printer.newPage() then
                error("The printer could not start another page; check paper and ink.")
            end
        end
    end)

    if not ok then return false, tostring(err) end
    return true, "Receipt printed for order #" .. order.id .. "."
end

local function refreshOrders()
    if providerAddress and not providerAddressRegistered then
        registerProviderAddress()
    end
    local response, err = request({ type = "provider_list" })
    if not response then return nil, err end
    return response.orders or {}
end

local function refreshProducts()
    local response, err = request({ type = "get_provider_products" })
    if not response then return nil, err end
    return response.products or {}
end

local function loadProviderAddress()
    if type(riftAccount.providerAddress) == "string" then
        return riftAccount.providerAddress
    end
    if not fs.exists(ADDRESS_FILE) then return "" end
    local file = fs.open(ADDRESS_FILE, "r")
    if not file then return "" end
    local contents = file.readAll()
    file.close()
    local ok, saved = pcall(textutils.unserialize, contents)
    if ok and type(saved) == "table" and type(saved.address) == "string" then
        return saved.address
    end
    return ""
end

local function saveProviderAddress(address)
    if not rift.account.current() then
        return false, "The signed-in Rift account could not be loaded."
    end
    if not rift.account.set("market", "providerAddress", address) then
        return false, "Could not save the Rift account."
    end
    riftAccount.providerAddress = address
    return true
end

local function configureProviderAddress()
    drawHeader("PROVIDER PAYMENT ADDRESS", "THIS ADDRESS IS SAVED WITH YOUR ORDERS")
    writeAt(2, 5, "Enter the address customers should send payments to.", colors.lightGray)
    writeAt(2, 7, "Current: " .. (providerAddress ~= "" and providerAddress or "not set"), colors.yellow)
    term.setCursorPos(2, 9)
    write("Address: ")
    local address = read():match("^%s*(.-)%s*$")
    if address == "" then return end
    if #address > 64 or address:find("%c") then
        showNotice("INVALID ADDRESS", "Use 1 to 64 characters without control characters.")
        return
    end
    local saved, saveError = saveProviderAddress(address)
    if not saved then
        showNotice("ADDRESS NOT SAVED", saveError)
        return
    end
    providerAddress = address
    if fs.exists(ADDRESS_FILE) then
        local deleted, deleteError = pcall(fs.delete, ADDRESS_FILE)
        if not deleted then
            showNotice("ADDRESS SAVED", "The Rift account was updated, but the old address file could not be removed: "
                .. tostring(deleteError))
        end
    end
    local registered, err = registerProviderAddress()
    if not registered then
        showNotice("ADDRESS SAVED LOCALLY", "Could not register with the order server: " .. err)
        return
    end
    showNotice("ADDRESS REGISTERED", "Orders will route to " .. address .. ".")
end

local function drawOrderMonitor(orders, errorMessage)
    if not orderMonitor then return end

    local width, height = orderMonitor.getSize()
    local function line(row, text, foreground, background)
        if row < 1 or row > height then return end
        orderMonitor.setCursorPos(1, row)
        orderMonitor.setTextColor(foreground or colors.white)
        orderMonitor.setBackgroundColor(background or colors.black)
        orderMonitor.write(tostring(text):sub(1, width))
        orderMonitor.setBackgroundColor(colors.black)
    end

    orderMonitor.setBackgroundColor(colors.black)
    orderMonitor.setTextColor(colors.white)
    orderMonitor.clear()
    line(1, string.rep(" ", width), colors.white, colors.cyan)
    line(1, " PROVIDER ORDERS  |  " .. #orders .. " ACTIVE", colors.white, colors.cyan)

    if errorMessage then
        line(3, "SERVER CONNECTION ERROR", colors.red)
        line(4, errorMessage, colors.lightGray)
        return
    end
    if #orders == 0 then
        line(3, "No active orders. Waiting for orders...", colors.lightGray)
        return
    end

    local row = 3
    for index = #orders, 1, -1 do
        local order = orders[index]
        if row + 2 > height then break end
        local statusColor = order.status == "preparing" and colors.orange or colors.yellow
        line(row, (order.reference or string.format("ORD-%06d", order.id))
            .. "  " .. order.status:upper() .. "  " .. money(order.total), statusColor)
        local summary = {}
        for _, item in ipairs(order.items) do
            table.insert(summary, item.quantity .. "x " .. item.name)
        end
        line(row + 1, table.concat(summary, ", "), colors.lightGray)
        line(row + 2, "TO " .. (order.deliveryAddress or "ADDRESS NOT SET"), colors.yellow)
        row = row + 3
    end
end

local function showOrders(orders, page, errorMessage)
    local function render()
        drawHeader("PROVIDER CONSOLE", "LIVE ORDERS  /  N/V OR WHEEL TO BROWSE")
        sectionTitle(4, "ACTIVE ORDERS  |  " .. #orders)
        local visibleOrders = {}
        local firstRow = 5

        if errorMessage then
            writeAt(2, 6, errorMessage, colors.red)
        elseif #orders == 0 then
            writeAt(2, 6, "No active orders right now.", colors.lightGray)
        else
            local _, height = term.getSize()
            local perPage = math.max(1, math.floor((height - 8) / 3))
            local pageCount = math.max(1, math.ceil(#orders / perPage))
            page = math.max(1, math.min(page, pageCount))
            local first = (page - 1) * perPage + 1
            local last = math.min(#orders, first + perPage - 1)

            for index = first, last do
                local order = orders[index]
                local y = firstRow + (index - first) * 3
                table.insert(visibleOrders, { order = order, firstRow = y })
                local statusColor = order.status == "preparing" and colors.orange or colors.yellow
                writeAt(2, y, order.reference or string.format("ORD-%06d", order.id), colors.cyan)
                writeAt(18, y, order.status:upper(), statusColor)
                local width = term.getSize()
                writeAt(width - 9, y, money(order.total), colors.white)
                local summary = {}
                for _, item in ipairs(order.items) do
                    table.insert(summary, item.quantity .. "x " .. item.name)
                end
                writeAt(2, y + 1, table.concat(summary, ", "), colors.lightGray)
                writeAt(2, y + 2, "DELIVER TO: " .. (order.deliveryAddress or "ADDRESS NOT SET"), colors.yellow)
            end
            writeAt(2, height - 3, "PAGE " .. page .. " / " .. pageCount, colors.yellow)
        end
        return visibleOrders
    end

    local visibleOrders = render()
    local buttons = drawChoices("p products|a address|r refresh|q quit")
    local refreshTimer = os.startTimer(5)
    while true do
        local event, eventId, x, y = os.pullEvent()
        if event == "timer" and eventId == refreshTimer then
            local freshOrders, refreshError = refreshOrders()
            if freshOrders then
                orders = freshOrders
                errorMessage = nil
            else
                errorMessage = refreshError
            end
            drawOrderMonitor(orders, errorMessage)
            visibleOrders = render()
            buttons = drawChoices("p products|a address|r refresh|q quit")
            refreshTimer = os.startTimer(5)
        elseif event == "mouse_click" and eventId == 1 then
            for _, choice in ipairs(buttons) do
                if y == choice.row and x >= choice.left and x <= choice.right then
                    return choice.key, page, nil, orders
                end
            end
            for _, entry in ipairs(visibleOrders) do
                if y >= entry.firstRow and y <= entry.firstRow + 2 then
                    return "order", page, entry.order, orders
                end
            end
        elseif event == "mouse_scroll" then
            page = eventId > 0 and page + 1 or math.max(1, page - 1)
            visibleOrders = render()
            buttons = drawChoices("p products|a address|r refresh|q quit")
        elseif event == "key" and (eventId == keys.n or eventId == keys.v) then
            page = eventId == keys.n and page + 1 or math.max(1, page - 1)
            visibleOrders = render()
            buttons = drawChoices("p products|a address|r refresh|q quit")
        end
    end
end

local function showDeliveryDetails(order)
    drawHeader(order.reference or string.format("ORDER #%06d", order.id),
        "STATUS  /  " .. order.status:upper())
    sectionTitle(4, "DELIVERY ADDRESS")
    local width, height = term.getSize()
    writeAt(2, 5, "PAYMENT REF: "
        .. (order.reference or string.format("ORD-%06d", order.id)), colors.cyan)
    local address = order.deliveryAddress or "No address was saved. Update and restart rift-server.lua."
    local lineWidth = math.max(1, width - 3)
    local row = 6
    for start = 1, #address, lineWidth do
        writeAt(2, row, address:sub(start, start + lineWidth - 1), colors.yellow)
        row = row + 1
        if row >= height - 3 then break end
    end
    readChoice("b back")
end

local updateStatus

local function showOrderActions(order)
    while true do
        drawHeader(order.reference or string.format("ORDER #%06d", order.id),
            "ORDER ACTIONS  /  " .. order.status:upper())
        sectionTitle(4, "ORDER DETAILS")
        writeAt(2, 6, "TOTAL  " .. money(order.total), colors.lime)
        writeAt(2, 8, "DELIVER TO  " .. (order.deliveryAddress or "ADDRESS NOT SET"), colors.yellow)
        local action = readChoice("s status|d address|p print receipt|b back")
        if action == "s" then
            updateStatus(order)
            return
        elseif action == "d" then
            showDeliveryDetails(order)
        elseif action == "p" then
            local printed, message = printReceipt(order)
            showNotice(printed and "RECEIPT PRINTED" or "RECEIPT NOT PRINTED", message)
        elseif action == "b" or action == "q" then
            return
        end
    end
end

local function productPage(products, page, errorMessage)
    drawHeader("MY PRODUCTS", "CLICK TO MANAGE  /  N/V OR WHEEL TO BROWSE")
    sectionTitle(4, "YOUR CATALOG  |  " .. #products)
    local visibleProducts = {}

    if errorMessage then
        writeAt(2, 6, errorMessage, colors.red)
    elseif #products == 0 then
        writeAt(2, 6, "No products published yet.", colors.lightGray)
    else
        local width, height = term.getSize()
        local perPage = math.max(1, height - 8)
        local pageCount = math.max(1, math.ceil(#products / perPage))
        page = math.max(1, math.min(page, pageCount))
        local first = (page - 1) * perPage + 1
        local last = math.min(#products, first + perPage - 1)
        for index = first, last do
            local product = products[index]
            local y = 5 + index - first
            table.insert(visibleProducts, { product = product, row = y })
            writeAt(2, y, product.name:sub(1, math.max(1, width - 23)), colors.white)
            writeAt(width - 14, y, money(product.price), colors.yellow)
            writeAt(width - 6, y, product.available and "ON" or "OFF",
                product.available and colors.lime or colors.gray)
        end
        writeAt(2, height - 3, "PAGE " .. page .. " / " .. pageCount, colors.yellow)
    end

    local buttons = drawChoices("a add|b back")
    while true do
        local event, button, x, y = os.pullEvent()
        if event == "mouse_click" and button == 1 then
            for _, choice in ipairs(buttons) do
                if y == choice.row and x >= choice.left and x <= choice.right then
                    return choice.key, page
                end
            end
            for _, entry in ipairs(visibleProducts) do
                if y == entry.row then return "product", page, entry.product end
            end
        elseif event == "mouse_scroll" and button > 0 then
            return "n", page
        elseif event == "mouse_scroll" then
            return "v", page
        elseif event == "key" and (button == keys.n or button == keys.v) then
            return button == keys.n and "n" or "v", page
        end
    end
end

local editProduct
local toggleProduct

local function productActions(product)
    while true do
        drawHeader(product.name, "TAP AN ACTION")
        sectionTitle(4, "LISTING")
        writeAt(2, 6, product.name, colors.white)
        writeAt(2, 8, money(product.price) .. "  |  "
            .. (product.available and "VISIBLE IN MARKET" or "HIDDEN FROM MARKET"), colors.yellow)
        local action = readChoice("e edit|t toggle availability|b back")
        if action == "e" then
            editProduct(product)
            return
        elseif action == "t" then
            toggleProduct(product)
            return
        elseif action == "b" or action == "q" then
            return
        end
    end
end

local function publishProduct(product)
    if not providerAddress or providerAddress == "" then
        showNotice("ADDRESS REQUIRED", "Set your payment address before publishing products.")
        return false
    end
    product.providerName = riftAccount.username
    product.providerAddress = providerAddress
    local response, err = request({ type = "publish_product", product = product })
    if not response then
        showNotice("PRODUCT NOT SAVED", err)
        return false
    end
    showNotice("PRODUCT SAVED", response.product.name .. " is now on the server catalog.")
    return true
end

local function addProduct()
    drawHeader("NEW PRODUCT", "PUBLISH A LISTING TO THE SHARED CATALOG")
    writeAt(2, 5, "Product names can be up to 32 characters.", colors.lightGray)
    term.setCursorPos(2, 7)
    write("Name: ")
    local name = read()
    if name == "" then return end
    term.setCursorPos(2, 9)
    write("Price in dollars: $")
    local price = tonumber(read())
    if not price or price <= 0 or price > 10000 then
        showNotice("INVALID PRICE", "Enter a price < $0 and > $10000.")
        return
    end
    publishProduct({ name = name, price = math.floor(price * 100 + 0.5), available = true })
end

editProduct = function(product)
    drawHeader("EDIT PRODUCT", "Leave a field blank to keep it unchanged.")
    term.setCursorPos(2, 6)
    write("Name [" .. product.name .. "]: ")
    local name = read()
    term.setCursorPos(2, 8)
    write("Price [$" .. string.format("%.2f", product.price / 100) .. "]: $")
    local priceInput = read()
    local price = priceInput == "" and product.price or tonumber(priceInput)
    if not price or price <= 0 or price > 10000 then
        showNotice("INVALID PRICE", "Enter a price greater than $0 and no more than $10000.")
        return
    end
    publishProduct({
        id = product.id,
        name = name == "" and product.name or name,
        price = math.floor(price * 100 + 0.5),
        available = product.available,
    })
end

toggleProduct = function(product)
    publishProduct({
        id = product.id,
        name = product.name,
        price = product.price,
        available = not product.available,
    })
end

updateStatus = function(order)
    local allowed = NEXT_STATUSES[order.status]
    if not allowed then
        showNotice("NO STATUS CHANGES", "This order is already " .. order.status .. ".")
        return
    end
    drawHeader("UPDATE ORDER #" .. order.id, "TAP A VALID NEXT STATUS")
    local menu = {}
    for index, nextStatus in ipairs(allowed) do
        menu[index] = tostring(index) .. " " .. nextStatus:sub(1, 1):upper() .. nextStatus:sub(2)
    end
    menu[#menu + 1] = "q cancel"
    local choice = readChoice(table.concat(menu, " | "))
    local selectedIndex = tonumber(choice)
    if not selectedIndex or not allowed[selectedIndex] then return end
    local response, err = request({ type = "set_status", orderId = order.id, status = allowed[selectedIndex] })
    if not response then
        showNotice("UPDATE REJECTED", err)
        return
    end
    showNotice("STATUS UPDATED", "Order " .. response.order.reference
        .. " is now " .. response.order.status .. ".")
end

openModems()
local authenticated, authenticationError = authenticateRiftAccount()
if not authenticated then
    if authenticationError ~= "Sign-in cancelled." then
        showNotice("RIFT ACCOUNT SIGN IN", authenticationError)
    end
    return
elseif authenticationError then
    showNotice("RIFT ACCOUNT SIGN IN", authenticationError)
end
providerAddress = loadProviderAddress()
if providerAddress == "" then
    configureProviderAddress()
else
    if riftAccount.providerAddress ~= providerAddress then
        local migrated, migrationError = saveProviderAddress(providerAddress)
        if not migrated then
            showNotice("ADDRESS NOT MIGRATED", "Could not save the existing address to your Rift account: "
                .. migrationError)
        elseif fs.exists(ADDRESS_FILE) then
            local deleted, deleteError = pcall(fs.delete, ADDRESS_FILE)
            if not deleted then
                showNotice("ADDRESS MIGRATED", "The account was updated, but the old address file could not be removed: "
                    .. tostring(deleteError))
            end
        end
    end
    local registered, addressError = registerProviderAddress()
    if not registered then
        showNotice("ADDRESS NOT REGISTERED", "Could not register with the order server: " .. addressError)
    end
end
local orderPage = 1
local productPageNumber = 1
local printedReceipts = {}

while true do
    local orders, orderError = refreshOrders()
    orders = orders or {}
    drawOrderMonitor(orders, orderError)

    if not peripheral.find("printer") then
        printedReceipts = {}
    else
        for _, order in ipairs(orders) do
            if order.status == "preparing" and not printedReceipts[order.id] then
                printedReceipts[order.id] = true
                local printed, printMessage = printReceipt(order)
                if not printed then showNotice("RECEIPT NOT PRINTED", printMessage) end
            end
        end
    end

    local choice, shownOrderPage, selectedOrder, currentOrders = showOrders(orders, orderPage, orderError)
    orderPage = shownOrderPage or orderPage
    orders = currentOrders or orders
    if choice == "order" then
        showOrderActions(selectedOrder)
    elseif choice == "p" then
        while true do
            local products, productError = refreshProducts()
            local productChoice, shownProductPage, selectedProduct = productPage(
                products or {}, productPageNumber, productError)
            productPageNumber = shownProductPage or productPageNumber
            if productChoice == "a" then
                addProduct()
            elseif productChoice == "product" then
                productActions(selectedProduct)
            elseif productChoice == "n" then
                productPageNumber = productPageNumber + 1
            elseif productChoice == "v" then
                productPageNumber = math.max(1, productPageNumber - 1)
            elseif productChoice == "b" or productChoice == "q" then
                break
            end
        end
    elseif choice == "a" then
        configureProviderAddress()
    elseif choice == "n" then
        orderPage = orderPage + 1
    elseif choice == "v" then
        orderPage = math.max(1, orderPage - 1)
    elseif choice == "r" then
        orderPage = 1
    elseif choice == "q" then
        break
    end
end
