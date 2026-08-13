--[[--
Markdown to the small subset of HTML an EPUB needs.

A **fallback**, not a general-purpose converter. It is reached in two cases:

  * a Karakeep *text* bookmark, whose body is markdown by definition;
  * a link bookmark with no crawled HTML at all, where the readable-content
    endpoint is the last resort and serves markdown.

Both are situations where getting something readable onto the device matters
much more than rendering every CommonMark corner. Headings, lists (bulleted and
numbered), block quotes, fenced code, horizontal rules, images, links, bold,
italic and inline code are covered; tables, footnotes, nested lists and
reference links are not.

Pure Lua, no KOReader dependencies.

@module karabridge.formats.markdown_html
]]

local Text = require("karabridge.shared.text")

local MarkdownHtml = {}

--- Convert markdown to HTML.
-- @tparam any md
-- @treturn string
function MarkdownHtml.render(md)
    if type(md) ~= "string" then
        return ""
    end

    local out = {}
    local in_code = false
    local list_kind = nil -- nil, "ul" or "ol"

    local function closeList()
        if list_kind then
            table.insert(out, "</" .. list_kind .. ">")
            list_kind = nil
        end
    end

    local function openList(kind)
        if list_kind ~= kind then
            closeList()
            table.insert(out, "<" .. kind .. ">")
            list_kind = kind
        end
    end

    -- Inline spans. Escaping happens first, so any HTML in the markdown is
    -- shown as text rather than interpreted -- the markdown here comes from a
    -- crawler and is not to be trusted with markup.
    local function inline(text)
        text = Text.escapeXml(text)

        -- Images before links: the two syntaxes differ only by a leading "!".
        text = text:gsub("!%[([^%]]*)%]%((%S-)%)", function(alt, src)
            if alt == "" then
                -- An empty alt attribute becomes a bare one after crengine
                -- balances the document, which is not well-formed XML.
                return string.format('<img src="%s"/>', src)
            end
            return string.format('<img src="%s" alt="%s"/>', src, alt)
        end)
        text = text:gsub("%[([^%]]*)%]%((%S-)%)", function(label, href)
            return string.format('<a href="%s">%s</a>', href, label)
        end)

        text = text:gsub("`([^`]+)`", "<code>%1</code>")
        text = text:gsub("%*%*([^%*]+)%*%*", "<strong>%1</strong>")
        text = text:gsub("__([^_]+)__", "<strong>%1</strong>")
        text = text:gsub("%*([^%*]+)%*", "<em>%1</em>")

        return text
    end

    for line in (md .. "\n"):gmatch("(.-)\r?\n") do
        if line:match("^%s*```") then
            closeList()
            table.insert(out, in_code and "</pre>" or "<pre>")
            in_code = not in_code
        elseif in_code then
            -- Inside a fence everything is literal, including markdown syntax.
            table.insert(out, Text.escapeXml(line))
        else
            local hashes, heading = line:match("^(#+)%s+(.*)$")
            local bullet = line:match("^%s*[%*%-%+]%s+(.*)$")
            local numbered = line:match("^%s*%d+[%.%)]%s+(.*)$")
            local quote = line:match("^%s*>%s?(.*)$")

            if heading then
                closeList()
                local level = math.min(#hashes, 6)
                table.insert(out, string.format("<h%d>%s</h%d>", level, inline(heading), level))
            elseif bullet then
                openList("ul")
                table.insert(out, "<li>" .. inline(bullet) .. "</li>")
            elseif numbered then
                openList("ol")
                table.insert(out, "<li>" .. inline(numbered) .. "</li>")
            elseif quote then
                closeList()
                table.insert(out, "<blockquote>" .. inline(quote) .. "</blockquote>")
            elseif line:match("^%s*[%-%*_]%s*[%-%*_]%s*[%-%*_][%s%-%*_]*$") then
                closeList()
                table.insert(out, "<hr/>")
            elseif line:match("^%s*$") then
                closeList()
            else
                closeList()
                table.insert(out, "<p>" .. inline(line) .. "</p>")
            end
        end
    end

    closeList()
    if in_code then
        -- An unterminated fence: close it rather than emit unbalanced markup.
        table.insert(out, "</pre>")
    end

    return table.concat(out, "\n")
end

return MarkdownHtml
