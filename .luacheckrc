-- Luacheck configuration for KaraBridge.
--
--   luacheck karabridge.koplugin spec scripts
--
-- KOReader's own .luacheckrc is the model here; the notable difference is that
-- KaraBridge is an external plugin, so it only declares the KOReader globals it
-- is actually allowed to touch rather than the whole set.

std = "lua51"

-- KOReader creates these before any plugin is loaded. They are read-only from a
-- plugin's point of view: writing to them would leak state across plugins.
read_globals = {
    "G_reader_settings",
    "G_defaults",
}

-- The gettext idiom `local _ = require("gettext")` shadows the throwaway
-- variable name used in `for _, v in ipairs(...)`. KOReader accepts this
-- everywhere, so both plugin and spec code do too.
ignore = {
    "212/_",   -- unused argument `_`
    "213/_",   -- unused loop variable `_`
    "421/_",   -- shadowing an upvalue named `_`
    "431/_",   -- shadowing an upvalue named `_`
    "542",     -- empty if branch (used for documented "do nothing" cases)
}

max_line_length = 120

files["spec/"] = {
    -- Busted's DSL is injected into the spec environment by the runner.
    read_globals = {
        "describe", "it", "setup", "teardown",
        "before_each", "after_each",
        "assert", "spy", "stub", "mock",
        "pending", "finally",
    },
}

exclude_files = {
}
