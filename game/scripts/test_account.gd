extends Node
## The account screen, played like a person would: Ranked asks for an account first; creating
## one (the two passwords must match), logging out, logging in again, a wrong password.
##   godot --path game -- --test=menu_account --ranked_server=http://127.0.0.1:PORT
## (tools/test_account.py starts the backend for it.) Prints OK / FAIL lines and ACCOUNT_DONE.

var main: Node
var _fails := 0
const NAME := "Tester"
const MAIL := "tester@example.com"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run()


func _check(cond: bool, what: String) -> void:
	print(("OK    " if cond else "FAIL  ") + what)
	if not cond:
		_fails += 1


func _wait(s: float) -> void:
	await get_tree().create_timer(s, true, false, true).timeout


func _key(code: Key, text := "", ctrl := false) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.unicode = text.unicode_at(0) if text != "" else 0
	ev.ctrl_pressed = ctrl
	ev.pressed = true
	Input.parse_input_event(ev)
	await _wait(0.05)


func _type(text: String) -> void:
	for ch in text:
		await _key(KEY_NONE, ch)


## A press of the accept button (the menu reads it as a click for one frame).
func _click() -> void:
	main.menu._clicked = true
	await _wait(0.12)


func _capture(n: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("res://").path_join("../captures/account_%s.png" % n))


func _until(cond: Callable, seconds: float) -> bool:
	var t := 0.0
	while t < seconds:
		if cond.call():
			return true
		await _wait(0.1)
		t += 0.1
	return cond.call()


func _run() -> void:
	var m: Menu = main.menu
	var r: Ranked = main.ranked
	# A clean start: whatever an earlier run saved on this computer is forgotten.
	DirAccess.remove_absolute(r._save_path)
	r.token = ""
	r.last_name = ""
	m.acc.name = ""
	await _wait(1.5)
	# The first screen of the game: with no account, the account screen comes before everything else.
	main._args["force_gate"] = "1"
	m.screen = "title"
	m.open_menu()
	await _wait(0.3)
	_check(m.screen == "account" and m.acc_gate and m.acc_mode == "register", "the game starts on the account screen when there is no account (%s, register %s)" % [m.screen, m.acc_mode == "register"])
	main._args.erase("force_gate")
	m.acc_gate = false
	m._go("ranked")
	await _wait(0.3)
	_check(m.screen == "account" and m.acc_mode == "login", "Ranked without an account opens the login screen (%s, %s)" % [m.screen, m.acc_mode])
	await _capture("login")

	# Create an account: F2, name, email, password, a different repeat.
	await _key(KEY_F2)
	_check(m.acc_mode == "register" and m.acc_fields().size() == 4, "F2 switches to Create account (4 fields)")
	await _type(NAME)
	await _key(KEY_ENTER)
	await _type(MAIL)
	await _key(KEY_ENTER)
	await _type("secret1")
	await _key(KEY_ENTER)
	await _type("secret2")
	await _capture("register")
	await _key(KEY_ENTER)
	_check(m.screen == "account" and m.acc_msg != "" and m.acc_field == 3, "different passwords: refused on the spot, the field is the repeat (%s)" % m.acc_msg)
	await _key(KEY_BACKSPACE)
	await _type("1")
	await _key(KEY_ENTER)
	var ok: bool = await _until(func(): return m.screen == "ranked" and r.logged_in() and not r.loading, 8.0)
	_check(ok and str(r.me.get("name", "")) == NAME, "creating the account goes on to Ranked as %s (%s)" % [NAME, str(r.me.get("name", ""))])
	_check(bool(r.me.get("has_password", false)), "the account has a password")
	await _capture("ranked")
	# What the Ranked card looks like for a player in a division, and for one still calibrating.
	r.cancel()
	await _wait(0.3)
	var base_me := r.me.duplicate(true)
	r.me_at = Time.get_unix_time_from_system()
	r.me = base_me.duplicate(true)
	r.me.merge({"rating": 1175, "wins": 7, "losses": 3, "games": 14, "calibrating": false, "division": "Gold", "rank": 3, "last_division": "Silver",
		"division_info": {"name": "Gold", "next": "Platinum", "next_at": 1250.0, "progress": 0.5},
		"season": {"name": "2026-11", "seconds_left": 23 * 86400 + 4 * 3600}}, true)
	r.board = [{"id": 1, "name": NAME, "rating": 1175, "wins": 7, "losses": 3, "division": "Gold", "rank": 1},
		{"id": 2, "name": "Misty", "rating": 1120, "wins": 5, "losses": 2, "division": "Gold", "rank": 2},
		{"id": 3, "name": "Brock", "rating": 910, "wins": 3, "losses": 6, "division": "Bronze", "rank": 3}]
	await _wait(0.4)
	_check(m.screen == "ranked" and r.state == "idle", "the Ranked screen shows a player in a division")
	await _capture("ranked_gold")
	r.me = base_me.duplicate(true)
	r.me.merge({"rating": 1040, "games": 4, "calibrating": true, "division": "", "placement": 4, "placement_of": 10, "wins": 3, "losses": 1,
		"season": {"name": "2026-11", "seconds_left": 5 * 3600}}, true)
	await _wait(0.4)
	await _capture("ranked_calibrating")
	# The lobby of a 2 vs 2 with a friend (a made-up party: no server needed).
	r.team_pref = true
	r.party = {"status": "party", "code": "K7PQ2", "leader": true, "queue": "idle", "members": [
		{"name": NAME, "leader": true, "avatar": "gengar", "rating": 1040}, {"name": "Misty", "leader": false, "avatar": "lucario", "rating": 1100}]}
	r._party_t = 1000.0
	await _wait(0.5)
	await _capture("lobby_2v2")
	# The empty slot opens the list of players I played with; the code of the lobby is there from the start.
	r.party = {"status": "party", "code": "K7PQ2", "leader": true, "queue": "idle", "members": [{"name": NAME, "leader": true, "avatar": "gengar", "rating": 1040}]}
	await _wait(0.3)
	await _capture("lobby_empty_slot")
	m.friends_open()
	await _wait(0.6)
	_check(m.screen == "friends", "F4 / the empty slot opens the friends list (%s)" % m.screen)
	r.recent = [{"name": "Misty", "rating": 1120, "division": "Gold", "online": true}, {"name": "Brock", "rating": 910, "division": "Bronze", "online": false}]
	r.recent_loading = false
	r.invite_msg = "Invitation sent to Misty."
	await _wait(0.4)
	await _capture("friends")
	r.invites = [{"code": "ABCDE", "from": "Misty", "avatar": "lucario"}]
	m._go("ranked")
	await _wait(0.4)
	await _capture("invite_banner")
	r.invites = []
	r.party = {}
	r.team_pref = false
	m.room_open()
	m.room_input = "K7P"
	m.room_focus = 1
	await _wait(0.4)
	_check(m.screen == "room", "F4 / the friend button opens the friendly-match screen")
	await _capture("room")
	# The draft screen in the middle of a pick (a made-up state: no server needed).
	m.draft = {"stage": "pick", "bans": ["pikachu", "snorlax"], "ban_done": [true, true], "picks": ["charizard", null], "turn": 1, "left": 17.0}
	m.draft_at = Time.get_ticks_msec() / 1000.0
	m.draft_cursor = 7
	m._go("draft")
	await _wait(0.5)
	await _capture("draft")
	r.skip_auto = true
	m._go("ranked")
	r.cancel()
	r.me = base_me
	await _wait(0.3)

	# Log out from Options (the last row, with a question first): back to the login screen.
	r.cancel()
	m._go("options")
	await _wait(0.4)
	var list: Array = main.options.items()
	main.options.cursor = list.size() - 1
	_check(str(list[list.size() - 1].id) == "logout", "Log out is the very last row of Options (%s)" % str(list[list.size() - 1].id))
	await _click()
	await _wait(0.4)
	_check(not m.confirm.is_empty() and m.screen == "options", "it asks first")
	m.confirm.on = 1                  # "Yes"
	await _click()
	await _wait(0.5)
	_check(m.screen == "account" and m.acc_mode == "login" and not r.logged_in(), "Log out in Options logs out and shows the login screen")
	_check(str(m.acc.name) == NAME, "the login screen offers the last name (%s)" % m.acc.name)

	# A wrong password.
	await _key(KEY_DOWN)
	await _type("not-it")
	await _key(KEY_ENTER)
	await _until(func(): return not m.acc_busy and m.acc_msg != "", 5.0)
	_check(m.screen == "account" and m.acc_msg.to_lower().contains("wrong"), "a wrong password is refused (%s)" % m.acc_msg)
	await _capture("wrong")

	# The right one, by email instead of the name.
	m.acc.name = MAIL
	m.acc.password = ""
	m.acc_field = 1
	await _type("secret1")
	await _key(KEY_ENTER)
	ok = await _until(func(): return m.screen == "ranked" and r.logged_in() and str(r.me.get("name", "")) == NAME, 8.0)
	_check(ok, "logging in with the email works")
	r.cancel()
	await _wait(0.3)

	# A new copy of the game (the saved token) stays logged in.
	var saved := FileAccess.get_file_as_string(r._save_path)
	_check(saved.contains("token") and saved.contains(NAME), "the login is saved on this computer")
	# A real player (the tests' own accounts search by themselves, a person does not): opening Ranked waits in the
	# lobby until FIND MATCH is pressed.
	main._args.erase("ranked_account")
	r.state = "idle"
	r.skip_auto = false
	m._go("main")
	await _wait(0.3)
	m._go("ranked")
	await _wait(2.5)
	_check(m.screen == "ranked" and r.state == "idle", "opening Ranked waits in the lobby: no search until FIND MATCH (%s)" % r.state)
	await _click()
	await _wait(0.5)
	_check(r.state == "searching", "FIND MATCH starts the search (%s)" % r.state)
	r.cancel()
	print("ACCOUNT_DONE %s" % ("ok" if _fails == 0 else "failed"))
	get_tree().quit(1 if _fails > 0 else 0)
