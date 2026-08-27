addon.name    = 'targetlines';
addon.author  = 'Jyouya';
addon.version = '1.2';
addon.desc    = 'FFXII style target lines';

require('common');

local renderer = require('drawArc');
local arcs     = require('tracker');
local helpers  = require('helpers');
local settings = require('settings');

local config   = require('config');

local s        = settings.get();


local function getArcsForIndex(targetIndex, res)
    res = res or T {};
    for k, v in pairs(arcs) do
        if (k == targetIndex or v.dst == targetIndex) then
            if (not res[k]) then
                res[k] = v;
                getArcsForIndex(v.dst, res);
            end
        end
    end

    return res;
end

local function getPartyArcs(alliance)
    local party = AshitaCore:GetMemoryManager():GetParty()
    local res = T {};
    for i = 0, alliance and 17 or 5 do
        if (party:GetMemberIsActive(i) ~= 0) then
            local targetIndex = party:GetMemberTargetIndex(i);
            getArcsForIndex(targetIndex, res);
        end
    end

    return res;
end

local color    = T {
    player = 0xFF0088FF,
    enemy = 0xFFFF1133,
    playerFriendly = 0xFF00FF66,
    enemyFriendly = 0xFFFF8800
};
-- pet color 0xFFFF00AA

local timeouts = T {
    player = 10,
    enemy = 10,
    playerFriendly = 5,
    enemyFriendly = 5
};

local endpointFrame = {};
local endpointValid = {};
local endpointX = {};
local endpointY = {};
local endpointZ = {};
local frameNumber = 0;

local function getEndpoint(entity, index)
    if (endpointFrame[index] == frameNumber) then
        if (endpointValid[index]) then
            return endpointX[index], endpointY[index], endpointZ[index];
        end
        return;
    end

    endpointFrame[index] = frameNumber;
    endpointValid[index] = false;

    local pointer = entity:GetActorPointer(index);
    if (pointer == nil or pointer == 0) then
        return;
    end

    local x, y, z, baseZ = helpers.getBone(pointer, 2);
    if (x == nil or y == nil or z == nil or baseZ == nil) then
        return;
    end

    endpointX[index] = x;
    endpointY[index] = y;
    endpointZ[index] = (baseZ + z) / 2;
    endpointValid[index] = true;
    return endpointX[index], endpointY[index], endpointZ[index];
end

ashita.events.register('load', 'load_cb', function()
    ashita.events.register('d3d_present', 'present_cb', function()
        local now = os.clock();

        for src, arc in pairs(arcs) do
            local timeout = timeouts[arc.color];
            if (timeout == nil or now - arc.clock > timeout) then
                arcs[src] = nil;
            end
        end

        local filteredArcs
        if (s.filter == 'All') then
            filteredArcs = arcs;
        else
            filteredArcs = getPartyArcs(s.filter == 'Alliance');
        end

        if (not renderer.beginFrame()) then
            return;
        end

        frameNumber = frameNumber + 1;
        local entity = AshitaCore:GetMemoryManager():GetEntity();

        for src, v in pairs(filteredArcs) do
            local dTime = now - v.clock;
            local timeout = timeouts[v.color];
            local dFirstTime = v.firstClock and now - v.firstClock;
            local lineType = v.color;

            local fromIndex = src;
            local toIndex = v.dst;
            local progress;
            local showOrb = true;

            if (lineType == 'player' and dFirstTime and dFirstTime > 2.5) then
                fromIndex = v.dst;
                toIndex = src;
                progress = math.max((3 - dFirstTime) * 2, 0);
                showOrb = false;
            elseif (dTime > timeout - 0.5) then
                fromIndex = v.dst;
                toIndex = src;
                progress = math.min(1 - (0.5 - math.min(timeout - dTime, 1)) * 2, 1);
                showOrb = false;
            else
                progress = math.min(1 - (0.5 - math.min(dTime, 1)) * 2, 1);
            end

            if (progress > 0) then
                local x1, y1, z1 = getEndpoint(entity, fromIndex);
                local x2, y2, z2 = getEndpoint(entity, toIndex);
                if (x1 ~= nil and x2 ~= nil) then
                    renderer.drawArc(x1, y1, z1, x2, y2, z2, color[v.color], progress, showOrb);
                end
            end
        end

        renderer.endFrame();
    end);
end);
