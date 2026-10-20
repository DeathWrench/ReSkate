local h = require("harness")
local t = h.module("menu")
local overlay = require("checks/overlay")

-- Its page in the menu's PLUGINS section shows this panel: it tries every widget.
local presses, size, colour, built, saved_ui = 0, 5, 1, 0, nil
reskate.menu.panel("reskate-test", function(ui)
    built += 1
    saved_ui = ui
    ui:heading("Widgets")
    ui:label(string.format("Built %d times. The button was pressed %d times.", built, presses))
    if ui:button("press", "PRESS ME") then
        presses += 1
        reskate.audio.play_ui("select")
    end
    overlay.set_hud(ui:toggle("hud", "Test HUD", overlay.hud()))
    size = ui:slider("size", "A slider", size, 0, 10)
    colour = ui:dropdown("colour", "A dropdown", {"Blue", "Yellow", "Red"}, colour)
    ui:separator()
    ui:label(string.format("Slider %.2f, dropdown %d", size, colour))
end)

t.check("a panel's title is taken once", function()
    h.refused(reskate.menu.panel, "reskate-test", function() end)
end)
t.check("widgets are refused outside a panel's function", function()
    if saved_ui == nil then return h.skip("its page in the menu has not been opened") end
    h.refused(saved_ui.button, saved_ui, "x", "x")
end)
