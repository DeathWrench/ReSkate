-- SmokeyDawg58's throwdown modes on the Throwdowns page, as his challenge_registry.cpp registered them:
-- R.E.S.K.A.T.E. in S.K.A.T.E.'s place, then (after the stock Spot Battle and Skate Jam) 1-UP and his
-- game modes in mode_rules.h's all_modes order. A card is cloned from his donor: the tag-like modes
-- (Skate Tag, Infection, Hide & Seek) S.K.A.T.E.'s, Spot Jam Skate Jam's, the rest Spot Battle's.
-- Colours are his registry's (0xAABBGGRR, as his generated placeholder atlas), descriptions his
-- registry's (mode_summary for the game modes), flags his ReSkate.<key> placement prefabs
-- (throwdown_lab.cpp: World/ReSkate/Throwdowns/Flags/<key>_Placement). Each mode's setup page, waiting
-- card, HUD and panel are the documents td/ui.lua publishes.
--
-- Beyond the kit's fields each entry keeps what his Definition had for his UI: supports_turns (a turn
-- timer: R.E.S.K.A.T.E. and Hide & Seek) and needs_points (Deathrace's route, Domination's spots).
local logos = "UI/ReSkate/Throwdowns/"
local flags = "World/ReSkate/Throwdowns/Flags/"
-- His native setup's Players slider (1 to 6) and each mode's first capacity: a game mode's draft
-- had 6 (mode_capacity), 1-UP's setup 4 (max_players).
local function players(default) return {min = 1, max = 6, default = default} end
local function mode(id, name, color, card, order, description, extra)
    local entry = {id = id, name = name, description = description, art = logos .. "img_" .. id .. "_Placeholder", color = color,
                   card = card, order = order, flag = flags .. id .. "_Placement", players = players(6)}
    for k, v in pairs(extra or {}) do entry[k] = v end
    return entry
end

return {
    mode("skate", "R.E.S.K.A.T.E.", 0xffd9df00, "skate", 0,
        "Set a trick. Copy it or take a letter. Spell R.E.S.K.A.T.E. and you are out; last skater wins.",
        {replaces = "skate", art = logos .. "img_skate_Reskate_1024", supports_turns = true}),
    mode("oneup", "1-UP", 0xffef8b22, "spot", 1, "Beat the previous turn total. Three penalties and you're out. Last skater wins!",
        {art = "UI/ReSkate/OneUp/img_OneUp_Blue_1024", players = players(4)}),
    mode("jam", "Spot Jam", 0xffab4fff, "jam", 2, "Land lines inside the area. Every line adds to your score; highest total wins."),
    mode("meat", "Hall of Meat", 0xff218aff, "spot", 3, "Bail as hard as you can. Speed, drops and tumbling score; most meat wins."),
    -- Deathrace's start flag may stand on anything (his NativeFlagCursorHeight::ceiling, 99999 m).
    mode("race", "Deathrace", 0xff3434ff, "spot", 4,
        "Cross required gates in order; gray guides are optional. Reach the red finish. Countdown only in the final 30 seconds.",
        {needs_points = true, cursor_height = 99999}),
    mode("domination", "Domination", 0xffff558c, "spot", 5, "Take spots with your best line there. Every second you hold one scores.",
        {needs_points = true}),
    mode("graffiti", "Graffiti", 0xff9fd929, "spot", 6,
        "Grind it, manual it, gap it: what you skate takes your colour. A bigger line steals it. Most tags wins."),
    mode("tag", "Skate Tag", 0xff31d3ff, "skate", 7, "One player is it: get close to tag someone else. No tag-backs. Least time spent it wins."),
    mode("infection", "Infection", 0xff24d675, "skate", 8,
        "One player starts infected. Everyone they reach is infected too and joins the hunt. Survive longest to win."),
    mode("hide", "Hide & Seek", 0xffffbd39, "skate", 9,
        "Hide while the seeker can't see. Then they hunt: whoever is found seeks too. Stay hidden longest to win.",
        {supports_turns = true}),
}
