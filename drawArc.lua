local d3d            = require('d3d8');
local d3d8dev        = d3d.get_device();
local ffi            = require('ffi');
local C              = ffi.C;

local helpers        = require('helpers');
local rotateVector16 = helpers.rotateVector16;
local matrixMultiply = helpers.matrixMultiply;
local worldToScreen  = helpers.worldToScreen;
local getTexture     = helpers.getTexture;

local Bezier3D_2     = require('Bezier3D_2');

ffi.cdef [[
    #pragma pack(1)
    struct VertFormatFFFFUFF
    {
        float x;
        float y;
        float z;
        float rhw;
        unsigned int diffuse;
        float u;
        float v;
    };
]]

local renderer = {};

local VERTICES_PER_ARC = 82;
local VERTICES_PER_ORB = 4;
local MAX_VERTICES = 32768;
local LINE_WIDTH = 3;

local vertFormatMask = bit.bor(C.D3DFVF_XYZRHW, C.D3DFVF_DIFFUSE, C.D3DFVF_TEX1);
local vertexStride = ffi.sizeof('struct VertFormatFFFFUFF');
local staging = ffi.new('struct VertFormatFFFFUFF[?]', MAX_VERTICES);

local vertexBuffer;
local vertexCount = 0;
local beamStarts = {};
local beamCount = 0;
local orbStarts = {};
local orbCount = 0;

local view;
local projection;
local viewProj;
local viewportWidth;
local viewportHeight;
local frameReady = false;

local arcTex;
local orbTex;

local function ensureVertexBuffer()
    if (vertexBuffer ~= nil) then
        return true;
    end

    local result, buffer = d3d8dev:CreateVertexBuffer(
        MAX_VERTICES * vertexStride,
        bit.bor(C.D3DUSAGE_DYNAMIC, C.D3DUSAGE_WRITEONLY),
        vertFormatMask,
        C.D3DPOOL_DEFAULT);

    if (result ~= C.S_OK or buffer == nil) then
        return false;
    end

    vertexBuffer = d3d.gc_safe_release(buffer);
    return true;
end

local function writeVertex(index, x, y, z, color, u, v)
    local vertex = staging[index];
    vertex.x = x;
    vertex.y = y;
    vertex.z = z;
    vertex.rhw = 1;
    vertex.diffuse = color;
    vertex.u = u;
    vertex.v = v;
end

local function writeCurveSample(baseIndex, sampleIndex, reverse, t, u, color,
                                p0x, p0y, p0z, bx, by, bz, ax, ay, az,
                                cx, cy, cz)
    local t2 = t * t;
    local px = p0x + t * bx + t2 * ax;
    local py = p0y + t * by + t2 * ay;
    local pz = p0z + t * bz + t2 * az;

    local tx = bx + 2 * ax * t;
    local ty = by + 2 * ay * t;
    local tz = bz + 2 * az * t;

    local nx = cy * tz - cz * ty;
    local ny = cz * tx - cx * tz;
    local nz = cx * ty - cy * tx;
    local normalLength2 = nx * nx + ny * ny + nz * nz;

    if (normalLength2 < 0.000001) then
        nx = -ty;
        ny = tx;
        normalLength2 = nx * nx + ny * ny;
    end

    if (normalLength2 > 0) then
        local scale = LINE_WIDTH / math.sqrt(normalLength2);
        nx = nx * scale;
        ny = ny * scale;
    else
        nx = 0;
        ny = 0;
    end

    local plusIndex;
    local minusIndex;
    if (reverse) then
        plusIndex = baseIndex + VERTICES_PER_ARC - 1 - sampleIndex * 2;
        minusIndex = plusIndex - 1;
    else
        plusIndex = baseIndex + sampleIndex * 2;
        minusIndex = plusIndex + 1;
    end

    writeVertex(plusIndex, px + nx, py + ny, pz, color, u, 0);
    writeVertex(minusIndex, px - nx, py - ny, pz, color, u, 0.5);

    return px, py, pz;
end

function renderer.beginFrame()
    vertexCount = 0;
    beamCount = 0;
    orbCount = 0;
    frameReady = false;

    local viewResult;
    local projectionResult;
    local viewportResult;

    viewResult, view = d3d8dev:GetTransform(C.D3DTS_VIEW);
    projectionResult, projection = d3d8dev:GetTransform(C.D3DTS_PROJECTION);
    local viewport;
    viewportResult, viewport = d3d8dev:GetViewport();

    if (viewResult ~= C.S_OK or projectionResult ~= C.S_OK or
            viewportResult ~= C.S_OK or view == nil or projection == nil or viewport == nil) then
        return false;
    end

    viewProj = matrixMultiply(view, projection);
    viewportWidth = viewport.Width;
    viewportHeight = viewport.Height;
    frameReady = true;
    return true;
end

function renderer.drawArc(x1, y1, z1, x2, y2, z2, color, progress, orb)
    if (not frameReady or vertexCount + VERTICES_PER_ARC + VERTICES_PER_ORB > MAX_VERTICES) then
        return false;
    end

    local zoom = (2.8 - projection._11) * 0.47619047619;

    local p1x = (x1 + x2) / 2;
    local p1y = (z1 + z2) / 2 - 2 - 2 * zoom;
    local p1z = (y1 + y2) / 2;

    local cameraX = view._11 * p1x + view._21 * p1y + view._31 * p1z + view._41;
    local cameraY = view._12 * p1x + view._22 * p1y + view._32 * p1z + view._42;
    local cameraZ = view._13 * p1x + view._23 * p1y + view._33 * p1z + view._43;
    local p1Distance = math.sqrt(cameraX * cameraX + cameraY * cameraY + cameraZ * cameraZ);

    p1y = p1y + math.max(6 - p1Distance, 0) / 2 + progress;

    local p0x, p0y, p0z = x1, z1, y1;
    local p2x, p2y, p2z = x2, z2, y2;

    local axisX = p2x - p0x;
    local axisY = p2y - p0y;
    local axisZ = p2z - p0z;
    local axisLength2 = axisX * axisX + axisY * axisY + axisZ * axisZ;
    if (axisLength2 == 0) then
        return false;
    end

    local inverseAxisLength = 1 / math.sqrt(axisLength2);
    axisX = axisX * inverseAxisLength;
    axisY = axisY * inverseAxisLength;
    axisZ = axisZ * inverseAxisLength;

    local rotatedX, rotatedY, rotatedZ = rotateVector16(
        axisX, axisY, axisZ,
        p1x - p0x, p1y - p0y, p1z - p0z,
        not orb);
    p1x = rotatedX + p0x;
    p1y = rotatedY + p0y;
    p1z = rotatedZ + p0z;

    local bcurve = Bezier3D_2:new({
        { p0x, p0y, p0z },
        { p1x, p1y, p1z },
        { p2x, p2y, p2z }
    });

    local wx0, wy0, wz0 = worldToScreen(p0x, p0y, p0z, viewProj, viewportWidth, viewportHeight);
    local wx1, wy1, wz1 = worldToScreen(p1x, p1y, p1z, viewProj, viewportWidth, viewportHeight);
    local wx2, wy2, wz2 = worldToScreen(p2x, p2y, p2z, viewProj, viewportWidth, viewportHeight);

    if ((wz0 > 1 and wz1 > 1 and wz2 > 1) or
            (wz0 < 0 and wz1 < 0 and wz2 < 0) or
            (wx0 > viewportWidth and wx1 > viewportWidth and wx2 > viewportWidth) or
            (wx0 < 0 and wx1 < 0 and wx2 < 0) or
            (wy0 > viewportHeight and wy1 > viewportHeight and wy2 > viewportHeight) or
            (wy0 < 0 and wy1 < 0 and wy2 < 0)) then
        return false;
    end

    local cp0;
    local cp1;
    local cp2;
    local tMin = 0;
    local tMax = 1;

    if (wx0 > viewportWidth or wx0 < 0 or wy0 > viewportHeight or wy0 < 0 or wz0 > 1 or wz0 < 0) then
        local _, tZero = bcurve:solveZeros(viewProj);
        if (not tZero) then
            return false;
        end

        tMin = tZero;
        cp0, cp1, cp2 = table.unpack(bcurve:subdivide(tZero)[2]);
    elseif (wx2 > viewportWidth or wx2 < 0 or wy2 > viewportHeight or wy2 < 0 or wz2 > 1 or wz2 < 0) then
        local tZero = bcurve:solveZeros(viewProj);
        if (not tZero) then
            return false;
        end

        tMax = tZero;
        cp0, cp1, cp2 = table.unpack(bcurve:subdivide(tZero)[1]);
    else
        cp0 = bcurve.P0;
        cp1 = bcurve.P1;
        cp2 = bcurve.P2;
    end

    if (progress < tMin or tMax <= tMin) then
        return false;
    end

    p0x, p0y, p0z = worldToScreen(cp0[1], cp0[2], cp0[3], viewProj, viewportWidth, viewportHeight);
    p1x, p1y, p1z = worldToScreen(cp1[1], cp1[2], cp1[3], viewProj, viewportWidth, viewportHeight);
    p2x, p2y, p2z = worldToScreen(cp2[1], cp2[2], cp2[3], viewProj, viewportWidth, viewportHeight);

    local bx = -2 * p0x + 2 * p1x;
    local by = -2 * p0y + 2 * p1y;
    local bz = -2 * p0z + 2 * p1z;
    local ax = p0x - 2 * p1x + p2x;
    local ay = p0y - 2 * p1y + p2y;
    local az = p0z - 2 * p1z + p2z;

    local crossX = (p2y - p0y) * (p1z - p0z) - (p2z - p0z) * (p1y - p0y);
    local crossY = (p2z - p0z) * (p1x - p0x) - (p2x - p0x) * (p1z - p0z);
    local crossZ = (p2x - p0x) * (p1y - p0y) - (p2y - p0y) * (p1x - p0x);
    local crossLength2 = crossX * crossX + crossY * crossY + crossZ * crossZ;
    if (crossLength2 > 0) then
        local inverseCrossLength = 1 / math.sqrt(crossLength2);
        crossX = crossX * inverseCrossLength;
        crossY = crossY * inverseCrossLength;
        crossZ = crossZ * inverseCrossLength;
    end

    local tAdjusted = (progress - tMin) / (tMax - tMin);
    local tEnd = math.min(tAdjusted, 1);
    local tInterval = 0.95 * tEnd / 38;
    local reverse = p2z > p0z;
    local beamStart = vertexCount;

    local firstU = tMin > 0 and 0.25 or 0;
    writeCurveSample(beamStart, 0, reverse, 0, firstU, color,
        p0x, p0y, p0z, bx, by, bz, ax, ay, az, crossX, crossY, crossZ);

    local t = 0.025;
    for sampleIndex = 1, 39 do
        writeCurveSample(beamStart, sampleIndex, reverse, t, 0.25 + t / 2, color,
            p0x, p0y, p0z, bx, by, bz, ax, ay, az, crossX, crossY, crossZ);
        t = t + tInterval;
    end

    t = t + 0.025 - tInterval;
    local lastU = tMax < tAdjusted and 0.75 or 1;
    local orbX, orbY, orbZ = writeCurveSample(beamStart, 40, reverse, t, lastU, color,
        p0x, p0y, p0z, bx, by, bz, ax, ay, az, crossX, crossY, crossZ);

    beamCount = beamCount + 1;
    beamStarts[beamCount] = beamStart;
    vertexCount = vertexCount + VERTICES_PER_ARC;

    if (orb and tMax >= tAdjusted and progress < 1) then
        local orbStart = vertexCount;
        writeVertex(orbStart, orbX - 10, orbY - 10, orbZ, color, 0, 0);
        writeVertex(orbStart + 1, orbX + 10, orbY - 10, orbZ, color, 1, 0);
        writeVertex(orbStart + 2, orbX - 10, orbY + 10, orbZ, color, 0, 1);
        writeVertex(orbStart + 3, orbX + 10, orbY + 10, orbZ, color, 1, 1);

        orbCount = orbCount + 1;
        orbStarts[orbCount] = orbStart;
        vertexCount = vertexCount + VERTICES_PER_ORB;
    end

    return true;
end

function renderer.endFrame()
    frameReady = false;
    if (vertexCount == 0 or not ensureVertexBuffer()) then
        return false;
    end

    local uploadSize = vertexCount * vertexStride;
    local lockResult, pointer = vertexBuffer:Lock(0, uploadSize, C.D3DLOCK_DISCARD);
    if (lockResult ~= C.S_OK or pointer == nil) then
        return false;
    end

    ffi.copy(pointer, staging, uploadSize);
    local unlockResult = vertexBuffer:Unlock();
    if (unlockResult ~= C.S_OK) then
        return false;
    end

    arcTex = arcTex or getTexture(addon.path .. 'assets/beam.png');
    if (arcTex == nil) then
        return false;
    end

    d3d8dev:SetStreamSource(0, vertexBuffer, vertexStride);
    d3d8dev:SetTexture(0, arcTex);
    d3d8dev:SetTextureStageState(0, C.D3DTSS_COLOROP, C.D3DTOP_BLENDTEXTUREALPHA);
    d3d8dev:SetTextureStageState(0, C.D3DTSS_COLORARG1, C.D3DTA_TEXTURE);
    d3d8dev:SetTextureStageState(0, C.D3DTSS_COLORARG2, C.D3DTA_DIFFUSE);
    d3d8dev:SetTextureStageState(0, C.D3DTSS_ALPHAOP, C.D3DTOP_SELECTARG1);
    d3d8dev:SetTextureStageState(0, C.D3DTSS_ALPHAARG1, C.D3DTA_TEXTURE);
    d3d8dev:SetRenderState(C.D3DRS_ZENABLE, 0);
    d3d8dev:SetRenderState(C.D3DRS_ALPHABLENDENABLE, 1);
    d3d8dev:SetRenderState(C.D3DRS_SRCBLEND, C.D3DBLEND_SRCALPHA);
    d3d8dev:SetRenderState(C.D3DRS_DESTBLEND, C.D3DBLEND_INVSRCALPHA);
    d3d8dev:SetVertexShader(vertFormatMask);

    for index = 1, beamCount do
        d3d8dev:DrawPrimitive(C.D3DPT_TRIANGLESTRIP, beamStarts[index], 80);
    end

    if (orbCount > 0) then
        orbTex = orbTex or getTexture(addon.path .. 'assets/orb.png');
        if (orbTex ~= nil) then
            d3d8dev:SetTexture(0, orbTex);
            for index = 1, orbCount do
                d3d8dev:DrawPrimitive(C.D3DPT_TRIANGLESTRIP, orbStarts[index], 2);
            end
        end
    end

    return true;
end

return renderer;
