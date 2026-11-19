local mod = RegisterMod("Pill Rebalance (Local)", 1)
local rules = include("pill_rebalance_rules")
local redRooms = include("pill_rebalance_red_rooms")
local json = require("json")
local game = Game()
local effects, colors, flags = PillEffect, PillColor, UseFlag
local telepills = effects.PILLEFFECT_TELEPILLS
local tearsUp = effects.PILLEFFECT_TEARS_UP
local foundPills = effects.PILLEFFECT_I_FOUND_PILLS
local customTeleport = Isaac.GetPillEffectByName("Telepills (Rebalanced)")
local customTears = Isaac.GetPillEffectByName("Tears Up (Rebalanced)")
local replacement = {}
local vanillaEffect = {}
for base, custom in pairs({[telepills] = customTeleport, [tearsUp] = customTears}) do
    if custom >= effects.NUM_PILL_EFFECTS then
        replacement[base] = custom
        vanillaEffect[custom] = base
    end
end
local scriptedUse = false
local quietPill = flags.USE_NOANIM | flags.USE_NOANNOUNCER | flags.USE_NOHUD
local rng = RNG()
local startSeed
local tearUnits = {}
local eidRegistered = false
local visibleWithIcon = (1 << 0) | (1 << 2)
-- Red rooms that Ansuz generated on the current floor, keyed by grid index.
local ansuzFloorSeed
local ansuzGrids = {}

local function randomInt(limit)
    return rng:RandomInt(limit)
end

local function heldColor(player)
    return player:GetPill(0)
end

local function trackPocket(player)
    player:GetData().PillRebalanceColor = heldColor(player)
end

local function sourceColor(effect, player, useFlags, color)
    if type(color) == "number" and color > colors.PILL_NULL then
        return color
    end
    if (useFlags & flags.USE_NOHUD) ~= 0 then
        return colors.PILL_BLUE_BLUE
    end
    if (useFlags & flags.USE_MIMIC) ~= 0 then
        local current = heldColor(player)
        if current ~= colors.PILL_NULL and game:GetItemPool():GetPillEffect(current, player) == effect then
            return current
        end
    end

    local previous = player:GetData().PillRebalanceColor
    if previous and previous ~= colors.PILL_NULL
        and (previous & colors.PILL_COLOR_MASK) ~= colors.PILL_GOLD
        and game:GetItemPool():GetPillEffect(previous, player) == effect then
        return previous
    end
    return colors.PILL_BLUE_BLUE
end

local function playerKey(player)
    local target = GetPtrHash(player)
    for index = 0, game:GetNumPlayers() - 1 do
        if GetPtrHash(Isaac.GetPlayer(index)) == target then
            return tostring(index)
        end
    end
    return "seed:" .. tostring(player.InitSeed)
end

local function evaluateTears(player)
    player:AddCacheFlags(CacheFlag.CACHE_FIREDELAY)
    player:EvaluateItems()
end

local function grantTears(player, horse)
    local key = playerKey(player)
    tearUnits[key] = (tearUnits[key] or 0) + (horse and 2 or 1)
    evaluateTears(player)
end

local function getOrdinaryDestination()
    local level = game:GetLevel()
    local current = level:GetCurrentRoomDesc().ListIndex
    local rooms = level:GetRooms()
    local choices = {}
    local roomCount = 0
    for index = 0, rooms.Size - 1 do
        local desc = rooms:Get(index)
        if desc.Data and desc.SafeGridIndex >= 0 then
            local inDimension = level:GetRoomByIdx(desc.SafeGridIndex)
            if inDimension.Data and inDimension.ListIndex == desc.ListIndex then
                roomCount = roomCount + 1
                if desc.Data.Type == RoomType.ROOM_DEFAULT and desc.ListIndex ~= current then
                    choices[#choices + 1] = desc.SafeGridIndex
                end
            end
        end
    end
    if #choices > 0 then
        return choices[1 + randomInt(#choices)], roomCount
    end
    return nil, roomCount
end

local function teleportTo(player, roomIndex)
    game:StartRoomTransition(roomIndex, Direction.NO_DIRECTION, RoomTransitionAnim.TELEPORT, player, -1)
end

local function processVanillaPill(player, effect, color)
    scriptedUse = true
    local ok, err = pcall(player.UsePill, player, effect, color, quietPill)
    scriptedUse = false
    if not ok then
        error(err, 0)
    end
end

-- Special branch: rare Black Market, the engine's I AM ERROR roll, then the Repentance+ horse search.
local function doSpecialTeleport(player, baseColor, roomCount)
    if rules.blackMarket(roomCount, randomInt) then
        teleportTo(player, GridRooms.ROOM_BLACK_MARKET_IDX)
        return
    end
    local seed = 1 + randomInt(0x7ffffffe)
    if game:GetLevel():GetRandomRoomIndex(true, seed) == GridRooms.ROOM_ERROR_IDX then
        teleportTo(player, GridRooms.ROOM_ERROR_IDX)
    else
        processVanillaPill(player, telepills, baseColor | colors.PILL_GIANT_FLAG)
    end
end

local function doTeleport(player, horse, baseColor)
    local route = rules.teleport(horse, randomInt)
    if route == "certificate" then
        player:UseActiveItem(CollectibleType.COLLECTIBLE_DEATH_CERTIFICATE,
            flags.USE_NOANIM | flags.USE_NOCOSTUME | flags.USE_ALLOWNONMAIN, -1)
        return
    end

    local target, roomCount = getOrdinaryDestination()
    if route == "special" or not target then
        -- Without another ordinary room, fall back to the special branch instead of wasting the pill.
        doSpecialTeleport(player, baseColor, roomCount)
    else
        teleportTo(player, target)
    end
end

local function getAssignedEffects(player)
    local pool = game:GetItemPool()
    local assigned = {}
    for color = colors.PILL_BLUE_BLUE, colors.NUM_STANDARD_PILLS - 1 do
        -- Omitting the player retrieves the original assignment for this run.
        local base = pool:GetPillEffect(color)
        if base >= 0 then
            assigned[vanillaEffect[base] or base] = true
        end
        local effective = pool:GetPillEffect(color, player)
        if effective >= 0 then
            assigned[vanillaEffect[effective] or effective] = true
        end
    end
    return assigned
end

local function getOffPoolEffects(player)
    local assigned = getAssignedEffects(player)
    local config = Isaac.GetItemConfig()
    local greedMode = game:IsGreedMode()
    local candidates = {}
    for effect = 0, effects.NUM_PILL_EFFECTS - 1 do
        if effect ~= foundPills and not assigned[effect] then
            local pill = config:GetPillEffect(effect)
            if pill and pill:IsAvailable() and (not greedMode or pill.GreedModeAllowed) then
                candidates[#candidates + 1] = effect
            end
        end
    end
    return candidates
end

local function useOffPoolEffects(player, horse, baseColor)
    local picks = rules.drawEffects(getOffPoolEffects(player), horse and 2 or 1, randomInt)
    for _, effect in ipairs(picks) do
        if effect == telepills then
            doTeleport(player, false, baseColor)
        elseif effect == tearsUp then
            grantTears(player, false)
        else
            processVanillaPill(player, effect, baseColor)
        end
    end
end

local function onUse(_, effect, player, useFlags, pillColor)
    if scriptedUse then return end

    local color = sourceColor(effect, player, useFlags, pillColor)
    local horse = (color & colors.PILL_GIANT_FLAG) ~= 0
    local baseColor = color & colors.PILL_COLOR_MASK
    if baseColor == colors.PILL_NULL or baseColor == colors.PILL_GOLD then
        baseColor = colors.PILL_BLUE_BLUE
    end
    if effect == customTeleport then
        doTeleport(player, horse, baseColor)
    elseif effect == customTears then
        grantTears(player, horse)
        if (useFlags & flags.USE_NOANIM) == 0 then player:AnimateHappy() end
    elseif effect == foundPills then
        useOffPoolEffects(player, horse, baseColor)
    end
end

-- Ansuz is refused in Home and in the mirror world, where the floor's room indices differ.
local function ansuzAllowed()
    return game:GetLevel():GetStage() ~= LevelStage.STAGE8 and not game:GetRoom():IsMirrorWorld()
end

-- Boss rooms and the 4-3 shop never get red doors, matching the original generation rules.
local function isClosedRoom(room)
    local level = game:GetLevel()
    local stage = level:GetStage()
    if room.type == RoomType.ROOM_BOSS then
        local labyrinth = (level:GetCurses() & LevelCurse.CURSE_OF_LABYRINTH) ~= 0
        return stage ~= LevelStage.STAGE7
            and (not labyrinth or room.listIndex == level:GetLastBossRoomListIndex())
    end
    return room.type == RoomType.ROOM_SHOP and stage == LevelStage.STAGE4_3
end

local function snapshotFloor()
    local level = game:GetLevel()
    local rooms = level:GetRooms()
    local list = {}
    for index = 0, rooms.Size - 1 do
        local desc = rooms:Get(index)
        if desc.Data and desc.SafeGridIndex >= 0 then
            local writable = level:GetRoomByIdx(desc.SafeGridIndex)
            if writable.Data and writable.ListIndex == desc.ListIndex then
                list[#list + 1] = {
                    grid = desc.GridIndex,
                    shape = desc.Data.Shape,
                    doors = desc.Data.Doors,
                    type = desc.Data.Type,
                    listIndex = desc.ListIndex,
                    writable = writable,
                }
            end
        end
    end
    return list
end

-- Generates every red room reachable from the existing floor and shows it on the map.
-- The doors into those rooms are hidden again (see hideAnsuzDoors) so they still have to be
-- opened with Red Key, Cracked Key or Soul of Cain, as if the rooms did not exist yet.
local function revealAnsuzFloor()
    local level = game:GetLevel()
    local seed = level:GetDungeonPlacementSeed()
    if ansuzFloorSeed ~= seed then
        ansuzFloorSeed = seed
        ansuzGrids = {}
    end
    redRooms.generate({
        rooms = snapshotFloor,
        isClosed = isClosedRoom,
        roomExists = function(grid) return level:GetRoomByIdx(grid).Data ~= nil end,
        makeDoor = function(grid, slot) return level:MakeRedRoomDoor(grid, slot) end,
        onCreated = function(grid) ansuzGrids[grid] = false end,
    })
    for _, room in ipairs(snapshotFloor()) do
        room.writable.DisplayFlags = room.writable.DisplayFlags | visibleWithIcon
    end
    level:UpdateVisibility()
end

local hiddenSlots = {}
local openingSlots = {}
local invisibleDoor = Color(1, 1, 1, 0)
local doorOutline = Sprite()
doorOutline:Load("gfx/1000.154_door outline.anm2", true)
doorOutline:Play("Idle", true)

local function ansuzActive()
    return ansuzFloorSeed ~= nil and next(ansuzGrids) ~= nil
        and game:GetLevel():GetDungeonPlacementSeed() == ansuzFloorSeed
end

local function holdingOpener()
    for index = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(index)
        if player:HasCollectible(CollectibleType.COLLECTIBLE_RED_KEY) then return true end
        for pocket = 0, 3 do
            local card = player:GetCard(pocket)
            if card == Card.CARD_SOUL_CAIN or card == Card.CARD_CRACKED_KEY then return true end
        end
    end
    return false
end

local function keepDoorsHidden()
    local room = game:GetRoom()
    for slot, entry in pairs(openingSlots) do
        local door = room:GetDoor(slot)
        if door and door.TargetRoomIndex == entry.target then
            local elapsed = game:GetFrameCount() - entry.frame
            local progress = math.min(1, (elapsed + 1) / 8)
            door:GetSprite().Color = Color.Lerp(invisibleDoor, entry.color, progress)
            if progress < 1 then
                door.CollisionClass = GridCollisionClass.COLLISION_WALL
            else
                door.CollisionClass = GridCollisionClass.COLLISION_NONE
                openingSlots[slot] = nil
            end
        else
            openingSlots[slot] = nil
        end
    end
    if next(hiddenSlots) == nil then return end
    doorOutline:Update()
    for slot, entry in pairs(hiddenSlots) do
        local door = room:GetDoor(slot)
        if door and door.TargetRoomIndex == entry.target then
            local sprite = door:GetSprite()
            if not entry.color then
                entry.color, entry.extra = Color.Lerp(sprite.Color, sprite.Color, 0), door.ExtraVisible
            end
            if door.State ~= DoorState.STATE_CLOSED or door:IsOpen() then
                door:Close(true)
                door.State = DoorState.STATE_CLOSED
                sprite:Play("Closed", true)
            end
            door.CollisionClass = GridCollisionClass.COLLISION_WALL
            sprite.Color = invisibleDoor
            door.ExtraVisible = false
        end
    end
end

local function renderDoorOutlines()
    if next(hiddenSlots) == nil or not holdingOpener() then return end
    local room = game:GetRoom()
    for slot, entry in pairs(hiddenSlots) do
        local door = room:GetDoor(slot)
        if door and door.TargetRoomIndex == entry.target then
            doorOutline.Rotation = (slot % 4 - 1) * 90
            doorOutline:Render(Isaac.WorldToScreen(room:GetDoorSlotPosition(slot)))
        end
    end
end

local function hideAnsuzDoors()
    if not ansuzActive() then return end
    local level = game:GetLevel()
    local desc = level:GetCurrentRoomDesc()
    if not desc.Data or desc.SafeGridIndex < 0 or not ansuzAllowed()
        or level:GetRoomByIdx(desc.SafeGridIndex, 0).ListIndex ~= desc.ListIndex then return end
    -- Teleporting straight into an unopened room opens it.
    if ansuzGrids[desc.SafeGridIndex] == false then ansuzGrids[desc.SafeGridIndex] = true end
    for slot = 0, 7 do
        local target = redRooms.slotTarget(desc.GridIndex, desc.Data.Shape, slot)
        if target and ansuzGrids[target] == false and not hiddenSlots[slot] then
            hiddenSlots[slot] = {target = target}
        end
    end
    keepDoorsHidden()
end

local function enterAnsuzRoom()
    hiddenSlots = {}
    openingSlots = {}
    hideAnsuzDoors()
end

local function openSealedDoor(slot)
    local entry = hiddenSlots[slot]
    local door = game:GetRoom():GetDoor(slot)
    if not door or not entry or door.TargetRoomIndex ~= entry.target then return end
    local sprite = door:GetSprite()
    local color = entry.color or Color(1, 1, 1, 1)
    if color.A == 0 then color = Color(1, 1, 1, 1) end
    if entry.extra ~= nil then door.ExtraVisible = entry.extra end
    door:SetLocked(false)
    door.State = DoorState.STATE_CLOSED
    sprite:Play("Closed", true)
    door:Open()
    local animation = door.OpenAnimation
    sprite:Play(animation and animation ~= "" and animation or "Open", true)
    sprite.Color = Color.Lerp(invisibleDoor, color, 1 / 8)
    door.CollisionClass = GridCollisionClass.COLLISION_WALL
    openingSlots[slot] = {target = entry.target, color = color, frame = game:GetFrameCount()}
    ansuzGrids[entry.target] = true
    hiddenSlots[slot] = nil
    return true
end

local function openNearbyDoor(player)
    local room = game:GetRoom()
    local nearest, maxDistance = nil, 64
    for slot, entry in pairs(hiddenSlots) do
        local door = room:GetDoor(slot)
        if door and door.TargetRoomIndex == entry.target then
            local distance = player.Position:Distance(room:GetDoorSlotPosition(slot))
            if distance < maxDistance then nearest, maxDistance = slot, distance end
        end
    end
    if nearest then return openSealedDoor(nearest) end
end

local function useSealedRedKey(player)
    if player:GetData().PillRebalanceKeyFrame == game:GetFrameCount() then return end
    if openNearbyDoor(player) then
        player:GetData().PillRebalanceKeyFrame = game:GetFrameCount()
        return true
    end
end

local function checkRedKeyButton(player)
    if next(hiddenSlots) == nil or not player.ControlsEnabled or game:IsPaused() then return end
    local slot
    if Input.IsActionTriggered(ButtonAction.ACTION_ITEM, player.ControllerIndex) then
        slot = ActiveSlot.SLOT_PRIMARY
    elseif player:GetCard(0) == 0 and player:GetPill(0) == 0 and
        Input.IsActionTriggered(ButtonAction.ACTION_PILLCARD, player.ControllerIndex) then
        slot = ActiveSlot.SLOT_POCKET
    end
    if not slot or player:GetActiveItem(slot) ~= CollectibleType.COLLECTIBLE_RED_KEY then return end
    local charge = player:GetActiveCharge(slot) + player:GetBatteryCharge(slot)
    if charge >= 4 and useSealedRedKey(player) then
        player:DischargeActiveItem(slot)
        player:AnimateCollectible(CollectibleType.COLLECTIBLE_RED_KEY, "UseItem", "PlayerPickup")
    end
end

local function registerDescriptions()
    if eidRegistered or not EID then return end
    eidRegistered = true
    local function add(id, nameZh, regularZh, horseZh, nameEn, regularEn, horseEn)
        if id < 0 then return end
        EID:addPill(id, regularZh, nameZh, "zh_cn")
        EID:addHorsePill(id, horseZh, nameZh, "zh_cn")
        EID:addPill(id, regularEn, nameEn, "en_us")
        EID:addHorsePill(id, horseEn, nameEn, "en_us")
    end
    add(customTeleport, "传送胶囊", "40%进入特殊房间（可能进入错误房，极小概率进入黑市），其余传送至本层普通房间",
        "80%进入特殊房间（可能进入错误房，极小概率进入黑市），该分支有1.117%前往死亡证明房间#其余传送至本层普通房间",
        "Telepills", "40% to a special room, possibly I AM ERROR or, very rarely, the Black Market. Otherwise, a normal room on this floor",
        "80% to a special room. That branch includes I AM ERROR, a very rare Black Market, and a 1.117% chance to enter the Death Certificate area")
    add(customTears, "射速上升", "射速修正+0.35，可突破软上限", "射速修正+0.70，可突破软上限",
        "Tears Up", "+0.35 uncapped tears", "+0.70 uncapped tears")
    add(foundPills, "我找到枚怪药", "随机触发1种本局药池外的药效", "随机触发2种不同的本局药池外药效",
        "I Found Pills", "Triggers 1 random pill effect outside this run's pool",
        "Triggers 2 distinct random pill effects outside this run's pool")
    EID:addCard(Card.RUNE_ANSUZ, "揭示本层地图，并生成所有能从现有房间通过红门到达的红房#门仍需用红钥匙或该隐魂石打开",
        "诸神符文", "zh_cn")
    EID:addCard(Card.RUNE_ANSUZ, "Reveals this floor and generates every red room reachable from existing rooms#Their doors still have to be opened with Red Key or Soul of Cain",
        "Ansuz", "en_us")
end

mod:AddCallback(ModCallbacks.MC_GET_PILL_EFFECT, function(_, effect)
    if not scriptedUse then
        return replacement[effect]
    end
end)

mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, function(_, player)
    trackPocket(player)
end)

-- Query the live pocket slot at the actual action as well as on the preceding update.
mod:AddCallback(ModCallbacks.MC_INPUT_ACTION, function(_, entity, hook, action)
    if entity and hook == InputHook.IS_ACTION_TRIGGERED and action == ButtonAction.ACTION_PILLCARD then
        local player = entity:ToPlayer()
        if player and heldColor(player) ~= colors.PILL_NULL then trackPocket(player) end
    end
end)

for _, effect in ipairs({customTeleport, customTears, foundPills}) do
    if effect >= 0 then mod:AddCallback(ModCallbacks.MC_USE_PILL, onUse, effect) end
end

mod:AddCallback(ModCallbacks.MC_USE_CARD, function()
    if ansuzAllowed() then
        revealAnsuzFloor()
        hideAnsuzDoors()
    end
end, Card.RUNE_ANSUZ)

mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, enterAnsuzRoom)
mod:AddCallback(ModCallbacks.MC_POST_UPDATE, function()
    keepDoorsHidden()
    if next(hiddenSlots) then
        for index = 0, game:GetNumPlayers() - 1 do
            checkRedKeyButton(Isaac.GetPlayer(index))
        end
    end
end)
mod:AddCallback(ModCallbacks.MC_POST_RENDER, renderDoorOutlines)
mod:AddCallback(ModCallbacks.MC_PRE_USE_ITEM, function(_, _, _, player)
    if player:GetData().PillRebalanceKeyFrame == game:GetFrameCount() then return true end
    return useSealedRedKey(player)
end, CollectibleType.COLLECTIBLE_RED_KEY)
mod:AddCallback(ModCallbacks.MC_USE_CARD, function()
    for slot in pairs(hiddenSlots) do openSealedDoor(slot) end
end, Card.CARD_SOUL_CAIN)
mod:AddCallback(ModCallbacks.MC_USE_CARD, function(_, _, player)
    openNearbyDoor(player)
end, Card.CARD_CRACKED_KEY)

mod:AddCallback(ModCallbacks.MC_EVALUATE_CACHE, function(_, player)
    local units = tearUnits[playerKey(player)] or 0
    if units > 0 then
        player.MaxFireDelay = rules.fireDelay(player.MaxFireDelay, units)
    end
end, CacheFlag.CACHE_FIREDELAY)

mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function(_, continued)
    startSeed = game:GetSeeds():GetStartSeed()
    tearUnits = {}
    ansuzFloorSeed = nil
    ansuzGrids = {}
    local rngSeed = startSeed
    if continued and mod:HasData() then
        local ok, save = pcall(json.decode, mod:LoadData())
        if ok and type(save) == "table" and save.startSeed == startSeed
            and type(save.tearUnits) == "table" and type(save.rngSeed) == "number" then
            tearUnits = save.tearUnits
            rngSeed = save.rngSeed
            if type(save.ansuzFloorSeed) == "number" and type(save.ansuzGrids) == "table" then
                ansuzFloorSeed = save.ansuzFloorSeed
                -- Each entry is {grid, opened}; 1.4.1 saves held bare grid numbers.
                for _, entry in ipairs(save.ansuzGrids) do
                    if type(entry) == "table" and type(entry[1]) == "number" then
                        ansuzGrids[entry[1]] = entry[2] == true
                    elseif type(entry) == "number" then
                        ansuzGrids[entry] = true
                    end
                end
            end
        end
    end
    rng:SetSeed(rngSeed, 35)
    for index = 0, game:GetNumPlayers() - 1 do
        evaluateTears(Isaac.GetPlayer(index))
    end
    registerDescriptions()
    enterAnsuzRoom()
end)

mod:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, function(_, shouldSave)
    if startSeed and shouldSave then
        local grids = {}
        for grid, opened in pairs(ansuzGrids) do grids[#grids + 1] = {grid, opened} end
        mod:SaveData(json.encode({
            startSeed = startSeed,
            tearUnits = tearUnits,
            rngSeed = rng:GetSeed(),
            ansuzFloorSeed = ansuzFloorSeed,
            ansuzGrids = grids,
        }))
    end
end)

Isaac.DebugString(string.format("[Pill Rebalance] v1.5.5 loaded: Telepills=%s TearsUp=%s",
    tostring(customTeleport), tostring(customTears)))
