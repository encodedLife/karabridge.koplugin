--[[--
User-facing messages, in one place.

Two levels of intrusiveness, chosen by whether the user asked for the thing
that is now finished:

  * `Notification` — a corner toast. For anything that happened on its own,
    such as an automatic sync. It must never interrupt reading.
  * `InfoMessage` — a modal. For the result of something the user just tapped.

Keeping both behind one module means a feature never has to decide which
widget to require, and a future "quiet mode" setting has exactly one place to
take effect.

Everything is required lazily so that features which merely *can* notify stay
loadable in the specs.

@module karabridge.shared.notification
]]

local Notification = {}

local overrides

--- Replace the widget layer. Used by the specs to capture messages.
-- @tparam table|nil sink Table with info/alert functions, or nil to reset.
function Notification.setBackend(sink)
    overrides = sink
end

--- A non-blocking toast in the corner of the screen.
-- @tparam string text
function Notification.info(text)
    if overrides then
        return overrides.info(text)
    end

    local ok, Widget = pcall(require, "ui/widget/notification")
    if not ok then
        return
    end
    require("ui/uimanager"):show(Widget:new({ text = text }))
end

--- A modal the user has to dismiss.
-- @tparam string text
-- @tparam[opt] number timeout Seconds before it closes itself.
function Notification.alert(text, timeout)
    if overrides then
        return overrides.alert(text, timeout)
    end

    local ok, Widget = pcall(require, "ui/widget/infomessage")
    if not ok then
        return
    end
    require("ui/uimanager"):show(Widget:new({ text = text, timeout = timeout }))
end

--- Show `text` as a toast when `quiet`, and as a modal otherwise.
--
-- The single decision every sync entry point has to make, so it is made here
-- once rather than duplicated at each call site.
--
-- @tparam string text
-- @tparam boolean quiet
function Notification.report(text, quiet)
    if quiet then
        return Notification.info(text)
    end
    return Notification.alert(text)
end

return Notification
