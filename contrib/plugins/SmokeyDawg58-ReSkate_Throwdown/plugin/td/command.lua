-- game_modes.cpp lines 3109-3623, translated line for line: flick_test, command (every verb),
-- request_race_route_action, native_flag_offers, join_native_flag_offer, accept_race_start,
-- accept_native_start_flag, request_native_start, request_native_quit; and on_ui_command, what
-- arrives from his UI (td/ui_events.lua turns the throwdown kit's events into these, as his UI and the
-- C++ bridge, mode_bridge.cpp, did).
local M = require("td/core")
local RR = require("td/h/race_route")
local RE = require("td/h/race_editor")
local ML = require("td/h/mode_lobby")
local MP = require("td/h/mode_participation")

-- mode_name(mode) / timed(mode) of mode_rules.h, for a mode key.
-- (A mode is its name, "jam" ... "oneup" ...; td/rules.lua has his functions.)
local function mode_name(key)
	local mode = M.parse_mode(key)
	return if mode then M.mode_name(mode) else ""
end
local function timed(key)
	local mode = M.parse_mode(key)
	return mode ~= nil and M.timed(mode)
end
-- parse_mode(word): the mode, or nil.
local function parse_mode(word)
	return M.parse_mode(word)
end

-- std::from_chars of a std::uint64_t: the leading decimal digits (nil when there are none). `whole`
-- also asks that they are the whole text (his `parsed.ptr == text.data() + text.size()`).
local function digits_of(text, whole)
	if type(text) ~= "string" then return nil end
	local digits = string.match(text, whole and "^(%d+)$" or "^(%d+)")
	return digits
end
-- The same digits as a 64-bit id string (leading zeros dropped, as the number has none).
local function id_text(digits)
	local trimmed = string.gsub(digits, "^0+", "")
	return trimmed == "" and "0" or trimmed
end
local function finite(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- `static_cast<std::uint32_t>((now * 2654435761ULL) ^ (now >> 16)) | 1u`, exactly, in doubles: only
-- the low 32 bits of the product survive the cast, so the product is taken modulo 2^32 in 16-bit halves.
local function new_game_id(now)
	now = math.floor(now)
	local k = 2654435761
	local low = now % 4294967296
	local a0 = low % 65536
	local a1 = (low - a0) // 65536
	local product = (a0 * k + ((a1 * k) % 65536) * 65536) % 4294967296
	local shifted = (now // 65536) % 4294967296
	return bit32.bor(bit32.bxor(product, shifted), 1)
end

-- std::atomic<bool> &flick_test_flag(): a State boolean, `s.flick_test`.
function M.flick_test()
	return M.state().flick_test == true
end

function M.command(verb, arguments)
	arguments = arguments or {}
	local s = M.state()
	local now = M.now_ms()
	local v = verb or ""
	if v == "" or v == "help" or v == "list" then return M.help() end
	-- ReSkate: `tdm test` runs the rules' self-tests (td/rules_tests.lua, his mode_rules_tests.cpp's).
	if v == "test" then return require("td/rules_tests").run() end
	if v == "bonecam" then
		-- With ReSkate's own Hall of Meat, `on` / `off` / `meat` are its switch (every bail, or Hall of
		-- Meat games only); the Bone Cam keeps the choice for a game build without it.
		local word = #arguments == 0 and "" or arguments[1]
		-- The SDK's Bone Cam calls his `meat` setting `game`: it shows while this plugin's Hall of
		-- Meat game asks for it (td/hud.lua).
		local words = {}
		for i, a in ipairs(arguments) do words[i] = (i == 1 and a == "meat") and "game" or a end
		if M.hall_of_meat.available() and (word == "on" or word == "off" or word == "meat") then
			local _ = reskate.skater.bone_cam(table.unpack(words))
			M.hall_of_meat.set_enabled(word == "on")
			return word == "on" and "Hall of Meat shows on every bail." or "Hall of Meat shows in Hall of Meat games."
		end
		-- bone_cam_command(arguments): with none, his status line ("status").
		if #words == 0 then return reskate.skater.bone_cam("status") end
		return reskate.skater.bone_cam(table.unpack(words))
	end
	if v == "games" then
		if #s.offers == 0 then return "No other games right now." end
		local text = "Open games (mode join <n>):"
		for i = 0, #s.offers - 1 do
			local o = s.offers[i + 1]
			text ..= string.format("\n  %d. %s's %s - %s player%s%s", i + 1, M.name_of(s, o.leader), mode_name(o.settings.mode), tostring(o.players),
				o.players == 1 and "" or "s", M.offer_open(o) and "" or " (in progress)")
		end
		return text
	end
	if v == "join" then
		-- `mode join` takes the announced or nearest game; `mode join <n>` the list's nth; a menu row
		-- passes its host's id.
		local pick = nil
		if #arguments == 0 then
			for _, o in s.offers do
				-- PORT: s.join_target, his optional pair (leader, game), is taken as {leader, game} or
				-- {first, second} (or a list of the two), whichever core keeps.
				local target = s.join_target
				if target and o.leader == (target.leader or target.first or target[1]) and o.game == (target.game or target.second or target[2]) then pick = o end
			end
			if not pick and #s.offers == 1 then pick = s.offers[1] end
		else
			local text = arguments[1]
			local digits = digits_of(text, false)
			if digits then
				-- PORT: `value` is a std::uint64_t: as a list index it is a number, as a host's id the
				-- same digits as an id string (ids are never arithmetic here).
				local value = tonumber(digits)
				if value and value >= 1 and value <= #s.offers then pick = s.offers[value] end
				local id = id_text(digits)
				for _, o in s.offers do
					if o.leader == id then pick = o end
				end
			end
		end
		if not pick then return #s.offers == 0 and "error: there is no game to join." or "error: which one? mode games lists them." end
		local offer = M.copy(pick)
		return M.join_offer(s, offer, now)
	end
	-- PORT: his trick logger (trick_log_command) is not ported.
	if v == "tricklog" then return "The trick logger is not in this build." end
	if v == "diagram" then
		local trick = ""
		for _, word in arguments do trick ..= (trick == "" and "" or " ") .. word end
		if trick == "" then return "error: usage: mode diagram <trick>, e.g. mode diagram 360 Flip + Indy" end
		-- prepare_trick_gestures(): nothing (reading starts on the first trick_gesture call).
		s.diagram_trick = trick
		s.diagram_until = now + 10000
		local plus = string.find(trick, " + ", 1, true)
		local first = plus and string.sub(trick, 1, plus - 1) or trick
		return #reskate.tricks.gesture(first) == 0
			and "Showing it for 10 seconds (if the trick has a flick, its diagram shows once the game's gestures are read)."
			or "Showing its flick diagram for 10 seconds."
	end
	if v == "zone" then
		if not s.game or s.game.settings.mode ~= "skate" then return "error: trick zones belong to R.E.S.K.A.T.E." end
		-- R.E.S.K.A.T.E.'s trick zone: a circle this many metres wide around the start flag (or the
		-- player, until the flag is placed); 0 or off: anywhere counts.
		if #arguments > 0 and arguments[1] == "custom" then
			if not s.game or not s.game.leading then return "error: only the game's leader sets its zone." end
			local g = s.game
			if g.state and g.state.phase ~= "setup" then return "error: the zone is set before the game starts." end
			g.zone_custom = true
			g.settings.area_radius = 0.0
			table.clear(g.settings.corners)
			M.settings_changed(g)
			reskate.log("R.E.S.K.A.T.E.: Trick zone: custom cones, placed after the flag.", "info")
			return "Custom trick zone: after the start flag, place a cone at each corner."
		end
		local off = #arguments > 0 and (arguments[1] == "off" or arguments[1] == "0")
		local metres
		if off then metres = 0.0 else metres = M.number(arguments, 0) end
		if not metres or (metres ~= 0.0 and (metres < M.min_area_radius or metres > M.max_area_radius)) then
			return string.format("error: usage: mode zone <%.0f-%.0f metres>|off", M.min_area_radius, M.max_area_radius)
		end
		if not s.game or not s.game.leading then return "error: only the game's leader sets its zone." end
		local g = s.game
		if g.state and g.state.phase ~= "setup" then return "error: the zone is set before the game starts." end
		g.zone_custom = false
		g.settings.area_radius = metres
		if metres > 0.0 then
			g.settings.corners = {if g.settings.has_spawn then g.settings.spawn else s.position}
		else
			table.clear(g.settings.corners)
		end
		M.settings_changed(g)
		local said = metres > 0.0 and string.format("Trick zone: %.0f m around the start.", metres) or "No trick zone: tricks count anywhere."
		reskate.log("R.E.S.K.A.T.E.: " .. said, "info")
		return said
	end
	if v == "flicktest" then
		local on = #arguments > 0 and arguments[1] == "on"
		s.flick_test = on
		return on and "The trick picture slot shows the 1UP badge (test)." or "The trick picture slot shows the flick-it picture."
	end
	if v == "stance" then
		if #arguments == 0 or (arguments[1] ~= "regular" and arguments[1] ~= "goofy") then
			return string.format("R.E.S.K.A.T.E.'s flick diagrams are shown for a %s stance. Usage: mode stance regular|goofy", s.goofy and "goofy" or "regular")
		end
		s.goofy = arguments[1] == "goofy"
		s.stance_loaded = true
		M.save_stance(s.goofy)
		return string.format("Flick diagrams shown for a %s stance (kept for next time).", s.goofy and "goofy" or "regular")
	end
	if v == "spectate" then
		if #arguments == 0 or (arguments[1] ~= "on" and arguments[1] ~= "off") then
			return string.format("R.E.S.K.A.T.E. spectating is %s. Usage: mode spectate on|off", s.spectate and "on" or "off")
		end
		s.spectate = arguments[1] == "on"
		return s.spectate and "In R.E.S.K.A.T.E. the camera follows whoever is up." or "In R.E.S.K.A.T.E. the camera stays on you."
	end
	if v == "results" then
		return "error: results are supplied only by a completed challenge."
	end
	if v == "bounce" then return "error: optional bail-bounce hooks are unavailable in this build. Native Hall of Meat scoring remains enabled." end
	if v == "debug" then
		local on = #arguments >= 2 and arguments[1] == "states" and arguments[2] == "on"
		if #arguments < 2 or arguments[1] ~= "states" or (arguments[2] ~= "on" and arguments[2] ~= "off") then
			return "error: usage: mode debug states on|off"
		end
		s.log_states = on
		s.logged_state = 0
		return on and "Logging physics states to ReSkate.log." or "Stopped logging physics states."
	end
	if v == "status" then
		if not s.game then return "No game. " .. M.help() end
		local g = s.game
		local text = string.format("%s led by %s; ", mode_name(g.settings.mode), M.name_of(s, g.leader))
		text ..= string.format("area: %d corners, points: %d, ", #g.settings.corners, #g.settings.points)
		text ..= timed(g.settings.mode) and string.format("time: %s s", tostring(g.settings.duration_s))
			or string.format("turns: %s s, strikes: %s", tostring(g.settings.turn_s), tostring(g.settings.strikes))
		if g.state then text ..= string.format(", players: %d", #g.state.standings) end
		return text
	end
	if v == "new" then
		local mode = nil
		if #arguments > 0 then mode = parse_mode(arguments[1]) end
		if not mode then return "error: usage: mode new jam|meat|race|domination|graffiti|tag|infection|hide" end
		-- PORT: Mode::one_up's key is "1up" (mode_key, which mode_json writes); PORT.md calls it "oneup".
		if mode == "1up" or mode == "oneup" then
			return "error: use the native 1-UP Throwdowns card; a duplicate game-mode implementation is not started."
		end
		-- A `new` from his UI (the bridge's {key, world, game}) was checked by the bridge before his UI
		-- went on to `setup`, whose native placement is already open by the time the plugin hears it.
		local from_ui = #arguments >= 3
		if not from_ui and (M.nz(M.one_up_match()) or M.placement("placing") or M.placement("local_throwdown")) then
			return "error: quit the active Throwdown before starting another challenge."
		end
		if s.barred then return "error: your mods change trick scoring, so you cannot start a game in this session." end
		if not s.skater then return "error: get on your board in the world first." end
		if s.game and not s.game.leading and s.game.state and s.game.state.phase ~= "results" then
			return "error: " .. M.name_of(s, s.game.leader) .. "'s game is on. `mode leave` first."
		end
		if s.game and s.game.leading then M.send(s, M.header(s.game, "end")) end
		-- Retire the completed match's native flag/input ownership before a
		-- saved course is reopened. The course is copied by end_game first.
		M.end_game(s, "", from_ui)
		local g = M.Game()
		g.leader = M.self_id(s)
		-- The bridge chose the game id ({key, world, game}) and its draft view shows it already; a verb
		-- without one makes it as his code does.
		local given = #arguments >= 3 and tonumber(arguments[3]) or nil
		if given and given ~= 0 then g.id = given else g.id = new_game_id(now) end
		g.leading = true
		g.settings.mode = mode
		g.settings.duration_s = M.default_duration(mode)
		reskate.physics.prepare()
		if M.tag_like(mode) then g.settings.radius = M.default_tag_reach end -- how close tags (or infects)
		if mode == "skate" then -- R.E.S.K.A.T.E.: seven letters, time to line a trick up
			g.settings.strikes = M.max_strikes
			g.settings.turn_s = 45
		end
		-- Where it was set up: its banner's spot for the others until an area or route is placed.
		g.settings.spawn = s.position
		g.settings.has_spawn = true
		if mode == "race" then s.draft_width = RE.default_race_editor_width; s.snap_angle = RE.default_race_editor_snap_angle; s.route_snap = true end
		-- Saved routes are loaded only by an explicit selection in the builder.
		-- A new world/match always starts without any previous gates.
		s.editor_exit_confirm = false; s.clear_hold = RR.RaceClearHold.new()
		g.heard = now
		s.game = g
		s.active = true
		local next
		if mode == "race" then next = "Open Throwdowns > Deathrace > Place Route: place the native start flag, then switch with LT/RT to checkpoints and the red finish."
		elseif mode == "domination" then next = "Ride to each spot and use `mode point`, then `mode start`."
		elseif mode == "graffiti" then next = "Open Throwdowns > Graffiti to set an optional area, then Start Game."
		elseif mode == "tag" then next = "The whole map is the playground; Place Circle in Throwdowns fences it in (up to 3 km across). Then START GAME."
		elseif mode == "infection" then next = "The whole map is the hunting ground; Place Circle in Throwdowns fences it in. Then START GAME."
		elseif mode == "hide" then next = "Pick the hiding time in Throwdowns > Hide & Seek, PLACE CIRCLE to keep everyone close (recommended), then START GAME."
		elseif mode == "skate" then next = "Pick the turn time in Throwdowns > R.E.S.K.A.T.E. (`mode tricks` limits the kinds of trick), then START."
		else next = "Optional: `mode corner` at each corner of an area. Then `mode start`." end
		return string.format("%s set up. %s", mode_name(mode), next)
	end
	if not s.game then return "error: no game. Start one with `mode new <mode>`." end
	local g = s.game
	if v == "quit" then
		-- Quit leaves immediately; Stop deliberately presents match results.
		-- Followers also suppress the same host's still-advertised match.
		M.send(s, M.header(g, MP.local_quit_kind(g.leading)))
		if not g.leading and ML.lobby_departure_blocks_rejoin(g.state and g.state.phase or "setup") then s.sat_out[M.pair_key(g.leader, g.id)] = true end
		M.end_game(s, "")
		return "You quit the Throwdown."
	end
	if v == "leave" then
		if g.leading then return "error: you lead this game: `mode stop` ends it for everyone." end
		M.send(s, M.header(g, "leave"))
		if ML.lobby_departure_blocks_rejoin(g.state and g.state.phase or "setup") then s.sat_out[M.pair_key(g.leader, g.id)] = true end
		M.end_game(s, "")
		return "You left the game."
	end
	if not g.leading then return "error: only " .. M.name_of(s, g.leader) .. " (the leader) can change or start this game." end
	if v == "stop" then
		-- Stopped while it is on: everyone sees the results first.
		if g.referee and (g.referee:phase() == "playing" or g.referee:phase() == "countdown") then
			g.referee:end_now(now)
			g.state_sent = 0
			return "Game ended: here are the results."
		end
		M.send(s, M.header(g, "end"))
		M.end_game(s, "")
		return "Game stopped."
	end
	if g.referee then return "error: the game has started; only `mode stop` now." end
	if M.starts_with(v, "route-") and g.settings.mode == "race" and s.placing == "points" then
		if v == "route-cancel" then
			s.route_input_release:arm(); s.route_dialog = s.route_dialog == 3 and 2 or 0; s.route_dialog_serial += 1; s.route_dialog_error = ""
			return "Route menu closed."
		end
		local ok, result = pcall(function(): string?
			if v == "route-reveal" and #arguments > 0 then
				local digits = digits_of(arguments[1], true)
				if not digits then error("Choose a saved route.", 0) end
				-- PORT: showing the route's file in Explorer (race_route_library(s).path(id),
				-- SHOpenFolderAndSelectItems) has no plugin API: the dialog's rows have no folder button.
				error("Showing a route file in Explorer is not available.", 0)
			end
			if v == "route-save" and #arguments > 0 then
				local issue = RR.race_route_save_error(g.settings, g.race_finish_placed)
				if issue and issue ~= "" then error(issue, 0) end
				s.route_saved_id = M.race_route_library(s):save({
					id = arguments[1] == s.route_name and s.route_saved_id or 0,
					name = arguments[1],
					map = s.course_map,
					settings = M.copy(g.settings),
				})
				s.route_name = arguments[1]
				s.route_input_release:arm(); s.route_dialog = 0; s.route_dialog_error = ""; s.placing = "none"
				g.race_publication:save(g.settings); M.settings_changed(g)
				M.popup(s, "Named route saved. Players can enroll."); return "Route saved."
			end
			if v == "route-rename" and #arguments > 0 then
				local digits = digits_of(arguments[1], true)
				local id = digits and tonumber(digits) or 0
				local saved = digits and M.race_route_library(s):find(id) or nil
				if not saved then error("This saved route is no longer available.", 0) end
				s.route_rename_id = id; s.route_dialog = 3; s.route_dialog_serial += 1; s.route_dialog_error = ""; return "Rename route."
			end
			if v == "route-rename-save" and #arguments > 0 and (s.route_rename_id or 0) ~= 0 then
				M.race_route_library(s):rename(s.route_rename_id, arguments[1])
				if s.route_saved_id == s.route_rename_id then s.route_name = arguments[1] end
				s.route_dialog = 2; s.route_dialog_serial += 1; s.route_dialog_error = ""; return "Route renamed."
			end
			if (v == "route-load" or v == "route-import") and #arguments > 0 then
				local id = 0
				local text = arguments[1]
				if v == "route-import" then
					-- His argument was the chosen file's path; the dialog's file button hands its text.
					id = M.race_route_library(s):import_json(text, s.course_map)
				else
					local digits = digits_of(text, true)
					id = digits and tonumber(digits) or 0
				end
				local saved = M.race_route_library(s):find(id)
				if not saved or saved.map ~= s.course_map then error("Choose a route saved on the current map.", 0) end
				if #g.settings.points == 0 then error("Place the starting flag before loading a route.", 0) end
				s.route_saved_id = saved.id; s.route_name = saved.name
				local before = g.settings
				local at = before.points[1]
				local yaw = #before.yaws == 0 and g.native_flag_yaw or before.yaws[1]
				g.settings = M.copy(saved.settings); g.settings.duration_s = before.duration_s
				g.race_finish_placed = g.settings.race_finish
				-- PORT: edit_race_route's `bool& finish` is taken as its second result.
				local _, finish = RR.edit_race_route(g.settings, g.race_finish_placed, RR.RaceObject.start, at, yaw, M.gate_half_width(before, 0))
				if finish ~= nil then g.race_finish_placed = finish end
				g.race_publication:begin_edit(); s.route_history:reset(); s.route_history:resume(g.settings)
				s.route_input_release:arm(); s.route_dialog = 0; s.route_dialog_error = ""; s.editor_angles_ready = false; s.rotation_original:clear()
				s.editor_rotating = false; s.editor_manual_rotation = false; s.arrow_line_snap:reset(); M.settings_changed(g)
				M.popup(s, "Route loaded. Review it, then tap Start to save."); return "Route loaded."
			end
			return nil
		end)
		if not ok then
			s.route_dialog_error = tostring(result); return "error: " .. s.route_dialog_error
		end
		if result ~= nil then return result end
		return "error: route action is unavailable."
	end
	if v == "setup" then
		local race = g.settings.mode == "race"
		-- begin_race_flag_placement / begin_native_mode_setup: the kit's native flag with its setup
		-- page. A card's `open` (td/ui_events.lua, "from-kit") has it open already.
		if arguments[1] ~= "from-kit" then
			local opened = race and M.placement("race", s.world, g.id, g.capacity, true)
				or reskate.throwdowns.flag.begin(g.settings.mode, g.id, {players = math.clamp(g.capacity, 1, 10), seconds = g.settings.duration_s})
			if not opened then return "error: native Throwdown setup is still busy." end
		end
		g.native_lobby = true; g.native_flag_placed = false; s.race_resume_editor = false
		s.placing = "none"; s.cursor_ok = false
		M.set_placement_flight(s, false)
		-- overlay::pause_game_input(false): nothing (the pause lapses by itself).
		return race and "Deathrace: choose Players, then Confirm to place required gates, gray guides and one red finish. Choose the finish deadline in setup."
			or string.format("%s: choose settings, Confirm to place the starting flag, then hold Start in the waiting HUD.", mode_name(g.settings.mode))
	end
	local function changed(text)
		M.settings_changed(g)
		return text
	end
	if v == "place" then
		local what = #arguments == 0 and "circle" or arguments[1]
		if what == "cancel" or what == "done" then
			if g.settings.mode == "race" and g.native_lobby then
				if what == "done" and not RR.race_route_ready(g.settings, g.race_finish_placed) then
					return "error: place the red finish before saving the route."
				end
				if what == "cancel" then
					M.end_game(s, "Deathrace placement cancelled. Only named saves are kept.")
					return "Placing stopped."
				end
			end
			if g.settings.mode == "race" and what == "done" then M.open_route_dialog(s, 1); return "Name and save this route." end
			s.placing = "none"
			M.settings_changed(g)
			return "Placing stopped."
		end
		if what == "freecam" then
			local value = #arguments > 1 and arguments[2] or (s.free_place and "off" or "on")
			if value ~= "on" and value ~= "off" then return "error: usage: mode place freecam on|off" end
			s.free_place = value == "on"
			return s.free_place and "Placing flies the free camera: aim at the ground (WASD/mouse or the sticks) and drop with D-pad Right (Enter)."
				or "Placing follows your skater: skate to each spot."
		end
		if not s.skater then return "error: get on your board in the world first." end
		-- Presses already down when placing starts (the menu's own) count only once let go.
		s.pad_previous = 0xFFFFFFFF
		s.keys_previous = {true, true, true, true}
		s.placing_tick = 0
		if what == "circle" then
			if g.settings.area_radius > 0 then s.draft_radius = g.settings.area_radius end
			s.placing = "circle"
			return "Close the menu and skate to the centre of your spot. D-pad Up/Down (PgUp/PgDn) sizes the circle; "
				.. "D-pad Right (Enter) sets it."
		end
		if what == "corners" then
			table.clear(g.settings.corners)
			g.settings.area_radius = 0
			M.settings_changed(g)
			s.placing = "corners"
			return "Close the menu and skate to each corner: D-pad Right (Enter) adds one, D-pad Down (End) finishes."
		end
		if what == "points" then
			if g.settings.mode == "race" then -- a route is skated again from its start
				-- begin_race_flag_placement(world, game, capacity), without the native setup page.
				if not M.placement("race", s.world, g.id, g.capacity, false) then
					return "error: native flag placement is still busy."
				end
				g.native_lobby = true; g.native_flag_placed = false; g.race_publication:begin_edit(); M.settings_changed(g)
				-- Re-enter the builder with the existing course. Only its
				-- deliberate hold-to-clear action removes all saved gates.
				s.yaw_offset = 0
				s.draft_width = g.settings.mode == "race" and RE.default_race_editor_width
					or math.clamp(g.settings.radius, M.min_gate_half_width, M.max_gate_half_width)
				s.placing = "none"
				return "Place the native starting flag to edit the saved course. Hold Back/View to clear all gates, or press Start to save it unchanged."
			end
			s.placing = "points"
			return string.format("Close the menu and skate to each %s: D-pad Right (Enter) adds one, D-pad Down (End) finishes.", M.point_name(g))
		end
		return "error: usage: mode place circle|corners|points|cancel"
	end
	if v == "circle" then
		if not s.skater then return "error: get on your board in the world first." end
		local radius
		if #arguments == 0 then radius = s.draft_radius else radius = M.number(arguments, 0) end
		if not radius or radius < M.min_area_radius or radius > M.max_area_radius then
			return string.format("error: usage: mode circle [radius %s-%s]", tostring(M.min_area_radius), tostring(M.max_area_radius))
		end
		s.draft_radius = radius
		g.settings.corners = {s.position}
		g.settings.area_radius = math.round(radius)
		return changed(string.format("Area set: a circle %.0f m across, around you.", g.settings.area_radius * 2))
	end
	if v == "corner" or v == "point" then
		if v == "point" and g.settings.mode == "race" then return "error: use Place race route in the native Throwdown menu to edit gates." end
		local list = v == "corner" and g.settings.corners or g.settings.points
		local limit = v == "corner" and M.max_corners or M.max_points
		local what = v == "corner" and "corner" or M.point_name(g)
		local sub = #arguments == 0 and "" or arguments[1]
		if sub == "clear" then
			table.clear(list)
			if v == "corner" then g.settings.area_radius = 0 end
			return changed(string.format("All %ss cleared.", what))
		end
		if sub == "undo" then
			if #list == 0 then return "error: nothing to undo." end
			table.remove(list)
			if #g.settings.corners == 0 then g.settings.area_radius = 0 end
			return changed(string.format("Last %s removed (%d left).", what, #list))
		end
		if not s.skater then return "error: no skater to mark the spot with." end
		if v == "corner" and g.settings.area_radius > 0 then -- corners replace a circle
			table.clear(g.settings.corners)
			g.settings.area_radius = 0
		end
		if #list >= limit then return string.format("error: at most %d %ss.", limit, what) end
		table.insert(list, s.position)
		return changed(string.format("%s %d placed at %.1f, %.1f, %.1f.", what, #list, s.position.x, s.position.y,
			s.position.z))
	end
	local function set_number(low, high, apply, label)
		local value = M.number(arguments, 0)
		if not value or value < low or value > high then return string.format("error: usage: mode %s <%s-%s>", v, tostring(low), tostring(high)) end
		apply(value)
		return changed(string.format("%s set to %s.", label, tostring(value)))
	end
	if v == "players" then return set_number(1, 6, function(x) g.capacity = math.round(x) end, "Players") end
	if v == "time" then return set_number(30, 3600, function(x) g.settings.duration_s = M.trunc(x) end, "Time (s)") end
	if v == "turn" then return set_number(10, 120, function(x) g.settings.turn_s = M.trunc(x) end, "Turn time (s)") end
	if v == "strikes" then return set_number(1, g.settings.mode == "skate" and M.max_strikes or 5, function(x) g.settings.strikes = M.trunc(x) end, "Strikes") end
	if v == "tricks" then
		-- R.E.S.K.A.T.E.: the kinds of trick that may be set, one or more.
		local kinds = 0
		for _, word in arguments do
			if word == "flips" or word == "flip" then kinds = bit32.bor(kinds, M.trick_flips)
			elseif word == "grabs" or word == "grab" then kinds = bit32.bor(kinds, M.trick_grabs)
			elseif word == "grinds" or word == "grind" or word == "slides" then kinds = bit32.bor(kinds, M.trick_grinds)
			elseif word == "manuals" or word == "manual" then kinds = bit32.bor(kinds, M.trick_manuals)
			elseif word == "all" or word == "any" then kinds = M.all_trick_kinds
			else return "error: usage: mode tricks flips|grabs|grinds|manuals|all (one or more)" end
		end
		if kinds == 0 then return "error: usage: mode tricks flips|grabs|grinds|manuals|all (one or more)" end
		g.settings.trick_kinds = kinds
		return changed("Tricks that can be set: " .. M.trick_kinds_text(kinds) .. ".")
	end
	if v == "radius" then
		return set_number(1, 50, function(x)
			g.settings.radius = x
			-- Deathrace: the reach is how wide its gates are, the ones placed already too.
			local half = math.clamp(x, M.min_gate_half_width, M.max_gate_half_width)
			for i = 1, #g.settings.widths do g.settings.widths[i] = half end
			s.draft_width = half
		end, "Radius (m)")
	end
	if v == "start" then
		if g.native_lobby and not g.native_flag_placed then return "error: place the native starting flag before starting this Throwdown." end
		if g.native_lobby and s.placing ~= "none" then return "error: finish placing the area or capture spots before starting this Throwdown." end
		if g.settings.mode == "race" and (not g.race_publication:ready(g.settings) or not RR.race_route_ready(g.settings, g.race_finish_placed) or s.placing ~= "none" or
			(M.placement("race_owned") and not M.placement("waiting"))) then
			return "error: finish placing the start flag, checkpoints and one red finish first."
		end
		if g.settings.mode == "race" then
			local err = M.race_world_start_error(s.world, g.id)
			if err and err ~= "" then return "error: " .. err end
		end
		if g.settings.mode == "race" and not reskate.physics.stock_ready() then return "error: stock physics are still loading; wait a moment before starting." end
		local why = M.missing(g.settings)
		if why ~= "" then return "error: " .. why end
		if g.settings.mode == "race" then
			-- Start plane and lineup share the placed flag's authored facing.
			-- Broadcast the change before countdown so every racer uses it.
			RR.align_race_start(g.settings); M.settings_changed(g)
		end
		if s.skater and g.settings.mode ~= "race" and not g.native_flag_placed then
			g.settings.spawn = s.position
			g.settings.has_spawn = true
			M.settings_changed(g)
		end
		g.referee = M.Referee.new(g.settings, g.leader, g.id)
		g.referee:add(M.self_id(s))
		for _, id in g.joiners do g.referee:add(id) end
		g.referee:start(now)
		g.setup_sent = 0; g.state_sent = 0
		return string.format("%s starting with %d player%s!", mode_name(g.settings.mode), #g.joiners + 1,
			#g.joiners == 0 and "" or "s")
	end
	return "error: unknown `mode " .. v .. "`. " .. M.help()
end

-- request_race_route_action(world, game, action, argument): his checks, against the view this
-- plugin last published (his native_view()).
local function request_race_route_action(world, game, action, argument)
	if action ~= "cancel" and action ~= "save" and action ~= "load" and action ~= "rename" and action ~= "rename-save" and action ~= "import" and action ~= "reveal" then return false end
	-- His import argument was a path (32768); here it is the file's text (his read_text's 64 KB).
	if #argument > (action == "import" and 65536 or 64) then return false end
	local view = M.state().native or {}
	if not view.active or not view.leading or not view.placing or (view.route_dialog or 0) == 0 or view.world ~= world or view.game ~= game then return false end
	local s = M.state()
	s.route_action = {world = world, game = game, action = action, argument = argument}
	return true
end

-- native_view() is s.native (core publishes it); the offers his native Throwdowns page shows.
function M.native_flag_offers(world)
	local s = M.state()
	local result = {}
	if not s.session or not M.nz(s.world) or s.world ~= world or s.barred or (s.game and (not s.game.state or s.game.state.phase ~= "results")) then return result end
	local now = M.now_ms()
	for _, offer in s.offers do
		if #result == 64 then break end
		-- PORT: `now - offer.heard` is unsigned: one heard "later" than now wraps to a huge age.
		local age = now - offer.heard
		if not M.offer_open(offer) or age < 0 or age > M.leader_timeout_ms or not s.present[offer.leader] then continue end
		if offer.settings.mode == "race" and not RR.race_route_ready(offer.settings, offer.settings.race_finish) then continue end
		local at = M.game_spot(offer.settings)
		if at then
			table.insert(result, {
				leader = offer.leader,
				game = offer.game,
				key = offer.settings.mode,
				at = at,
				yaw = offer.settings.mode == "race" and M.gate_heading(offer.settings, 0) or 0.0,
				players = offer.players,
				duration_s = offer.settings.duration_s,
				required_gates = M.mandatory_gates(offer.settings, #offer.settings.points),
			})
		end
	end
	return result
end

-- join_native_flag_offer(requested, mmid), after the bridge's adopt_native_mode_flag: the bridge
-- sends {leader, game, mmid} of an offer this plugin published.
local function join_native_flag_offer(leader, game, mmid)
	local s = M.state()
	if not mmid or mmid == 0 or s.barred or not s.present[leader] then return false end
	local offer = nil
	for _, candidate in s.offers do
		local age = M.now_ms() - candidate.heard
		-- PORT: his `mode_key(candidate.settings.mode) == requested.key` is always true here: the key
		-- the bridge sends back is the one native_flag_offers published for this offer.
		if candidate.leader == leader and candidate.game == game and M.offer_open(candidate) and age >= 0 and age <= M.leader_timeout_ms then
			offer = candidate
			break
		end
	end
	local already = s.game and not s.game.leading and s.game.leader == leader and s.game.id == game
	if not already and not offer then return false end
	if s.game and not already and (not s.game.state or s.game.state.phase ~= "results") then return false end
	local settings = already and s.game.settings or offer.settings
	-- PORT: adopt_native_mode_flag(world, game, mmid, at, yaw, duration_s, 6, race) was done by the
	-- bridge; `requested.yaw` is the yaw native_flag_offers published for this offer's settings.
	local yaw = settings.mode == "race" and M.gate_heading(settings, 0) or 0.0
	if not already then
		local copy = M.copy(offer)
		if M.starts_with(M.join_offer(s, copy, M.now_ms()), "error:") then
			return false
		end
	end
	s.game.native_lobby = true; s.game.native_flag_placed = true; s.game.native_flag_yaw = yaw
	return true
end

local function valid_at(at)
	return finite(at.x) and math.abs(at.x) < 100000 and finite(at.y) and math.abs(at.y) < 100000 and finite(at.z) and math.abs(at.z) < 100000
end
-- accept_race_start / accept_native_start_flag: {world, game, x, y, z, yaw} as the bridge formats them.
local function start_of(args)
	local world = args[1]
	local game = tonumber(args[2] or "")
	local x, y, z, yaw = tonumber(args[3] or ""), tonumber(args[4] or ""), tonumber(args[5] or ""), tonumber(args[6] or "")
	if not M.nz(world) or not game or game == 0 or not finite(yaw) or not finite(x) or not finite(y) or not finite(z) then return nil end
	local at = vector.create(x, y, z)
	-- His yaw is a float: the bridge's shortest text of it, read back as one.
	yaw = vector.create(yaw, 0, 0).x
	if not valid_at(at) then return nil end
	return {world = world, game = game, at = at, yaw = yaw}
end
local function accept_race_start(args)
	local start = start_of(args)
	if not start then return false end
	M.state().race_start = start
	return true
end
local function accept_native_start_flag(args)
	local start = start_of(args)
	if not start then return false end
	M.state().native_flag = start
	return true
end
local function request_native_start(world, game)
	local v = M.state().native or {}
	if not M.nz(world) or not game or game == 0 or not v.active or not v.leading or not v.waiting or v.world ~= world or v.game ~= game then return false end
	M.state().native_start = {world = world, game = game}
	return true
end
local function request_native_quit(world, game)
	local v = M.state().native or {}
	if not M.nz(world) or not game or game == 0 or not v.active or v.world ~= world or v.game ~= game then return false end
	M.state().native_quit = {world = world, game = game}
	return true
end

-- What his UI sent through the bridge (mode_bridge.cpp), td/ui_events.lua sends now: the setters' verbs, and every verb of
-- command(). Returns the command's text ("" for a request taken, "error: ..." for one refused).
M.request_native_start, M.request_native_quit = request_native_start, request_native_quit

function M.on_ui_command(verb, args)
	args = args or {}
	verb = verb or ""
	if verb == "race-start" then
		return accept_race_start(args) and "" or "error: the race start is not valid."
	end
	if verb == "start-flag" then
		return accept_native_start_flag(args) and "" or "error: the start flag is not valid."
	end
	if verb == "native-start" then
		return request_native_start(args[1], tonumber(args[2] or "")) and "" or "error: there is no waiting game to start."
	end
	if verb == "native-quit" then
		return request_native_quit(args[1], tonumber(args[2] or "")) and "" or "error: there is no game to quit."
	end
	if verb == "join-flag" then
		if join_native_flag_offer(args[1], tonumber(args[2] or ""), tonumber(args[3] or "")) then return "" end
		-- PORT: the kit adopted the native flag before the Lua heard of it, so any refusal here
		-- gives the registration back (his code did that only when join_offer refused, as he adopted
		-- after his own checks).
		M.placement("left")
		return "error: that game cannot be joined."
	end
	if M.starts_with(verb, "route-") then
		-- PORT: the bridge sends only {argument}; its own check matched the world and game against the
		-- view, so the view's are the request's.
		local view = M.state().native or {}
		local action = string.sub(verb, 7)
		return request_race_route_action(view.world, view.game, action, args[1] or "") and "" or "error: the route menu is not open."
	end
	return M.command(verb, args)
end

return nil
