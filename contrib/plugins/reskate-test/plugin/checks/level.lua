local t = require("harness").module("level")

local heard = {}
reskate.on("level_loaded", function(name) table.insert(heard, "loaded " .. name) end)
reskate.on("level_unloading", function(name) table.insert(heard, "leaving " .. name) end)

t.check("current is nil, or a table with the level's name", function()
    local level = reskate.level.current()
    assert(level == nil or (type(level) == "table" and type(level.name) == "string" and #level.name > 0))
end)
t.check("level events name the level", function()
    for _, line in heard do
        assert(#line > #"loaded ", "an event without a name: " .. line)
    end
end)
