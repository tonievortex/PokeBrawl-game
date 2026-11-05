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
const JOIN_TRY := 12.0        # one connection attempt
const JOIN_TOTAL := 45.0
const REPORT_EVERY := 3.0     # asking again until the other side's report is in
const REPORT_TRIES := 45
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
var opponent := {}
var starting := false         # Ranked itself is (re)opening the room: not a "leave"

var _match := {}              # the backend's answer for the match in progress
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
## The rematch on the result screen: "" (none), "asking" (I asked, waiting for the answer),
## "asked" (my rival asked me), "starting" (accepted, the server is making the new match).
var rematch := ""
var _rm_t := 0.0
var _last_id := 0             # the match that just ended (a rematch follows it)
var _last_won := false


func _ready() -> void:
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


# ---------------------------------------------------------------- the screen

## The Ranked screen opened: who am I and how is the ranking. Unless something just ended
## (a result, a cancelled match), it starts looking for a rival right away.
func open() -> void:
	if state != "idle":
		return
	_auto = not skip_auto
	skip_auto = false
	loading = true
	if token == "":
		_register(_clean_name(), 0)
	else:
		_refresh_me()
	_refresh_board()


func can_search() -> bool:
	return state == "idle" and not loading and token != "" and not me.is_empty()


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
	_call(HTTPClient.METHOD_POST, "/register", {"name": name}, func(code: int, d: Dictionary):
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
			loading = false
			if _auto and can_search():
				_auto = false
				search()
		elif code == 401:
			# The backend does not know this account (new database): start again.
			token = ""
			_register(_clean_name(), 0)
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
		f.store_string(JSON.stringify({"server": server, "token": token}))


# ---------------------------------------------------------------- queue

func search() -> void:
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
	_call(HTTPClient.METHOD_POST, "/queue/join", {"version": Menu.version()}, _on_ticket)


## Leaves the queue, or cancels the match being set up.
func cancel() -> void:
	if state == "searching":
		_call(HTTPClient.METHOD_POST, "/queue/leave", {}, func(_c: int, _d: Dictionary): pass)
		state = "idle"
	elif state in ["connecting", "playing"]:
		abort(tr("Cancelled."))


func _on_ticket(code: int, d: Dictionary) -> void:
	if state != "searching":
		return
	if code == 0 or code >= 500:
		_fails += 1
		if _fails >= 4:
			state = "idle"
			notice = "!" + tr("Could not reach the ranking server.")
		return
	_fails = 0
	match d.get("status", ""):
		"matched":
			_begin_match(d)
		"waiting":
			waited = float(d.get("waited", waited))
			in_queue = int(d.get("in_queue", 0))
		"idle":
			# The backend dropped the ticket (it was not asked for in time): ask again.
			_call(HTTPClient.METHOD_POST, "/queue/join", {"version": Menu.version()}, _on_ticket)


func _begin_match(d: Dictionary) -> void:
	_match = d
	opponent = d.get("opponent", {})
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
	var err: String = main.start_net(as_host, ip)
	starting = false
	if err != "":
		abort(err)


# ---------------------------------------------------------------- the match

func _process(delta: float) -> void:
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
			elif _match.role == "host":
				if _t > HOST_WAIT:
					abort(tr("Your rival could not connect."))
			elif not _joined and _t >= JOIN_DELAY:
				_joined = true
				_join_at = _t
				_open_room(false, str(_match.host_ip))
			elif _joined and _t - _join_at > JOIN_TRY:
				if _t > JOIN_TOTAL:
					abort(tr("Could not connect to your rival."))
				else:
					_join_at = _t
					_open_room(false, str(_match.host_ip))
	if rematch in ["asking", "asked"]:
		_rm_t += delta
		if _rm_t > REMATCH_WAIT:
			if rematch == "asked":
				answer_rematch(false)
			else:
				on_rematch_no()
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
	if _live:
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
	_call(HTTPClient.METHOD_POST, "/match/started", {"match_id": _match.match_id}, func(_c: int, _d: Dictionary): pass)


## From Main: the battle ended, for me with this result.
func battle_ended(won: bool) -> void:
	if _live and _started:
		_settle("win" if won else "loss")


## From Main: the rival's connection dropped. Before the battle nothing counts; during it,
## whoever stays wins. After a settled match it only closes the room.
func on_disconnect(_reason: String) -> void:
	var was_room := _room
	_room = false
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
	if not _live:
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
	if _live:
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

## Only the one who lost can ask: A on the result screen.
func can_ask_rematch() -> bool:
	return in_ranked_room() and rematch == "" and _last_id > 0 and not _last_won and main._end_t > main.CHOICES_AT


func ask_rematch() -> void:
	if not can_ask_rematch():
		return
	rematch = "asking"
	_rm_t = 0.0
	main.net.send_event({"t": "rm_ask"})


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
