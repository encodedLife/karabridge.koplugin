--[[--
A minimal busted-compatible harness.

KaraBridge's unit specs are written in busted syntax, because that is what
KOReader's own test suite uses and a spec should be movable between the two
without editing. But busted is not installable everywhere KaraBridge is
developed: it needs Penlight and a LuaRocks tree, and the copy inside KOReader's
build only works from inside that build's directory.

So `scripts/test-unit.sh` prefers the real busted and falls back to this, which
implements the subset the pure-Lua specs use:

    describe / it / setup / teardown / before_each / after_each / pending
    assert.is_true / is_false / is_nil / is_not_nil / is_table / is_string
    assert.equals / same / matches / has_error / has_no_error / truthy / falsy
    assert.is_truthy / is_falsy  (aliases, as in busted)

`assert.same` is a deep comparison, like busted's. Anything not listed is a
deliberate omission: if a spec needs `spy` or `mock`, it belongs in the
KOReader-hosted suite where the real busted is available.

@module spec.support.busted_lite
]]

local Lite = {
    passed = 0,
    failed = 0,
    skipped = 0,
    failures = {},
}

local context_stack = {}
local hooks_stack = {}

local function currentName(name)
    local parts = {}
    for _, entry in ipairs(context_stack) do
        table.insert(parts, entry)
    end
    table.insert(parts, name)
    return table.concat(parts, " :: ")
end

local function runHooks(kind)
    for _, level in ipairs(hooks_stack) do
        for _, hook in ipairs(level[kind] or {}) do
            hook()
        end
    end
end

local function describe(name, body)
    table.insert(context_stack, name)
    table.insert(hooks_stack, { before_each = {}, after_each = {} })

    local level = hooks_stack[#hooks_stack]
    local ok, err = pcall(body)
    if not ok then
        Lite.failed = Lite.failed + 1
        table.insert(Lite.failures, { name = currentName("<describe body>"), err = tostring(err) })
    end

    for _, hook in ipairs(level.teardown or {}) do
        pcall(hook)
    end

    table.remove(hooks_stack)
    table.remove(context_stack)
end

local function it(name, body)
    local label = currentName(name)

    runHooks("before_each")

    local ok, err = xpcall(body, function(e)
        return tostring(e) .. "\n" .. debug.traceback("", 2)
    end)

    runHooks("after_each")

    if ok then
        Lite.passed = Lite.passed + 1
        io.write(".")
    else
        Lite.failed = Lite.failed + 1
        table.insert(Lite.failures, { name = label, err = err })
        io.write("F")
    end
    io.flush()
end

local function pending(_name)
    Lite.skipped = Lite.skipped + 1
    io.write("-")
    io.flush()
end

local function setup(fn)
    -- Runs immediately: describe bodies execute top to bottom, so a setup
    -- declared before the its it prepares has already run by the time they do.
    fn()
end

local function teardown(fn)
    local level = hooks_stack[#hooks_stack]
    if level then
        level.teardown = level.teardown or {}
        table.insert(level.teardown, fn)
    end
end

local function before_each(fn)
    local level = hooks_stack[#hooks_stack]
    if level then
        table.insert(level.before_each, fn)
    end
end

local function after_each(fn)
    local level = hooks_stack[#hooks_stack]
    if level then
        table.insert(level.after_each, fn)
    end
end

-- Assertions ------------------------------------------------------------------

local function render(value, depth)
    depth = depth or 0
    if type(value) == "string" then
        return string.format("%q", value)
    end
    if type(value) ~= "table" or depth > 3 then
        return tostring(value)
    end

    local keys = {}
    for key in pairs(value) do
        table.insert(keys, key)
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)

    local parts = {}
    for _, key in ipairs(keys) do
        table.insert(parts, string.format("%s = %s", tostring(key), render(value[key], depth + 1)))
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

local function deepEqual(a, b)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end

    for key, value in pairs(a) do
        if not deepEqual(value, b[key]) then
            return false
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end

    return true
end

local function fail(message)
    error(message, 3)
end

local assertions = {}

function assertions.is_true(value, message)
    if value ~= true then
        fail((message or "expected true") .. ", got " .. render(value))
    end
end

function assertions.is_false(value, message)
    if value ~= false then
        fail((message or "expected false") .. ", got " .. render(value))
    end
end

function assertions.is_nil(value, message)
    if value ~= nil then
        fail((message or "expected nil") .. ", got " .. render(value))
    end
end

function assertions.is_not_nil(value, message)
    if value == nil then
        fail(message or "expected a value, got nil")
    end
end

function assertions.is_table(value, message)
    if type(value) ~= "table" then
        fail((message or "expected a table") .. ", got " .. type(value))
    end
end

function assertions.is_string(value, message)
    if type(value) ~= "string" then
        fail((message or "expected a string") .. ", got " .. type(value))
    end
end

function assertions.is_number(value, message)
    if type(value) ~= "number" then
        fail((message or "expected a number") .. ", got " .. type(value))
    end
end

function assertions.is_function(value, message)
    if type(value) ~= "function" then
        fail((message or "expected a function") .. ", got " .. type(value))
    end
end

function assertions.is_boolean(value, message)
    if type(value) ~= "boolean" then
        fail((message or "expected a boolean") .. ", got " .. type(value))
    end
end

function assertions.truthy(value, message)
    if not value then
        fail((message or "expected a truthy value") .. ", got " .. render(value))
    end
end

function assertions.falsy(value, message)
    if value then
        fail((message or "expected a falsy value") .. ", got " .. render(value))
    end
end

-- busted spells these both ways, and a spec that picks the wrong one should
-- not fail for that reason alone.
assertions.is_truthy = assertions.truthy
assertions.is_falsy = assertions.falsy

local function prefix(message)
    return message and (message .. ": ") or ""
end

function assertions.equals(expected, actual, message)
    if expected ~= actual then
        fail(string.format("%sexpected %s, got %s", prefix(message), render(expected), render(actual)))
    end
end

function assertions.same(expected, actual, message)
    if not deepEqual(expected, actual) then
        fail(string.format("%sexpected %s, got %s", prefix(message), render(expected), render(actual)))
    end
end

function assertions.matches(pattern, actual, message)
    if type(actual) ~= "string" or not actual:find(pattern) then
        fail(string.format("%sexpected %s to match %s", prefix(message), render(actual), render(pattern)))
    end
end

function assertions.has_error(fn, expected)
    local ok, err = pcall(fn)
    if ok then
        fail("expected an error, but none was raised")
    end
    if expected and not tostring(err):find(tostring(expected), 1, true) then
        fail(string.format("expected error %s, got %s", render(expected), render(tostring(err))))
    end
end

function assertions.has_no_error(fn, message)
    local ok, err = pcall(fn)
    if not ok then
        fail((message or "expected no error") .. ", got " .. render(tostring(err)))
    end
end

-- busted's assert is callable and carries the named assertions; both forms are
-- used in the specs, so both work here.
local assert_table = setmetatable({}, {
    __index = function(_, key)
        local named = assertions[key]
        if named then
            return named
        end
        -- assert.is_not.same(...) and friends are not supported; say so loudly
        -- rather than silently passing.
        error("busted_lite does not implement assert." .. tostring(key), 2)
    end,
    __call = function(_, value, message)
        if not value then
            fail(message or "assertion failed")
        end
        return value
    end,
})

--- Install the DSL into a table (normally `_G`).
-- @tparam[opt=_G] table env
function Lite.install(env)
    env = env or _G
    env.describe = describe
    env.it = it
    env.pending = pending
    env.setup = setup
    env.teardown = teardown
    env.before_each = before_each
    env.after_each = after_each
    env.assert = assert_table
    return env
end

--- Print the summary. Returns true when everything passed.
-- @treturn boolean
function Lite.report()
    io.write("\n\n")
    for _, failure in ipairs(Lite.failures) do
        io.write("FAILED: " .. failure.name .. "\n  " .. failure.err .. "\n\n")
    end
    io.write(string.format("%d passed, %d failed, %d pending\n", Lite.passed, Lite.failed, Lite.skipped))
    return Lite.failed == 0
end

return Lite
