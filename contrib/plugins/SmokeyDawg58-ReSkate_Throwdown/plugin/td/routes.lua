-- SmokeyDawg58's race_route_library.h / race_route_library.cpp and race_route_json.h, line for line:
-- his saved Deathrace routes, one JSON file a route in a folder a map, read back with their ids and
-- names. His folder was <game>/Mods/ReSkateRoutes/Deathrace/<map>/<name>.json; here it is "routes/"
-- in the plugin's own data folder, laid out the same (reskate.files:
-- <game>/Mods/.reskate_plugin_data/<plugin>/routes/<map>/<name>.json), so his saves copy straight in.
-- A route is {id, name, map, settings} (settings as td/rules.lua's Settings, positions vectors).
local R = require("td/rules")
local RR = require("td/h/race_route")

local RL = {}
local root = "routes"
local uint64_max = 18446744073709551615

-- ---- race_route_library.h ------------------------------------------------------------------------
-- race_route_name(name): trimmed of blanks, at most 64 characters without control characters ("" if not).
function RL.race_route_name(name)
    local first = string.find(name, "[^ \t\r\n]")
    if not first then return "" end
    local last = #name
    while last > first and string.find(string.sub(name, last, last), "[ \t\r\n]") do last -= 1 end
    name = string.sub(name, first, last)
    if #name > 64 or string.find(name, "[%z\1-\31\127]") then return "" end
    return name
end
-- encode_named_race(route)'s checks (its bytes are the wire's; only its refusal is used here).
local function check_named_race(route)
    local name = RL.race_route_name(route.name)
    if name == "" or route.map == "" or #route.map > 512 or not RR.race_route_ready(route.settings, route.settings.race_finish) then
        error("Name the completed route before saving.", 0)
    end
    if not R.valid_settings(route.settings) then error("Name the completed route before saving.", 0) end
end

-- ---- race_route_json.h -----------------------------------------------------------------------------
local function quote(text)
    return '"' .. string.gsub(text, '[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        if c == "\n" then return "\\n" end
        if c == "\t" then return "\\t" end
        if c == "\r" then return "\\r" end
        return string.format("\\u%04x", string.byte(c))
    end) .. '"'
end
local function number(n)
    if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%d", n) end
    return string.format("%.9g", n)
end
local function numbers(list)
    local out = {}
    for i, n in ipairs(list) do out[i] = number(n) end
    return "[" .. table.concat(out, ", ") .. "]"
end
local function point(v) return "[" .. number(v.x) .. ", " .. number(v.y) .. ", " .. number(v.z) .. "]" end
local function points(list)
    local out = {}
    for i, v in ipairs(list) do out[i] = point(v) end
    return "[" .. table.concat(out, ", ") .. "]"
end
-- encode_named_race_json(route): his data.dump(2), an object of format, version, id, name, map and
-- settings. PORT: written by hand (reskate.json.encode turns an empty list into {}); the keys in his
-- order, every list on one line.
function RL.encode_named_race_json(route)
    check_named_race(route)
    local s = route.settings
    local kinds = {}
    for i, k in ipairs(s.gate_kinds) do kinds[i] = quote(k == "arrow" and "arrow" or k == "guide" and "guide" or "required") end
    local settings = {
        '"duration_seconds": ' .. number(s.duration_s), '"turn_seconds": ' .. number(s.turn_s), '"strikes": ' .. number(s.strikes),
        '"radius": ' .. number(s.radius), '"area_radius": ' .. number(s.area_radius), '"corners": ' .. points(s.corners),
        '"points": ' .. points(s.points), '"yaw_degrees": ' .. numbers(s.yaws), '"half_widths": ' .. numbers(s.widths),
        '"gate_types": [' .. table.concat(kinds, ", ") .. "]", '"arrow_roll_degrees": ' .. numbers(s.arrow_rolls),
        '"pitch_degrees": ' .. numbers(s.gate_pitches), '"spawn": ' .. point(s.spawn), '"has_spawn": ' .. tostring(s.has_spawn),
        '"finish_gate": ' .. tostring(s.race_finish), '"trick_kinds": ' .. number(s.trick_kinds),
    }
    local text = "{\n" ..
        '  "format": "ReSkate Deathrace route",\n' ..
        '  "version": 1,\n' ..
        '  "id": ' .. number(route.id or 0) .. ",\n" ..
        '  "name": ' .. quote(RL.race_route_name(route.name)) .. ",\n" ..
        '  "map": ' .. quote(route.map) .. ",\n" ..
        '  "settings": {\n    ' .. table.concat(settings, ",\n    ") .. "\n  }\n}\n"
    if #text > 65536 then error("This route is too large to save.", 0) end
    return text
end
-- A JSON list (an empty one may come back from reskate.json.decode as an empty table either way).
local function list_of(v)
    if type(v) ~= "table" then error("Invalid route array", 0) end
    local n = #v
    for k in pairs(v) do
        if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then error("Invalid route array", 0) end
    end
    if n > 2048 then error("Invalid route array", 0) end
    return v
end
local function whole(v)
    return type(v) == "number" and v == math.floor(v)
end
-- decode_named_race_json(text): the route, or nil.
function RL.decode_named_race_json(text)
    local ok, route = pcall(function()
        if #text > 65536 then error("too large", 0) end
        local j = reskate.json.decode(text)
        if type(j) ~= "table" or j.format ~= "ReSkate Deathrace route" or not whole(j.version) or j.version ~= 1 then return nil end
        local r = {id = 0, name = j.name, map = j.map, settings = R.Settings()}
        if type(r.name) ~= "string" or type(r.map) ~= "string" then return nil end
        if j.id ~= nil then
            if not whole(j.id) or j.id < 0 or j.id >= uint64_max then return nil end
            r.id = j.id
        end
        if RL.race_route_name(r.name) ~= r.name or string.find(r.map, "%z") then return nil end
        local v = j.settings
        if type(v) ~= "table" then return nil end
        local s = r.settings
        s.mode = "race"
        local function integer(key, maximum)
            local n = v[key]
            if not whole(n) or n < 0 or n > maximum then error("Invalid route setting", 0) end
            return n
        end
        local function num(n)
            if type(n) ~= "number" or n ~= n or math.abs(n) > 10000000 then error("Invalid route coordinate", 0) end
            return vector.create(n, 0, 0).x -- a float, as his
        end
        local function pos(value)
            if type(value) ~= "table" or #value ~= 3 then error("Invalid route position", 0) end
            return vector.create(num(value[1]), num(value[2]), num(value[3]))
        end
        local function floats(key)
            local out = {}
            for i, n in ipairs(list_of(v[key])) do out[i] = num(n) end
            return out
        end
        local function positions(key)
            local out = {}
            for i, n in ipairs(list_of(v[key])) do out[i] = pos(n) end
            return out
        end
        s.duration_s = integer("duration_seconds", 3600); s.turn_s = integer("turn_seconds", 120); s.strikes = integer("strikes", 5)
        s.radius = num(v.radius); s.area_radius = num(v.area_radius); s.corners = positions("corners"); s.points = positions("points")
        s.yaws = floats("yaw_degrees"); s.widths = floats("half_widths"); s.arrow_rolls = floats("arrow_roll_degrees"); s.gate_pitches = floats("pitch_degrees")
        for _, kind in ipairs(list_of(v.gate_types)) do
            if kind ~= "required" and kind ~= "guide" and kind ~= "arrow" then return nil end
            table.insert(s.gate_kinds, kind)
        end
        s.spawn = pos(v.spawn)
        if type(v.has_spawn) ~= "boolean" or type(v.finish_gate) ~= "boolean" then return nil end
        s.has_spawn = v.has_spawn; s.race_finish = v.finish_gate; s.trick_kinds = integer("trick_kinds", 15)
        check_named_race(r)
        return r
    end)
    return ok and route or nil
end

-- ---- race_route_library.cpp ---------------------------------------------------------------------------
-- file_component(value): a name the file system takes. PORT: the plugin's data paths are printable
-- ASCII without \ or :, so any other byte becomes _ as well.
local function file_component(value)
    value = string.gsub(value, '[%c<>:"/\\|%?%*\128-\255]', "_")
    while #value > 0 and (string.sub(value, -1) == "." or string.sub(value, -1) == " ") do value = string.sub(value, 1, -2) end
    if value == "" or value == "." or value == ".." then value = "Route" end
    local stem = string.upper(string.match(value, "^[^%.]*"))
    if stem == "CON" or stem == "PRN" or stem == "AUX" or stem == "NUL" or
        (#stem == 4 and (string.sub(stem, 1, 3) == "COM" or string.sub(stem, 1, 3) == "LPT") and string.find(string.sub(stem, 4), "[1-9]")) then
        value = "_" .. value
    end
    return value
end
local function exists(path) return reskate.files.read(path) ~= nil end
local function read_text(path)
    local text = reskate.files.read(path)
    if text == nil or #text > 65536 then error("Choose a readable Deathrace JSON file smaller than 64 KB.", 0) end
    return text
end
local function write(path, text)
    local ok, why = reskate.files.write(path, text)
    if not ok then error("The route could not be written. Your editor stays open." .. (why and " (" .. tostring(why) .. ")" or ""), 0) end
end

-- Settings == Settings (his operator==): every member.
local function same(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, x in pairs(a) do
        if not same(x, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local Library = {}
Library.__index = Library
function RL.new() return setmetatable({routes_ = {}, paths_ = {}, next_ = 1}, Library) end
function Library:routes() return self.routes_ end
function Library:find(id)
    for _, r in ipairs(self.routes_) do
        if r.id == id then return r end
    end
    return nil
end
function Library:path(id)
    local found = self.paths_[id]
    if not found then error("This saved route is no longer available.", 0) end
    return found
end
function Library:save(route)
    route = {id = route.id or 0, name = RL.race_route_name(route.name), map = route.map, settings = R.deep_copy(route.settings)}
    local old = nil
    if route.id ~= 0 then
        for i, r in ipairs(self.routes_) do
            if r.id == route.id then old = i end
        end
    end
    if route.id ~= 0 and not old then error("This saved route is no longer available.", 0) end
    if route.id == 0 and #self.routes_ >= 256 then error("The route library is full.", 0) end
    for _, r in ipairs(self.routes_) do
        if r.id ~= route.id and r.map == route.map and r.name == route.name then
            error("That route name already exists on this map. Choose another name.", 0)
        end
    end
    if route.id == 0 then
        route.id = self.next_
        self.next_ += 1
    end
    local text = RL.encode_named_race_json(route)
    local map_name = string.match(route.map, "([^/\\]*)$") or route.map
    local final = root .. "/" .. file_component(map_name) .. "/" .. file_component(route.name) .. ".json"
    local previous = old and self:path(route.id) or nil
    local there = exists(final)
    local same = there and previous ~= nil and previous == final
    if there and not same then error("That route filename already exists. Choose another name.", 0) end
    write(final, text)
    if previous and previous ~= final and string.sub(previous, -5) == ".json" then
        local ok = reskate.files.remove(previous)
        if not ok then
            reskate.files.remove(final)
            error("The original route file could not be renamed.", 0)
        end
    end
    self.paths_[route.id] = final
    if old then self.routes_[old] = route else table.insert(self.routes_, route) end
    return route.id
end
-- read(): every route saved, sorted by map, name and id. PORT: his library also migrated .race
-- files and the old Mods/ReSkate folder; the plugin's data folder has neither. A read costs a file
-- call a folder and a file (the API allows 64 a second, and a save after it needs three), so a read
-- makes at most 48 calls: seven map folders and the first forty routes or so.
-- ReSkate: `map` (the current one) has its folder read first, so its routes fit the calls.
function Library:read(map)
    self.routes_ = {}
    self.paths_ = {}
    self.next_ = 1
    local files = {}
    local top = reskate.files.list(root) or {}
    if map then
        local mine = file_component(string.match(map, "([^/\\]*)$") or map) .. "/"
        table.sort(top, function(a, b)
            if (a == mine) ~= (b == mine) then return a == mine end
            return a < b
        end)
    end
    local calls = 1
    for _, name in ipairs(top) do
        if string.sub(name, -1) == "/" then
            calls += 1
            if calls > 8 then break end
            local inner_names = reskate.files.list(root .. "/" .. string.sub(name, 1, -2)) or {}
            table.sort(inner_names)
            for _, inner in ipairs(inner_names) do
                if string.sub(inner, -5) == ".json" then table.insert(files, root .. "/" .. name .. inner) end
            end
        elseif string.sub(name, -5) == ".json" then
            table.insert(files, root .. "/" .. name)
        end
    end
    for _, file in ipairs(files) do
        if #self.routes_ >= 256 or calls >= 48 then break end
        calls += 1
        local ok, route = pcall(function() return RL.decode_named_race_json(read_text(file)) end)
        if ok and route then
            if route.id ~= 0 and route.id < uint64_max then self.next_ = math.max(self.next_, route.id + 1) end
            if route.id == 0 or self:find(route.id) then
                route.id = self.next_
                self.next_ += 1
            end
            self.paths_[route.id] = file
            table.insert(self.routes_, route)
        end
    end
    table.sort(self.routes_, function(a, b)
        if a.map ~= b.map then return a.map < b.map end
        if a.name ~= b.name then return a.name < b.name end
        return a.id < b.id
    end)
end
-- import_json(text, current_map): his took a file's path; the dialog's file button hands its text.
function Library:import_json(text, current_map)
    local route = RL.decode_named_race_json(text)
    if not route then error("This is not a valid completed Deathrace route JSON file.", 0) end
    if route.map ~= current_map then error("This route belongs to another map. Switch to that map before loading it.", 0) end
    -- PORT: his first check, the chosen file being one of the library's own (std::filesystem::equivalent),
    -- has no counterpart: a picked file is outside the plugin's data folder.
    for _, saved in ipairs(self.routes_) do
        if saved.map == route.map and saved.name == route.name and same(saved.settings, route.settings) then return saved.id end
    end
    route.id = 0
    return self:save(route)
end
function Library:rename(id, name)
    local original = self:find(id)
    if not original then error("This saved route is no longer available.", 0) end
    local route = {id = original.id, name = name, map = original.map, settings = original.settings}
    self:save(route)
end

return RL
