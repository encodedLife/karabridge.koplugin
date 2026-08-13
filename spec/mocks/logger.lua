--[[--
A capturing log sink.

Its real job is the security assertion: after a request, every line this
collected is searched for the API token, and finding it fails the spec. That
check is worth more than any amount of care at each individual call site,
because it catches the next person's `logger.dbg("request", request)` too.

@module spec.mocks.logger
]]

local MockLogger = {}

MockLogger.lines = {}

local function record(level)
    return function(...)
        local parts = {}
        for index = 1, select("#", ...) do
            parts[index] = tostring((select(index, ...)))
        end
        table.insert(MockLogger.lines, { level = level, text = table.concat(parts, " ") })
    end
end

MockLogger.dbg = record("dbg")
MockLogger.info = record("info")
MockLogger.warn = record("warn")
MockLogger.err = record("err")

--- Forget everything logged so far.
function MockLogger.reset()
    MockLogger.lines = {}
end

--- Everything logged, as one string.
-- @treturn string
function MockLogger.text()
    local parts = {}
    for index, line in ipairs(MockLogger.lines) do
        parts[index] = line.level .. " " .. line.text
    end
    return table.concat(parts, "\n")
end

--- Does anything logged contain this substring?
-- @tparam string needle
-- @treturn boolean
function MockLogger.contains(needle)
    return MockLogger.text():find(needle, 1, true) ~= nil
end

return MockLogger
