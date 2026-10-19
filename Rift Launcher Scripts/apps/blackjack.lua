if type(riftCasino) ~= "table" then
    shell.run("casino.lua", "blackjack")
    return
end
local casino = riftCasino
local MIN_BET = 2
local balance = 0
local bet = 20
local mode = "betting"
local deck, playerHand, dealerHand = {}, {}, {}
local dealerRevealed = false
local lastResult = ""
local gameMessage = "Set your bet, then deal."

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
    writeAt(2, 1, "BLACKJACK", colors.white, colors.cyan)
    writeAt(2, 2, subtitle, colors.lightGray)
end

local function drawButtons(options)
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
    local response, err = casino.transact(action, amount)
    if response then balance = response.balance end
    return response, err
end

local function connectToCasino()
    local response, err = casino.getBalance()
    if not response then error(err) end
    balance = response.balance
end

local function makeDeck()
    local suits = { "S", "H", "D", "C" }
    local ranks = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }
    local cards = {}
    for _, suit in ipairs(suits) do
        for _, rank in ipairs(ranks) do
            table.insert(cards, { suit = suit, rank = rank })
        end
    end
    for index = #cards, 2, -1 do
        local swapIndex = math.random(index)
        cards[index], cards[swapIndex] = cards[swapIndex], cards[index]
    end
    return cards
end

local function drawCardFromDeck(hand)
    table.insert(hand, table.remove(deck))
end

local function handValue(hand)
    local total, aces = 0, 0
    for _, card in ipairs(hand) do
        if card.rank == "A" then
            total = total + 11
            aces = aces + 1
        elseif card.rank == "K" or card.rank == "Q" or card.rank == "J" then
            total = total + 10
        else
            total = total + tonumber(card.rank)
        end
    end
    while total > 21 and aces > 0 do
        total = total - 10
        aces = aces - 1
    end
    return total, aces > 0
end

local function isBlackjack(hand)
    return #hand == 2 and handValue(hand) == 21
end

local function drawCard(x, y, card, hidden)
    local width = term.getSize()
    if x + 8 > width then return end
    if hidden then
        writeAt(x, y, "+-------+", colors.white, colors.blue)
        writeAt(x, y + 1, "|#######|", colors.white, colors.blue)
        writeAt(x, y + 2, "|###?###|", colors.white, colors.blue)
        writeAt(x, y + 3, "|#######|", colors.white, colors.blue)
        writeAt(x, y + 4, "+-------+", colors.white, colors.blue)
        return
    end
    local suitColor = (card.suit == "H" or card.suit == "D") and colors.red or colors.white
    local leftRank = #card.rank == 1 and (card.rank .. " ") or card.rank
    local rightRank = #card.rank == 1 and (" " .. card.rank) or card.rank
    writeAt(x, y, "+-------+", colors.white)
    writeAt(x, y + 1, "|" .. leftRank .. "     |", suitColor)
    writeAt(x, y + 2, "|   " .. card.suit .. "   |", suitColor)
    writeAt(x, y + 3, "|     " .. rightRank .. "|", suitColor)
    writeAt(x, y + 4, "+-------+", colors.white)
end

local function drawHand(hand, y, hideSecond)
    local width = term.getSize()
    local visible = math.min(#hand, math.floor(width / 10))
    for index = 1, visible do
        drawCard(2 + (index - 1) * 10, y, hand[index], hideSecond and index == 2)
    end
    if #hand > visible then
        writeAt(2, y + 4, "+" .. (#hand - visible) .. " more cards", colors.lightGray)
    end
end

local function drawFelt()
    local width, height = term.getSize()
    local felt = term.isColor() and colors.green or colors.black
    for row = 3, height - 3 do
        writeAt(1, row, string.rep(" ", width), colors.white, felt)
    end
end

local function drawBetting()
    drawHeader("AUTOMATED DEALER  /  HITS SOFT 17")
    drawFelt()
    writeAt(2, 4, "CHIPS  " .. balance, colors.white)
    writeAt(2, 6, "YOUR BET  " .. bet, colors.yellow)
    writeAt(2, 8, "Choose a wager. Chips are local game points.", colors.lightGray)
    writeAt(2, 10, "Blackjack pays 3:2. Dealer stands on hard 17.", colors.white)
    if lastResult ~= "" then writeAt(2, 13, lastResult, colors.lime) end
    if balance < MIN_BET then
        return drawButtons({
            { id = "reset", label = "RESET CHIPS", key = keys.r },
            { id = "quit", label = "QUIT", key = keys.q },
        })
    end
    return drawButtons({
        { id = "less10", label = "-10", key = keys.left },
        { id = "less2", label = "-2", key = keys.down },
        { id = "more2", label = "+2", key = keys.up },
        { id = "more10", label = "+10", key = keys.right },
        { id = "max", label = "MAX", key = keys.m },
        { id = "deal", label = "DEAL", key = keys.enter },
        { id = "quit", label = "QUIT", key = keys.q },
    })
end

local function drawGame(message)
    drawHeader("CHIPS  " .. balance .. "  /  BET  " .. bet)
    drawFelt()
    local dealerTotal = handValue(dealerHand)
    local playerTotal = handValue(playerHand)
    local dealerLabel = dealerRevealed and ("DEALER  " .. dealerTotal) or ("DEALER  " .. dealerHand[1].rank .. " + ?")
    writeAt(2, 4, dealerLabel, colors.white)
    drawHand(dealerHand, 5, not dealerRevealed)
    writeAt(2, 11, "YOU  " .. playerTotal, playerTotal > 21 and colors.red or colors.white)
    drawHand(playerHand, 12, false)
    writeAt(2, 17, message or gameMessage, colors.yellow)
end

local function finishRound(result, natural)
    local payout = 0
    if result == "blackjack" then
        local profit = bet * 3 / 2
        payout = bet + profit
        lastResult = "BLACKJACK!  +" .. profit .. " chips"
    elseif result == "win" then
        payout = bet * 2
        lastResult = "YOU WIN  +" .. bet .. " chips"
    elseif result == "push" then
        payout = bet
        lastResult = "PUSH  /  BET RETURNED"
    else
        lastResult = natural and "DEALER BLACKJACK  /  YOU LOSE" or "DEALER WINS"
    end
    if payout > 0 then
        local response, err = casinoTransaction("credit", payout)
        if response then
            balance = response.balance
        else
            lastResult = "PAYOUT FAILED  /  " .. tostring(err)
        end
    end
    mode = "result"
end

local function resolveShowdown()
    local playerTotal = handValue(playerHand)
    local dealerTotal = handValue(dealerHand)
    if dealerTotal > 21 or playerTotal > dealerTotal then
        finishRound("win")
    elseif playerTotal == dealerTotal then
        finishRound("push")
    else
        finishRound("lose")
    end
end

local function playDealer()
    dealerRevealed = true
    mode = "dealer"
    drawGame("Dealer reveals and plays...")
    local total, soft = handValue(dealerHand)
    while total < 17 or total == 17 and soft do
        os.sleep(0.45)
        drawCardFromDeck(dealerHand)
        drawGame("Dealer hits...")
        total, soft = handValue(dealerHand)
    end
    os.sleep(0.35)
    resolveShowdown()
end

local function startRound()
    if bet < MIN_BET or bet > balance then return end
    local response, err = casinoTransaction("debit", bet)
    if not response then
        lastResult = "BET REJECTED  /  " .. tostring(err)
        return
    end
    balance = response.balance
    deck = makeDeck()
    playerHand, dealerHand = {}, {}
    dealerRevealed = false
    lastResult = ""
    drawCardFromDeck(playerHand)
    drawCardFromDeck(dealerHand)
    drawCardFromDeck(playerHand)
    drawCardFromDeck(dealerHand)
    mode = "playing"

    local playerNatural = isBlackjack(playerHand)
    local dealerNatural = isBlackjack(dealerHand)
    if playerNatural or dealerNatural then
        dealerRevealed = true
        if playerNatural and dealerNatural then
            finishRound("push")
        elseif playerNatural then
            finishRound("blackjack")
        else
            finishRound("lose", true)
        end
    else
        gameMessage = "Choose hit, stand, or double down."
    end
end

local function hit()
    drawCardFromDeck(playerHand)
    local total = handValue(playerHand)
    if total > 21 then
        dealerRevealed = true
        finishRound("lose")
    elseif total == 21 then
        playDealer()
    else
        gameMessage = "Choose hit or stand."
    end
end

local function doubleDown()
    if #playerHand ~= 2 or balance < bet then return end
    local response, err = casinoTransaction("debit", bet)
    if not response then
        gameMessage = "Double-down rejected: " .. tostring(err)
        return
    end
    balance = response.balance
    bet = bet * 2
    drawCardFromDeck(playerHand)
    if handValue(playerHand) > 21 then
        dealerRevealed = true
        finishRound("lose")
    else
        playDealer()
    end
end

local function drawPlayingButtons()
    local options = {
        { id = "hit", label = "HIT", key = keys.h },
        { id = "stand", label = "STAND", key = keys.s },
    }
    if #playerHand == 2 and balance >= bet then
        table.insert(options, { id = "double", label = "DOUBLE", key = keys.d })
    end
    return drawButtons(options)
end

local function adjustBet(action)
    if action == "less10" then bet = math.max(MIN_BET, bet - 10)
    elseif action == "less2" then bet = math.max(MIN_BET, bet - 2)
    elseif action == "more2" then bet = math.min(balance, bet + 2)
    elseif action == "more10" then bet = math.min(balance, bet + 10)
    elseif action == "max" then bet = balance end
end

math.randomseed(os.epoch("utc") % 2147483647 + os.getComputerID())
connectToCasino()
bet = math.min(bet, math.max(balance, MIN_BET))

while true do
    if mode == "betting" then
        local choice = waitForAction(drawBetting())
        if choice == "deal" then
            startRound()
        elseif choice == "reset" then
            local response, err = casinoTransaction("rebuy")
            if response then
                balance = response.balance
                bet = 20
                lastResult = ""
            else
                lastResult = "REBUY FAILED  /  " .. tostring(err)
            end
        elseif choice == "quit" then
            break
        else
            adjustBet(choice)
        end
    elseif mode == "playing" then
        drawGame(gameMessage)
        local choice = waitForAction(drawPlayingButtons())
        if choice == "hit" then
            hit()
        elseif choice == "stand" then
            playDealer()
        elseif choice == "double" then
            doubleDown()
        end
    elseif mode == "dealer" then
        playDealer()
    elseif mode == "result" then
        drawGame(lastResult)
        local choice = waitForAction(drawButtons({
            { id = "next", label = "NEXT HAND", key = keys.enter },
            { id = "bet", label = "CHANGE BET", key = keys.b },
            { id = "quit", label = "QUIT", key = keys.q },
        }))
        if choice == "next" or choice == "bet" then
            bet = math.min(bet, math.max(balance, MIN_BET))
            mode = "betting"
        elseif choice == "quit" then
            break
        end
    end
end

clearScreen()
