--[[--
Builds the deterministic EPUB the round-trip test uses.

Run from the repository root with any Lua 5.1:

    lua5.1 spec/fixtures/ebooks/build_fixture.lua

It writes `spec/fixtures/ebooks/karabridge-test.epub`. The file is generated
rather than committed as a binary so that what is in it can be reviewed as
text, and so a regeneration is reproducible: every timestamp inside the archive
is fixed, so two builds produce byte-identical output.

## What the content is for

Each sentence exists to exercise something specific:

| Sentence | Tests |
|---|---|
| `The first unique sentence in chapter one.` | plain ASCII matching |
| `Ein Satz mit Umlauten: ä ö ü ß.` | UTF-8 vs UTF-16 offsets |
| `A sentence with an emoji 😀 in the middle.` | surrogate pairs — two UTF-16 units for one code point |
| `This exact sentence appears in both chapters.` | duplicate text; the case text alone cannot resolve |

The repeated sentence is the important one. It is what proves the fingerprint
does its job: highlighted in both chapters it must produce two distinct
Karakeep highlights that stay mapped to the right local annotations.

The zip is written by hand — store-only, no compression — so this needs no
libarchive and runs anywhere. An EPUB reader accepts a stored-only archive;
`mimetype` still has to be first.

@script spec.fixtures.ebooks.build_fixture
]]

local OUTPUT = "spec/fixtures/ebooks/karabridge-test.epub"

-- Fixed, so two builds are byte-identical. 2020-01-01 00:00:00.
local DOS_TIME = 0
local DOS_DATE = 40 * 512 -- (2020-1980) << 9

local CHAPTER_ONE = [[<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Chapter One</title></head>
<body>
<h1>Chapter One</h1>
<p>The first unique sentence in chapter one.</p>
<p>Ein Satz mit Umlauten: &#228; &#246; &#252; &#223;.</p>
<p>A sentence with an emoji &#128512; in the middle.</p>
<p>This exact sentence appears in both chapters.</p>
</body>
</html>
]]

local CHAPTER_TWO = [[<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Chapter Two</title></head>
<body>
<h1>Chapter Two</h1>
<p>This exact sentence appears in both chapters.</p>
<p>Another unique sentence, this one in chapter two.</p>
</body>
</html>
]]

local CONTAINER = [[<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
]]

local OPF = [[<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="2.0">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:title>KaraBridge Test Book</dc:title>
<dc:creator>KaraBridge Test Suite</dc:creator>
<dc:identifier id="bookid">urn:karabridge:test-fixture-1</dc:identifier>
<dc:language>en</dc:language>
</metadata>
<manifest>
<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
<item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
<item id="ch2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
</manifest>
<spine toc="ncx"><itemref idref="ch1"/><itemref idref="ch2"/></spine>
</package>
]]

local NCX = [[<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head><meta name="dtb:uid" content="urn:karabridge:test-fixture-1"/></head>
<docTitle><text>KaraBridge Test Book</text></docTitle>
<navMap>
<navPoint id="np1" playOrder="1"><navLabel><text>Chapter One</text></navLabel><content src="chapter1.xhtml"/></navPoint>
<navPoint id="np2" playOrder="2"><navLabel><text>Chapter Two</text></navLabel><content src="chapter2.xhtml"/></navPoint>
</navMap>
</ncx>
]]

--- Bitwise xor, in plain Lua 5.1, which has no bit library.
local function xor(a, b)
    local result, bit = 0, 1
    while a > 0 or b > 0 do
        local abit, bbit = a % 2, b % 2
        if abit ~= bbit then
            result = result + bit
        end
        a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
    end
    return result
end

-- The standard CRC-32 table, built once. 0xEDB88320 is the reversed polynomial.
local crc_table = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        if c % 2 == 1 then
            c = xor(math.floor(c / 2), 3988292384)
        else
            c = math.floor(c / 2)
        end
    end
    crc_table[i] = c
end

--- CRC-32 of a string. The zip format requires it per entry.
local function crc32(s)
    local crc = 4294967295
    for i = 1, #s do
        crc = xor(math.floor(crc / 256), crc_table[xor(crc % 256, s:byte(i))])
    end
    return xor(crc, 4294967295)
end

local function le(value, bytes)
    local out = {}
    for _ = 1, bytes do
        table.insert(out, string.char(value % 256))
        value = math.floor(value / 256)
    end
    return table.concat(out)
end

--- Write a store-only zip.
local function writeZip(path, entries)
    local parts, directory = {}, {}
    local offset = 0

    for _, entry in ipairs(entries) do
        local name, data = entry[1], entry[2]
        local crc = crc32(data)

        local local_header = table.concat({
            "PK\3\4",
            le(20, 2), -- version needed
            le(0, 2), -- flags
            le(0, 2), -- method: store
            le(DOS_TIME, 2),
            le(DOS_DATE, 2),
            le(crc, 4),
            le(#data, 4),
            le(#data, 4),
            le(#name, 2),
            le(0, 2),
            name,
        })

        table.insert(parts, local_header)
        table.insert(parts, data)

        table.insert(
            directory,
            table.concat({
                "PK\1\2",
                le(20, 2),
                le(20, 2),
                le(0, 2),
                le(0, 2),
                le(DOS_TIME, 2),
                le(DOS_DATE, 2),
                le(crc, 4),
                le(#data, 4),
                le(#data, 4),
                le(#name, 2),
                le(0, 2),
                le(0, 2),
                le(0, 2),
                le(0, 2),
                le(0, 4),
                le(offset, 4),
                name,
            })
        )

        offset = offset + #local_header + #data
    end

    local central = table.concat(directory)
    local ending = table.concat({
        "PK\5\6",
        le(0, 2),
        le(0, 2),
        le(#entries, 2),
        le(#entries, 2),
        le(#central, 4),
        le(offset, 4),
        le(0, 2),
    })

    local handle = assert(io.open(path, "wb"))
    handle:write(table.concat(parts))
    handle:write(central)
    handle:write(ending)
    handle:close()
end

writeZip(OUTPUT, {
    -- mimetype first and stored, per the EPUB specification.
    { "mimetype", "application/epub+zip" },
    { "META-INF/container.xml", CONTAINER },
    { "OEBPS/content.opf", OPF },
    { "OEBPS/toc.ncx", NCX },
    { "OEBPS/chapter1.xhtml", CHAPTER_ONE },
    { "OEBPS/chapter2.xhtml", CHAPTER_TWO },
})

print("wrote " .. OUTPUT)
