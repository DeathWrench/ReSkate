local h = require("harness")
local t = h.module("console")

-- Try it by hand: ptest echo a b c
reskate.console.command("ptest echo", "Prints its words back", function(args)
    reskate.console.print("ptest echo: " .. table.concat(args, " "))
end)

t.check("print works", function() reskate.console.print("ptest: console.print works") end)
t.check("a ReSkate command's name is refused", function()
    h.refused(reskate.console.command, "load mine", "x", function() end)
    h.refused(reskate.console.command, "plugin mine", "x", function() end)
    h.refused(reskate.console.command, "help mine", "x", function() end)
end)
t.check("names must be 1 to 3 lowercase words", function()
    for _, name in {"", "Bad", "a b c d", " lead", "trail ", "two  spaces", "sym!"} do
        h.refused(reskate.console.command, name, "x", function() end)
    end
end)
t.check("a name registered already is refused", function()
    h.refused(reskate.console.command, "ptest", "x", function() end)
end)
t.check("a command needs a function", function()
    h.refused(reskate.console.command, "ptest other", "x", 5)
end)
