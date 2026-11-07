extends Node
## Ranked test through the menu (two copies at once; tools/test_ranked.py starts them):
## each copy presses the buttons like a player: title, Ranked (the backend pairs them), picks a
## Pokémon, ready, VS, battle, then the result and the way out. (Hosting a game by IP is no longer
## in the menu: --host / --join on the command line still start a direct game, see test_net.gd.)
## Prints a MENU_NET_FINAL line to compare both copies.

const CHOOSES := {"host": ["charizard", "gengar"], "guest": ["lucario", "pikachu"], "host2": ["blastoise", "scizor"], "guest2": ["greninja", "venusaur"]}

var main: Node
var role := "host"
var _t := 0.0
var _wait_t := 0.0
var _round := 0                  # 0: first pick, 1: second
var _combat_t := -1.0
var _typed := false
var _captures := {}
var _steps: Array = []
var _battles: Array = []
var _end := ""
var _states_at_start := 0     # net.states_applied when the battle started
var _last := {}                # HP and state of the last battle frame
## --ranked: instead of host/join, both press Ranked and let the backend pair them (it
## also decides who hosts: "role" is taken from it). One battle; then the rating result
## the backend sent back is checked. Needs the backend and --ranked_server=URL
## --ranked_account=a|b (a file of its own for each copy on the same computer).
## --scenario=accept (default): the loser asks for a rematch, the winner accepts, a second
## ranked battle is played and both leave to the Ranked screen.
## --scenario=decline: the winner declines: the loser must land on the Ranked screen with
## "declined" on it, the winner too.
var _ranked := false
var _ranked_done := false
var _scenario := "accept"
## --room=create|join (with --room_file=path): a private room instead of the ranked search. The
## copy that creates it writes the code into the file, the other one reads it and joins.
var _room_mode := ""
var _room_file := ""
var _room_started := false
var _room_written := false
var _replay_step := 0          # arena: after the result, the player opens the replay of the match and watches it
var _replay_info := {}
var _replay_pos := Vector3.ZERO
var _replay_t := 0.0
var _report_step := 0          # arena: F5, a reason, "sent" (the rival reported once, as a player would)
var _rm_count := 0            # ranked battles finished in this room
var _rm_sent := false         # the key of the current step was pressed
## Smoothness of the rival's copy (the "teleports" players see): how many times it jumped
## more than 1.5 m in one frame, and the biggest jump. And the ping seen during the battles.
var _jumps := 0
var _max_jump := 0.0
var _prev_remote := Vector3.ZERO
var _prev_remote_ok := false
var _prev_own := Vector3.ZERO
var _prev_own_ok := false
var _own_jumps := 0
var _max_own_jump := 0.0
var _ping_sum := 0
var _ping_n := 0
var _last_path := ""          # "direct" or "relay": how the packets travelled in the last battle
var _team_ok := false         # a 2 vs 2: the four fighters were built as they should
var _lobby_searched := false
var _slot_seen := -1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	role = main._args.get("role", "host")
	_ranked = main._args.has("ranked")
	_scenario = str(main._args.get("scenario", "accept"))
	_room_mode = str(main._args.get("room", ""))
	_room_file = str(main._args.get("room_file", ""))
	if _room_mode != "":
		main.ranked.skip_auto = true        # no ranked search by itself: this copy goes to the room screen


func _step(text: String) -> void:
	if _steps.is_empty() or _steps.back() != text:
		_steps.append(text)
		print("MENU_NET %s t=%.1f %s" % [role, _t, text])


func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.action_press(action)
	get_tree().create_timer(0.05, true, false, true).timeout.connect(func(): Input.action_release(action))
	_wait_t = 0.3


func _key(source: Key, text := "") -> void:
	var ev := InputEventKey.new()
	ev.keycode = source
	ev.physical_keycode = source
	ev.unicode = text.unicode_at(0) if text != "" else 0
	ev.pressed = true
	Input.parse_input_event(ev)


func _capture(n: String) -> void:
	if _captures.has(n) or DisplayServer.get_name() == "headless":
		return
	_captures[n] = true
	var img := get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("res://").path_join("../captures/net_%s_%s.png" % [role, n]))


## --scenario=serverdown: the test kills the ranking server in the middle of the battle and starts it again later.
## What this copy must show: it is taken out of the match with the server error on the Ranked screen (nothing
## online works there), and when the server is back the lobby works again by itself.
var _sd_seen := false
var _sd_kicked := false


func _sd_check() -> bool:
	var r: Ranked = main.ranked
	if r.server_down:
		_sd_seen = true
		if not _sd_kicked and main.net == null and main.menu.is_open and main.menu.screen == "ranked":
			_sd_kicked = true
			_step("server error: out of the match, on the Ranked screen (can_search %s)" % r.can_search())
			_capture("server_error")
		return true
	if _sd_seen and not r.loading and r.notice == "" and not r.me.is_empty() and main.menu.is_open and main.menu.screen == "ranked":
		_step("the server is back: the lobby works again (can_search %s)" % r.can_search())
		_finish("" if _sd_kicked and r.can_search() else "after the server error: kicked %s, can search %s" % [_sd_kicked, r.can_search()])
		return true
	return _sd_seen


func _physics_process(delta: float) -> void:
	_t += delta
	if _scenario == "serverdown" and _sd_check():
		return
	if _t > (260.0 if _ranked else 150.0) and not _sd_seen:
		_finish("timed out at: " + str(_steps.back() if not _steps.is_empty() else "start"))
		return
	if _ranked_done:
		_wait_t -= delta
		if _wait_t <= 0.0:
			_ranked_after()
		return
	_wait_t -= delta
	if _wait_t > 0.0:
		return
	var m: Menu = main.menu
	if m.is_open:
		_menu(m)
	else:
		_combat(delta)


func _menu(m: Menu) -> void:
	match m.screen:
		"title":
			_step("title")
			_press("menu_accept")
		"main":
			_step("main: going to Ranked")
			_go_to(m, m.MAIN_MENU, "ranked")
		"draft":
			_step("draft: %s" % str(m.draft.get("stage", "waiting")))
			var dstage := str(m.draft.get("stage", ""))
			if dstage == "ban" and m.draft_action() == "ban":
				m._draft_confirm(m.pokemon_list()[0])
			elif dstage == "pick" and m.draft_action() == "pick":
				var dlist := m.pokemon_list()
				for di in dlist.size():
					if not m.draft_blocked(dlist[di]):
						m._draft_confirm(dlist[di])
						break
				_wait_t = 0.6
		"ranked":
			var rk: Ranked = main.ranked
			_step("ranked screen: %s (%s)" % [rk.state, str(rk.me.get("name", "no account yet"))])
			if _room_mode != "" and not _room_started and rk.state == "idle" and rk.can_search():
				if _room_mode == "create":
					_room_started = true
					m.room_open()
					m._room_create()          # (a lobby with a friend: a party)
					return
				if FileAccess.file_exists(_room_file):
					var code := FileAccess.get_file_as_string(_room_file).strip_edges()
					if code.length() == 5:
						_room_started = true
						m.room_open()
						m.room_input = code
						_step("joining room %s" % code)
						m._room_join()
						return
			var lobby_code := str(rk.party.get("code", ""))
			if _room_mode == "create" and not _room_written and lobby_code != "":
				_room_written = true
				var f := FileAccess.open(_room_file, FileAccess.WRITE)
				f.store_string(lobby_code)
				f.close()
				_step("lobby %s open" % lobby_code)
			# The leader looks for a match once the friend is in.
			if _room_mode == "create" and _room_written and not _lobby_searched and rk.state == "idle" and rk.party.get("members", []).size() == 2:
				_lobby_searched = true
				_step("the lobby has two players: the leader looks for a 2 vs 2")
				rk.search()
			if rk.state == "searching":
				_capture("ranked_search")
		"selection":
			if _ranked and main.ranked.is_active():
				role = main.ranked._match.role      # the backend decided who hosts
			if _combat_t >= 0.0:
				# The other one went back to selection before the end was seen here.
				_round_end()
				return
			if _round >= 2:
				return
			# Second battle: the host changes the stage (mov2) to the floating one.
			if role == "host" and _round == 1 and m.choice.stage != "floating":
				_press("mov2")
				return
			# Picked: on the options, Ready is already highlighted.
			if m.sel_phase == "setup":
				if not m.me_ready:
					_press("menu_accept")
				elif m.rival_choice_id != "":
					_capture("selection_%d" % (_round + 1))
				return
			var want: String = CHOOSES[role][_round]
			_step("selection %d: want %s" % [_round + 1, want])
			if m.me_ready:
				if m.rival_choice_id != "":
					_capture("selection_%d" % (_round + 1))
				return
			var list := m.pokemon_list()
			var target := list.find(want)
			if m.cursor == target:
				_press("menu_accept")
			elif target / m.COLUMNS > m.cursor / m.COLUMNS:
				_press("move_down")
			elif target / m.COLUMNS < m.cursor / m.COLUMNS:
				_press("move_up")
			else:
				_press("move_right" if target > m.cursor else "move_left")
		"vs":
			_step("VS %s vs %s" % m._vs)
			_capture("vs_%d" % (_round + 1))


func _go_to(m: Menu, list: Array, id: String) -> void:
	var i := list.map(func(e): return e[0]).find(id)
	if m.cursor == i:
		_press("menu_accept")
	else:
		_press("move_right")          # Online and Join are to the right of the first tile


func _combat(delta: float) -> void:
	var net: Net = main.net
	if net == null:
		if _round >= 2 and role == "host":
			_finish("")
		return
	if not net.in_battle or net.local == null or not is_instance_valid(net.remote):
		return
	var l: Fighter = net.local
	var r: Fighter = net.remote
	if _combat_t < 0.0:
		_combat_t = 0.0
		_prev_remote_ok = false
		_step("battle %d: me %s, rival %s, ping %d ms" % [_round + 1, l.species, r.species, net.ping_ms()])
		_states_at_start = net.states_applied
		var ridx := 0 if _ranked else _round      # a ranked rematch keeps the same Pokémon
		var expected: Array = [CHOOSES[role][ridx], CHOOSES["guest" if role == "host" else "host"][ridx]]
		if net.players() == 4:
			expected = [l.species, r.species]            # (a 2 vs 2: who the first rival is depends on the slots)
			_team_check(net)
		if not main.ranked.draft_match and [l.species, r.species] != expected:
			_finish("species swapped: %s, expected %s" % [[l.species, r.species], expected])
			return
		# Both play on the stage the host picked.
		var want_stage := "floating" if (_round == 1 and not _ranked) else "night"
		_step("stage %s" % main.arena.stage)
		# Each side's moves: the rival's must be what it saved (it sends them with its choice).
		_step("moves: me %s, rival %s" % [",".join(l.data.moves), ",".join(r.data.moves)])
		# (In the arena the server picks a random stage.)
		if main.arena.stage != want_stage and not net is ArenaClient:
			_finish("battle %d on stage %s, expected %s" % [_round + 1, main.arena.stage, want_stage])
			return
	_combat_t += delta
	# The rival's copy must move smoothly: a jump of more than 1.5 m between two frames is a
	# teleport on the player's screen (normal movement is under 0.6 m per frame). The first
	# second is left out: the Pokémon are being put on their starting places then.
	if _prev_remote_ok and main._end_t < 0.0 and _combat_t > 1.0:
		var jump := r.global_position.distance_to(_prev_remote)
		if jump > 1.5:
			_jumps += 1
			_max_jump = maxf(_max_jump, jump)
	_prev_remote = r.global_position
	_prev_remote_ok = main._end_t < 0.0
	# Your own Pokémon too (the arena predicts it, the server corrects it: it must not jump).
	if _prev_own_ok and main._end_t < 0.0 and _combat_t > 1.0:
		var own_jump := l.global_position.distance_to(_prev_own)
		if own_jump > 1.5:
			_own_jumps += 1
			_max_own_jump = maxf(_max_own_jump, own_jump)
	_prev_own = l.global_position
	_prev_own_ok = main._end_t < 0.0
	if net.ping_ms() > 0:
		_ping_sum += net.ping_ms()
		_ping_n += 1
	_last_path = net.path()
	_last = {"me_ko": l.state == "ko", "my_hp": int(l.hp), "rival_hp": int(r.hp)}
	if _combat_t > 3.0:
		_capture("combat_%d" % (_round + 1))
	# To avoid waiting for a whole battle: at 10 s each side drops itself to 1 HP
	# (each copy controls its own); the next hit ends it.
	if _combat_t > 10.0 and _combat_t - delta <= 10.0 and not net is ArenaClient:
		l.hp = minf(l.hp, 1.0)
	# In sync: the rival's states keep arriving during the battle, also after "pick another".
	if _combat_t > 8.0 and _combat_t - delta <= 8.0 and net.states_applied - _states_at_start < 120:
		_finish("battle %d out of sync: only %d rival states applied in 8 s" % [_round + 1, net.states_applied - _states_at_start])
		return
	if main._end_t > main.CHOICES_AT + 0.3:
		_round_end()
		if _ranked:
			_ranked_done = true
			_rm_count += 1
			_rm_sent = false
			_wait_t = 0.5
			return
		if role == "host":
			if _round == 1:
				_press("menu_back")          # both go back to pick
			else:
				main.back_to_menu()           # leaves: the other gets the disconnect
				_finish("")
		else:
			_wait_t = 1.0
	elif _combat_t > 60.0:
		_finish("battle %d does not end" % (_round + 1))


## Ranked, after a battle: wait for the rating, then play the scenario's steps (see the top).
func _ranked_after() -> void:
	var r: Ranked = main.ranked
	var m: Menu = main.menu
	# --scenario=rematch (arena): both press A on the result screen at the same moment: nobody accepts, the
	# server starts the new match (a draft again) for both.
	if _scenario == "rematch":
		if r._live and r._last_id > 0 and int(r._match.get("match_id", 0)) != r._last_id:
			_step("rematch started: match %d (after %d)" % [int(r._match.match_id), r._last_id])
			_finish("")
			return
		if main.net is ArenaClient and not r.result.is_empty() and not _rm_sent and r.can_ask_rematch():
			_rm_sent = true
			_step("both ask for the rematch at once")
			_press("jump")
		return
	# Out of the room already (the other one declined or left): the Ranked screen.
	if main.net == null:
		if m.is_open and m.screen == "replays":
			m._go("ranked")             # out of the replay: back to Ranked, where the test ends
			return
		if m.is_open and m.screen == "ranked":
			_step("on the Ranked screen: \"%s\"" % r.notice)
			_capture("ranked_after")
			_finish("")
		return
	# The arena has no rematch: once the server's result and the new rating are in, it is over.
	if main.net is ArenaClient or (main.net is ReplayPlayer and _report_step == 3):
		if r.result.is_empty():
			return
		_step("ranked result: %s (battle %d)" % [JSON.stringify(r.result), _rm_count])
		_capture("ranked_result_arena")
		match _report_step:
			0:
				_key(KEY_F5)
				_report_step = 1
				_wait_t = 0.4
				return
			1:
				if r.report_state == "choose":
					_capture("report_choose")
					_key(KEY_1)
					_report_step = 2
					_wait_t = 0.4
					return
				_step("the report menu did not open")
				_report_step = 3
			2:
				if r.report_state == "target":
					_capture("report_target")
					_key(KEY_1)          # a 2 vs 2: which player (the first of the three)
					_wait_t = 0.4
					return
				if r.report_state != "sent":
					return
				_step("report sent")
				_report_step = 3
		if _report_step == 3 and _replay_step < 5:
			match _replay_step:
				0:
					m.replays_open(0)
					_replay_step = 1
					_wait_t = 0.5
				1:
					if r.replays_loading:
						return
					_replay_info["listed"] = r.replays.size()
					if r.replays.is_empty():
						_replay_step = 5
						return
					_step("replays: %d listed" % r.replays.size())
					main.start_replay(int(r.replays[0].match_id), false)
					_replay_step = 2
				2:
					var rp = main.net
					if not (rp is ReplayPlayer) or main.fighters.size() < 2 or not rp.in_battle:
						_replay_t += 0.0167
						if _replay_t > 30.0:
							_step("the replay did not start")
							_replay_step = 5
						return
					_replay_info["started"] = true
					_replay_pos = main.fighters[0].global_position + main.fighters[1].global_position
					_replay_t = 0.0
					_replay_step = 3
				3:
					_replay_t += 0.0167
					if _replay_t < 9.0:
						return
					var rp2: ReplayPlayer = main.net
					var moved: bool = (main.fighters[0].global_position + main.fighters[1].global_position).distance_to(_replay_pos) > 0.5
					_replay_info["moved"] = moved
					_replay_info["frames"] = rp2.frames.size()
					_replay_info["states"] = rp2.states_applied
					_replay_info["position"] = snappedf(rp2.position, 0.1)
					_step("watched the replay: %s" % JSON.stringify(_replay_info))
					_capture("replay")
					main.back_to_menu("replays")
					_replay_step = 4
					_wait_t = 0.4
				4:
					m._go("ranked")
					_replay_step = 5
					_wait_t = 0.4
			return
		if not _rm_sent:
			_rm_sent = true
			_press("jump")          # the only option: back to Ranked (then the check above finishes)
		return
	# Accepted: the new battle began (same room, a new match number). The rating of the first
	# one is cleared by then, so this is checked before waiting for it.
	if _scenario == "accept" and _rm_count == 1 and r._live and int(r._match.get("match_id", 0)) != r._last_id and main._end_t < 0.0:
		_step("rematch started: match %d" % int(r._match.match_id))
		_ranked_done = false
		_combat_t = -1.0
		_rm_sent = false
		return
	if r.result.is_empty() or not r._pending.is_empty():
		return          # the backend has not settled this match yet
	_step("ranked result: %s (battle %d)" % [JSON.stringify(r.result), _rm_count])
	if _rm_count >= 2:
		# The second battle is over: both leave with B.
		if not _rm_sent:
			_rm_sent = true
			_capture("ranked_result_2")
			_press("menu_back")
		return
	if not bool(r.result.get("won", false)):
		if not _rm_sent and r.can_ask_rematch():
			_rm_sent = true
			_capture("rematch_ask")
			_press("jump")
	elif r.rematch == "asked" and not _rm_sent:
		_rm_sent = true
		_capture("rematch_prompt")
		_press("jump" if _scenario == "accept" else "menu_back")


## A 2 vs 2 on this screen: four Pokémon, mine and my team-mate's on team 0, the two rivals' on team 1, in the
## order mine, rival, team-mate, rival; every one of them has its place in the slot list.
func _team_check(net: Net) -> void:
	var c: ArenaClient = net
	var f: Array = main.fighters
	var ok: bool = f.size() == 4 and f[0].team == 0 and f[2].team == 0 and f[1].team == 1 and f[3].team == 1
	ok = ok and c.slot_fighters.size() == 4 and c.slot_fighters[c.slot] == f[0] and c.slot_fighters[c.ally_slot()] == f[2]
	ok = ok and main.hud._portraits.size() == 4 and main.trainers.size() == 4
	_team_ok = ok
	_slot_seen = c.slot
	_step("2 vs 2 on screen: %s (slot %d, ally slot %d)" % ["ok" if ok else "WRONG", c.slot, c.ally_slot()])


func _round_end() -> void:
	var winner := "rival" if _last.get("me_ko", false) else "me"
	_battles.append({"round": _round + 1, "winner": winner, "my_hp": _last.get("my_hp", -1), "rival_hp": _last.get("rival_hp", -1)})
	_step("KO in battle %d: %s wins (my HP %d, rival HP %d)" % [_round + 1, winner, _last.get("my_hp", -1), _last.get("rival_hp", -1)])
	_capture("ko_%d" % (_round + 1))
	_combat_t = -1.0
	_round += 1


func _finish(error: String) -> void:
	if _end != "":
		return
	_end = "ok" if error == "" else error
	var data := {"role": role, "result": _end, "battles": _battles, "steps": _steps.size(),
		"jumps": _jumps, "max_jump": snappedf(_max_jump, 0.1), "own_jumps": _own_jumps, "max_own_jump": snappedf(_max_own_jump, 0.1), "ping_avg": (_ping_sum / _ping_n) if _ping_n > 0 else 0,
		"path": _last_path}
	if _ranked:
		data["ranked"] = main.ranked.result
		data["screen"] = main.menu.screen
		data["notice"] = main.ranked.notice
		data["played"] = _rm_count
		data["report"] = main.ranked.report_state
		data["replay"] = _replay_info
		data["slot"] = _slot_seen
		data["server"] = {"seen": _sd_seen, "kicked": _sd_kicked}
		data["rematch"] = {"old": main.ranked._last_id, "new": int(main.ranked._match.get("match_id", 0)), "draft": main.ranked.draft_match}
		data["team"] = {"match": main.ranked.team_match, "ok": _team_ok, "ally": main.ranked.allies.size(), "enemies": main.ranked.enemies.size()}
		data["draft"] = {"match": main.ranked.draft_match, "stage": str(main.menu.draft.get("stage", "")),
			"bans": main.menu.draft.get("bans", []), "picks": main.menu.draft.get("picks", [])}
	print("MENU_NET_FINAL ", JSON.stringify(data))
	get_tree().create_timer(0.5, true, false, true).timeout.connect(func(): get_tree().quit())
