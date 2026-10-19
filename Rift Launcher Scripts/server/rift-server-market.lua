local PROTOCOL = "order_system_v1"
local DATA_FILE = "orders.db"
local BACKUP_FILE = "orders.db.bak"
local TEMP_FILE = "orders.db.tmp"
local PRODUCTS_FILE = "products.db"
local PRODUCTS_BACKUP_FILE = "products.db.bak"
local PRODUCTS_TEMP_FILE = "products.db.tmp"
local TERMINAL_ORDER_RETENTION = 3 * 60 * 60 * 1000
local function createMarketServer(getAuthenticatedUser)
local state

local ALLOWED_TRANSITIONS = {
    waiting = { preparing = true, cancelled = true },
    preparing = { completed = true, cancelled = true },
    completed = {},
    cancelled = {},
}

local function readOrdersState(path)
    if not fs.exists(path) then return nil end
    local file = fs.open(path, "r")
    if not file then return nil end
    local contents = file.readAll()
    file.close()
    local ok, data = pcall(textutils.unserialize, contents)
    if ok and type(data) == "table" and type(data.nextId) == "number"
        and type(data.orders) == "table" then
        return data
    end
    return nil
end

local function readProductsState(path)
    if not fs.exists(path) then return nil end
    local file = fs.open(path, "r")
    if not file then return nil end
    local contents = file.readAll()
    file.close()
    local ok, data = pcall(textutils.unserialize, contents)
    if ok and type(data) == "table" and type(data.products) == "table" then
        if type(data.nextProductId) == "number" or type(data.providerAddresses) == "table" then
            return data
        end
    end
    return nil
end

local function generateProductId(products)
    while true do
        local parts = {}
        for index = 1, 24 do
            parts[index] = string.format("%x", math.random(0, 15))
        end
        local candidate = table.concat(parts)
        local inUse = false
        for _, product in ipairs(products) do
            if product.id == candidate then
                inUse = true
                break
            end
        end
        if not inUse then return candidate end
    end
end

local function isProductId(productId)
    return type(productId) == "string" and #productId == 24
        and productId:match("^[%x]+$") ~= nil
end

local function rebuildProviderAddressesFromProducts(products)
    local providerAddresses = {}
    for _, product in ipairs(products) do
        if type(product.providerId) == "number" and type(product.providerAddress) == "string" and product.providerAddress ~= "" then
            providerAddresses[tostring(product.providerId)] = product.providerAddress
        end
    end
    return providerAddresses
end

local function loadState()
    math.randomseed((os.epoch("utc") + os.getComputerID() + math.floor(os.clock() * 1000)) % 2147483647)
    local defaultState = { nextId = 1, nextProductId = 1, orders = {}, products = {}, providerAddresses = {} }
    if not fs.exists(DATA_FILE) and not fs.exists(BACKUP_FILE)
        and not fs.exists(PRODUCTS_FILE) and not fs.exists(PRODUCTS_BACKUP_FILE) then
        return defaultState
    end

    local legacyState = readOrdersState(DATA_FILE) or readOrdersState(BACKUP_FILE)
    local loadedOrders = readOrdersState(DATA_FILE) or readOrdersState(BACKUP_FILE) or legacyState
    local loadedProducts = readProductsState(PRODUCTS_FILE) or readProductsState(PRODUCTS_BACKUP_FILE)

    if not loadedOrders and not loadedProducts and not legacyState then
        error("Could not read the saved order or product data; refusing to overwrite order data.")
    end

    local loaded = {
        nextId = (loadedOrders and loadedOrders.nextId) or (legacyState and legacyState.nextId) or defaultState.nextId,
        nextProductId = (loadedProducts and loadedProducts.nextProductId) or (legacyState and legacyState.nextProductId) or defaultState.nextProductId,
        orders = (loadedOrders and loadedOrders.orders) or (legacyState and legacyState.orders) or defaultState.orders,
        products = (loadedProducts and loadedProducts.products) or (legacyState and legacyState.products) or defaultState.products,
        providerAddresses = (loadedProducts and loadedProducts.providerAddresses) or (legacyState and legacyState.providerAddresses) or defaultState.providerAddresses,
    }

    loaded.products = type(loaded.products) == "table" and loaded.products or {}
    for _, product in ipairs(loaded.products) do
        if not isProductId(product.id) then
            product.id = generateProductId(loaded.products)
        end
    end
    for index, product in ipairs(loaded.products) do
        for earlierIndex = 1, index - 1 do
            if loaded.products[earlierIndex].id == product.id then
                product.id = generateProductId(loaded.products)
                break
            end
        end
    end
    loaded.providerAddresses = type(loaded.providerAddresses) == "table" and loaded.providerAddresses or rebuildProviderAddressesFromProducts(loaded.products)
    local derivedProviderAddresses = rebuildProviderAddressesFromProducts(loaded.products)
    for providerId, address in pairs(derivedProviderAddresses) do
        loaded.providerAddresses[providerId] = address
    end
    loaded.nextProductId = loaded.nextProductId or 1
    for _, order in ipairs(loaded.orders) do
        order.reference = order.reference or string.format("ORD-%06d", order.id)
        if order.status == "received" then
            order.status = "waiting"
        elseif order.status == "ready" then
            order.status = "preparing"
        elseif order.status == "shipping" then
            order.status = "preparing"
        end
    end
    return loaded
end

local function saveOrdersFile()
    local file = fs.open(TEMP_FILE, "w")
    file.write(textutils.serialize({
        nextId = state.nextId,
        orders = state.orders,
    }))
    file.close()
    if fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
    if fs.exists(DATA_FILE) then fs.move(DATA_FILE, BACKUP_FILE) end
    fs.move(TEMP_FILE, DATA_FILE)
    if fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
end

local function saveProductsFile()
    local file = fs.open(PRODUCTS_TEMP_FILE, "w")
    file.write(textutils.serialize({
        nextProductId = state.nextProductId,
        products = state.products,
        providerAddresses = state.providerAddresses,
    }))
    file.close()
    if fs.exists(PRODUCTS_BACKUP_FILE) then fs.delete(PRODUCTS_BACKUP_FILE) end
    if fs.exists(PRODUCTS_FILE) then fs.move(PRODUCTS_FILE, PRODUCTS_BACKUP_FILE) end
    fs.move(PRODUCTS_TEMP_FILE, PRODUCTS_FILE)
    if fs.exists(PRODUCTS_BACKUP_FILE) then fs.delete(PRODUCTS_BACKUP_FILE) end
end

local function saveState()
    saveOrdersFile()
    saveProductsFile()
end

local function sendError(senderId, message)
    rednet.send(senderId, { type = "error", message = message }, PROTOCOL)
end

local function findOrder(orderId)
    for _, order in ipairs(state.orders) do
        if order.id == orderId then return order end
    end
end

local function generateOrderId()
    local minId = 100000
    local maxId = 999999
    local tries = 0
    while true do
        local candidate = math.random(minId, maxId)
        if not findOrder(candidate) then return candidate end
        tries = tries + 1
        if tries > 1000 then
            candidate = candidate + 1
            if candidate > maxId then candidate = minId end
            if not findOrder(candidate) then return candidate end
        end
    end
end

local function findProduct(productId)
    for _, product in ipairs(state.products) do
        if product.id == productId then return product end
    end
end

local function userOwns(record, userField, legacyIdField, senderId, username)
    if record[userField] ~= nil then return record[userField] == username end
    return record[legacyIdField] == senderId
end

local function accountOwns(record, userField, username)
    return record[userField] == username
end

local function migrateLegacyProviderOwnership(senderId, username)
    local changed = false
    for _, product in ipairs(state.products) do
        if product.providerUser == nil and product.providerId == senderId then
            product.providerUser = username
            product.providerName = username:sub(1, 24)
            changed = true
        end
    end
    for _, order in ipairs(state.orders) do
        if order.providerUser == nil and order.providerId == senderId then
            order.providerUser = username
            changed = true
        end
    end

    local legacyAddress = state.providerAddresses[tostring(senderId)]
    if state.providerAddresses[username] == nil and type(legacyAddress) == "string" then
        state.providerAddresses[username] = legacyAddress
        changed = true
    end
    if changed then saveState() end
end

local function createOrder(senderId, username, message)
    if type(message.deliveryAddress) ~= "string" then
        return sendError(senderId, "A delivery address is required.")
    end
    local deliveryAddress = message.deliveryAddress:match("^%s*(.-)%s*$")
    if #deliveryAddress < 1 or #deliveryAddress > 100 or deliveryAddress:find("%c") then
        return sendError(senderId, "Enter a valid delivery address up to 100 characters.")
    end
    if type(message.items) ~= "table" or #message.items < 1 or #message.items > 50 then
        return sendError(senderId, "Choose at least one available product.")
    end
    local items, total, seen = {}, 0, {}
    local orderProviderId
    local orderProviderUser
    local orderProviderKey
    local orderProviderAddress
    for _, requested in ipairs(message.items) do
        if type(requested) ~= "table" or not isProductId(requested.productId)
            or type(requested.quantity) ~= "number"
            or requested.quantity % 1 ~= 0 or requested.quantity < 1 or requested.quantity > 99 then
            return sendError(senderId, "The order contains an invalid item or quantity.")
        end
        local product = findProduct(requested.productId)
        if not product or not product.available or seen[requested.productId] then
            return sendError(senderId, "A product is unavailable or repeated in this order.")
        end
        local providerKey = product.providerUser or ("computer:" .. tostring(product.providerId))
        if orderProviderKey and orderProviderKey ~= providerKey then
            return sendError(senderId, "Place separate orders for products from different providers.")
        end
        orderProviderKey = providerKey
        orderProviderId = product.providerId
        orderProviderUser = product.providerUser
        orderProviderAddress = state.providerAddresses[product.providerUser or ""]
            or state.providerAddresses[tostring(product.providerId)] or product.providerAddress
        seen[requested.productId] = true
        local lineTotal = product.price * requested.quantity
        total = total + lineTotal
        table.insert(items, {
            productId = product.id,
            providerId = product.providerId,
            providerName = product.providerName,
            name = product.name,
            quantity = requested.quantity,
            unitPrice = product.price,
            lineTotal = lineTotal,
        })
    end
    if not orderProviderAddress or orderProviderAddress == "" then
        return sendError(senderId, "This provider has not registered a payment address yet.")
    end
    local now = os.epoch("utc")
    local orderId = generateOrderId()
    local order = {
        id = orderId,
        reference = string.format("ORD-%06d", orderId),
        customerId = senderId,
        customerUser = username,
        providerId = orderProviderId,
        providerUser = orderProviderUser,
        providerAddress = orderProviderAddress,
        deliveryAddress = deliveryAddress,
        items = items,
        total = total,
        status = "waiting",
        createdAt = now,
        updatedAt = now,
    }
    state.nextId = math.max(state.nextId or 1, orderId + 1)
    table.insert(state.orders, order)
    saveState()
    rednet.send(senderId, { type = "order_created", order = order }, PROTOCOL)
end

local function getOrder(senderId, username, message)
    if type(message.orderId) ~= "number" then
        return sendError(senderId, "Enter a valid order number.")
    end
    local order = findOrder(message.orderId)
    if not order then return sendError(senderId, "Order not found.") end
    if not userOwns(order, "customerUser", "customerId", senderId, username)
        and not accountOwns(order, "providerUser", username) then
        return sendError(senderId, "That order belongs to another customer.")
    end
    local orderCopy = {}
    for key, value in pairs(order) do orderCopy[key] = value end
    orderCopy.providerAddress = orderCopy.providerAddress
        or state.providerAddresses[order.providerUser or ""]
        or state.providerAddresses[tostring(order.providerId)]
    rednet.send(senderId, { type = "order_status", order = orderCopy }, PROTOCOL)
end

local function completeOrder(senderId, username, message)
    if type(message.orderId) ~= "number" then
        return sendError(senderId, "Enter a valid order number.")
    end
    local order = findOrder(message.orderId)
    if not order then return sendError(senderId, "Order not found.") end
    if not userOwns(order, "customerUser", "customerId", senderId, username) then
        return sendError(senderId, "Only the customer who placed this order can complete it.")
    end
    if order.status ~= "preparing" then
        return sendError(senderId, "You can complete the order after it is marked preparing.")
    end

    order.status = "completed"
    order.updatedAt = os.epoch("utc")
    saveState()
    rednet.send(senderId, { type = "order_completed", order = order }, PROTOCOL)
end

local function listCustomerOrders(senderId, username)
    local orders = {}
    for _, order in ipairs(state.orders) do
        if order.customerUser == username
            or order.customerUser == nil and order.customerId == senderId then
            local orderCopy = {}
            for key, value in pairs(order) do orderCopy[key] = value end
            orderCopy.providerAddress = orderCopy.providerAddress
                or state.providerAddresses[order.providerUser or ""]
                or state.providerAddresses[tostring(order.providerId)]
            table.insert(orders, orderCopy)
        end
    end
    table.sort(orders, function(first, second)
        return (first.createdAt or 0) > (second.createdAt or 0)
    end)
    rednet.send(senderId, { type = "customer_orders", orders = orders }, PROTOCOL)
end

local function listOrders(senderId, username)
    local active = {}
    for _, order in ipairs(state.orders) do
        if accountOwns(order, "providerUser", username)
            and order.status ~= "completed" and order.status ~= "cancelled" then
            local orderCopy = {}
            for key, value in pairs(order) do orderCopy[key] = value end
            orderCopy.providerAddress = orderCopy.providerAddress
                or state.providerAddresses[order.providerUser or ""]
                or state.providerAddresses[tostring(order.providerId)]
            table.insert(active, orderCopy)
        end
    end
    rednet.send(senderId, { type = "provider_orders", orders = active }, PROTOCOL)
end

local function setProviderAddress(senderId, username, message)
    if type(message.address) ~= "string" then
        return sendError(senderId, "A provider payment address is required.")
    end
    local address = message.address:match("^%s*(.-)%s*$")
    if #address < 1 or #address > 64 or address:find("%c") then
        return sendError(senderId, "Provider addresses must be 1 to 64 characters without control characters.")
    end

    state.providerAddresses[username] = address
    for _, product in ipairs(state.products) do
        if accountOwns(product, "providerUser", username) then
            product.providerAddress = address
        end
    end
    saveState()
    rednet.send(senderId, { type = "provider_address_saved", address = address }, PROTOCOL)
end

local function getCatalog(senderId)
    local available = {}
    for _, product in ipairs(state.products) do
        if product.available then table.insert(available, product) end
    end
    rednet.send(senderId, { type = "catalog", products = available }, PROTOCOL)
end

local function listProviderProducts(senderId, username)
    local products = {}
    for _, product in ipairs(state.products) do
        if accountOwns(product, "providerUser", username) then
            table.insert(products, product)
        end
    end
    rednet.send(senderId, { type = "provider_products", products = products }, PROTOCOL)
end

local function publishProduct(senderId, username, message)
    local submitted = message.product
    if type(submitted) ~= "table" or type(submitted.name) ~= "string"
        or type(submitted.price) ~= "number" or submitted.price % 1 ~= 0
        or submitted.price < 1 or submitted.price > 1000000
        or type(submitted.available) ~= "boolean" then
        return sendError(senderId, "Product name, price, or availability is invalid.")
    end
    local name = submitted.name:match("^%s*(.-)%s*$")
    if #name < 1 or #name > 32 or name:find("%c") then
        return sendError(senderId, "Product names must be 1 to 32 characters without control characters.")
    end
    local providerAddress = state.providerAddresses[username]
        or state.providerAddresses[tostring(senderId)]
    if submitted.providerAddress ~= nil then
        if type(submitted.providerAddress) ~= "string" then
            return sendError(senderId, "The provider Packager address is invalid.")
        end
        providerAddress = submitted.providerAddress:match("^%s*(.-)%s*$")
        if #providerAddress < 1 or #providerAddress > 64 or providerAddress:find("%c") then
            return sendError(senderId, "Provider addresses must be 1 to 64 characters without control characters.")
        end
        state.providerAddresses[username] = providerAddress
    end

    local product
    if submitted.id ~= nil then
        if not isProductId(submitted.id) then
            return sendError(senderId, "Invalid product ID.")
        end
        product = findProduct(submitted.id)
        if not product
            or not accountOwns(product, "providerUser", username) then
            return sendError(senderId, "You can only edit your own products.")
        end
    else
        product = {
            id = generateProductId(state.products),
            providerUser = username,
            createdAt = os.epoch("utc"),
        }
        table.insert(state.products, product)
    end

    product.providerUser = username
    product.name = name
    product.price = submitted.price
    product.available = submitted.available
    product.providerName = username:sub(1, 24)
    product.providerAddress = providerAddress
    product.updatedAt = os.epoch("utc")
    saveState()
    rednet.send(senderId, { type = "product_saved", product = product }, PROTOCOL)
end

local function updateOrder(senderId, username, message)
    if type(message.orderId) ~= "number" or type(message.status) ~= "string" then
        return sendError(senderId, "The status update is invalid.")
    end
    local order = findOrder(message.orderId)
    if not order then return sendError(senderId, "Order not found.") end
    if not accountOwns(order, "providerUser", username) then
        return sendError(senderId, "You can only update orders for your products.")
    end
    if not ALLOWED_TRANSITIONS[order.status] or not ALLOWED_TRANSITIONS[order.status][message.status] then
        return sendError(senderId, "That status change is not allowed for this order.")
    end
    order.status = message.status
    order.updatedAt = os.epoch("utc")
    saveState()
    rednet.send(senderId, { type = "status_updated", order = order }, PROTOCOL)
end

local display = peripheral.find("monitor")
if display then display.setTextScale(0.5) end

local function drawDashboard()
    if not display then return end
    local screen = display
    local width, height = screen.getSize()
    screen.setBackgroundColor(colors.black)
    screen.setTextColor(colors.white)
    screen.clear()

    local function line(row, text, foreground, background)
        if row < 1 or row > height then return end
        screen.setCursorPos(1, row)
        screen.setTextColor(foreground or colors.white)
        screen.setBackgroundColor(background or colors.black)
        screen.write(tostring(text):sub(1, width))
        screen.setBackgroundColor(colors.black)
    end

    line(1, string.rep(" ", width), colors.white, colors.cyan)
    line(1, " ORDER SERVER  |  ONLINE", colors.white, colors.cyan)

    local activeCount, completedCount, cancelledCount, liveProducts = 0, 0, 0, 0
    for _, order in ipairs(state.orders) do
        if order.status == "completed" then
            completedCount = completedCount + 1
        elseif order.status == "cancelled" then
            cancelledCount = cancelledCount + 1
        else
            activeCount = activeCount + 1
        end
    end
    for _, product in ipairs(state.products) do
        if product.available then liveProducts = liveProducts + 1 end
    end

    line(2, " Computer #" .. os.getComputerID() .. "  |  Protocol: " .. PROTOCOL, colors.lightGray)
    line(4, "ACTIVE ORDERS  " .. activeCount, colors.white, colors.blue)
    line(5, "COMPLETED " .. completedCount .. "   CANCELLED " .. cancelledCount, colors.lightGray)
    line(6, "CATALOG  " .. liveProducts .. " live / " .. #state.products .. " total", colors.lime)
    line(8, "RECENT ACTIVE ORDERS", colors.white, colors.blue)

    local row = 9
    local shown = 0
    for index = #state.orders, 1, -1 do
        local order = state.orders[index]
        if order.status ~= "completed" and order.status ~= "cancelled" then
            if row + 2 > height then break end
            local statusColor = order.status == "preparing" and colors.orange or colors.yellow
            line(row, "#" .. order.id .. "  " .. order.status:upper() .. "  $"
                .. string.format("%.2f", order.total / 100), statusColor)
            local summary = {}
            for _, item in ipairs(order.items) do
                table.insert(summary, item.quantity .. "x " .. item.name)
            end
            line(row + 1, table.concat(summary, ", "), colors.lightGray)
            line(row + 2, "TO " .. (order.deliveryAddress or "ADDRESS NOT SAVED"), colors.yellow)
            row = row + 3
            shown = shown + 1
        end
    end
    if shown == 0 then line(9, "Waiting for orders...", colors.lightGray) end
end

local function getDashboardStats()
    local activeOrders, completedOrders, cancelledOrders, liveProducts = 0, 0, 0, 0
    local recentOrders, orders, products = {}, {}, {}
    for _, order in ipairs(state.orders) do
        table.insert(orders, order)
        if order.status == "completed" then
            completedOrders = completedOrders + 1
        elseif order.status == "cancelled" then
            cancelledOrders = cancelledOrders + 1
        else
            activeOrders = activeOrders + 1
            table.insert(recentOrders, order)
        end
    end
    for _, product in ipairs(state.products) do
        table.insert(products, product)
        if product.available then liveProducts = liveProducts + 1 end
    end
    table.sort(orders, function(first, second)
        return (first.createdAt or 0) > (second.createdAt or 0)
    end)
    table.sort(products, function(first, second)
        return (first.createdAt or 0) > (second.createdAt or 0)
    end)
    table.sort(recentOrders, function(first, second)
        return (first.createdAt or 0) > (second.createdAt or 0)
    end)

    return {
        activeOrders = activeOrders,
        completedOrders = completedOrders,
        cancelledOrders = cancelledOrders,
        liveProducts = liveProducts,
        totalProducts = #state.products,
        recentOrders = recentOrders,
        orders = orders,
        products = products,
    }
end

local function cleanupExpiredOrders()
    local cutoff = os.epoch("utc") - TERMINAL_ORDER_RETENTION
    local removed = false
    for index = #state.orders, 1, -1 do
        local order = state.orders[index]
        local terminalAt = order.updatedAt or order.createdAt
        if (order.status == "completed" or order.status == "cancelled")
            and type(terminalAt) == "number" and terminalAt <= cutoff then
            table.remove(state.orders, index)
            removed = true
        end
    end
    if removed then
        saveState()
        drawDashboard()
    end
    return removed
end

state = loadState()
if not cleanupExpiredOrders() then saveState() end
drawDashboard()

local function handleMarketRequest(senderId, message)
    local username = getAuthenticatedUser(senderId)
    if type(username) ~= "string" then
        return sendError(senderId, "Sign in to your Rift account before using Rift Market.")
    end

    if type(message) ~= "table" then return sendError(senderId, "Invalid request.") end
    if message.type == "provider_list" or message.type == "set_provider_address"
        or message.type == "get_provider_products" or message.type == "publish_product"
        or message.type == "set_status" then
        migrateLegacyProviderOwnership(senderId, username)
    end
    if message.type == "place_order" then
        createOrder(senderId, username, message)
    elseif message.type == "get_order" then
        getOrder(senderId, username, message)
    elseif message.type == "complete_order" then
        completeOrder(senderId, username, message)
    elseif message.type == "my_orders" then
        listCustomerOrders(senderId, username)
    elseif message.type == "provider_list" then
        listOrders(senderId, username)
    elseif message.type == "set_provider_address" then
        setProviderAddress(senderId, username, message)
    elseif message.type == "get_catalog" then
        getCatalog(senderId)
    elseif message.type == "get_provider_products" then
        listProviderProducts(senderId, username)
    elseif message.type == "publish_product" then
        publishProduct(senderId, username, message)
    elseif message.type == "set_status" then
        updateOrder(senderId, username, message)
    else
        sendError(senderId, "Unknown request.")
    end
    drawDashboard()
end

return handleMarketRequest, getDashboardStats, cleanupExpiredOrders
end

return createMarketServer
