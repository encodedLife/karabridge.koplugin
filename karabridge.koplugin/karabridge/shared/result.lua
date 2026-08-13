--[[--
The single success/failure value used across KaraBridge module boundaries.

Failures can be returned in many shapes -- positionally, as
`(false, "network_error", 503)`, or as
`(nil, Error.new("..."))`. Neither carries a stable machine-readable code
*and* a message a user can read, so callers end up matching on English
strings. A Result carries both, plus optional details for the log.

Codes are the contract; messages are for humans and may be reworded freely.

    local ok = Result.ok(bookmark)
    local bad = Result.err("unauthorized", "Karakeep rejected the API key.")

    if result:isOk() then
        use(result.value)
    else
        logger.warn(result:describe())
    end

This module has no KOReader dependencies.

@module karabridge.shared.result
]]

local Result = {}
Result.__index = Result

--- A successful result.
-- @param value any The payload; may be nil for operations with no return value.
-- @treturn Result
function Result.ok(value)
    return setmetatable({ ok = true, value = value }, Result)
end

--- A failed result.
-- @tparam string code Stable machine-readable code, e.g. "unauthorized".
-- @tparam[opt] string message Human-readable explanation.
-- @tparam[opt] table details Extra context for logs; never shown to the user.
-- @treturn Result
function Result.err(code, message, details)
    return setmetatable({
        ok = false,
        code = code or "unknown",
        message = message,
        details = details,
    }, Result)
end

--- Is this value a Result?
-- @param value any
-- @treturn boolean
function Result.is(value)
    return getmetatable(value) == Result
end

function Result:isOk()
    return self.ok == true
end

function Result:isErr()
    return self.ok ~= true
end

--- The error code, or nil on success.
-- @treturn string|nil
function Result:errorCode()
    if self.ok then
        return nil
    end
    return self.code
end

--- The value, or `fallback` when this is an error.
-- @param fallback any
-- @return any
function Result:valueOr(fallback)
    if self.ok then
        return self.value
    end
    return fallback
end

--- Apply `fn` to the value of a successful result, passing errors through.
--
-- `fn` may return a plain value or another Result; both are accepted so that
-- chains do not have to wrap every intermediate step.
--
-- @tparam function fn
-- @treturn Result
function Result:map(fn)
    if not self.ok then
        return self
    end
    local mapped = fn(self.value)
    if Result.is(mapped) then
        return mapped
    end
    return Result.ok(mapped)
end

--- A one-line description suitable for a log entry.
--
-- Never include a token here: callers pass secrets through
-- `karabridge.shared.logging`.mask() before they reach `details`.
--
-- @treturn string
function Result:describe()
    if self.ok then
        return "ok"
    end
    if self.message and self.message ~= "" then
        return string.format("%s: %s", self.code, self.message)
    end
    return self.code
end

return Result
