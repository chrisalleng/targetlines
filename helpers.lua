local ffi = require('ffi');
local d3d = require('d3d8');

local C = ffi.C;
local d3d8dev = d3d.get_device();

local function matrixMultiply(m1, m2)
    return ffi.new('D3DXMATRIX', {
        --
        m1._11 * m2._11 + m1._12 * m2._21 + m1._13 * m2._31 + m1._14 * m2._41,
        m1._11 * m2._12 + m1._12 * m2._22 + m1._13 * m2._32 + m1._14 * m2._42,
        m1._11 * m2._13 + m1._12 * m2._23 + m1._13 * m2._33 + m1._14 * m2._43,
        m1._11 * m2._14 + m1._12 * m2._24 + m1._13 * m2._34 + m1._14 * m2._44,
        --
        m1._21 * m2._11 + m1._22 * m2._21 + m1._23 * m2._31 + m1._24 * m2._41,
        m1._21 * m2._12 + m1._22 * m2._22 + m1._23 * m2._32 + m1._24 * m2._42,
        m1._21 * m2._13 + m1._22 * m2._23 + m1._23 * m2._33 + m1._24 * m2._43,
        m1._21 * m2._14 + m1._22 * m2._24 + m1._23 * m2._34 + m1._24 * m2._44,
        --
        m1._31 * m2._11 + m1._32 * m2._21 + m1._33 * m2._31 + m1._34 * m2._41,
        m1._31 * m2._12 + m1._32 * m2._22 + m1._33 * m2._32 + m1._34 * m2._42,
        m1._31 * m2._13 + m1._32 * m2._23 + m1._33 * m2._33 + m1._34 * m2._43,
        m1._31 * m2._14 + m1._32 * m2._24 + m1._33 * m2._34 + m1._34 * m2._44,
        --
        m1._41 * m2._11 + m1._42 * m2._21 + m1._43 * m2._31 + m1._44 * m2._41,
        m1._41 * m2._12 + m1._42 * m2._22 + m1._43 * m2._32 + m1._44 * m2._42,
        m1._41 * m2._13 + m1._42 * m2._23 + m1._43 * m2._33 + m1._44 * m2._43,
        m1._41 * m2._14 + m1._42 * m2._24 + m1._43 * m2._34 + m1._44 * m2._44,
    });
end

local function vec4Transform(v, m)
    return ffi.new('D3DXVECTOR4', {
        m._11 * v.x + m._21 * v.y + m._31 * v.z + m._41 * v.w,
        m._12 * v.x + m._22 * v.y + m._32 * v.z + m._42 * v.w,
        m._13 * v.x + m._23 * v.y + m._33 * v.z + m._43 * v.w,
        m._14 * v.x + m._24 * v.y + m._34 * v.z + m._44 * v.w,
    });
end

local function worldToScreen(x, y, z, viewProj, width, height)
    local cameraX = viewProj._11 * x + viewProj._21 * y + viewProj._31 * z + viewProj._41;
    local cameraY = viewProj._12 * x + viewProj._22 * y + viewProj._32 * z + viewProj._42;
    local cameraZ = viewProj._13 * x + viewProj._23 * y + viewProj._33 * z + viewProj._43;
    local cameraW = viewProj._14 * x + viewProj._24 * y + viewProj._34 * z + viewProj._44;
    local rhw = 1 / cameraW;

    local ndcX = cameraX * rhw;
    local ndcY = cameraY * rhw;
    local ndcZ = cameraZ * rhw;

    return math.floor((ndcX + 1) * 0.5 * width),
        math.floor((1 - ndcY) * 0.5 * height),
        ndcZ;
end

local function getBone(actorPointer, bone)
    local x = ashita.memory.read_float(actorPointer + 0x678);
    local y = ashita.memory.read_float(actorPointer + 0x680);
    local z = ashita.memory.read_float(actorPointer + 0x67C);

    local skeletonBaseAddress = ashita.memory.read_uint32(actorPointer + 0x6B8);

    local skeletonOffsetAddress = ashita.memory.read_uint32(skeletonBaseAddress + 0x0C);

    local skeletonAddress = ashita.memory.read_uint32(skeletonOffsetAddress);

    local boneCount = ashita.memory.read_uint16(skeletonAddress + 0x32);

    local bufferPointer = skeletonAddress + 0x30;
    local skeletonSize = 0x04;
    local boneSize = 0x1E;

    local generatorsAddress = bufferPointer + skeletonSize + boneSize * boneCount + 4;

    return x + ashita.memory.read_float(generatorsAddress + (bone * 0x1A) + 0x0E + 0x0),
        y + ashita.memory.read_float(generatorsAddress + (bone * 0x1A) + 0x0E + 0x8),
        z + ashita.memory.read_float(generatorsAddress + (bone * 0x1A) + 0x0E + 0x4),
        z
end

local function normalize(vec3)
    local u = (vec3[1] ^ 2 + vec3[2] ^ 2 + vec3[3] ^ 2) ^ (-0.5);
    return { vec3[1] * u, vec3[2] * u, vec3[3] * u };
end

local function getTexture(path)
    local texture_ptr = ffi.new('IDirect3DTexture8*[1]');
    if (C.D3DXCreateTextureFromFileA(d3d8dev, path, texture_ptr) ~= C.S_OK) then
        return nil;
    end

    return d3d.gc_safe_release(ffi.cast('IDirect3DBaseTexture8*', texture_ptr[0]));
end

local rotateVector16;
do
    local angle = -math.pi / 16;
    local sin = math.sin(angle);
    local cos = math.cos(angle);

    local angle2 = math.pi / 16;
    local sin2 = math.sin(angle2);
    local cos2 = math.cos(angle2);
    -- Rotates vector v around axis k by pi/16 radians
    -- k must be magnitude 1
    function rotateVector16(kx, ky, kz, vx, vy, vz, flip)
        -- k . v
        local kv = kx * vx + ky * vy + kz * vz;

        local rx, ry, rz
        if (flip) then
            local kvcos = kv * (1 - cos2);
            rx = vx * cos2 + (ky * vz - kz * vy) * sin2 + kx * kvcos;
            ry = vy * cos2 + (kz * vx - kx * vz) * sin2 + ky * kvcos;
            rz = vz * cos2 + (kx * vy - ky * vx) * sin2 + kz * kvcos;
        else
            local kvcos = kv * (1 - cos);

            rx = vx * cos + (ky * vz - kz * vy) * sin + kx * kvcos;
            ry = vy * cos + (kz * vx - kx * vz) * sin + ky * kvcos;
            rz = vz * cos + (kx * vy - ky * vx) * sin + kz * kvcos;
        end
        return rx, ry, rz;
    end
end

return {
    matrixMultiply = matrixMultiply,
    vec4Transform = vec4Transform,
    worldToScreen = worldToScreen,
    getBone = getBone,
    normalize = normalize,
    getTexture = getTexture,
    rotateVector16 = rotateVector16
};
