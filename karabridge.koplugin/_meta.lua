local _ = require("gettext")

-- `name` is deliberately absent: PluginLoader derives it from the directory
-- ("karabridge", from karabridge.koplugin) and logs a deprecation warning for
-- any plugin that sets it here. See frontend/pluginloader.lua.
return {
    -- The arrow as explicit UTF-8 bytes, not a \u escape: see
    -- karabridge/shared/text.lua for why those are avoided.
    fullname = _("KaraBridge (Karakeep \226\134\148 KOReader)"),
    description = _([[
Two-way bridge between Karakeep and KOReader.

Downloads Karakeep articles for offline reading and sends reading status and highlights back, and exports
highlights and notes from your own EPUB and PDF books as one Karakeep card per book.]]),
    version = "0.0.1",
    author = "encodedLife",
}
