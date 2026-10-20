-- A starting point for a server plugin: greets each player who joins and counts their visits,
-- and gives the server console a `starter` command. Copy the folder into the server's Plugins.
reskate.on("player_joined", function(player)
    local visits = (reskate.storage.get("visits." .. player.id) or 0) + 1
    reskate.storage.set("visits." .. player.id, visits)
    reskate.server.tell(player.id, "Welcome, " .. player.name .. " (visit " .. visits .. ")")
end)

reskate.console.command("starter", "Server starter plugin: starter say <text>", function(args)
    if args[1] ~= "say" or not args[2] then return reskate.console.print("starter say <text>") end
    reskate.server.say(table.concat(args, " ", 2))
end)

reskate.log("server-starter loaded")
