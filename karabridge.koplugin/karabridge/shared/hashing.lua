--[[--
Content hashing, used to skip exports that would change nothing.

FNV-1a rather than a real digest: the question this answers is "has the
Markdown for this book changed since I last sent it", not "is this content
authentic". FNV-1a is a few lines of pure Lua 5.1, needs no C library present
on every device, and is fast enough to run over a book's whole highlight set on
a Kobo. It is emphatically not a cryptographic hash and must never be used as
one.

A 64-bit value is produced as two independent 32-bit FNV-1a passes with
different offset bases, which keeps every intermediate product inside the 53
bits a double can hold exactly. Lua 5.1 has no bitwise operators and plain Lua
has no `bit` library, so the xor and the wrapping multiply are done in
arithmetic.

@module karabridge.shared.hashing
]]

local Hashing = {}

local FNV_PRIME = 16777619
local FNV_OFFSET_A = 2166136261
-- Second basis: FNV-1a's offset for 32 bits with the low bit flipped, giving an
-- independent-looking second half without inventing a new algorithm.
local FNV_OFFSET_B = 2166136260

local TWO_32 = 4294967296

--- Xor of two bytes, without a bit library.
local function xor8(a, b)
    local result, bit_value = 0, 1
    for _ = 1, 8 do
        local abit, bbit = a % 2, b % 2
        if abit ~= bbit then
            result = result + bit_value
        end
        a = (a - abit) / 2
        b = (b - bbit) / 2
        bit_value = bit_value * 2
    end
    return result
end

--- (value * FNV_PRIME) mod 2^32, split so no product exceeds 2^53.
local function mulPrime(value)
    local low = value % 65536
    local high = (value - low) / 65536

    -- high * prime overflows 32 bits entirely; only its low 16 bits survive the
    -- shift back up, so it is reduced before multiplying out.
    local low_product = low * FNV_PRIME
    local high_product = (high * FNV_PRIME) % 65536

    return (low_product + high_product * 65536) % TWO_32
end

local function fnv1a(text, offset)
    local hash = offset
    for index = 1, #text do
        local byte = text:byte(index)
        -- Only the low 8 bits of the hash are affected by xor with a byte.
        local low = hash % 256
        hash = hash - low + xor8(low, byte)
        hash = mulPrime(hash)
    end
    return hash
end

--- Hash a string.
-- @tparam any text
-- @treturn string 16 lowercase hex characters. Stable across runs and devices.
function Hashing.hash(text)
    if type(text) ~= "string" then
        text = tostring(text)
    end
    return string.format("%08x%08x", fnv1a(text, FNV_OFFSET_A), fnv1a(text, FNV_OFFSET_B))
end

--- Hash an array of strings as one value.
--
-- The separator matters: without it, `{"ab", "c"}` and `{"a", "bc"}` would
-- hash alike, and two different highlight sets could be mistaken for
-- unchanged. `\0` cannot occur in the text KOReader gives us.
--
-- @tparam table parts Array of strings.
-- @treturn string
function Hashing.hashParts(parts)
    if type(parts) ~= "table" then
        return Hashing.hash("")
    end

    local rendered = {}
    for index, part in ipairs(parts) do
        rendered[index] = tostring(part)
    end

    return Hashing.hash(table.concat(rendered, "\0"))
end

return Hashing
