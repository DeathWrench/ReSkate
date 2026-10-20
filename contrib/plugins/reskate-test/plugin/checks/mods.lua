local t = require("harness").module("mods")

t.check("the mod list has this plugin, switched on", function()
    local found = false
    for _, mod in reskate.mods.list() do
        assert(type(mod.folder) == "string" and type(mod.title) == "string" and type(mod.on) == "boolean")
        if mod.folder == reskate.id then found = mod.on end
    end
    assert(found, reskate.id .. " is not in the list as on")
    assert(reskate.mods.installed(reskate.id) == "on")
    assert(reskate.mods.installed("no such mod at all") == nil)
end)
