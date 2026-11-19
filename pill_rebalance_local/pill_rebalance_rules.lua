local rules = {}

function rules.teleport(horse, randomInt)
    local specialChance = horse and 80 or 40
    if randomInt(100) >= specialChance then
        return "normal"
    end
    if horse and randomInt(100000) < 1117 then
        return "certificate"
    end
    return "special"
end

-- Vanilla Telepills adds the Black Market to its uniform target list 2% of the time.
-- That list then holds every floor room plus I AM ERROR and the Black Market.
function rules.blackMarket(roomCount, randomInt)
    if randomInt(100) >= 2 then
        return false
    end
    return randomInt(math.max(roomCount, 0) + 2) == 0
end

function rules.fireDelay(baseDelay, units)
    return 30 / (30 / (baseDelay + 1) + units * 0.35) - 1
end

function rules.drawEffects(candidates, count, randomInt)
    local picked = {}
    for i = 1, math.min(count, #candidates) do
        picked[i] = table.remove(candidates, 1 + randomInt(#candidates))
    end
    return picked
end

return rules
