--[[--
Choosing the article download folder.

Folder selection is centralised here — the picker, the persistence and the
validation — rather than inlined in the menu, because three separate things
have to hold together and each has a way of going quietly wrong:

  * **The picker.** KOReader's `ui/downloadmgr` wraps `PathChooser` and is what
    KOReader offers for choosing a folder. Typing a path by
    hand is offered as well, but never *instead*: on a Kobo the picker is the
    only way to discover where the storage is actually mounted.
  * **Cancellation.** `DownloadMgr:chooseDir()` calls `onConfirm` only when the
    user confirms; dismissing the chooser calls nothing. So cancelling is
    harmless by construction and there is deliberately no cancel callback here
    to get wrong.
  * **Validation.** A folder that exists is not necessarily writable. Under
    Flatpak an unreachable folder is the *likely* default, and without an
    upfront check the failure surfaces later as every single article failing to
    build, one confusing line at a time, from inside the zip writer. That is
    this and added the same probe; the reasoning is reproduced here rather than
    the code.

@module karabridge.features.menu.download_folder
]]

local Filesystem = require("karabridge.shared.filesystem")
local Logging = require("karabridge.shared.logging")

local log = Logging.forModule("menu.download_folder")

local DownloadFolder = {}

--- Text for the menu item, showing the folder that is actually in use.
--
-- The full path, not a shortened one: on a device with both internal storage
-- and an SD card, the leading part is the only thing that distinguishes them,
-- and that is precisely what a user needs to check.
--
-- @tparam table settings A `karabridge.config.settings`.
-- @treturn string
function DownloadFolder.describe(settings)
    local folder = settings:get("download_folder")
    if not folder or folder == "" then
        return "Download folder: not set"
    end
    return "Download folder: " .. folder
end

--- Save a chosen folder, after checking it can be written to.
--
-- Saved either way. A folder that is momentarily unwritable — an SD card not
-- yet mounted, say — is still the folder the user meant, and discarding their
-- choice to punish a transient condition helps nobody. The problem is reported
-- and the setting kept.
--
-- @tparam table settings
-- @tparam string path
-- @treturn table { ok, path, message }
function DownloadFolder.apply(settings, path)
    if type(path) ~= "string" or path == "" then
        return { ok = false, message = "No folder was chosen." }
    end

    local saved, problem = settings:set("download_folder", path)
    if not saved then
        return { ok = false, path = path, message = problem }
    end
    settings:flush()

    local check = Filesystem.checkWritableDirectory(path)
    if check:isErr() then
        log.warn("download folder is not usable:", path, "-", check:describe())

        local message
        if check:errorCode() == "mkdir_failed" then
            message = "This folder does not exist and could not be created:\n\n" .. path
        else
            message = table.concat({
                "This folder cannot be written to:",
                "",
                path,
                "",
                "If KOReader is running as a Flatpak, the sandbox may not reach it. Check with:",
                "flatpak info --show-permissions rocks.koreader.KOReader",
            }, "\n")
        end

        return { ok = false, path = path, message = message }
    end

    log.info("download folder set to", path)
    return { ok = true, path = path }
end

--- Open the native folder picker.
--
-- @tparam table settings
-- @tparam[opt] function on_done Called with the result of `apply()`.
function DownloadFolder.choose(settings, on_done)
    local ok, DownloadMgr = pcall(require, "ui/downloadmgr")
    if not ok then
        log.err("ui/downloadmgr is unavailable; cannot open the folder picker")
        if on_done then
            on_done({ ok = false, message = "The folder picker is not available." })
        end
        return
    end

    DownloadMgr:new({
        title = "Choose the KaraBridge download folder",
        onConfirm = function(path)
            local outcome = DownloadFolder.apply(settings, path)
            if on_done then
                on_done(outcome)
            end
        end,
    }):chooseDir(settings:get("download_folder"))
end

--- Type a path by hand. A fallback, not a replacement for the picker.
--
-- Useful over SSH, in the emulator, and for a path the picker cannot reach
-- because it is not mounted at the moment.
--
-- @tparam table settings
-- @tparam[opt] function on_done Called with the result of `apply()`.
function DownloadFolder.enterManually(settings, on_done)
    local ok, InputDialog = pcall(require, "ui/widget/inputdialog")
    if not ok then
        return
    end
    local UIManager = require("ui/uimanager")

    local dialog
    dialog = InputDialog:new({
        title = "Download folder",
        description = "Full path to the folder. It is created if it does not exist.",
        input = settings:get("download_folder") or "",
        buttons = {
            {
                {
                    text = "Cancel",
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = "Save",
                    callback = function()
                        local path = dialog:getInputText()
                        UIManager:close(dialog)
                        local outcome = DownloadFolder.apply(settings, path)
                        if on_done then
                            on_done(outcome)
                        end
                    end,
                },
            },
        },
    })

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return DownloadFolder
