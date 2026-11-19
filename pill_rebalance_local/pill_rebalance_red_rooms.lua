-- Ansuz red rooms. The game's Level:MakeRedRoomDoor does the real generation (room type,
-- contents and the red door itself). This module only decides which door slots are safe to
-- pass to it. MakeRedRoomDoor on a slot that leads nowhere valid creates an I AM ERROR door,
-- so every candidate must point at an empty in-bounds cell that the room's shape can open.
local redRooms = {}

local GRID = 13
local shape = RoomShape
local cellsByShape = {
    [shape.ROOMSHAPE_1x1] = {"#"},
    [shape.ROOMSHAPE_IH] = {"#"},
    [shape.ROOMSHAPE_IV] = {"#"},
    [shape.ROOMSHAPE_1x2] = {"#", "#"},
    [shape.ROOMSHAPE_IIV] = {"#", "#"},
    [shape.ROOMSHAPE_2x1] = {"##"},
    [shape.ROOMSHAPE_IIH] = {"##"},
    [shape.ROOMSHAPE_2x2] = {"##", "##"},
    [shape.ROOMSHAPE_LTL] = {".#", "##"},
    [shape.ROOMSHAPE_LTR] = {"#.", "##"},
    [shape.ROOMSHAPE_LBL] = {"##", ".#"},
    [shape.ROOMSHAPE_LBR] = {"##", "#."},
}

-- Narrow rooms only have doors on their long sides.
local narrowDoorMasks = {
    [shape.ROOMSHAPE_IH] = 0x05,
    [shape.ROOMSHAPE_IV] = 0x0A,
    [shape.ROOMSHAPE_IIV] = 0x0A,
    [shape.ROOMSHAPE_IIH] = 0x05,
}

-- Ordered like DoorSlot.LEFT0 through DOWN0; DoorSlot = direction - 1 + 4 * edgeCell.
local directions = {{-1, 0}, {0, -1}, {1, 0}, {0, 1}}

local function gridIndex(column, row)
    if column >= 0 and column < GRID and row >= 0 and row < GRID then
        return row * GRID + column
    end
end

local function hasCell(cells, column, row)
    local line = cells[row + 1]
    return line ~= nil and column >= 0 and line:sub(column + 1, column + 1) == "#"
end

-- rooms: list of {grid, shape, doors, type, listIndex}
-- isClosed(room): true when the room gets no red doors on this floor (boss or shop rules).
-- Returns one entry per open door slot that leads to an empty in-bounds cell.
function redRooms.plan(rooms, isClosed)
    local occupied = {}
    for _, room in ipairs(rooms) do
        local cells = cellsByShape[room.shape]
        if cells then
            local column0, row0 = room.grid % GRID, room.grid // GRID
            for row = 0, #cells - 1 do
                for column = 0, #cells[row + 1] - 1 do
                    if hasCell(cells, column, row) then
                        local cell = gridIndex(column0 + column, row0 + row)
                        if cell then occupied[cell] = true end
                    end
                end
            end
        end
    end

    local plan, queued = {}, {}
    for _, room in ipairs(rooms) do
        local cells = cellsByShape[room.shape]
        if cells then
            local doorMask = room.doors & (narrowDoorMasks[room.shape] or 0xFF)
            if isClosed(room) then doorMask = 0 end
            local column0, row0 = room.grid % GRID, room.grid // GRID
            for row = 0, #cells - 1 do
                for column = 0, #cells[row + 1] - 1 do
                    if hasCell(cells, column, row) then
                        for direction, offset in ipairs(directions) do
                            local nextColumn, nextRow = column + offset[1], row + offset[2]
                            if not hasCell(cells, nextColumn, nextRow) then
                                local target = gridIndex(column0 + nextColumn, row0 + nextRow)
                                local slot = direction - 1 + 4 * (offset[1] == 0 and column or row)
                                if target and not occupied[target] and not queued[target]
                                    and (doorMask & (1 << slot)) ~= 0 then
                                    queued[target] = true
                                    plan[#plan + 1] = {grid = room.grid, slot = slot, target = target}
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return plan
end

-- Grid cell that DoorSlot `slot` of a room (top-left grid, shape) leads to, or nil.
function redRooms.slotTarget(grid, roomShape, slot)
    local cells = cellsByShape[roomShape]
    if not cells then return nil end
    local column0, row0 = grid % GRID, grid // GRID
    for row = 0, #cells - 1 do
        for column = 0, #cells[row + 1] - 1 do
            if hasCell(cells, column, row) then
                for direction, offset in ipairs(directions) do
                    local nextColumn, nextRow = column + offset[1], row + offset[2]
                    if not hasCell(cells, nextColumn, nextRow)
                        and direction - 1 + 4 * (offset[1] == 0 and column or row) == slot then
                        return gridIndex(column0 + nextColumn, row0 + nextRow)
                    end
                end
            end
        end
    end
end

-- env.rooms() -> snapshot list; env.roomExists(grid) -> bool; env.makeDoor(grid, slot) -> bool;
-- env.isClosed(room) -> bool.
-- Re-plans after every pass so chains of red rooms are followed until nothing new can open.
function redRooms.generate(env, maxPasses)
    local created = 0
    for _ = 1, maxPasses or 64 do
        local progressed = false
        for _, entry in ipairs(redRooms.plan(env.rooms(), env.isClosed)) do
            if not env.roomExists(entry.target) and env.makeDoor(entry.grid, entry.slot)
                and env.roomExists(entry.target) then
                created = created + 1
                progressed = true
                if env.onCreated then env.onCreated(entry.target) end
            end
        end
        if not progressed then break end
    end
    return created
end

return redRooms
