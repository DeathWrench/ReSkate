-- An INI file as Windows' private profile functions read it (GetPrivateProfileString and friends,
-- which the companion uses): sections and keys without regard to case, a value is what follows the
-- first "=" with the spaces around it trimmed. Every line it does not change is written back as it
-- was, comments, blank lines, unknown keys and the order of everything included.
local M = {}

local function trim(text) return (string.gsub(text, "^%s*(.-)%s*$", "%1")) end
local function lower(text) return string.lower(text) end

-- parse(text): {lines = {...}, newline = "\r\n" or "\n"}. Each line is one of
-- {section = name}, {key = name, value = text} or {raw = text}; a section or key line keeps its
-- `raw` text until it is changed.
function M.parse(text)
    local doc = {lines = {}, newline = if string.find(text or "", "\r\n", 1, true) or (text or "") == "" then "\r\n" else "\n"}
    for line in string.gmatch((text or "") .. "\n", "([^\n]*)\n") do
        line = string.gsub(line, "\r$", "")
        local stripped = trim(line)
        local section = string.match(stripped, "^%[(.-)%]$")
        local key, value = string.match(line, "^%s*([^=;#%[][^=]-)%s*=(.*)$")
        if section then
            table.insert(doc.lines, {section = trim(section), raw = line})
        elseif key and trim(key) ~= "" then
            table.insert(doc.lines, {key = trim(key), value = trim(value), raw = line})
        else
            table.insert(doc.lines, {raw = line})
        end
    end
    -- The split above makes one empty line past the last newline: drop it.
    local last = doc.lines[#doc.lines]
    if last and not last.key and not last.section and last.raw == "" then table.remove(doc.lines) end
    return doc
end

-- The lines of a section: the index of its header and of the line past its last line, or nil.
local function bounds(doc, section)
    local name = lower(section)
    for i, line in doc.lines do
        if line.section and lower(line.section) == name then
            local last = i
            for j = i + 1, #doc.lines do
                if doc.lines[j].section then break end
                if doc.lines[j].key or doc.lines[j].section or trim(doc.lines[j].raw) ~= "" then last = j end
            end
            return i, last + 1
        end
    end
    return nil
end

-- A blank line: no section, no key, nothing but spaces.
function M.blank(line) return not line.key and not line.section and trim(line.raw) == "" end

function M.has_section(doc, section) return bounds(doc, section) ~= nil end

-- get(doc, section, key): the value, or nil. The first of a key wins, as for Windows.
function M.get(doc, section, key)
    local first, past = bounds(doc, section)
    if not first then return nil end
    local name = lower(key)
    for i = first + 1, past - 1 do
        local line = doc.lines[i]
        if line.key and lower(line.key) == name then return line.value end
    end
    return nil
end

-- number(doc, section, key, fallback): as GetPrivateProfileInt, the whole number a value starts with.
function M.number(doc, section, key, fallback)
    local value = M.get(doc, section, key)
    local digits = value and string.match(value, "^%s*([+-]?%d+)")
    return if digits then tonumber(digits) else fallback
end

-- set(doc, section, key, value): in its place when the key is there, else at the end of the section,
-- else in a new section at the end of the file.
function M.set(doc, section, key, value)
    value = tostring(value)
    local first, past = bounds(doc, section)
    if not first then
        if #doc.lines > 0 and not M.blank(doc.lines[#doc.lines]) then
            table.insert(doc.lines, {raw = ""})
        end
        table.insert(doc.lines, {section = section})
        table.insert(doc.lines, {key = key, value = value})
        return
    end
    local name = lower(key)
    for i = first + 1, past - 1 do
        local line = doc.lines[i]
        if line.key and lower(line.key) == name then
            line.value, line.raw = value, nil
            return
        end
    end
    table.insert(doc.lines, past, {key = key, value = value})
end

-- entries(doc, section): {{key, value}, ...} in file order, the first of each key only.
function M.entries(doc, section)
    local out, seen = {}, {}
    local first, past = bounds(doc, section)
    if not first then return out end
    for i = first + 1, past - 1 do
        local line = doc.lines[i]
        if line.key and not seen[lower(line.key)] then
            seen[lower(line.key)] = true
            table.insert(out, {key = line.key, value = line.value})
        end
    end
    return out
end

-- replace_section(doc, section, list): the section holds exactly these {key, value} pairs, as
-- WritePrivateProfileSection leaves it; made at the end of the file when there is none.
function M.replace_section(doc, section, list)
    local first, past = bounds(doc, section)
    local lines = {}
    for _, pair in list do table.insert(lines, {key = pair.key, value = tostring(pair.value)}) end
    if not first then
        if #doc.lines > 0 and not M.blank(doc.lines[#doc.lines]) then
            table.insert(doc.lines, {raw = ""})
        end
        table.insert(doc.lines, {section = section})
        for _, line in lines do table.insert(doc.lines, line) end
        return
    end
    for _ = first + 1, past - 1 do table.remove(doc.lines, first + 1) end
    for i, line in lines do table.insert(doc.lines, first + i, line) end
end

function M.dump(doc)
    local out = {}
    for _, line in doc.lines do
        if line.raw then table.insert(out, line.raw)
        elseif line.section then table.insert(out, "[" .. line.section .. "]")
        else table.insert(out, line.key .. "=" .. line.value) end
    end
    return table.concat(out, doc.newline) .. doc.newline
end

return M
