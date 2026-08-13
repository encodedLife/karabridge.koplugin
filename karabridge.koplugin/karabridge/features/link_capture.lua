--[[--
"Save to Karakeep" on a link tapped while reading.

KOReader shows a dialog for an external link, and `ReaderLink` lets a plugin
add a button to it — `addToExternalLinkDialog(idx, fn)`, where `idx` orders the
buttons among the others. This is the hook KOReader offers for it, and
it is the right one.

This is the operation the queue exists for. Everything else KaraBridge sends
can be reconstructed from something durable: reading status from the `.sdr`
sidecar, a book card from the book's highlights. A link tapped while offline is
recorded nowhere. If it is not queued at the moment it is tapped, it is gone.

So the flow is: online, send it now; offline or the send failed, queue it. The
user is told which happened, because "saved" and "saved when you next have
Wi-Fi" are different promises.

@module karabridge.features.link_capture
]]

local Bookmarks = require("karabridge.api.bookmarks")
local Logging = require("karabridge.shared.logging")
local Notification = require("karabridge.shared.notification")
local Connectivity = require("karabridge.features.connectivity")

local log = Logging.forModule("link_capture")

local LinkCapture = {}

-- Ordering among the other buttons in the external-link dialog. Deliberately
-- after KOReader's own actions, which are what most taps want.
LinkCapture.BUTTON_ID = "50_karabridge_save"

--- Is the device connected right now?
--
-- Asked, rather than prompted for: this is reached from a dialog the user
-- opened for a different reason, and asking them to turn Wi-Fi on because they
-- tapped a link would be presumptuous. Queue it instead.
--
-- `Connectivity.isConnected` and not `NetworkMgr:isOnline`, because the latter
-- resolves a hostname to decide -- see `features/connectivity.lua`. With that
-- domain blocklisted, every tapped link went to the queue on a device that was
-- perfectly able to send it.
local function isOnline()
    return Connectivity.isConnected()
end

--- Save a link, or queue it when that is not possible.
--
-- @tparam table plugin Needs `settings`, `getClient` and `queue`.
-- @tparam string url
-- @treturn string One of "saved", "queued", "unconfigured".
function LinkCapture.save(plugin, url)
    if type(url) ~= "string" or url == "" then
        return "unconfigured"
    end

    if not plugin.settings:readiness().connect then
        Notification.alert("Set the Karakeep server address and API key first.")
        return "unconfigured"
    end

    if not isOnline() then
        plugin.queue:queueLink(url)
        plugin.queue.store:flush()
        Notification.info("Will be saved to Karakeep at the next sync.")
        return "queued"
    end

    local created = Bookmarks.new(plugin:getClient()):createLink({ url = url })

    if created:isOk() then
        Notification.info("Saved to Karakeep.")
        return "saved"
    end

    log.warn("could not save", url, "-", created:describe(), "- queueing instead")
    plugin.queue:queueLink(url)
    plugin.queue.store:flush()
    Notification.info("Karakeep could not be reached. It will be saved at the next sync.")

    return "queued"
end

--- Add the button to KOReader's external-link dialog.
--
-- Called from `init()` and only in the reader: `self.ui.link` exists on a
-- ReaderUI and not on a FileManager, which is why this checks rather than
-- assumes.
--
-- @tparam table plugin
function LinkCapture.attach(plugin)
    local ui = plugin.ui
    if not ui or not ui.link or type(ui.link.addToExternalLinkDialog) ~= "function" then
        return false
    end

    ui.link:addToExternalLinkDialog(LinkCapture.BUTTON_ID, function(this, link_url)
        return {
            text = "Save to Karakeep",
            callback = function()
                local UIManager = require("ui/uimanager")
                UIManager:close(this.external_link_dialog)
                LinkCapture.save(plugin, link_url)
            end,
        }
    end)

    log.dbg("attached to the external link dialog")
    return true
end

return LinkCapture
