--[[--
An in-memory stand-in for KOReader's LuaSettings.

Only the five methods `karabridge.config.settings` actually uses, which is the
point: a mock that reimplements all of LuaSettings would drift from it and
start passing tests the real thing would fail.

`flush_count` is exposed because "did this write to disk, and how often" is
behaviour worth asserting — a settings layer that flushes on every keystroke
wears out a Kobo's flash.

@module spec.mocks.luasettings
]]

local MockLuaSettings = {}
MockLuaSettings.__index = MockLuaSettings

--- @tparam[opt] table initial Values already "on disk".
function MockLuaSettings.new(initial)
    local data = {}
    for key, value in pairs(initial or {}) do
        data[key] = value
    end

    return setmetatable({ data = data, flush_count = 0 }, MockLuaSettings)
end

function MockLuaSettings:readSetting(key, default)
    if self.data[key] == nil and default ~= nil then
        -- Faithful to the real thing: reading with a default writes it back,
        -- which is exactly the behaviour config seeding has to work around.
        self.data[key] = default
    end
    return self.data[key]
end

function MockLuaSettings:saveSetting(key, value)
    self.data[key] = value
    return self
end

function MockLuaSettings:delSetting(key)
    self.data[key] = nil
    return self
end

function MockLuaSettings:has(key)
    return self.data[key] ~= nil
end

function MockLuaSettings:flush()
    self.flush_count = self.flush_count + 1
    return self
end

return MockLuaSettings
