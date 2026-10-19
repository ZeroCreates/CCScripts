if type(riftCasino) ~= "table" then
    shell.run("casino.lua", "holdem")
    return
end
local casino = riftCasino
local BOT_STACK_STORAGE = "casino/holdem-bot-stacks"
local LEGACY_BOT_STACK_FILE = "texas-holdem-bots.db"
local LEGACY_STACK_FILE = "texas-holdem-stacks.db"
local storage = require("storage")
local STARTING_STACK = 1000
local SMALL_BLIND = 5
local BIG_BLIND = 10
local SEAT_COUNT = 4
local HERO = 1
local CATEGORY_NAMES = {
    [0] = "HIGH CARD",
    [1] = "PAIR",
    [2] = "TWO PAIR",
    [3] = "THREE OF A KIND",
    [4] = "STRAIGHT",
    [5] = "FLUSH",
    [6] = "FULL HOUSE",
    [7] = "FOUR OF A KIND",
    [8] = "STRAIGHT FLUSH",
}
local RANKS = { ["2"] = 2, ["3"] = 3, ["4"] = 4, ["5"] = 5, ["6"] = 6, ["7"] = 7,
    ["8"] = 8, ["9"] = 9, ["10"] = 10, J = 11, Q = 12, K = 13, A = 14 }
local RANK_GLYPHS = { [11] = "J", [12] = "Q", [13] = "K", [14] = "A" }
local SUITS = { "S", "H", "D", "C" }
local players = {
    { name = "YOU", human = true, stack = STARTING_STACK },
    { name = "BOT 1", stack = STARTING_STACK },
    { name = "BOT 2", stack = STARTING_STACK },
    { name = "BOT 3", stack = STARTING_STACK },
}
local deck, board = {}, {}
local button = 0
local handNumber = 0
local currentMessage = "Three opponents are ready. Start a hand."
local handFinished = true
local currentStreet = ""

local function writeAt(x, y, text, foreground, background)
    local width, height = term.getSize()
    if y < 1 or y > height or x > width then return end
    term.setCursorPos(x, y)
    term.setTextColor(foreground or colors.white)
    term.setBackgroundColor(background or colors.black)
    term.write(tostring(text):sub(1, width - x + 1))
    term.setBackgroundColor(colors.black)
end

local function clearScreen()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
end

local function drawHeader(subtitle)
    local width = term.getSize()
    clearScreen()
    writeAt(1, 1, string.rep(" ", width), colors.white, colors.cyan)
    writeAt(2, 1, "RIFT HOLD'EM", colors.white, colors.cyan)
    writeAt(2, 2, subtitle, colors.lightGray)
end

local function drawButtons(options)
    if #options == 0 then return {} end
    local width, height = term.getSize()
    local columns = math.min(3, #options)
    local rowCount = math.ceil(#options / columns)
    local buttons = {}
    for index, option in ipairs(options) do
        local column = (index - 1) % columns
        local row = height - rowCount + math.floor((index - 1) / columns) + 1
        local left = math.floor(column * width / columns) + 1
        local right = math.floor((column + 1) * width / columns)
        local label = ("[ " .. option.label .. " ]"):sub(1, right - left + 1)
        writeAt(left, row, string.rep(" ", right - left + 1), colors.black, colors.lightBlue)
        writeAt(left, row, label, colors.black, colors.lightBlue)
        table.insert(buttons, { id = option.id, key = option.key, row = row, left = left, right = right })
    end
    return buttons
end

local function waitForAction(buttons)
    while true do
        local event, value, x, y = os.pullEvent()
        if event == "mouse_click" and value == 1 then
            for _, choice in ipairs(buttons) do
                if y == choice.row and x >= choice.left and x <= choice.right then
                    return choice.id
                end
            end
        elseif event == "key" then
            for _, choice in ipairs(buttons) do
                if choice.key == value then return choice.id end
            end
        end
    end
end

local function casinoTransaction(action, amount)
    return casino.transact(action, amount)
end

local function saveStacks()
    local savedStacks = {}
    for seat = 2, SEAT_COUNT do savedStacks[seat - 1] = players[seat].stack end
    local saved, saveError = storage.write(BOT_STACK_STORAGE, savedStacks)
    if not saved then error("Could not save Casino bot stacks: " .. tostring(saveError), 0) end
end

local function applyBotStacks(savedStacks)
    if type(savedStacks) ~= "table" then
        error("Casino bot stack storage is invalid; refusing to reset bot stacks.")
    end
    for seat = 2, SEAT_COUNT do
        local stack = savedStacks[seat - 1]
        if type(stack) ~= "number" or stack < 0 or stack % 1 ~= 0 then
            error("Casino bot stack storage is invalid; refusing to reset bot stacks.")
        end
        players[seat].stack = stack
    end
end

local function removeLegacyStackFiles()
    for _, path in ipairs({ LEGACY_BOT_STACK_FILE, LEGACY_STACK_FILE }) do
        if fs.exists(path) then pcall(fs.delete, path) end
    end
end

local function readLegacyBotStacks()
    for _, path in ipairs({ LEGACY_BOT_STACK_FILE, LEGACY_STACK_FILE }) do
        if fs.exists(path) then
            local file = fs.open(path, "r")
            if not file then error("Could not read legacy Hold'em stacks; refusing to reset bot stacks.") end
            local contents = file.readAll()
            file.close()
            local ok, legacy = pcall(textutils.unserialize, contents)
            if not ok or type(legacy) ~= "table" then
                error("Could not parse legacy Hold'em stacks; refusing to reset bot stacks.")
            end
            local savedStacks = {}
            for seat = 2, SEAT_COUNT do
                local index = path == LEGACY_STACK_FILE and seat or seat - 1
                local stack = legacy[index]
                if type(stack) ~= "number" or stack < 0 or stack % 1 ~= 0 then
                    error("Legacy Hold'em stacks are invalid; refusing to reset bot stacks.")
                end
                savedStacks[seat - 1] = stack
            end
            return savedStacks
        end
    end
end

local function loadStacks()
    local savedStacks, storageError = storage.read(BOT_STACK_STORAGE)
    if savedStacks ~= nil then
        applyBotStacks(savedStacks)
        removeLegacyStackFiles()
    elseif storageError == "Stored data was not found." then
        local legacyStacks = readLegacyBotStacks()
        if legacyStacks then
            local saved, saveError = storage.write(BOT_STACK_STORAGE, legacyStacks)
            if not saved then error("Could not migrate Hold'em bot stacks: " .. tostring(saveError), 0) end
            applyBotStacks(legacyStacks)
            removeLegacyStackFiles()
        end
    else
        error("Could not load Hold'em bot stacks: " .. tostring(storageError), 0)
    end
    local response, err = casino.getBalance()
    if not response then error(err) end
    players[HERO].stack = response.balance
end

local function makeDeck()
    local cards = {}
    for _, suit in ipairs(SUITS) do
        for rank, value in pairs(RANKS) do
            table.insert(cards, { suit = suit, rank = rank, value = value })
        end
    end
    for index = #cards, 2, -1 do
        local swapIndex = math.random(index)
        cards[index], cards[swapIndex] = cards[swapIndex], cards[index]
    end
    return cards
end

local function drawCard(player)
    table.insert(player.cards, table.remove(deck))
end

local function nextSeat(seat)
    return seat % SEAT_COUNT + 1
end

local function nextFundedSeat(seat)
    for _ = 1, SEAT_COUNT do
        seat = nextSeat(seat)
        if players[seat].stack > 0 then return seat end
    end
end

local function canAct(player)
    return not player.folded and not player.allIn and player.stack > 0
end

local function contenderCount()
    local count = 0
    for _, player in ipairs(players) do
        if not player.folded then count = count + 1 end
    end
    return count
end

local function activeCount()
    local count = 0
    for _, player in ipairs(players) do
        if canAct(player) then count = count + 1 end
    end
    return count
end

local function potSize()
    local pot = 0
    for _, player in ipairs(players) do pot = pot + player.totalContribution end
    return pot
end

local function putChipsIn(player, amount)
    local paid = math.min(amount, player.stack)
    if paid > 0 and player.human then
        local response, err = casinoTransaction("debit", paid)
        if not response then error("Casino debit failed: " .. tostring(err), 0) end
        player.stack = response.balance
    else
        player.stack = player.stack - paid
    end
    player.streetContribution = player.streetContribution + paid
    player.totalContribution = player.totalContribution + paid
    if player.stack == 0 then player.allIn = true end
    saveStacks()
    return paid
end

local function cardText(card)
    if not card then return "[??]" end
    local rank = card.value <= 10 and tostring(card.value) or RANK_GLYPHS[card.value]
    return "[" .. rank .. card.suit .. "]"
end

local function cardColor(card)
    if card and (card.suit == "H" or card.suit == "D") then return colors.red end
    return colors.white
end

local function formatCards(cards, hidden)
    local values = {}
    for index, card in ipairs(cards) do
        values[index] = hidden and "[##]" or cardText(card)
    end
    return #values > 0 and table.concat(values, "  ") or "--"
end

local function drawTable(message, revealBots)
    local width, height = term.getSize()
    drawHeader("HAND " .. handNumber .. "  /  " .. currentStreet:upper()
        .. "  /  POT " .. potSize())
    local felt = term.isColor() and colors.green or colors.black
    for row = 3, height - 3 do
        writeAt(1, row, string.rep(" ", width), colors.white, felt)
    end

    for seat = 2, SEAT_COUNT do
        local player = players[seat]
        local row = seat + 2
        local state = player.folded and "FOLDED" or player.allIn and "ALL-IN"
            or (player.streetContribution > 0 and ("BET " .. player.streetContribution) or "IN")
        local line = player.name .. "  " .. player.stack .. "  " .. state
        writeAt(2, row, line, player.folded and colors.lightGray or colors.white)
        writeAt(27, row, formatCards(player.cards or {}, not revealBots), colors.lightGray)
    end

    writeAt(2, 8, "BOARD", colors.yellow)
    for index, card in ipairs(board) do
        local x = 2 + (index - 1) * 9
        writeAt(x, 9, cardText(card), cardColor(card))
    end
    writeAt(2, 12, "YOUR HAND  " .. players[HERO].stack .. " CHIPS", colors.white)
    writeAt(2, 13, formatCards(players[HERO].cards or {}, false), colors.yellow)
    writeAt(2, 15, message or currentMessage, colors.lightGray)
end

local function evaluateFive(cards)
    local counts, ranks = {}, {}
    local flush = true
    for index, card in ipairs(cards) do
        counts[card.value] = (counts[card.value] or 0) + 1
        ranks[index] = card.value
        if index > 1 and card.suit ~= cards[1].suit then flush = false end
    end
    table.sort(ranks, function(left, right) return left > right end)

    local groups = {}
    for rank, count in pairs(counts) do
        table.insert(groups, { rank = rank, count = count })
    end
    table.sort(groups, function(left, right)
        if left.count == right.count then return left.rank > right.rank end
        return left.count > right.count
    end)

    local unique = {}
    for _, rank in ipairs(ranks) do
        if unique[#unique] ~= rank then table.insert(unique, rank) end
    end
    local straightHigh
    if #unique == 5 then
        if unique[1] - unique[5] == 4 then
            straightHigh = unique[1]
        elseif unique[1] == 14 and unique[2] == 5 and unique[3] == 4
            and unique[4] == 3 and unique[5] == 2 then
            straightHigh = 5
        end
    end

    local score = {}
    if flush and straightHigh then
        score = { 8, straightHigh }
    elseif groups[1].count == 4 then
        score = { 7, groups[1].rank, groups[2].rank }
    elseif groups[1].count == 3 and groups[2].count == 2 then
        score = { 6, groups[1].rank, groups[2].rank }
    elseif flush then
        score = { 5, ranks[1], ranks[2], ranks[3], ranks[4], ranks[5] }
    elseif straightHigh then
        score = { 4, straightHigh }
    elseif groups[1].count == 3 then
        score = { 3, groups[1].rank }
        for index = 2, #groups do table.insert(score, groups[index].rank) end
    elseif groups[1].count == 2 and groups[2].count == 2 then
        score = { 2, math.max(groups[1].rank, groups[2].rank), math.min(groups[1].rank, groups[2].rank), groups[3].rank }
    elseif groups[1].count == 2 then
        score = { 1, groups[1].rank }
        for index = 2, #groups do table.insert(score, groups[index].rank) end
    else
        score = { 0, ranks[1], ranks[2], ranks[3], ranks[4], ranks[5] }
    end
    return score
end

local function compareScores(left, right)
    for index = 1, math.max(#left, #right) do
        local leftValue, rightValue = left[index] or 0, right[index] or 0
        if leftValue ~= rightValue then return leftValue > rightValue and 1 or -1 end
    end
    return 0
end

local function bestHand(cards)
    local chosen, best = {}, nil
    local function selectCards(startAt)
        if #chosen == 5 then
            local score = evaluateFive(chosen)
            if not best or compareScores(score, best) > 0 then best = score end
            return
        end
        local needed = 5 - #chosen
        for index = startAt, #cards - needed + 1 do
            table.insert(chosen, cards[index])
            selectCards(index + 1)
            table.remove(chosen)
        end
    end
    selectCards(1)
    return best
end

local function evaluatePlayer(player)
    local cards = {}
    for _, card in ipairs(player.cards) do table.insert(cards, card) end
    for _, card in ipairs(board) do table.insert(cards, card) end
    return bestHand(cards)
end

local function handName(score)
    return CATEGORY_NAMES[score[1]] or "HAND"
end

local function botStrength(player)
    if #board >= 3 then
        local score = evaluatePlayer(player)
        local strength = score[1] / 8
        if #board < 5 and score[1] <= 1 then
            local suits, ranks = {}, {}
            for _, card in ipairs(player.cards) do
                suits[card.suit] = (suits[card.suit] or 0) + 1
                ranks[card.value] = true
            end
            for _, card in ipairs(board) do
                suits[card.suit] = (suits[card.suit] or 0) + 1
                ranks[card.value] = true
            end
            for _, count in pairs(suits) do
                if count == 4 then strength = strength + 0.13; break end
            end
            local rankList = {}
            for rank in pairs(ranks) do table.insert(rankList, rank) end
            table.sort(rankList)
            for index = 1, #rankList do
                local low = rankList[index]
                local high = rankList[index]
                for nextIndex = index + 1, #rankList do
                    high = rankList[nextIndex]
                    if high - low > 4 then break end
                    if nextIndex - index >= 3 then strength = strength + 0.1; break end
                end
            end
        end
        return math.min(strength, 1)
    end

    local first, second = player.cards[1].value, player.cards[2].value
    local high, low = math.max(first, second), math.min(first, second)
    if first == second then return 0.35 + high / 45 end
    local suited = player.cards[1].suit == player.cards[2].suit and 0.08 or 0
    local connected = high - low <= 2 and 0.06 or 0
    local faceBonus = high >= 11 and 0.07 or 0
    return math.min(0.12 + high / 42 + low / 110 + suited + connected + faceBonus, 0.82)
end

local function payPotToOne(winner)
    local amount = potSize()
    local payoutError
    if winner.human and amount > 0 then
        local response, err = casinoTransaction("credit", amount)
        if response then
            winner.stack = response.balance
        else
            payoutError = err
        end
    else
        winner.stack = winner.stack + amount
    end
    for _, player in ipairs(players) do
        player.totalContribution = 0
        player.streetContribution = 0
    end
    if payoutError then
        currentMessage = "PAYOUT PENDING  /  " .. tostring(payoutError)
    else
        currentMessage = winner.name .. " wins " .. amount .. " chips"
        if winner == players[HERO] then
            currentMessage = "YOU WIN " .. amount .. " CHIPS"
        end
    end
    handFinished = true
    saveStacks()
end

local function awardUncontested()
    for _, player in ipairs(players) do
        if not player.folded then
            payPotToOne(player)
            return
        end
    end
end

local function clockwiseWinners(winners)
    table.sort(winners, function(left, right)
        local leftDistance = (left - button) % SEAT_COUNT
        local rightDistance = (right - button) % SEAT_COUNT
        if leftDistance == 0 then leftDistance = SEAT_COUNT end
        if rightDistance == 0 then rightDistance = SEAT_COUNT end
        return leftDistance < rightDistance
    end)
end

local function settleShowdown()
    local highest, highestSeat, highestCount, secondHighest = 0, nil, 0, 0
    for seat, player in ipairs(players) do
        local contribution = player.totalContribution
        if contribution > highest then
            secondHighest = highest
            highest, highestSeat, highestCount = contribution, seat, 1
        elseif contribution == highest then
            highestCount = highestCount + 1
        elseif contribution > secondHighest then
            secondHighest = contribution
        end
    end
    local heroRefund = 0
    local payoutError
    if highestCount == 1 and highestSeat and highest > secondHighest then
        local refund = highest - secondHighest
        players[highestSeat].totalContribution = secondHighest
        if highestSeat == HERO then
            heroRefund = heroRefund + refund
        else
            players[highestSeat].stack = players[highestSeat].stack + refund
        end
    end

    local levels = {}
    for _, player in ipairs(players) do
        if player.totalContribution > 0 then levels[player.totalContribution] = true end
    end
    local sortedLevels = {}
    for level in pairs(levels) do table.insert(sortedLevels, level) end
    table.sort(sortedLevels)

    local previousLevel = 0
    local heroWon = 0
    local winnerNames = {}
    for _, level in ipairs(sortedLevels) do
        local contributors, eligible = {}, {}
        for seat, player in ipairs(players) do
            if player.totalContribution >= level then
                table.insert(contributors, seat)
                if not player.folded then table.insert(eligible, seat) end
            end
        end
        local sidePot = (level - previousLevel) * #contributors
        previousLevel = level
        local bestScore, winners = nil, {}
        for _, seat in ipairs(eligible) do
            local score = evaluatePlayer(players[seat])
            local comparison = bestScore and compareScores(score, bestScore) or 1
            if comparison > 0 then
                bestScore, winners = score, { seat }
            elseif comparison == 0 then
                table.insert(winners, seat)
            end
        end
        if #winners > 0 then
            clockwiseWinners(winners)
            local share = math.floor(sidePot / #winners)
            local remainder = sidePot - share * #winners
            for index, seat in ipairs(winners) do
                local payout = share + (index <= remainder and 1 or 0)
                if seat == HERO then
                    heroWon = heroWon + payout
                else
                    players[seat].stack = players[seat].stack + payout
                end
                local exists = false
                for _, name in ipairs(winnerNames) do
                    if name == players[seat].name then exists = true end
                end
                if not exists then table.insert(winnerNames, players[seat].name) end
            end
        end
    end

    local hero = players[HERO]
    local score = evaluatePlayer(hero)
    if heroWon + heroRefund > 0 then
        local response, err = casinoTransaction("credit", heroWon + heroRefund)
        if response then
            hero.stack = response.balance
        else
            payoutError = err
        end
    end
    if payoutError then
        currentMessage = "PAYOUT PENDING  /  " .. tostring(payoutError)
    elseif heroWon > 0 then
        currentMessage = table.concat(winnerNames, ", ") .. " win | YOU " .. handName(score)
    else
        currentMessage = table.concat(winnerNames, ", ") .. " win the pot"
    end
    for _, player in ipairs(players) do
        player.totalContribution = 0
        player.streetContribution = 0
    end
    handFinished = true
    saveStacks()
end

local function showPlayerCards(revealBots)
    for _, player in ipairs(players) do
        if player.cards then
            if revealBots or player.folded then
                player.showCards = true
            end
        end
    end
end

local function finishIfOneLeft()
    if contenderCount() <= 1 then
        awardUncontested()
        showPlayerCards(true)
        return true
    end
    return false
end

local function legalRaise(player, currentBet, minRaise)
    local amountDue = math.max(0, currentBet - player.streetContribution)
    return player.stack >= amountDue + minRaise
end

local function drawActionButtons(player, currentBet, minRaise)
    local amountDue = math.max(0, currentBet - player.streetContribution)
    local callLabel = amountDue == 0 and "CHECK" or (amountDue >= player.stack and "CALL ALL-IN" or "CALL " .. amountDue)
    local options = {
        { id = "fold", label = "FOLD", key = keys.f },
        { id = "call", label = callLabel, key = amountDue == 0 and keys.c or keys.c },
    }
    if legalRaise(player, currentBet, minRaise) then
        local label = currentBet == 0 and ("BET " .. minRaise) or ("RAISE TO " .. (currentBet + minRaise))
        table.insert(options, { id = "raise", label = label, key = keys.r })
    end
    return drawButtons(options)
end

local function applyAction(seat, action, pending, currentBet, minRaise)
    local player = players[seat]
    local amountDue = math.max(0, currentBet - player.streetContribution)
    if action == "fold" then
        player.folded = true
        player.action = "FOLDS"
    elseif action == "call" then
        local paid = putChipsIn(player, amountDue)
        player.action = amountDue == 0 and "CHECKS" or (player.allIn and "CALLS ALL-IN" or "CALLS " .. paid)
    elseif action == "raise" then
        local oldBet = currentBet
        local target = currentBet + minRaise
        local amount = target - player.streetContribution
        putChipsIn(player, amount)
        currentBet = player.streetContribution
        minRaise = currentBet - oldBet
        player.action = "RAISES TO " .. currentBet
        for otherSeat, other in ipairs(players) do
            if otherSeat ~= seat and canAct(other) and other.streetContribution < currentBet then
                pending[otherSeat] = true
            end
        end
    end
    return currentBet, minRaise
end

local function botDecision(player, currentBet, minRaise)
    local due = math.max(0, currentBet - player.streetContribution)
    local strength = botStrength(player)
    if due == 0 then
        if legalRaise(player, currentBet, minRaise) and strength > 0.72 and math.random() < 0.42 then
            return "raise"
        end
        if legalRaise(player, currentBet, minRaise) and strength < 0.18 and math.random() < 0.04 then
            return "raise"
        end
        return "call"
    end

    local potOdds = due / math.max(1, potSize() + due)
    if strength < math.max(0.16, potOdds * 0.72) then return "fold" end
    if legalRaise(player, currentBet, minRaise) and strength > 0.78 and math.random() < 0.28 then
        return "raise"
    end
    return "call"
end

local function runBettingRound(firstToAct, currentBet, minRaise)
    local pending = {}
    for seat, player in ipairs(players) do
        if canAct(player) then pending[seat] = true end
    end
    local lastActor = (firstToAct - 2) % SEAT_COUNT + 1

    while true do
        if finishIfOneLeft() then return currentBet, minRaise end
        local anyPending = false
        for seat in pairs(pending) do
            if canAct(players[seat]) then anyPending = true else pending[seat] = nil end
        end
        if not anyPending then break end

        local actor
        for _ = 1, SEAT_COUNT do
            lastActor = nextSeat(lastActor)
            if pending[lastActor] and canAct(players[lastActor]) then
                actor = lastActor
                break
            end
        end
        if not actor then break end

        local player = players[actor]
        pending[actor] = nil
        local action
        if player.human then
            local due = math.max(0, currentBet - player.streetContribution)
            drawTable("YOUR TURN  /  " .. (due == 0 and "CHECK OR BET" or ("TO CALL " .. due)), false)
            action = waitForAction(drawActionButtons(player, currentBet, minRaise))
        else
            os.sleep(0.35)
            action = botDecision(player, currentBet, minRaise)
        end
        currentBet, minRaise = applyAction(actor, action, pending, currentBet, minRaise)
        currentMessage = player.name .. " " .. (player.action or action):lower()
        drawTable(currentMessage, false)
        os.sleep(0.18)
    end
    return currentBet, minRaise
end

local function resetStreetContributions()
    for _, player in ipairs(players) do
        player.streetContribution = 0
        player.action = nil
    end
end

local function dealBoardCards(count)
    for _ = 1, count do table.insert(board, table.remove(deck)) end
end

local function allRemainingAllIn()
    for _, player in ipairs(players) do
        if not player.folded and not player.allIn then return false end
    end
    return true
end

local function runStreet(name, firstToAct, startingBet, minRaise)
    currentStreet = name
    local currentBet = startingBet
    runBettingRound(firstToAct, currentBet, minRaise)
    return contenderCount() > 1
end

local function playHand()
    handNumber = handNumber + 1
    handFinished = false
    currentStreet = "pre-flop"
    board, deck = {}, makeDeck()
    for _, player in ipairs(players) do
        player.cards = {}
        player.folded = player.stack == 0
        player.allIn = false
        player.streetContribution = 0
        player.totalContribution = 0
        player.action = nil
        player.showCards = false
    end
    for _ = 1, 2 do
        for offset = 1, SEAT_COUNT do
            local seat = (button + offset - 1) % SEAT_COUNT + 1
            if players[seat].stack > 0 then drawCard(players[seat]) end
        end
    end

    local smallBlindSeat = nextFundedSeat(button)
    local bigBlindSeat = nextFundedSeat(smallBlindSeat)
    if not smallBlindSeat or not bigBlindSeat then return false end
    putChipsIn(players[smallBlindSeat], SMALL_BLIND)
    players[smallBlindSeat].action = "SMALL BLIND"
    putChipsIn(players[bigBlindSeat], BIG_BLIND)
    players[bigBlindSeat].action = "BIG BLIND"

    local firstPreflop = nextSeat(bigBlindSeat)
    if not runStreet("pre-flop", firstPreflop, math.max(players[smallBlindSeat].streetContribution,
        players[bigBlindSeat].streetContribution), BIG_BLIND) then
        showPlayerCards(true)
        return true
    end

    local streets = {
        { name = "flop", count = 3 },
        { name = "turn", count = 1 },
        { name = "river", count = 1 },
    }
    for _, street in ipairs(streets) do
        if allRemainingAllIn() then
            while #board < 5 do dealBoardCards(#board == 0 and 3 or 1) end
            break
        end
        dealBoardCards(street.count)
        resetStreetContributions()
        if not runStreet(street.name, nextSeat(button), 0, BIG_BLIND) then
            showPlayerCards(true)
            return true
        end
    end

    currentStreet = "showdown"
    showPlayerCards(true)
    settleShowdown()
    return true
end

local function countFundedPlayers()
    local count = 0
    for _, player in ipairs(players) do
        if player.stack > 0 then count = count + 1 end
    end
    return count
end

local function beginNextHand()
    if players[HERO].stack < BIG_BLIND then
        local response, err = casinoTransaction("rebuy")
        if not response then
            currentMessage = "REBUY FAILED  /  " .. tostring(err)
            return false
        end
        players[HERO].stack = response.balance
        currentMessage = "Casino rebuy issued. Your balance is " .. response.balance .. "."
    end
    if countFundedPlayers() < 2 then
        for seat = 2, SEAT_COUNT do players[seat].stack = STARTING_STACK end
        currentMessage = "Bots reloaded. They each start with " .. STARTING_STACK .. "."
        saveStacks()
    end
    button = nextFundedSeat(button) or 1
    return playHand()
end

local function drawLobby()
    drawHeader("FOUR SEATS  /  YOU + THREE BOTS")
    local width, height = term.getSize()
    local felt = term.isColor() and colors.green or colors.black
    for row = 3, height - 3 do
        writeAt(1, row, string.rep(" ", width), colors.white, felt)
    end
    writeAt(2, 5, "TEXAS HOLD'EM  /  BLINDS " .. SMALL_BLIND .. " - " .. BIG_BLIND, colors.yellow)
    if handNumber > 0 then
        writeAt(2, 7, "LAST BOARD  " .. formatCards(board, false), colors.white)
        for seat, player in ipairs(players) do
            local row = 8 + seat
            writeAt(2, row, player.name .. "  " .. player.stack, colors.lightGray)
            writeAt(22, row, formatCards(player.cards or {}, false), colors.white)
        end
    else
        for seat, player in ipairs(players) do
            writeAt(2, 8 + seat, player.name .. "  " .. player.stack .. " chips", colors.lightGray)
        end
    end
    writeAt(2, 15, currentMessage, colors.white)
    return drawButtons({
        { id = "deal", label = "DEAL NEXT HAND", key = keys.enter },
        { id = "reset", label = "RESET TABLE", key = keys.r },
        { id = "quit", label = "QUIT", key = keys.q },
    })
end

math.randomseed(os.epoch("utc") % 2147483647 + os.getComputerID())
loadStacks()

while true do
    if handFinished then
        local choice = waitForAction(drawLobby())
        if choice == "deal" then
            beginNextHand()
        elseif choice == "reset" then
            for seat = 2, SEAT_COUNT do players[seat].stack = STARTING_STACK end
            if players[HERO].stack < BIG_BLIND then
                local response, err = casinoTransaction("rebuy")
                if response then
                    players[HERO].stack = response.balance
                    currentMessage = "Casino rebuy issued. Your balance is " .. response.balance .. "."
                else
                    currentMessage = "REBUY FAILED  /  " .. tostring(err)
                end
            else
                currentMessage = "Bot stacks reset."
            end
            handNumber = 0
            saveStacks()
        elseif choice == "quit" then
            break
        end
    end
end

saveStacks()
clearScreen()
