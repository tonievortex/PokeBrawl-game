class_name Ranked
extends Node
## Ranked play: the client of the ranking backend (plain HTTP + JSON, see the backend's
## README). Flow:
##   1. First time: registers an account (name from the profile) and keeps its token.
##   2. "Find match": joins the queue and asks every second until a rival is found.
##   3. The backend says who hosts: the host opens the room (Main.start_net), the guest
##      joins its address a few seconds later (retrying). Failing to connect voids the
##      match: nobody loses rating.
##   4. Both pick their Pokémon like in any online room. When the battle starts the
##      backend is told (from then on leaving counts as a loss); when it ends each side
##      reports win or loss. If the reports agree, the rating changes.
## The rating is only ever changed by the backend. Nothing here runs until the Ranked
## screen is opened.

const DEFAULT_SERVER := "http://57.128.211.104:44444"
const SAVE := "user://ranked.json"
const POLL := 1.0
const HOST_WAIT := 45.0       # the host waits this long for its rival to connect
const JOIN_DELAY := 3.0       # the guest waits for the host's port to open
const RELAY_JOIN_DELAY := 1.0 # through the relay there is no port to wait for
const JOIN_TRY := 12.0        # one connection attempt
const JOIN_TOTAL := 45.0
const REPORT_EVERY := 3.0     # asking again until the other side's report is in
const REPORT_TRIES := 45
const HEARTBEAT := 2.0         # asking the server whether it is there: this often
const HEARTBEAT_FAILS := 3     # ...it is "down" after this many answers missing in a row (one late answer is only lag)
const HEARTBEAT_TIMEOUT := 4.0
const REMATCH_WAIT := 25.0    # a rematch request is dropped (declined) after this long

var main: Node
var server := DEFAULT_SERVER
var token := ""
var me := {}                  # id, name, rating, wins, losses, rank
var board: Array = []         # the top of the ranking
var loading := false          # first contact with the server
var state := "idle"           # idle, searching, connecting (a rival was found), playing
var notice := ""              # last message for the screen ("!" in front: a problem)
var result := {}              # the last settled match: {won, delta}
var waited := 0.0
var in_queue := 0
var busy := false             # a rival is found but the server has no free match server yet
## Reporting the rival of the match that just ended (the result screen, F5, then 1 to 4).
const REPORT_REASONS := ["cheating", "abuse", "leaving", "other"]
var report_state := ""        # "", "choose", "target" (2 vs 2: which player), "sending", "sent" or "error"
var report_msg := ""
var _reported_match := 0
var draft_match := false      # the match in progress is a draft
var team_pref := false        # the lobby's mode: a ranked 2 vs 2 (four players, two teams) instead of a ranked 1 vs 1
var server_down := false      # the ranking server does not answer: nothing online works until it does
var _hb_t := 1.0
var _hb_fails := 0
var _hb_busy := false
var party := {}               # a 2 vs 2 lobby with a friend: {code, leader (am I), members: [{name, avatar, leader...}]}
var _party_t := 0.0
var _party_busy := false
var team_match := false       # the match in progress (or just played) is a 2 vs 2
var room_players := 0         # a room waiting for its players: how many are in...
var room_size := 2            # ...of how many (2, or 4 for a 2 vs 2)
var allies: Array = []        # a 2 vs 2: my team-mate (public records: name, rating...)
var enemies: Array = []       # ...and the two rivals
var _report_reason := ""
var _report_names: Array = [] # the players that can be reported after a 2 vs 2
var room_code := ""           # a private room is open (waiting for a friend): its code
var friendly := false         # the match in progress (or just played) is a private room's: no rating
var opponent := {}
var me_at := 0.0               # when `me` was fetched (the season's countdown runs from then)
var last_name := ""           # the account name used last (the login screen offers it)
var starting := false         # Ranked itself is (re)opening the room: not a "leave"

var _match := {}              # the backend's answer for the match in progress
var _relay_cfg := {}          # {host, port, match_id, token} when the fight goes through the relay
var _live := false            # a match is in progress and not settled on our side
var _started := false         # the battle began (leaving is a loss from then on)
var _t := 0.0
var _joined := false
var _join_at := 0.0
var _poll_t := 0.0
var _busy := false
var _fails := 0
var _pending := {}            # report waiting for the other side's: {match_id, result, t, tries}
var _return_screen := false
var _save_path := SAVE
var skip_auto := false        # the next time the Ranked screen opens, do not search by itself
var _auto := false            # the screen was just opened: search as soon as the account is ready
var _room := false            # the room of a ranked match is (or was) open
var _arena := false           # this match is run by the server (no reports, no rematch)
var _arena_wait := {}         # after a server result: asking /me until the rating has moved
const ARENA_CONNECT := 25.0   # the game server must answer within this long
## The rematch on the result screen: "" (none), "asking" (I asked, waiting for the answer),
## "asked" (my rival asked me), "starting" (accepted, the server is making the new match).
var rematch := ""
var _rm_t := 0.0
var _rm_poll := 0.0
var _rm_busy := false
var _last_id := 0             # the match that just ended (a rematch follows it)
var _last_won := false


func _ready() -> void:
	if main and main._args.has("team"):
		team_pref = true
	if main and main._args.has("ranked_server"):
		server = str(main._args.ranked_server)
	server = server.trim_suffix("/")
	# Tests run two copies on one computer: --ranked_account=a keeps its own account file.
	if main and main._args.has("ranked_account"):
		_save_path = "user://ranked_%s.json" % str(main._args.ranked_account)
	var f := FileAccess.open(_save_path, FileAccess.READ)
	if f:
		var d = JSON.parse_string(f.get_as_text())
		if d is Dictionary and d.get("server", "") == server:
			token = str(d.get("token", ""))
			last_name = str(d.get("name", ""))


# ---------------------------------------------------------------- the screen

## The Ranked screen opened: who am I and how is the ranking. Unless something just ended
## (a result, a cancelled match), it starts looking for a rival right away.
func open() -> void:
	if state != "idle":
		return
	# Opening the lobby never starts a search: the player chooses the mode and presses FIND MATCH. (Only the tests,
	# which have --ranked_account, still search by themselves.)
	_auto = not skip_auto and auto_account()
	skip_auto = false
	loading = true
	if token == "":
		_register(_clean_name(), 0)
	else:
		_refresh_me()
	_refresh_board()


## Whether there is an account to play with (the login screen comes first when not).
func logged_in() -> bool:
	return token != ""


## Tests (--ranked_account=a) make their accounts by themselves instead of showing the screen.
func auto_account() -> bool:
	return main != null and main._args.has("ranked_account")


## Seconds left of the season (counted down from when the server said how many).
func season_left() -> int:
	var s = me.get("season")
	if not s is Dictionary:
		return -1
	return maxi(0, int(s.get("seconds_left", 0)) - int(Time.get_unix_time_from_system() - me_at))


## Whether the rival of the match that just ended can be reported now.
func can_report() -> bool:
	return token != "" and _last_id > 0 and _reported_match != _last_id and report_state != "sent" and in_ranked_room()


func report_open() -> void:
	if can_report():
		report_state = "choose"
		report_msg = ""


func report_send(i: int) -> void:
	if report_state != "choose" or i < 0 or i >= REPORT_REASONS.size():
		return
	if team_match:
		# A 2 vs 2: the reason first, then which of the other three players.
		_report_reason = REPORT_REASONS[i]
		report_state = "target"
		return
	_post_report({"match_id": _last_id, "reason": REPORT_REASONS[i]})


## A 2 vs 2: the names that can be reported (the rivals first, then my team-mate).
func report_targets() -> Array:
	return _report_names


func report_send_target(i: int) -> void:
	if report_state != "target" or i < 0 or i >= _report_names.size():
		return
	_post_report({"match_id": _last_id, "reason": _report_reason, "target": str(_report_names[i])})


func _post_report(body: Dictionary) -> void:
	var mid: int = int(body.match_id)
	report_state = "sending"
	_call(HTTPClient.METHOD_POST, "/report", body, func(code: int, d: Dictionary):
		if code == 200:
			_reported_match = mid
			report_state = "sent"
		else:
			report_state = "error"
			report_msg = str(d.get("error", tr("Could not reach the ranking server."))))


# ---------------------------------------------------------------- replays

var replays: Array = []       # my latest matches that have a replay
var live_matches: Array = []  # matches being played now
var replays_loading := false


## Loads the list: live=false the player's own replays, live=true the matches on now.
func load_replays(live: bool) -> void:
	replays_loading = true
	_call(HTTPClient.METHOD_GET, "/live" if live else "/replays", {}, func(code: int, d: Dictionary):
		replays_loading = false
		if code == 200:
			if live:
				live_matches = d.get("matches", [])
			else:
				replays = d.get("replays", [])
		else:
			notice = "!" + tr("Could not reach the ranking server."))


## A piece of a replay file from `offset`: done(code, headers (lower-case names), body).
func fetch_replay(match_id: int, offset: int, done: Callable) -> void:
	var req := HTTPRequest.new()
	req.timeout = 15.0
	add_child(req)
	var headers := PackedStringArray(["Authorization: Bearer " + token])
	if req.request("%s/replay/%d?from=%d" % [server, match_id, offset], headers, HTTPClient.METHOD_GET) != OK:
		req.queue_free()
		done.call(0, {}, PackedByteArray())
		return
	req.request_completed.connect(func(res: int, code: int, hs: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		if res != HTTPRequest.RESULT_SUCCESS:
			done.call(0, {}, PackedByteArray())
			return
		var out := {}
		for h in hs:
			var at := h.find(":")
			if at > 0:
				out[h.substr(0, at).strip_edges().to_lower()] = h.substr(at + 1).strip_edges()
		done.call(code, out, body))


func calibrating() -> bool:
	return bool(me.get("calibrating", false))


func can_search() -> bool:
	return state == "idle" and not loading and token != "" and not me.is_empty() and not server_down


func is_active() -> bool:
	return _live


## Whether this online room is a ranked match's (no rematch there: each match is its own).
func in_ranked_room() -> bool:
	return _room and main.net != null


## Menu.disconnected asks once whether to land on the Ranked screen.
func consume_return() -> bool:
	var r := _return_screen
	_return_screen = false
	return r


# ---------------------------------------------------------------- account

func _clean_name() -> String:
	var rx := RegEx.new()
	rx.compile("[^A-Za-z0-9_\\-]")
	var n := rx.sub(str(main.options.shown_name()), "_", true).substr(0, 16)
	return n if n.length() >= 3 else "Trainer"


func _register(name: String, attempt: int) -> void:
	# (Only tests get here: players make their account on the account screen.)
	_call(HTTPClient.METHOD_POST, "/register", {"name": name, "email": "%s%d@test.local" % [name.to_lower(), attempt], "password": "test-password"}, func(code: int, d: Dictionary):
		if code == 201:
			token = str(d.token)
			me = d.duplicate()
			me.erase("token")
			me.rank = 0
			_save()
			loading = false
			_refresh_me()
		elif code == 409 and attempt < 6:
			# Taken: the same name with a number.
			_register(name.substr(0, 13) + str(randi_range(10, 999)), attempt + 1)
		else:
			loading = false
			_auto = false
			notice = "!" + (str(d.error) if d.has("error") else tr("Could not reach the ranking server.")))


func _refresh_me() -> void:
	_call(HTTPClient.METHOD_GET, "/me", {}, func(code: int, d: Dictionary):
		if code == 200:
			me = d
			me_at = Time.get_unix_time_from_system()
			loading = false
			if _auto and can_search():
				_auto = false
				search()
		elif code == 401:
			# The session is over (the account is gone, or it was logged out): log in again.
			token = ""
			_save()
			if auto_account():
				_register(_clean_name(), 0)
			else:
				loading = false
				_auto = false
				me = {}
				if main.menu.is_open and main.menu.screen == "ranked":
					main.menu.account_open("login", tr("Please log in again."))
		else:
			loading = false
			_auto = false
			notice = "!" + tr("Could not reach the ranking server."))


func _refresh_board() -> void:
	_call(HTTPClient.METHOD_GET, "/leaderboard?limit=10", {}, func(code: int, d: Dictionary):
		if code == 200 and d.get("players") is Array:
			board = d.players)


func _save() -> void:
	var f := FileAccess.open(_save_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"server": server, "token": token, "name": last_name}))


# ---------------------------------------------------------------- login

## The account screen's request. mode: "login", "register" or "secure" (an old account gets an
## email and a password); f: {name, email, password}. done(ok: bool, error: String).
func account_submit(mode: String, f: Dictionary, done: Callable) -> void:
	var path := "/login"
	var body := {"name": f.name, "password": f.password}
	if mode == "register":
		path = "/register"
		body = {"name": f.name, "email": f.email, "password": f.password}
	elif mode == "secure":
		path = "/account/secure"
		body = {"email": f.email, "password": f.password}
	_call(HTTPClient.METHOD_POST, path, body, func(code: int, d: Dictionary):
		if mode == "secure":
			if code == 200:
				me["has_password"] = true
				done.call(true, "")
			else:
				done.call(false, _account_error(code, d))
			return
		if (code == 200 or code == 201) and d.has("token"):
			token = str(d.token)
			me = d.duplicate()
			me.erase("token")
			me.rank = 0
			last_name = str(me.get("name", ""))
			_save()
			state = "idle"
			loading = false
			done.call(true, "")
		else:
			done.call(false, _account_error(code, d)))


func _account_error(code: int, d: Dictionary) -> String:
	if code == 0:
		return tr("Could not reach the ranking server.")
	var e := str(d.get("error", ""))
	match e.get_slice(":", 0):
		"name":
			return tr("That name is taken.") if e.contains("taken") else tr("The name needs 3 to 16 letters, digits, _ or -.")
		"email":
			return tr("An account with this email exists already.") if e.contains("exists") else tr("That does not look like an email address.")
		"password":
			return tr("The password needs at least 6 characters.")
	if code == 401:
		return tr("Wrong name or password.")
	if code == 429:
		return tr("Too many tries from this computer. Wait a few minutes.")
	return e if e != "" else tr("Something went wrong (%d).") % code


## Logs out: this computer forgets the account (the session ends on the server too).
func logout() -> void:
	if state == "searching":
		cancel()
	party_leave()
	if token != "":
		_call(HTTPClient.METHOD_POST, "/logout", {}, func(_c: int, _d: Dictionary): pass)
	token = ""
	me = {}
	result = {}
	notice = ""
	state = "idle"
	_save()


# ---------------------------------------------------------------- queue

func search() -> void:
	if not can_search() or in_party_as_member():
		return
	state = "searching"
	_room = false
	rematch = ""
	waited = 0.0
	in_queue = 0
	notice = ""
	result = {}
	_fails = 0
	_poll_t = POLL
	room_code = ""
	friendly = false
	report_state = ""
	_call(HTTPClient.METHOD_POST, "/queue/join", _join_body(), _on_ticket)


# ---------------------------------------------------------------- private rooms

## Opens a private room: the server gives a code to tell a friend. The wait looks like the search
## for a rival (and ends the same way), but only the friend with the code is matched, unrated.
func room_create(draft := false, team := false) -> void:
	if not can_search():
		return
	state = "searching"
	_room = false
	rematch = ""
	waited = 0.0
	in_queue = 0
	notice = ""
	result = {}
	_fails = 0
	_poll_t = POLL
	room_code = ""
	friendly = true
	_call(HTTPClient.METHOD_POST, "/room/create", dict_with(_join_body(), {"draft": draft and not team, "team": team}), _on_ticket)


## Joins a friend's room by its code. done(ok: bool, error: String).
func room_join(code: String, done: Callable) -> void:
	if not can_search():
		done.call(false, tr("Not ready yet: wait a moment."))
		return
	_call(HTTPClient.METHOD_POST, "/room/join", dict_with(_join_body(), {"code": code}), func(c: int, d: Dictionary):
		if c == 200 and d.has("status"):
			state = "searching"
			_room = false
			rematch = ""
			waited = 0.0
			notice = ""
			result = {}
			_fails = 0
			_poll_t = POLL
			room_code = ""
			friendly = true
			_on_ticket(c, d)
			done.call(true, "")
		elif c == 0:
			done.call(false, tr("Could not reach the ranking server."))
		else:
			done.call(false, str(d.get("error", tr("Something went wrong (%d).") % c))))


func dict_with(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := a.duplicate()
	out.merge(b, true)
	return out


## What the backend is told when joining the queue: the game version (only the same one
## meets) and this computer's home-network addresses (for two players on one router).
func _join_body() -> Dictionary:
	return {"version": Menu.version(), "local": Net.local_ips(), "arena": true, "draft": true, "team": team_pref}


## Who hosts and, for the guest, where it joins (for the screen).
func match_role() -> String:
	return str(_match.get("role", ""))


func match_host_ip() -> String:
	return str(_match.get("host_ip", ""))


# ---------------------------------------------------------------- the lobby with a friend (2 vs 2)

## The lobby's own random Pokémon, as the friend sees it.
func _avatar() -> String:
	return main.menu.lobby_avatar if main and main.menu else ""


## Whether I am in somebody else's lobby (the leader is the one who looks for the match).
func in_party_as_member() -> bool:
	return not party.is_empty() and not bool(party.get("leader", true))


## Opens a lobby: a code to give to a friend. Only a 2 vs 2 has one.
func party_create() -> void:
	if not can_search():
		return
	team_pref = true
	_call(HTTPClient.METHOD_POST, "/party/create", {"avatar": _avatar()}, func(code: int, d: Dictionary):
		if code == 200 and d.get("status", "") == "party":
			party = d
			_party_t = 1.0
		else:
			notice = "!" + str(d.get("error", tr("Could not reach the ranking server."))))


## Joins a friend's lobby by its code. done(ok: bool, error: String).
func party_join(code_text: String, done: Callable) -> void:
	if not can_search():
		done.call(false, tr("Not ready yet: wait a moment."))
		return
	_call(HTTPClient.METHOD_POST, "/party/join", {"code": code_text, "avatar": _avatar()}, func(code: int, d: Dictionary):
		if code == 200 and d.get("status", "") == "party":
			party = d
			team_pref = true
			_party_t = 1.0
			done.call(true, "")
		elif code == 0:
			done.call(false, tr("Could not reach the ranking server."))
		else:
			done.call(false, str(d.get("error", tr("Something went wrong (%d).") % code))))


func party_leave() -> void:
	if party.is_empty():
		return
	party = {}
	if token != "":
		_call(HTTPClient.METHOD_POST, "/party/leave", {}, func(_c: int, _d: Dictionary): pass)


## The lobby as the server says it is (polled while there is one): who is in it, whether the leader is searching.
func _on_party(code: int, d: Dictionary) -> void:
	if code != 200 or party.is_empty():
		return
	if d.get("status", "") != "party":
		party = {}
		notice = "!" + tr("The lobby was closed.")
		if state == "searching":
			state = "idle"
		return
	party = d
	team_pref = true
	if bool(d.get("leader", true)):
		return
	# A friend's lobby: the search the leader starts is mine too (the match arrives through the queue).
	if str(d.get("queue", "")) in ["waiting", "matched"] and state == "idle":
		state = "searching"
		_room = false
		rematch = ""
		waited = float(d.get("waited", 0.0))
		in_queue = 0
		notice = ""
		result = {}
		_fails = 0
		_poll_t = 0.2
		friendly = false
	elif str(d.get("queue", "")) == "idle" and state == "searching":
		state = "idle"
		notice = "!" + tr("The leader stopped searching.")


## Leaves the queue, or cancels the match being set up.
func cancel() -> void:
	if state == "searching":
		_call(HTTPClient.METHOD_POST, "/queue/leave", {}, func(_c: int, _d: Dictionary): pass)
		state = "idle"
	elif state in ["connecting", "playing"]:
		abort(tr("Cancelled."))


func _on_ticket(code: int, d: Dictionary) -> void:
	if code == 409 and state == "searching":
		# (a draft the server cannot run: say so instead of searching for ever)
		state = "idle"
		notice = "!" + str(d.get("error", tr("Something went wrong (%d).") % code))
		return
	if state != "searching":
		return
	if code == 0 or code >= 500:
		_fails += 1
		if _fails >= 4:
			state = "idle"
			notice = "!" + tr("Could not reach the ranking server.")
		return
	_fails = 0
	if d.get("status", "") == "idle" and in_party_as_member():
		state = "idle"          # the leader stopped searching
		notice = "!" + tr("The leader stopped searching.")
		return
	match d.get("status", ""):
		"matched":
			_begin_match(d)
		"waiting":
			waited = float(d.get("waited", waited))
			in_queue = int(d.get("in_queue", 0))
			busy = bool(d.get("busy", false))
			room_code = str(d.get("room", ""))
			room_players = int(d.get("room_players", 0))
			room_size = int(d.get("room_size", 2))
		"idle":
			if friendly and room_code != "":
				# The room closed (nobody joined in time): not a reason to start a ranked search.
				state = "idle"
				notice = "!" + tr("The room closed: nobody joined in time.")
				room_code = ""
				friendly = false
				return
			# The backend dropped the ticket (it was not asked for in time): ask again.
			_call(HTTPClient.METHOD_POST, "/queue/join", _join_body(), _on_ticket)


func _begin_match(d: Dictionary) -> void:
	_match = d
	_relay_cfg = {}
	_arena = false
	friendly = bool(d.get("friendly", false))
	draft_match = bool(d.get("draft", false))
	team_match = int(d.get("players", 2)) == 4
	allies = d.get("allies", []) if team_match else []
	enemies = d.get("enemies", []) if team_match else []
	_report_names = []
	if team_match:
		for p in enemies + allies:
			_report_names.append(str(p.get("name", "?")))
	room_code = ""
	room_size = 2
	room_players = 0
	opponent = d.get("opponent", {})
	if d.get("mode", "") == "arena" and d.get("relay") is Dictionary:
		# The server runs the fight: this game only plays its side (see ArenaClient).
		_arena = true
		_relay_cfg = {"host": _server_host(), "port": int(d.relay.port), "match_id": int(d.match_id),
			"token": str(d.relay.token), "slot": int(d.get("slot", 0)), "players": 4 if team_match else 2}
		_live = true
		_room = true
		_started = false
		_joined = false
		_t = 0.0
		state = "connecting"
		starting = true
		var err: String = main.start_arena(_relay_cfg, str(main._args.get("arena_pick", "")))
		starting = false
		if err != "":
			abort(err)
		return
	if d.get("mode", "") == "relay" and d.get("relay") is Dictionary:
		# Through the ranking server's relay: nobody has to open a port.
		_relay_cfg = {"host": _server_host(), "port": int(d.relay.port), "match_id": int(d.match_id), "token": str(d.relay.token),
			"no_direct": main._args.has("no_direct")}     # --no_direct: tests of the relay path alone
	_live = true
	_room = true
	_started = false
	_joined = false
	_t = 0.0
	state = "connecting"
	if d.role == "host":
		_open_room(true, "")


func _open_room(as_host: bool, ip: String) -> void:
	starting = true
	var err: String = main.start_net(as_host, ip, "", _relay_cfg)
	starting = false
	if err != "":
		abort(err)


## The ranking server's address without the scheme and port (the relay is on the same one).
func _server_host() -> String:
	var rest := server.get_slice("//", 1) if server.contains("//") else server
	return rest.get_slice("/", 0).get_slice(":", 0)


## "relay" (the fight goes through the ranking server) or "direct" (straight between players).
func match_mode() -> String:
	return "relay" if not _relay_cfg.is_empty() else "direct"


## Through the relay: whether the server has answered this player yet.
func relay_ok() -> bool:
	return main.net != null and main.net.relay_registered()


## Seconds since the rival was found.
func connecting_for() -> float:
	return _t


# ---------------------------------------------------------------- is the server there?

## Every few seconds the server is asked if it is there. A few answers missing in a row (not one late one: a
## laggy line is not a dead server) and the game says "server error": whoever is online is taken out, online
## play is off, the bot still works. When the server answers again everything comes back by itself.
func _heartbeat(delta: float) -> void:
	if main == null or (main._args.has("test") and not main._args.has("ranked_server")) or _hb_busy:
		return
	_hb_t -= delta
	if _hb_t > 0.0:
		return
	_hb_t = HEARTBEAT
	_hb_busy = true
	var req := HTTPRequest.new()
	req.timeout = HEARTBEAT_TIMEOUT
	add_child(req)
	if req.request(server + "/health") != OK:
		req.queue_free()
		_hb_busy = false
		_hb_result(false)
		return
	req.request_completed.connect(func(res: int, code: int, _h: PackedStringArray, _b: PackedByteArray):
		req.queue_free()
		_hb_busy = false
		_hb_result(res == HTTPRequest.RESULT_SUCCESS and code == 200))


func _hb_result(ok: bool) -> void:
	if ok:
		_hb_fails = 0
		if server_down:
			_on_server_up()
		return
	_hb_fails += 1
	if _hb_fails >= HEARTBEAT_FAILS and not server_down:
		_on_server_down()


func _on_server_down() -> void:
	server_down = true
	var was_match: bool = _live or (main.net != null and in_ranked_room())
	state = "idle"
	_live = false
	_match = {}
	rematch = ""
	_arena_wait = {}
	_pending = {}
	party = {}
	busy = false
	room_code = ""
	skip_auto = true
	notice = ""
	main.server_error_kick(was_match)


func _on_server_up() -> void:
	server_down = false
	_hb_fails = 0
	notice = ""
	if token != "":
		loading = true
		_refresh_me()
		_refresh_board()


# ---------------------------------------------------------------- the match

func _process(delta: float) -> void:
	_heartbeat(delta)
	match state:
		"searching":
			waited += delta
			_poll_t -= delta
			if _poll_t <= 0.0 and not _busy:
				_poll_t = POLL
				_busy = true
				_call(HTTPClient.METHOD_GET, "/queue", {}, func(code: int, d: Dictionary):
					_busy = false
					_on_ticket(code, d))
		"connecting":
			_t += delta
			if main.net and main.net.linked:
				state = "playing"
			elif _arena:
				if _t > ARENA_CONNECT:
					abort(tr("Could not reach the game server."))
			elif _match.role == "host":
				if _t > HOST_WAIT:
					abort(tr("Your rival could not connect."))
			elif not _joined and _t >= (RELAY_JOIN_DELAY if not _relay_cfg.is_empty() else JOIN_DELAY):
				_joined = true
				_join_at = _t
				_open_room(false, str(_match.host_ip))
			elif _joined and _t - _join_at > JOIN_TRY:
				if _t > JOIN_TOTAL:
					abort(tr("Could not connect to your rival."))
				else:
					_join_at = _t
					_open_room(false, str(_match.host_ip))
	if token != "" and not party.is_empty() and not _party_busy:
		_party_t -= delta
		if _party_t <= 0.0:
			_party_t = 1.0
			_party_busy = true
			_call(HTTPClient.METHOD_GET, "/party", {}, func(code: int, d: Dictionary):
				_party_busy = false
				_on_party(code, d))
	if _arena and token != "" and _last_id > 0 and not team_match and main.net != null and main._end_t > main.CHOICES_AT and not _rm_busy:
		_rm_poll -= delta
		if _rm_poll <= 0.0:
			_rm_poll = 1.0
			_rm_busy = true
			var mid_now := _last_id
			_call(HTTPClient.METHOD_GET, "/rematch?match_id=%d" % mid_now, {}, func(code: int, d: Dictionary):
				_rm_busy = false
				if code == 200:
					_on_rematch_state(mid_now, d))
	if rematch in ["asking", "asked"]:
		_rm_t += delta
		if _rm_t > REMATCH_WAIT:
			if rematch == "asked":
				answer_rematch(false)
			else:
				on_rematch_no()
	if not _arena_wait.is_empty():
		_arena_wait.t += delta
		if _arena_wait.t >= 1.0 and not _arena_wait.busy:
			_arena_wait.t = 0.0
			_arena_wait.tries += 1
			_arena_wait.busy = true
			_call(HTTPClient.METHOD_GET, "/me", {}, _on_arena_me)
	if not _pending.is_empty():
		_pending.t += delta
		if _pending.t >= REPORT_EVERY and not _busy:
			_pending.t = 0.0
			_pending.tries += 1
			if _pending.tries > REPORT_TRIES:
				_pending = {}
				notice = tr("The result was sent. It will count once your rival's arrives.")
			else:
				_send_report()


## Stops the match in progress without a result (connection failed, someone left before
## the battle). Nobody's rating changes.
func abort(reason: String) -> void:
	if _live and not _arena:
		_call(HTTPClient.METHOD_POST, "/match/abort", {"match_id": _match.match_id, "reason": "connect_failed"}, func(_c: int, _d: Dictionary): pass)
	_live = false
	_match = {}
	state = "idle"
	skip_auto = true
	notice = "!" + reason
	starting = true
	main.close_net()
	starting = false
	_to_screen()


func _to_screen() -> void:
	var m: Menu = main.menu
	m.online = false
	m.open_menu("ranked")


## From Main: the battle began.
func battle_started() -> void:
	if not _live or _started:
		return
	_started = true
	if _arena:
		return          # the server knows: it runs the fight
	_call(HTTPClient.METHOD_POST, "/match/started", {"match_id": _match.match_id}, func(_c: int, _d: Dictionary): pass)


## From Main: the battle ended, for me with this result.
func battle_ended(won: bool) -> void:
	if _live and _started and not _arena:
		_settle("win" if won else "loss")


## From Main, in a ranked arena: the server's result for this match ({winner: slot, reason,
## hp}). The rating is then changed by the backend (it settles when the match server's
## process ends, a few seconds later): ask for it until it has moved.
func arena_result(d: Dictionary) -> void:
	if not _arena or not _live:
		return
	var winner := int(d.get("winner", -1))
	var slot := int(_match.get("slot", 0))
	if team_match:
		slot = slot % 2          # the winner of a 2 vs 2 is a team: 0 or 1
	_last_id = int(_match.match_id)
	_last_won = winner == slot
	_live = false
	_match = {}
	state = "idle"
	skip_auto = true
	rematch = ""
	if winner not in [0, 1]:
		notice = "!" + tr("The match was voided: it does not count.")
		return
	if friendly:
		# A private room: nothing to wait for, the rating does not move.
		result = {"won": winner == slot, "delta": 0, "friendly": true}
		notice = ""
		return
	notice = tr("Result sent.")
	_arena_wait = {"t": 0.0, "tries": 0, "busy": false, "rating": float(me.get("rating", 1000.0)),
		"games": int(me.get("wins", 0)) + int(me.get("losses", 0)), "won": winner == slot}


func _on_arena_me(code: int, d: Dictionary) -> void:
	if _arena_wait.is_empty():
		return
	_arena_wait.busy = false
	if code == 200 and int(d.get("wins", 0)) + int(d.get("losses", 0)) > int(_arena_wait.games):
		me = d
		result = {"won": _arena_wait.won, "delta": int(round(float(d.get("rating", 0.0)) - float(_arena_wait.rating)))}
		_arena_wait = {}
		notice = ""
		_refresh_board()
		if main.hud:
			main.hud.log_entry(tr("Ranked: %+d rating") % result.delta)
	elif _arena_wait.tries > 20:
		_arena_wait = {}
		notice = tr("The result is in. Your rating will update shortly.")
		_refresh_me()


## From Main: the rival's connection dropped. Before the battle nothing counts; during it,
## whoever stays wins. After a settled match it only closes the room.
func on_disconnect(_reason: String) -> void:
	var was_room := _room
	_room = false
	if _arena:
		# The connection to the game server is gone: if the fight was on, the server settles it
		# (a player who is silent forfeits). The rating shows once that is done.
		if _live:
			_live = false
			_match = {}
			state = "idle"
			skip_auto = true
			notice = "!" + _reason
			_return_screen = true
			main.get_tree().create_timer(8.0).timeout.connect(_refresh_me)
		return
	if not _live:
		if was_room:
			skip_auto = true
			_return_screen = true
			if rematch == "asking":
				notice = "!" + tr("Rematch declined.")
			rematch = ""
		return
	_return_screen = true
	if _started:
		_settle("win")
		notice = tr("Your rival left the battle.")
	else:
		abort_silent(tr("Your rival left before the battle."))


## From Main: I leave the battle (or the room) on my own.
func on_leave(battle_over: bool) -> void:
	if _arena and rematch in ["asking", "asked"]:
		_rematch_vote(false)          # leaving while a rematch is open: the rival is told it is a no
		rematch = ""
	if not _live:
		return
	if _arena:
		# Leaving a fight that is on: the ArenaClient tells the server (it counts as a loss).
		_live = false
		_match = {}
		state = "idle"
		skip_auto = true
		if _started and not battle_over:
			notice = "!" + tr("You left the match: it counts as a loss.")
			main.get_tree().create_timer(6.0).timeout.connect(_refresh_me)
		else:
			notice = "!" + tr("Cancelled.")
		return
	if _started and not battle_over:
		_settle("loss")
	elif not _started:
		abort_silent(tr("Cancelled."))


## From Main.close_net: the room was closed by the player (not by Ranked itself).
func on_room_closed() -> void:
	if starting or not _live or _started:
		return
	abort_silent(tr("Cancelled."))


## Like abort, without touching the room or the screen (the caller is already doing it).
func abort_silent(reason: String) -> void:
	if _live and not _arena:
		_call(HTTPClient.METHOD_POST, "/match/abort", {"match_id": _match.match_id, "reason": "left"}, func(_c: int, _d: Dictionary): pass)
	_live = false
	_match = {}
	state = "idle"
	skip_auto = true
	notice = "!" + reason


func _settle(res: String) -> void:
	_last_id = int(_match.match_id)
	_last_won = res == "win"
	rematch = ""
	_pending = {"match_id": _match.match_id, "result": res, "t": 0.0, "tries": 0}
	_live = false
	_match = {}
	state = "idle"
	skip_auto = true
	notice = tr("Result sent.")
	_send_report()


func _send_report() -> void:
	_busy = true
	_call(HTTPClient.METHOD_POST, "/match/report", {"match_id": _pending.match_id, "result": _pending.result}, _on_report)


func _on_report(code: int, d: Dictionary) -> void:
	_busy = false
	if _pending.is_empty() or code != 200:
		return
	match d.get("state", ""):
		"done":
			_pending = {}
			result = {"won": bool(d.get("won", false)), "delta": int(d.get("delta", 0))}
			notice = ""
			_refresh_me()
			_refresh_board()
			if main.hud:
				main.hud.log_entry(tr("Ranked: %+d rating") % result.delta)
		"void":
			_pending = {}
			notice = "!" + tr("The match was voided: it does not count.")

# ---------------------------------------------------------------- rematch

## A on the result screen. In a match run by the server (1 vs 1) either player can ask, and nobody has to
## accept: the server starts the new match as soon as both have said yes (also at the very same moment).
## A peer-to-peer match (an old game) keeps its old rule: the loser asks, the winner accepts.
func can_ask_rematch() -> bool:
	if not in_ranked_room() or rematch != "" or _last_id <= 0 or main._end_t <= main.CHOICES_AT:
		return false
	if _arena:
		return not team_match
	return not friendly and not _last_won


func ask_rematch() -> void:
	if not can_ask_rematch():
		return
	rematch = "asking"
	_rm_t = 0.0
	if _arena:
		_rematch_vote(true)
		return
	main.net.send_event({"t": "rm_ask"})


## Arena match: my yes or no to the server (the new match comes back with the answer, or on a later poll).
func _rematch_vote(yes: bool) -> void:
	var mid := _last_id
	_call(HTTPClient.METHOD_POST, "/match/rematch_vote", {"match_id": mid, "vote": yes}, func(code: int, d: Dictionary):
		if code == 200 and yes:
			_on_rematch_state(mid, d))


## What the server says about a rematch of match `mid` (a vote's answer or a poll).
func _on_rematch_state(mid: int, d: Dictionary) -> void:
	if mid != _last_id or not _arena:
		return
	match str(d.get("status", "")):
		"matched":
			if rematch in ["asking", "asked"]:
				_arena_rematch_begin(d)
		"waiting":
			# The rival asked first: the screen offers to accept (A), or to decline (B).
			if rematch == "" and bool(d.get("other", false)) and not bool(d.get("me", false)) and in_ranked_room() and main._end_t >= 0.0:
				rematch = "asked"
				_rm_t = 0.0
		"declined", "expired":
			if rematch in ["asking", "asked"]:
				rematch = ""
				skip_auto = true
				notice = "!" + (tr("Rematch declined.") if str(d.status) == "declined" else tr("Your rival did not answer."))
				main._leave_ranked()


## Both said yes: back to the Ranked screen's state of "connecting", to the new match's server (draft first).
func _arena_rematch_begin(d: Dictionary) -> void:
	rematch = ""
	_arena_wait = {}
	result = {}
	skip_auto = true
	main.back_to_menu("ranked")
	skip_auto = true
	_begin_match(d)


## The rival asked me (a net event).
func on_rematch_ask() -> void:
	if not in_ranked_room() or main._end_t < 0.0 or rematch != "":
		return
	rematch = "asked"
	_rm_t = 0.0


## I answer the rival's request: yes starts a new ranked match at once; no sends them back
## to the menu (and I go too, a moment later so the answer arrives first).
func answer_rematch(yes: bool) -> void:
	if rematch != "asked":
		return
	if _arena:
		if yes:
			rematch = "asking"
			_rm_t = 0.0
			_rematch_vote(true)
		else:
			_rematch_vote(false)
			rematch = ""
			notice = ""
			main.get_tree().create_timer(0.4).timeout.connect(func():
				if in_ranked_room():
					main._leave_ranked())
		return
	if yes:
		main.net.send_event({"t": "rm_yes"})
		_start_rematch()
		return
	main.net.send_event({"t": "rm_no"})
	rematch = ""
	notice = ""
	main.get_tree().create_timer(0.4).timeout.connect(func():
		if in_ranked_room():
			main._leave_ranked())


## The rival accepted (a net event).
func on_rematch_yes() -> void:
	if rematch == "asking":
		_start_rematch()


## The rival declined (a net event, or no answer in time): "declined" and back to the menu.
func on_rematch_no() -> void:
	if rematch != "asking":
		return
	rematch = ""
	skip_auto = true
	notice = "!" + tr("Rematch declined.")
	main._leave_ranked()


## Both sides call this when the rematch is on: the server makes one new match for the same
## pair (ranked like any other), then the battle restarts with the same Pokémon.
func _start_rematch() -> void:
	rematch = "starting"
	_call(HTTPClient.METHOD_POST, "/match/rematch", {"match_id": _last_id}, func(code: int, d: Dictionary):
		if code != 200 or not d.has("match_id"):
			rematch = ""
			skip_auto = true
			notice = "!" + tr("Could not start the rematch.")
			if in_ranked_room():
				main._leave_ranked()
			return
		_match = {"match_id": int(d.match_id), "role": str(d.role)}
		_live = true
		_started = false
		result = {}
		notice = ""
		state = "playing"
		rematch = ""
		main.rematch())


# ---------------------------------------------------------------- HTTP

## One request; `done` gets (HTTP code or 0 on failure, the JSON object).
func _call(method: int, path: String, body: Dictionary, done: Callable) -> void:
	var req := HTTPRequest.new()
	req.timeout = 8.0
	add_child(req)
	var headers := PackedStringArray(["Content-Type: application/json"])
	if token != "":
		headers.append("Authorization: Bearer " + token)
	var payload := JSON.stringify(body) if method == HTTPClient.METHOD_POST else ""
	var err := req.request(server + path, headers, method, payload)
	if err != OK:
		req.queue_free()
		done.call(0, {})
		return
	req.request_completed.connect(func(res: int, code: int, _h: PackedStringArray, raw: PackedByteArray):
		req.queue_free()
		if res != HTTPRequest.RESULT_SUCCESS:
			done.call(0, {})
			return
		var data = JSON.parse_string(raw.get_string_from_utf8())
		done.call(code, data if data is Dictionary else {}))
