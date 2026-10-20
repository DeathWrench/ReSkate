local h = require("harness")
local t = h.module("storage")

-- Its keys start with ptest. and are removed after each check.
local function clean()
    for _, key in reskate.storage.keys() do
        if key:sub(1, 6) == "ptest." then reskate.storage.set(key, nil) end
    end
end

t.check("set and get keep tables, lists, text and numbers", function()
    reskate.storage.set("ptest.table", {a = 1, list = {1, 2, 3}, name = "x", yes = true})
    local back = reskate.storage.get("ptest.table")
    clean()
    assert(back.a == 1 and back.list[3] == 3 and back.name == "x" and back.yes == true)
end)
t.check("add counts, from nothing", function()
    assert(reskate.storage.add("ptest.count") == 1)
    assert(reskate.storage.add("ptest.count", 4) == 5)
    reskate.storage.set("ptest.text", "x")
    local why = h.refused(reskate.storage.add, "ptest.text")
    clean()
    assert(why:find("number", 1, true), why)
end)
t.check("nil removes a key", function()
    reskate.storage.set("ptest.gone", 1)
    reskate.storage.set("ptest.gone", nil)
    assert(reskate.storage.get("ptest.gone") == nil)
end)
t.check("keys lists them", function()
    reskate.storage.set("ptest.listed", 1)
    local found = table.find(reskate.storage.keys(), "ptest.listed")
    clean()
    assert(found)
end)
t.check("a plugin has 1 MB", function()
    local why = h.refused(reskate.storage.set, "ptest.big", string.rep("x", 2000000))
    assert(why:find("full", 1, true), why)
    assert(reskate.storage.get("ptest.big") == nil, "the failed write was kept")
end)
t.check("bad keys and values are refused", function()
    h.refused(reskate.storage.set, "", 1)
    h.refused(reskate.storage.set, string.rep("k", 200), 1)
    h.refused(reskate.storage.set, "ptest.f", print)
    local cycle = {}
    cycle.me = cycle
    h.refused(reskate.storage.set, "ptest.c", cycle)
    clean()
end)
