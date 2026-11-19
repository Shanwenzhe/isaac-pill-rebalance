local base = "pill_rebalance_local/"
local callbacks = {}
ModCallbacks = setmetatable({}, {__index = function(_, name) return name end})
function RegisterMod()
    return {AddCallback = function(_, name, handler, filter)
        callbacks[name .. tostring(filter)] = handler
    end}
end
local function call(name, filter, ...)
    local handler = assert(callbacks[name .. tostring(filter)], name)
    return handler(nil, ...)
end
function include(name) return dofile(base .. name .. ".lua") end
package.preload.json = function() return {} end
PillEffect = {PILLEFFECT_TELEPILLS = 19, PILLEFFECT_TEARS_UP = 16, PILLEFFECT_I_FOUND_PILLS = 8, NUM_PILL_EFFECTS = 50}
PillColor = {}
UseFlag = {USE_NOANIM = 1, USE_NOHUD = 2, USE_NOANNOUNCER = 4, USE_OWNED = 8}
CacheFlag = {CACHE_FIREDELAY = 2}
Card = {RUNE_ANSUZ = 36, CARD_CRACKED_KEY = 78, CARD_SOUL_CAIN = 83}
CollectibleType = {COLLECTIBLE_RED_KEY = 580}
RoomType = {ROOM_DEFAULT = 1, ROOM_SHOP = 2, ROOM_BOSS = 5}
RoomShape = {}
for index, suffix in ipairs({"1x1", "IH", "IV", "1x2", "IIV", "2x1", "IIH", "2x2", "LTL", "LTR", "LBL", "LBR"}) do
    RoomShape["ROOMSHAPE_" .. suffix] = index
end
LevelStage = {STAGE8 = 13}
GridCollisionClass = {COLLISION_NONE = 0, COLLISION_WALL = 4}
DoorState = {STATE_CLOSED = 1, STATE_OPEN = 2}
RoomDescriptor = {FLAG_RED_ROOM = 1 << 10}
ActiveSlot = {SLOT_PRIMARY = 0}
EntityType = {ENTITY_EFFECT = 1000}
EffectVariant = {DOOR_OUTLINE = 133}
function RNG() return {} end
Color = setmetatable({Lerp = function(a,b,t) return {A = a.A + (b.A-a.A)*t} end},
    {__call = function(_,r,g,b,a) return {R=r,G=g,B=b,A=a} end})
local frame, pressed, charges, uses = 1, false, 4, 0
local playerData = {}
ButtonAction = {ACTION_ITEM = 5, ACTION_PILLCARD = 6}
Input = {IsActionTriggered = function(action) return pressed and action == ButtonAction.ACTION_ITEM end}
local drawn = {}
function Sprite()
    return {
        Load = function(_, path) assert(path == "gfx/1000.154_door outline.anm2") end,
        Play = function(_, name) assert(name == "Idle") end,
        Update = function() end,
        Render = function(self, pos) drawn[pos] = self.Rotation end,
    }
end
local vectorMethods = {}
function vectorMethods:DistanceSquared(other)
    return (self.X - other.X)^2 + (self.Y - other.Y)^2
end
function vectorMethods:Distance(other) return math.sqrt(self:DistanceSquared(other)) end
function Vector(horizontal, vertical)
    return setmetatable({X = horizontal, Y = vertical}, {__index = vectorMethods})
end
local positions = {[0] = Vector(0, 100), Vector(120, 0), Vector(240, 100), Vector(120, 210)}
local offsets = {[0] = -1, -13, 1, 13}
local startGrid = 84
local currentGrid = startGrid
local hasKey, pocketCard = true, 0
local player = {Position = Vector(120, 100), GetCard = function() return pocketCard end,
    ControlsEnabled = true, GetData = function() return playerData end,
    GetActiveItem = function() return 580 end, GetPill = function() return 0 end,
    GetActiveCharge = function() return charges end, GetBatteryCharge = function() return 0 end,
    DischargeActiveItem = function() charges=charges-4; uses=uses+1 end, AnimateCollectible = function() end,
    HasCollectible = function() return hasKey end, Size = 10, ControllerIndex = 0}
Isaac = {GetPillEffectByName = function() return 51 end, GetPlayer = function() return player end,
    WorldToScreen = function(pos) return pos end, DebugString = function() end}
local descriptors, rooms, doors = {}, {}, {}
local function addRoom(grid, doorMask, red)
    local desc = {Data = {Shape = RoomShape.ROOMSHAPE_1x1, Type = RoomType.ROOM_DEFAULT, Doors = doorMask},
        Flags = red and RoomDescriptor.FLAG_RED_ROOM or 0, SafeGridIndex = grid, GridIndex = grid,
        ListIndex = #rooms, DisplayFlags = 0}
    descriptors[grid] = desc
    rooms[#rooms + 1] = desc
end
local function doorTo(grid, slot)
    local sprite = {Color = Color(.9, .8, .7, 1), Play = function(self,anim) self.animation=anim end}
    return {TargetRoomIndex = grid, Slot = slot, open = true, Position = positions[slot], ExtraVisible = true,
        GetSprite = function() return sprite end, IsOpen = function(self) return self.open end,
        SetLocked = function(self, value) self.locked = value end,
        Open = function(self) self.open = true; self.State = DoorState.STATE_OPEN end,
        Close = function(self) self.open = false; self.State = DoorState.STATE_CLOSED end,
        CollisionClass = GridCollisionClass.COLLISION_NONE, State = DoorState.STATE_OPEN}
end
addRoom(startGrid, 15, false)
local empty = {}
local level = {
    GetDungeonPlacementSeed = function() return 777 end, GetStage = function() return 1 end,
    GetCurrentRoomDesc = function() return descriptors[currentGrid] end,
    GetCurrentRoomIndex = function() return currentGrid end,
    GetRoomByIdx = function(_, grid) return descriptors[grid] or empty end,
    GetRooms = function() return {Size = #rooms, Get = function(_, index) return rooms[index + 1] end} end,
    UpdateVisibility = function() end,
    MakeRedRoomDoor = function(_, grid, slot)
        assert(grid == startGrid, "fixture only supports doors leading out of the starting room")
        local target = grid + offsets[slot]
        addRoom(target, 0, true)
        doors[slot] = doorTo(target, slot)
        return true
    end,
}
local room = {GetDoor = function(_, slot) return doors[slot] end,
    IsDoorSlotAllowed = function(_, slot) return positions[slot] ~= nil end,
    GetDoorSlotPosition = function(_, slot) return assert(positions[slot]) end,
    IsClear = function() return true end, IsMirrorWorld = function() return false end,
    GetRoomShape = function() return RoomShape.ROOMSHAPE_1x1 end}
function Game()
    return {GetRoom = function() return room end, GetLevel = function() return level end,
        GetNumPlayers = function() return 1 end, GetFrameCount=function() return frame end, IsPaused=function() return false end}
end
local function tick(count)
    for _=1,count do frame=frame+1; call("MC_POST_UPDATE", nil) end
end
local function useCard(card) call("MC_USE_CARD", card, card, player, 0) end
local function useRedKey()
    local item = CollectibleType.COLLECTIBLE_RED_KEY
    return call("MC_PRE_USE_ITEM", item, item, nil, player, 0, 0, 0)
end
local function sealed(door)
    return not door:IsOpen() or door.CollisionClass == GridCollisionClass.COLLISION_WALL or door.State == 0
end
local function accessible(door)
    return door:IsOpen() and door.CollisionClass ~= GridCollisionClass.COLLISION_WALL and door:GetSprite().Color.A > 0
end
dofile(base .. "main.lua")
assert(useRedKey() == nil, "Red Key before Ansuz should fall through to vanilla")
useCard(Card.RUNE_ANSUZ)
useCard(Card.RUNE_ANSUZ)
assert(#rooms == 5, "Repeated Ansuz should preserve the generated native rooms")
for slot = 0, 3 do assert(sealed(doors[slot]), "All generated red doors begin sealed") end
call("MC_POST_RENDER", nil)
for slot = 0, 3 do
    assert(drawn[positions[slot]] == (slot - 1) * 90 and doors[slot]:GetSprite().Color.A == 0)
end
drawn, hasKey = {}, false
call("MC_POST_RENDER", nil)
assert(next(drawn) == nil, "Without an opener the walls should be blank")
for _, card in ipairs({Card.CARD_SOUL_CAIN, Card.CARD_CRACKED_KEY}) do
    drawn, pocketCard = {}, card
    call("MC_POST_RENDER", nil)
    assert(drawn[positions[0]], "Both pocket openers should reveal the outline")
end
hasKey, pocketCard = true, 0
doors[2]:Open()
call("MC_POST_UPDATE", nil)
assert(not doors[2]:IsOpen(), "Clearing the room must not grant entry")
assert(useRedKey() == nil, "Red Key used far from a wall should fall through")
player.Position = positions[0]
pressed, charges = true, 3
tick(1)
assert(sealed(doors[0]) and uses == 0, "Partial charge must not open or spend")
charges = 4
tick(1)
pressed = false
assert(uses == 1 and charges == 0 and doors[0]:GetSprite().animation == "Open")
assert(doors[0].CollisionClass == GridCollisionClass.COLLISION_WALL and doors[0]:GetSprite().Color.A < 1)
tick(8)
assert(accessible(doors[0]), "Physical button opens a single door without an engine use callback")
assert(doors[0]:GetSprite().Color.A == 1, "Repeated Ansuz must preserve the original door appearance")
drawn = {}
call("MC_POST_RENDER", nil)
assert(drawn[positions[0]] == nil and drawn[positions[1]] ~= nil, "Only sealed doors keep an outline")
assert(sealed(doors[1]) and sealed(doors[2]) and sealed(doors[3]), "A single Red Key should open exactly one door")
player.Position = positions[1]
useCard(Card.CARD_CRACKED_KEY)
tick(8)
assert(accessible(doors[1]) and sealed(doors[2]) and sealed(doors[3]), "Cracked Key should reveal only the nearest door")
local originalDoors = doors
currentGrid = startGrid - 1
doors = {[2] = doorTo(startGrid, 2)}
call("MC_POST_NEW_ROOM", nil)
assert(accessible(doors[2]), "The return exit into the original room should remain usable")
currentGrid = startGrid
doors = {}
for slot, previous in pairs(originalDoors) do doors[slot] = doorTo(previous.TargetRoomIndex, slot) end
call("MC_POST_NEW_ROOM", nil)
assert(accessible(doors[0]) and accessible(doors[1]) and sealed(doors[2]) and sealed(doors[3]),
    "Room revisit should preserve opened doors and reseal all others")
useCard(Card.CARD_SOUL_CAIN)
assert(doors[2]:GetSprite().animation == "Open" and doors[3]:GetSprite().animation == "Open")
tick(8)
assert(accessible(doors[2]) and accessible(doors[3]), "Soul of Cain should unseal both remaining doors across the room")
assert(useRedKey() == nil, "When no sealed target remains the native key should handle use")
print("Door regression passed: native floor generation, repeat Ansuz, Red Key, Cracked Key, Soul of Cain and revisit.")
