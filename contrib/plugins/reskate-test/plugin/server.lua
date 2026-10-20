-- reskate-test's server copy: on a lobby's host and on a dedicated server, the session's authority.
-- It answers `ptest server` with a pong to everyone and says so in chat.
local pings = 0
reskate.on("message", function(from, text)
    if text ~= "ping" then return end
    pings += 1
    reskate.net.send("all", "pong: ping " .. pings .. " from " .. from.name)
    reskate.server.say("reskate-test heard ping " .. pings .. " from " .. from.name)
    reskate.log("server copy: ping " .. pings .. " from " .. from.name)
end)
reskate.log("reskate-test server copy loaded")
