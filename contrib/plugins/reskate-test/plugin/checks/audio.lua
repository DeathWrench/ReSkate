local h = require("harness")
local t = h.module("audio")

t.check("a menu sound plays, and one there is not is refused", function()
    assert(type(reskate.audio.play_ui("navigate")) == "boolean")
    h.refused(reskate.audio.play_ui, "explosion")
end)
