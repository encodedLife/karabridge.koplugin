--[[--
Entry point for the fallback unit-test run.

Used by `scripts/test-unit.sh` when the real busted is not available. Spec
files are passed as arguments rather than discovered here, so the shell does
the globbing and this stays a plain Lua 5.1 script with no filesystem library.

    lua5.1 spec/support/run_unit.lua spec/unit/*_spec.lua

@script spec.support.run_unit
]]

local function repositoryRoot()
    local source = debug.getinfo(1, "S").source:sub(2)
    return (source:gsub("/spec/support/run_unit%.lua$", ""))
end

local root = repositoryRoot()
package.path = table.concat({
    root .. "/?.lua",
    root .. "/?/init.lua",
    package.path,
}, ";")

local Lite = require("spec.support.busted_lite")
Lite.install(_G)

local files = { ... }
if #files == 0 then
    io.stderr:write("usage: run_unit.lua <spec files...>\n")
    os.exit(2)
end

for _, file in ipairs(files) do
    local chunk, err = loadfile(file)
    if not chunk then
        io.write("\n")
        io.stderr:write("could not load " .. file .. ": " .. tostring(err) .. "\n")
        os.exit(1)
    end

    local ok, run_err = xpcall(chunk, function(e)
        return tostring(e) .. "\n" .. debug.traceback("", 2)
    end)
    if not ok then
        io.write("\n")
        io.stderr:write("error while running " .. file .. ":\n" .. tostring(run_err) .. "\n")
        os.exit(1)
    end
end

os.exit(Lite.report() and 0 or 1)
