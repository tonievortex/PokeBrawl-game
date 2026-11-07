class_name Menu
extends Node
## Menus: white and clean like Sword and Shield's, laid out like Smash Ultimate's. The
## stage is not behind them: it is only built when the battle starts. Screens:
##   title       the logo; A to enter
##   main        Battle, Ranked, Training, Moves, Options, Quit
##   account     log in or create an account (Ranked needs one)
##   ranked      rating, the ranking, and the search for a rival (the server runs the fight)
##   selection   Pokémon grid on top, each side's pick below with its moves, and the
##               battle's options (stage, difficulty, edit moves, fight). Online: each
##               picks their own and the host picks the stage
##   moves       each Pokémon's four moves and ability, its stats sheet and each move's
##               details (also opened from the selection, for last-minute changes)
##   options     controls, sound, screen and language (Options)
##   vs          both face to face before the battle
## Logic and input live here; MenuDraw draws. Visible text is English and goes through tr()
## when drawn (game/i18n).

const DIFFICULTIES := ["easy", "normal", "hard"]
const DIFFICULTY_NAME := {"easy": "Easy", "normal": "Normal", "hard": "Hard"}
const STAGES := ["night", "floating", "league"]
const STAGE_NAME := {"night": "Night Stadium", "floating": "Floating Stadium", "league": "League Stadium"}
const STAGE_TEXT := {"night": "A Galar stadium at night, packed and walled all round: nobody falls off.",
	"floating": "A platform over the void. Whoever is pushed off the edge is out.",
	"league": "The League's coliseum. The field closes in bit by bit: outside it you lose HP."}
const COLUMNS := 5
const MAIN_MENU := [["ranked", "Ranked", "Ranked 1 vs 1, or 2 vs 2 with a friend. Ban and pick before every match; the server keeps your rating and the ranking."],
	["combat", "Battle", "Against the AI. Pick your Pokémon, the rival and the difficulty."],
	["training", "Training", "Still or active rival, no rush. R resets, T stops or frees the rival."],
	["moves", "Moves", "Pick each Pokémon's four moves and its ability, and see what each one does."],
	["options", "Options", "Controls, sound, screen and language."],
	["quit", "Quit", "Close the game."],
	["profile", "Profile", "Your trainer and your name. Online, your rival sees them."]]
## The profile's name: up to NAME_MAX of these (with the pad, each letter goes round them).
const NAME_MAX := 12
## The nickname asked for the first time: at least this many characters.
const NICK_MIN := 3
const NAME_CHARS := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -_."
const PROFILE_COLUMNS := 3
## The on-screen keyboard for the name (pad and mouse; the real keyboard types directly):
## four rows of ten keys and a row of four wide ones.
const NAME_KEYS := [["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"], ["A", "S", "D", "F", "G", "H", "J", "K", "L", "Ñ"],
	["Z", "X", "C", "V", "B", "N", "M", "-", "_", "."], ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
	["shift", "space", "del", "done"]]
## The main menu is a wall of tiles of different sizes (MenuDraw): where each arrow goes
## from each one ([up, down, left, right], -1 stays).
const MAIN_NAV := [[-1, -1, -1, 1], [6, 3, 0, 2], [6, 4, 1, -1], [1, -1, 0, 4], [2, 5, 3, -1], [4, -1, 3, -1], [-1, 2, 1, -1]]

var main: Node
var is_open := false
var screen := "title"
var cursor := 0
var choice := {"p1": "pikachu", "p2": "snorlax", "diff": "normal", "mode": "combat", "stage": "night"}
var online := false
var sel_phase := "p1"             # p1, p2 (the rival against the AI), setup (options and start)
var setup_cursor := 0
var me_ready := false
var rival_choice_id := ""
var rival_loadout := {}          # the online rival's moves and ability (sent with its choice)
var rival_trainer := ""          # and its trainer
var rival_ready := false
var message := ""                # notices (connection errors, disconnects), already translated
## The account screen (log in / create an account / add an email and password to an old
## account): typed on the keyboard, the mouse clicks its fields and buttons.
var acc_mode := "login"           # "login", "register" or "secure"
var acc_field := 0
var acc := {"name": "", "email": "", "password": "", "password2": ""}
var acc_msg := ""
var acc_busy := false
## The friendly-match screen (private rooms): create a room, or type a friend's code.
var room_focus := 0               # 0 create, 1 the code field
var room_input := ""
var room_msg := ""
var room_busy := false
## The replays screen: my latest matches, or the ones being played now.
var rp_tab := 0                   # 0 my replays, 1 live
var rp_cursor := 0
## The draft (ban and pick) of a draft match, as the server tells it.
var draft := {}
var draft_cursor := 0
var draft_my_ban := ""
var draft_at := 0.0               # when the last state came (the countdown runs from then)
var acc_gate := false              # the account screen is the start of the game: it cannot be skipped...
var acc_offline_ok := false       # ...unless the server cannot be reached
var lobby_avatar := ""            # the random Pokémon shown as me in the ranked lobby
var team_picks := {}              # a 2 vs 2's selection: what each other slot has chosen {slot: {name, species, ready}}
const ROOM_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const ACC_LIMITS := {"name": 16, "email": 120, "password": 128, "password2": 128}
var confirm := {}                # a yes/no question on top: {text, yes (Callable), on (0 no, 1 yes)}
var portraits := {}               # species -> Texture2D (grid icons)
var enter_t := 0.0               # time on this screen (entry animations)
var draw: MenuDraw
var _key := Vector2i.ZERO        # selected key of the on-screen keypad (column, row)
var _t := 0.0
var _vs_t := -1.0
var _vs := []                    # [mine, theirs] on the VS screen
var _renders := {}               # slot -> {vp, model, species}: live 3D renders on the menus
var _generating := false
# Moves screen: pokemon (list), slots (its 4 + ability), list (options for the slot)
var edit_phase := "pokemon"
var edit_sp := ""
var edit_slot := 0               # 0-3: moves, 4: ability
var edit_cursor := 0             # highlighted option in the list
var edit_top := 0                # first option shown (the list scrolls)
var details := false             # the details panel of the highlighted move
var _edit_return := "main"       # where B leaves the Moves screen to
var rival_name := ""             # the online rival's name
var rival_version := ""          # the online rival's game version ("" until it says)
# Profile screen: -1 is the name, 0.. the trainers' grid.
var profile_cursor := 0
var name_edit := false           # typing the name
var name_key := Vector2i.ZERO    # the on-screen keyboard's key (column 0-9, row 0-4)
var name_lower := false          # its letters in lowercase
var _clicked := false            # a left click on what the pointer is over: accepts, this frame
var _back_click := false         # a right click: back, this frame


func _ready() -> void:
	draw = MenuDraw.new()
	draw.m = self


## Only those with all their moves done (the rest are half finished).
func pokemon_list() -> Array:
	var list: Array = []
	for sp in Roster.POKEMON:
		var data: Dictionary = Roster.POKEMON[sp]
		var ready := true
		for move in data.moves:
			if not Moves.DATA.has(move) or not ResourceLoader.exists(Moves.DATA[move].script):
				ready = false
		if ready:
			list.append(sp)
	return list


# ---------------------------------------------------------------- open and close

func open_menu(en := "") -> void:
	is_open = true
	_t = 0.0
	_vs_t = -1.0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	main.camera.target = null
	if main.arena:
		main.arena.visible = false
		# Nothing to show behind the menus: the stage stops (crowd, clocks, the League's field).
		main.arena.process_mode = Node.PROCESS_MODE_DISABLED
	if en == "":
		en = "main" if screen != "title" else "title"
	if en == "title" and _needs_account():
		# The very first screen of the game: whoever has no account makes one (or logs in) before anything else.
		acc_gate = true
		acc_offline_ok = false
		account_open("register", tr("Make an account to play: it keeps your rating and your replays. F2: log in instead."))
	else:
		_go(en)
	if portraits.is_empty() and not _generating:
		_generate_portraits()


func close() -> void:
	is_open = false
	confirm = {}
	_free_renders()
	if main.arena:
		main.arena.visible = true
		main.arena.process_mode = Node.PROCESS_MODE_INHERIT


func _go(p: String) -> void:
	# Ranked needs an account: without one the account screen comes first (tests, which
	# have --ranked_account, make theirs by themselves).
	if p in ["room", "replays"] and main.ranked.server_down:
		p = "ranked"                      # (no server: only its error card is there)
	if p == "ranked" and not main.ranked.logged_in() and not main.ranked.auto_account() and not main.ranked.server_down:
		account_open("login")
		return
	screen = p
	main.music.play(p if p in ["selection", "vs", "moves"] else "menu")
	cursor = 0
	enter_t = 0.0
	details = false
	confirm = {}
	if p == "selection":
		me_ready = false
		sel_phase = "p1"
		cursor = maxi(pokemon_list().find(choice.p1), 0)
		if online:
			if rival_choice_id != "":
				choice.p2 = rival_choice_id
			_send_choice()
	elif p == "profile":
		name_edit = false
		profile_cursor = TrainerData.ids().find(main.options.trainer)
	elif p == "nick":
		# The first-time window: the name is being typed from the start.
		name_edit = true
		name_key = Vector2i.ZERO
		message = ""
	elif p == "moves":
		edit_phase = "pokemon"
		var list := pokemon_list()
		cursor = maxi(list.find(choice.p1), 0)
		edit_sp = list[cursor]
	elif p != "vs":
		_free_renders()
	if p == "ranked":
		if main.ranked.party.is_empty() or lobby_avatar == "":
			var avatars := pokemon_list()
			lobby_avatar = str(avatars[randi() % avatars.size()])
		main.ranked.open()


## Online: once connected, both go on to pick.
func online_connected() -> void:
	online = true
	rival_choice_id = ""
	rival_version = ""
	rival_ready = false
	message = ""
	if main.ranked.draft_match and main.net is ArenaClient:
		# A draft: ban and pick first; the usual selection (moves, ready) comes after.
		draft = {}
		draft_cursor = 0
		draft_my_ban = ""
		if not is_open:
			open_menu("draft")
		else:
			_go("draft")
		return
	if not is_open:
		open_menu("selection")
	else:
		_go("selection")


func disconnected(reason: String) -> void:
	online = false
	message = reason
	# A ranked match that ended with the rival leaving: the result is on the Ranked screen.
	open_menu("ranked" if main.ranked.consume_return() else "main")


# ---------------------------------------------------------------- input

func _pressed(a: String) -> bool:
	# When the menu opens, the press that opened it (B after an online battle) does
	# not count here: otherwise it would leave the selection right after entering.
	if a == "menu_back" and _back_click:
		return true
	return _t > 0.15 and Input.is_action_just_pressed(a)


func _accept() -> bool:
	return _clicked or _pressed("menu_accept") or _pressed("jump")


func _process(delta: float) -> void:
	_menu_frame(delta)
	_clicked = false
	_back_click = false


func _menu_frame(delta: float) -> void:
	if not is_open:
		return
	_t += delta
	enter_t += delta
	if draw:
		draw.step(delta)
	if _vs_t >= 0.0:
		_vs_t += delta
		if _vs_t > 2.2:
			_vs_t = -1.0
			var vs := _vs.duplicate()
			close()
			if main.net is ArenaClient:
				main.start_arena_battle()      # the server chose the stage and has both picks
			else:
				if not online:
					main.set_stage(choice.stage)
				main.start_battle(vs[0], vs[1], choice.diff, rival_loadout if online else {}, rival_trainer if online else "")
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return
	if not confirm.is_empty():
		_confirm_input()
		return
	match screen:
		"title":
			if _accept():
				_sound("ok")
				# The first time (no nickname yet) it asks for one; tests skip it unless --force_nick.
				var skip: bool = has_nickname() or (main._args.has("test") and not main._args.has("force_nick"))
				if skip:
					_enter_main()
				else:
					_go("nick")
		"nick":
			_name_keyboard()
		"main":
			_move_nav(MAIN_NAV)
			if _accept():
				_sound("ok")
				match MAIN_MENU[cursor][0]:
					"combat", "training":
						online = false
						choice.mode = MAIN_MENU[cursor][0]
						main.mode = choice.mode
						_go("selection")
					"ranked":
						message = ""
						_go("ranked")
					"moves":
						_edit_return = "main"
						_go("moves")
					"options":
						_go("options")
					"profile":
						_go("profile")
					"quit":
						get_tree().quit()
			elif _pressed("menu_back"):
				_sound("back")
				_go("title")
		"ranked":
			_ranked_input()
		"replays":
			_replays_input()
		"draft":
			_draft_input()
		"selection":
			_selection()
		"moves":
			_edit_moves()
		"options":
			main.options.menu_input(self)
		"profile":
			_profile_input()


## From the title (or the first nickname) to the main menu. Whoever has no account makes one (or logs in) right
## here, at the start of the game, not later when pressing Ranked. Without a server there is nothing to make
## it with: Esc plays without one. (Tests and the test accounts skip all of this.)
func _needs_account() -> bool:
	if main._args.has("force_gate"):
		return not main.ranked.logged_in()
	return not main.ranked.logged_in() and not main.ranked.auto_account() and not main._args.has("test")


func _enter_main() -> void:
	if _needs_account():
		acc_gate = true
		acc_offline_ok = false
		account_open("register", tr("Make an account to play: it keeps your rating and your replays. F2: log in instead."))
		return
	_go("main")


## Opens the account screen. "mode": login, register or secure (an old account gets an email
## and a password).
func account_open(mode: String, msg := "") -> void:
	acc_mode = mode
	acc_field = 0
	acc_msg = msg
	acc_busy = false
	acc.password = ""
	acc.password2 = ""
	if mode == "login":
		acc.name = main.ranked.last_name if acc.name == "" else acc.name
	if mode == "secure":
		acc.email = ""
	if not is_open:
		open_menu("account")
	else:
		_go("account")


## A draft state from the server: stage ban / pick / done, the bans and picks, whose turn, seconds left.
func on_draft(d: Dictionary) -> void:
	draft = d
	draft_at = Time.get_ticks_msec() / 1000.0
	if str(d.get("stage", "")) == "done" and screen == "draft":
		var c: ArenaClient = main.net
		var rival_slot: int = c.enemy_slots()[0]
		choice.p1 = str(d.picks[c.slot])
		choice.p2 = str(d.picks[rival_slot])
		_go("selection")
		choice.p1 = str(d.picks[c.slot])
		choice.p2 = str(d.picks[rival_slot])
		_to_setup()


func draft_left() -> float:
	return maxf(0.0, float(draft.get("left", 0.0)) - (Time.get_ticks_msec() / 1000.0 - draft_at))


## What the player may do now: "ban", "pick" or "" (waiting).
func draft_action() -> String:
	if draft.is_empty() or not main.net is ArenaClient:
		return ""
	var slot: int = main.net.slot
	match str(draft.get("stage", "")):
		"ban":
			return "ban" if draft_my_ban == "" and not bool(draft.ban_done[slot]) else ""
		"pick":
			return "pick" if int(draft.turn) == slot else ""
	return ""


func draft_blocked(sp: String) -> bool:
	if draft.is_empty():
		return false
	if str(draft.stage) == "pick" or str(draft.stage) == "done":
		return draft.bans.has(sp) or draft.picks.has(sp)
	return false


func _draft_input() -> void:
	var list := pokemon_list()
	var before := draft_cursor
	if _pressed("move_left"):
		draft_cursor = (draft_cursor + list.size() - 1) % list.size()
	elif _pressed("move_right"):
		draft_cursor = (draft_cursor + 1) % list.size()
	elif _pressed("move_up"):
		draft_cursor = (draft_cursor + list.size() - COLUMNS) % list.size()
	elif _pressed("move_down"):
		draft_cursor = (draft_cursor + COLUMNS) % list.size()
	if draft_cursor != before:
		_sound("move")
	if _accept():
		_draft_confirm(list[draft_cursor])
	elif _pressed("menu_back"):
		_sound("back")
		ask(tr("Leave the match? You will be disconnected."), func():
			main.close_net()
			online = false
			_go("ranked"))


func _draft_confirm(sp: String) -> void:
	var action := draft_action()
	if action == "ban":
		draft_my_ban = sp
		main.net.send_event({"t": "ban", "species": sp})
		_sound("ok")
	elif action == "pick" and not draft_blocked(sp):
		main.net.send_event({"t": "pick", "species": sp})
		_sound("ok")


func replays_open(tab: int) -> void:
	rp_tab = tab
	rp_cursor = 0
	main.ranked.load_replays(tab == 1)
	_go("replays")


func rp_rows() -> Array:
	return main.ranked.live_matches if rp_tab == 1 else main.ranked.replays


func _replays_input() -> void:
	if main.net is ReplayPlayer:
		if _pressed("menu_back"):
			_sound("back")
			main.close_net()
		return
	var rows := rp_rows()
	if _pressed("move_left") or _pressed("move_right"):
		_sound("move")
		replays_open(1 - rp_tab)
	elif _pressed("move_up") and not rows.is_empty():
		rp_cursor = (rp_cursor + rows.size() - 1) % rows.size()
		_sound("move")
	elif _pressed("move_down") and not rows.is_empty():
		rp_cursor = (rp_cursor + 1) % rows.size()
		_sound("move")
	elif _accept() and not rows.is_empty():
		_sound("ok")
		main.start_replay(int(rows[clampi(rp_cursor, 0, rows.size() - 1)].match_id), rp_tab == 1)
	elif _pressed("menu_back"):
		_sound("back")
		main.ranked.skip_auto = true
		_go("ranked")


func room_open() -> void:
	room_focus = 0
	room_input = ""
	room_msg = ""
	room_busy = false
	_go("room")


func _room_key(k: InputEventKey) -> void:
	if room_busy:
		return
	match k.keycode:
		KEY_ESCAPE:
			_sound("back")
			main.ranked.skip_auto = true
			_go("ranked")
		KEY_TAB, KEY_LEFT, KEY_RIGHT:
			room_focus = 1 - room_focus
			_sound("move")
		KEY_ENTER, KEY_KP_ENTER:
			if room_focus == 0:
				_room_create()
			else:
				_room_join()
		KEY_BACKSPACE:
			room_input = room_input.substr(0, room_input.length() - 1)
			room_focus = 1
		KEY_V:
			if k.ctrl_pressed:
				room_focus = 1
				for ch in DisplayServer.clipboard_get().strip_edges().to_upper():
					if ROOM_CHARS.contains(ch) and room_input.length() < 5:
						room_input += ch
			elif k.unicode > 0:
				_room_type(k)
		_:
			if k.unicode > 0:
				_room_type(k)


func _room_type(k: InputEventKey) -> void:
	var ch := char(k.unicode).to_upper()
	if ROOM_CHARS.contains(ch) and room_input.length() < 5:
		room_input += ch
		room_focus = 1
		room_msg = ""


func _room_create() -> void:
	_sound("ok")
	main.ranked.skip_auto = true
	main.ranked.party_create()
	_go("ranked")


func _room_join() -> void:
	if room_input.length() != 5:
		room_msg = tr("A room code has 5 characters.")
		return
	room_busy = true
	room_msg = ""
	_sound("ok")
	main.ranked.party_join(room_input, _room_done)


func _room_done(ok: bool, err: String) -> void:
	room_busy = false
	if ok:
		main.ranked.skip_auto = true
		_go("ranked")
	else:
		room_msg = err


func acc_fields() -> Array:
	match acc_mode:
		"register":
			return ["name", "email", "password", "password2"]
		"secure":
			return ["email", "password", "password2"]
	return ["name", "password"]


func _acc_char_ok(key: String, ch: String) -> bool:
	var code := ch.unicode_at(0)
	match key:
		"name":
			# A name when registering; at login it can be the email too.
			return (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or ch in ["_", "-"] \
				or (acc_mode == "login" and (ch in ["@", "."] or code == 43))
		"email":
			return code > 32 and code < 127
	return code >= 32 and code != 127


func _account_key(k: InputEventKey) -> void:
	if acc_busy:
		return
	var fields := acc_fields()
	var key: String = fields[acc_field]
	match k.keycode:
		KEY_ESCAPE:
			if acc_gate and not acc_offline_ok:
				return
			_sound("back")
			acc_gate = false
			_go("ranked" if acc_mode == "secure" else "main")
		KEY_TAB:
			acc_field = (acc_field + (fields.size() - 1 if k.shift_pressed else 1)) % fields.size()
			_sound("move")
		KEY_UP:
			acc_field = (acc_field + fields.size() - 1) % fields.size()
			_sound("move")
		KEY_DOWN:
			acc_field = (acc_field + 1) % fields.size()
			_sound("move")
		KEY_ENTER, KEY_KP_ENTER:
			if acc_field < fields.size() - 1:
				acc_field += 1
				_sound("move")
			else:
				_account_submit()
		KEY_BACKSPACE:
			acc[key] = str(acc[key]).substr(0, str(acc[key]).length() - 1)
		KEY_F2:
			if acc_mode != "secure":
				account_switch("register" if acc_mode == "login" else "login")
		KEY_V:
			if k.ctrl_pressed:
				for ch in DisplayServer.clipboard_get().strip_edges():
					if _acc_char_ok(key, ch) and str(acc[key]).length() < int(ACC_LIMITS[key]):
						acc[key] = str(acc[key]) + ch
			elif k.unicode > 0:
				_account_type(key, k)
		_:
			if k.unicode > 0:
				_account_type(key, k)


func _account_type(key: String, k: InputEventKey) -> void:
	var ch := char(k.unicode)
	if _acc_char_ok(key, ch) and str(acc[key]).length() < int(ACC_LIMITS[key]):
		acc[key] = str(acc[key]) + ch
		acc_msg = ""


func account_switch(mode: String) -> void:
	if acc_busy or mode == acc_mode:
		return
	acc_mode = mode
	acc_field = 0
	acc_msg = ""
	# Creating an account starts from an empty name; logging in offers the last one used.
	if mode == "register":
		acc.name = ""
	elif mode == "login" and acc.name == "":
		acc.name = main.ranked.last_name
	_sound("move")


func _account_submit() -> void:
	if acc_busy:
		return
	var name := str(acc.name).strip_edges()
	var email := str(acc.email).strip_edges()
	var pw := str(acc.password)
	if acc_mode in ["login", "register"] and name == "":
		acc_msg = tr("Type your account name.") if acc_mode == "register" else tr("Type your account name or email.")
		acc_field = 0
		return
	if acc_mode == "register" and not _acc_name_ok(name):
		acc_msg = tr("The name needs 3 to 16 letters, digits, _ or -.")
		acc_field = 0
		return
	if acc_mode in ["register", "secure"] and not _acc_email_ok(email):
		acc_msg = tr("That does not look like an email address.")
		acc_field = acc_fields().find("email")
		return
	if acc_mode in ["register", "secure"] and pw.length() < 6:
		acc_msg = tr("The password needs at least 6 characters.")
		acc_field = acc_fields().find("password")
		return
	if acc_mode in ["register", "secure"] and pw != str(acc.password2):
		acc_msg = tr("The two passwords are not the same.")
		acc_field = acc_fields().find("password2")
		return
	if acc_mode == "login" and pw == "":
		acc_msg = tr("Type your password.")
		acc_field = 1
		return
	acc_busy = true
	acc_msg = ""
	_sound("ok")
	main.ranked.account_submit(acc_mode, {"name": name, "email": email, "password": pw}, _account_done)


func _account_done(ok: bool, err: String) -> void:
	acc_busy = false
	if not ok:
		acc_msg = err
		if acc_gate and err == tr("Could not reach the ranking server."):
			acc_offline_ok = true
			acc_msg = err + " " + tr("Esc: play without an account for now.")
		return
	acc.password = ""
	acc.password2 = ""
	acc_msg = ""
	main.ranked.skip_auto = false
	if acc_gate:
		acc_gate = false
		# The account's name is the player's name: no second window asking for a nickname.
		main.options.player_name = str(main.ranked.me.get("name", main.options.player_name)).substr(0, NAME_MAX)
		main.options.save()
		_go("main")
		return
	_go("ranked")


func _acc_name_ok(n: String) -> bool:
	var rx := RegEx.new()
	rx.compile("^[A-Za-z0-9_\\-]{3,16}$")
	return rx.search(n) != null


func _acc_email_ok(e: String) -> bool:
	var rx := RegEx.new()
	rx.compile("^[^@\\s]{1,64}@[^@\\s]{1,100}\\.[A-Za-z]{2,24}$")
	return rx.search(e) != null and e.length() <= 120


func _move_nav(nav: Array) -> void:
	var to := -1
	for i in 4:
		if _pressed(["move_up", "move_down", "move_left", "move_right"][i]):
			to = nav[cursor][i]
	if to >= 0 and to != cursor:
		cursor = to
		_sound("move")


## Menu sounds: soft and short (move, ok, back).
func _sound(kind := "move") -> void:
	main.audio.ui(kind)


## A yes/no question on top of the screen (leaving an online room...). B or "No" closes it.
func ask(text: String, yes: Callable) -> void:
	confirm = {"text": text, "yes": yes, "on": 0, "t": 0.0}


func _confirm_input() -> void:
	confirm.t += get_process_delta_time()
	if _pressed("move_left") or _pressed("move_right") or _pressed("move_up") or _pressed("move_down"):
		confirm.on = 1 - int(confirm.on)
		_sound("move")
	if _accept():
		var yes: Callable = confirm.yes
		var take: bool = confirm.on == 1
		confirm = {}
		if take:
			_sound("ok")
			yes.call()
		else:
			_sound("back")
	elif _pressed("menu_back"):
		_sound("back")
		confirm = {}


# ---------------------------------------------------------------- ranked

## The Ranked screen: it looks for a rival by itself when it opens. B cancels the search
## and goes back; if nothing is going on (an error, a finished match), A looks again.
func _ranked_input() -> void:
	var r: Ranked = main.ranked
	if r.server_down:
		if _pressed("menu_back"):
			_sound("back")
			_go("main")
		return
	match r.state:
		"idle":
			if _pressed("move_left"):
				_set_mode(false)
			elif _pressed("move_right"):
				_set_mode(true)
			if _accept() and r.can_search() and not r.in_party_as_member():
				_sound("ok")
				r.search()
			elif _accept() and not r.loading:
				_sound("ok")
				r.open()                    # no account yet / server unreachable: try again
			elif _pressed("menu_back"):
				_sound("back")
				r.notice = ""
				_go("main")
		"searching":
			if _pressed("menu_back"):
				_sound("back")
				r.cancel()
				r.notice = ""
				_go("main")
		"connecting":
			if _pressed("menu_back"):
				_sound("back")
				r.cancel()


## Options, "Log out" (with a question first): the account is forgotten on this computer.
func _ask_logout() -> void:
	ask(tr("Log out of this account?"), _logout)


## Logs out of the account (the ranking client forgets its token) and shows the login screen.
func _logout() -> void:
	_sound("back")
	main.ranked.logout()
	acc.name = main.ranked.last_name
	account_open("login")


## Whether the online room open now is a ranked match's (its selection shows both players).
func ranked_room() -> bool:
	return online and main.ranked.in_ranked_room()


func _unhandled_input(ev: InputEvent) -> void:
	# (The tests drive the menus with actions: the real pointer resting over their window
	# must not move the cursor.)
	if is_open and (ev is InputEventMouseMotion or ev is InputEventMouseButton) and confirm.is_empty() and _vs_t < 0.0 			and not (ev is InputEventMouseMotion and main._args.has("test")):
		_mouse(ev)
	if is_open and screen == "options":
		main.options.menu_event(self, ev)
		return
	if is_open and screen == "room" and ev is InputEventKey and ev.pressed:
		_room_key(ev)
		get_viewport().set_input_as_handled()
		return
	if is_open and screen == "ranked" and ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_F4 \
			and main.ranked.state == "idle" and main.ranked.can_search():
		room_open()
		return
	if is_open and screen == "ranked" and ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_F5 \
			and main.ranked.state == "idle" and not main.ranked.party.is_empty():
		main.ranked.party_leave()
		_sound("back")
		return
	if is_open and screen == "ranked" and ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode in [KEY_F6, KEY_F7] \
			and main.ranked.state == "idle" and main.ranked.can_search():
		replays_open(0 if ev.keycode == KEY_F6 else 1)
		return
	if is_open and screen == "account" and ev is InputEventKey and ev.pressed:
		_account_key(ev)
		get_viewport().set_input_as_handled()
		return
	if is_open and screen == "ranked" and ev is InputEventKey and ev.pressed and not ev.echo and main.ranked.state in ["idle", "searching"] \
			and main.ranked.logged_in() and not main.ranked.loading:
		if ev.keycode == KEY_F3 and not bool(main.ranked.me.get("has_password", true)):
			account_open("secure")
			return
	if is_open and screen in ["profile", "nick"] and name_edit and ev is InputEventKey and ev.pressed:
		_type_name(ev)
		get_viewport().set_input_as_handled()
		return


# ---------------------------------------------------------------- selection

## The options under the picks, in order. Online the guest cannot change the stage.
func setup_items() -> Array:
	if online:
		return ["stage", "build", "ready"]
	if choice.mode == "training":
		return ["stage", "build", "fight"]
	return ["stage", "diff", "build", "fight"]


func _selection() -> void:
	var list := pokemon_list()
	var n := list.size()
	var host: bool = online and main.net != null and main.net.host
	# Online, the host can also change the stage from the grid (RB / E).
	if host and sel_phase != "setup" and _pressed("mov2"):
		_cycle_stage(1)
	if sel_phase == "setup":
		_setup_input(list)
		return
	var to := cursor
	if _pressed("move_right"):
		to = mini(cursor + 1, n - 1)
	elif _pressed("move_left"):
		to = maxi(cursor - 1, 0)
	elif _pressed("move_down"):
		to = mini(cursor + COLUMNS, n - 1)
	elif _pressed("move_up"):
		to = maxi(cursor - COLUMNS, 0)
	if to != cursor:
		_pick_on_wall(to)
	if _accept():
		_sound("ok")
		choice[sel_phase] = list[cursor]
		if sel_phase == "p1" and not online:
			sel_phase = "p2"
			cursor = maxi(list.find(choice.p2), 0)
		else:
			_to_setup()
	elif _pressed("menu_back"):
		_sound("back")
		if online:
			ask(tr("Leave the room? You will be disconnected."), func():
				main.close_net()
				online = false
				_go("ranked"))
		elif sel_phase == "p2":
			sel_phase = "p1"
			cursor = maxi(list.find(choice.p1), 0)
		else:
			_go("main")


func _to_setup() -> void:
	sel_phase = "setup"
	var items := setup_items()
	setup_cursor = items.size() - 1          # straight on Fight / Ready
	if online:
		_send_choice()


func _setup_input(list: Array) -> void:
	var items := setup_items()
	var item: String = items[setup_cursor]
	var host: bool = not online or (main.net != null and main.net.host)
	if online and me_ready:
		if _pressed("menu_back"):
			_sound("back")
			me_ready = false
			_send_choice()
		return
	# The options sit side by side: left and right go through them, up and down change them.
	if _pressed("move_left"):
		setup_cursor = (setup_cursor + items.size() - 1) % items.size()
		_sound("move")
	elif _pressed("move_right"):
		setup_cursor = (setup_cursor + 1) % items.size()
		_sound("move")
	elif _pressed("move_up") or _pressed("move_down"):
		var step := 1 if _pressed("move_up") else -1
		match item:
			"stage":
				if host:
					_cycle_stage(step)
			"diff":
				var i := DIFFICULTIES.find(choice.diff)
				choice.diff = DIFFICULTIES[(i + step + 3) % 3]
				_sound("move")
	if _accept():
		match item:
			"stage":
				if host:
					_cycle_stage(1)
			"diff":
				var i := DIFFICULTIES.find(choice.diff)
				choice.diff = DIFFICULTIES[(i + 1) % 3]
				_sound("move")
			"build":
				_sound("ok")
				_edit_return = "selection"
				var keep := sel_phase
				_go("moves")
				edit_sp = choice.p1
				cursor = maxi(list.find(edit_sp), 0)
				edit_slot = 0
				edit_phase = "slots"
				sel_phase = keep
			"fight":
				_sound("ok")
				_start_vs(choice.p1, choice.p2)
			"ready":
				_sound("ok")
				me_ready = true
				_send_choice()
				main.check_start()
	elif _pressed("menu_back"):
		_sound("back")
		sel_phase = "p1" if online else "p2"
		cursor = maxi(list.find(choice[sel_phase]), 0)


# ---------------------------------------------------------------- profile

## Profile: your name on top, your trainers below. Moving over the trainers only points
## at them; A (or a click) makes the one pointed at yours (saved). A on the name starts
## editing it: the real keyboard types straight into it (Enter ends), and an on-screen
## keyboard comes up for the pad and the mouse (Done ends; B deletes a letter).
func _profile_input() -> void:
	var list := TrainerData.ids()
	if name_edit:
		_name_keyboard()
		return
	var before := profile_cursor
	if profile_cursor < 0:
		if _pressed("move_down"):
			profile_cursor = 0
	else:
		if _pressed("move_right"):
			profile_cursor = mini(profile_cursor + 1, list.size() - 1)
		elif _pressed("move_left"):
			profile_cursor = maxi(profile_cursor - 1, 0)
		elif _pressed("move_down"):
			profile_cursor = mini(profile_cursor + PROFILE_COLUMNS, list.size() - 1)
		elif _pressed("move_up"):
			profile_cursor = profile_cursor - PROFILE_COLUMNS if profile_cursor >= PROFILE_COLUMNS else -1
	if profile_cursor != before:
		_sound("move")
	if _accept():
		_sound("ok")
		if profile_cursor < 0:
			name_edit = true
			name_key = Vector2i.ZERO
		else:
			main.options.trainer = list[profile_cursor]
			main.options.save()
	elif _pressed("menu_back"):
		_sound("back")
		_go("main")
		cursor = 6


## The on-screen keyboard with the pad (the real keyboard's keys are typing then, so they
## do not move it; the mouse presses its keys in _mouse).
func _name_keyboard() -> void:
	if Controls.last_device == "keyboard":
		if _back_click:
			_end_name()
		return
	var before := name_key
	if _pressed("move_right"):
		name_key.x = (name_key.x + (3 if name_key.y == 4 else 1)) % 10
	elif _pressed("move_left"):
		name_key.x = (name_key.x + 10 - (3 if name_key.y == 4 else 1)) % 10
	elif _pressed("move_down"):
		name_key.y = (name_key.y + 1) % 5
	elif _pressed("move_up"):
		name_key.y = (name_key.y + 4) % 5
	if name_key != before:
		_sound("move")
	if _accept():
		_press_name_key()
	elif _pressed("menu_back"):
		var n: String = main.options.player_name
		if n == "":
			_end_name()
		else:
			main.options.player_name = n.substr(0, n.length() - 1)
			_sound("back")


## The key under the on-screen keyboard's cursor (the last row's four keys are 2.5 columns
## wide each).
func name_key_id() -> String:
	if name_key.y == 4:
		return NAME_KEYS[4][mini(int(name_key.x / 2.5), 3)]
	return NAME_KEYS[name_key.y][name_key.x]


func _press_name_key() -> void:
	var k := name_key_id()
	var n: String = main.options.player_name
	match k:
		"shift":
			name_lower = not name_lower
		"space":
			if n.length() < NAME_MAX and n != "":
				n += " "
		"del":
			n = n.substr(0, n.length() - 1)
		"done":
			_end_name()
			return
		_:
			if n.length() < NAME_MAX:
				n += k.to_lower() if name_lower else k
	main.options.player_name = n
	_sound("ok" if k == "done" else "move")


func _type_name(k: InputEventKey) -> void:
	var n: String = main.options.player_name
	if k.keycode == KEY_BACKSPACE:
		n = n.substr(0, n.length() - 1)
	elif k.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE]:
		_end_name()
		return
	elif k.unicode > 0 and n.length() < NAME_MAX and (NAME_CHARS.contains(char(k.unicode)) or "ÁÉÍÓÚÑÜáéíóúñü".contains(char(k.unicode))):
		n += char(k.unicode)
	main.options.player_name = n


func _end_name() -> void:
	main.options.player_name = main.options.player_name.strip_edges()
	if screen == "nick":
		# The first-time window needs a real name (the ranking's accounts are 3+ characters).
		if main.options.player_name.length() < NICK_MIN:
			message = tr("Your nickname needs at least %d characters.") % NICK_MIN
			_sound("back")
			return
		name_edit = false
		main.options.save()
		_sound("ok")
		_enter_main()
		return
	name_edit = false
	main.options.save()
	_sound("ok")


## Whether the player has already chosen a nickname.
func has_nickname() -> bool:
	return main.options.player_name.strip_edges().length() >= NICK_MIN


func _cycle_stage(step: int) -> void:
	var e := STAGES.find(choice.stage)
	choice.stage = STAGES[(e + step + STAGES.size()) % STAGES.size()]
	_sound("move")
	if online and main.net and main.net.host:
		main.net.send_event({"t": "stage", "id": choice.stage})


# ---------------------------------------------------------------- Moves screen

const EDIT_ROWS := 8             # options shown at once in the list


## Moves screen: pick a Pokémon in the list, then one of its four moves (or its ability),
## then what goes there. Every change is saved at once (Loadout). Y / X shows or hides
## the details of the highlighted move; X / R restores the defaults (see ask_restore).
func _edit_moves() -> void:
	var list := pokemon_list()
	var n := list.size()
	if _pressed("menu_info") and edit_phase != "pokemon":
		details = not details
		_sound("move")
	if _pressed("menu_extra"):
		ask_restore()
		return
	match edit_phase:
		"pokemon":
			var before := cursor
			cursor = _cycle(cursor, n)
			if cursor != before:
				edit_sp = list[cursor]
				main.audio.cry(edit_sp, main.camera.global_position, 1.0, -22.0)
			if _accept():
				_sound("ok")
				edit_sp = list[cursor]
				edit_slot = 0
				edit_phase = "slots"
			elif _pressed("menu_back"):
				_sound("back")
				_leave_moves()
		"slots":
			edit_slot = _cycle(edit_slot, 5)
			if _accept():
				_sound("ok")
				var options := edit_options()
				var lo := Loadout.saved(edit_sp)
				edit_cursor = maxi(options.find(lo.moves[edit_slot] if edit_slot < 4 else lo.ability), 0)
				edit_top = clampi(edit_cursor - EDIT_ROWS / 2, 0, maxi(options.size() - EDIT_ROWS, 0))
				edit_phase = "list"
			elif _pressed("menu_back"):
				_sound("back")
				if _edit_return == "selection":
					_leave_moves()
				else:
					edit_phase = "pokemon"
		"list":
			var options := edit_options()
			edit_cursor = _cycle(edit_cursor, options.size())
			edit_top = clampi(edit_top, edit_cursor - EDIT_ROWS + 1, edit_cursor)
			if _accept():
				_sound("ok")
				var lo := Loadout.saved(edit_sp)
				var pick: String = options[edit_cursor]
				if edit_slot < 4:
					# Already in another slot: they swap places.
					var other: int = lo.moves.find(pick)
					if other >= 0:
						lo.moves[other] = lo.moves[edit_slot]
					lo.moves[edit_slot] = pick
				else:
					lo.ability = pick
				Loadout.store(edit_sp, lo)
				edit_phase = "slots"
			elif _pressed("menu_back"):
				_sound("back")
				edit_phase = "slots"


## Restores the default moves and ability, after asking: every Pokémon's from the list of
## Pokémon, the one being edited from its slots or a slot's options.
func ask_restore() -> void:
	if restore_all():
		if pokemon_list().all(Loadout.is_default):
			_sound("back")
			return
		ask(tr("Restore every Pokémon's default moves and abilities?"), func(): Loadout.restore())
	else:
		if Loadout.is_default(edit_sp):
			_sound("back")
			return
		var sp := edit_sp
		ask(tr("Restore %s's default moves and ability?") % tr(Roster.POKEMON[sp].display_name), func():
			Loadout.restore(sp)
			edit_phase = "slots")


func restore_all() -> bool:
	return edit_phase == "pokemon"


func _leave_moves() -> void:
	if _edit_return == "selection":
		var keep := choice.duplicate()
		screen = "selection"
		enter_t = 0.0
		details = false
		choice = keep
		sel_phase = "setup"
		setup_cursor = setup_items().find("build")
		cursor = maxi(pokemon_list().find(choice.p1), 0)
		if online:
			_send_choice()
	else:
		_go("main")


## Up and down through n rows, wrapping around.
func _cycle(i: int, n: int) -> int:
	if n <= 0:
		return 0
	if _pressed("move_up"):
		_sound("move")
		return (i + n - 1) % n
	if _pressed("move_down"):
		_sound("move")
		return (i + 1) % n
	return i


## What can go in the slot being edited: move ids, or ability ids for slot 4.
func edit_options() -> Array:
	if edit_slot < 4:
		return Loadout.moves_for(edit_sp)
	return Loadout.abilities_for(edit_sp).map(func(a): return a.id)


## The move whose details are shown: the highlighted option, or the highlighted slot's.
func shown_move() -> String:
	if edit_phase == "list" and edit_slot < 4:
		var options := edit_options()
		return options[edit_cursor] if not options.is_empty() else ""
	if edit_phase == "slots" and edit_slot < 4:
		return Loadout.saved(edit_sp).moves[edit_slot]
	return ""


# ---------------------------------------------------------------- online

func _send_choice() -> void:
	if main.net:
		var d := {"t": "choice", "species": choice.p1, "ready": me_ready, "loadout": main.my_loadout(choice.p1), "trainer": main.options.trainer, "name": main.online_name(),
			"ver": Menu.version()}
		if main.net.host:
			d.stage = choice.stage            # so the rival sees the stage from the start
		main.net.send_event(d)


## The online rival changes Pokémon or gets ready.
## The game's version (project settings), sent online so both can tell they match.
static func version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", ""))


## Online: whether the rival plays another version (then the battle does not start).
func version_mismatch() -> bool:
	return rival_version != "" and rival_version != Menu.version()


## The lobby's mode: a ranked 1 vs 1 (alone in the lobby) or a ranked 2 vs 2 (a friend can join). Every ranked
## match has a draft, so that is not a choice.
func _set_mode(team: bool) -> void:
	var r: Ranked = main.ranked
	if r.state != "idle" or r.team_pref == team or r.in_party_as_member():
		return
	r.team_pref = team
	if not team:
		r.party_leave()           # a 1 vs 1 lobby is only you
	_sound("move")


## A 2 vs 2's selection: what another player (by the server's slot) has picked.
func team_choice(slot: int, d: Dictionary) -> void:
	team_picks[slot] = {"name": str(d.get("name", "")).substr(0, NAME_MAX), "species": str(d.get("species", "")),
		"ready": bool(d.get("ready", false))}


func rival_choice(sp: String, ready: bool, loadout := {}, trainer := "", rival := "", ver := "") -> void:
	if not Roster.POKEMON.has(sp):
		return
	rival_version = ver if ver != "" else "?"
	rival_name = rival.substr(0, NAME_MAX)
	rival_trainer = TrainerData.valid(trainer) if trainer != "" else ""
	rival_choice_id = sp
	rival_loadout = Loadout.valid(sp, loadout)
	rival_ready = ready
	if is_open and screen == "selection":
		choice.p2 = sp


func _start_vs(mine: String, theirs: String) -> void:
	_vs = [mine, theirs]
	_vs_t = 0.0
	screen = "vs"
	enter_t = 0.0
	main.portraits(mine, theirs)
	main.audio.cry(mine, main.camera.global_position, 1.0, -12.0)


func vs_pair() -> Array:
	return _vs


func vs_time() -> float:
	return _vs_t


## From main, online: both are ready.
func show_vs(mine: String, theirs: String) -> void:
	if not is_open:
		open_menu("selection")
	_start_vs(mine, theirs)


# ---------------------------------------------------------------- 3D renders

## A live render of a Pokémon (animated, turning a little) for a slot of the screen.
func render(slot: String, sp: String, px: Vector2i, turn := 0.45) -> Texture2D:
	var r: Dictionary = _renders.get(slot, {})
	if r.is_empty():
		var vp := SubViewport.new()
		vp.own_world_3d = true
		vp.transparent_bg = true
		vp.msaa_3d = Viewport.MSAA_4X
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(vp)
		r = {"vp": vp, "model": null, "species": "", "turn": turn}
		_renders[slot] = r
	var vp: SubViewport = r.vp
	if vp.size != px:
		vp.size = px
	if sp != r.species:
		r.species = sp
		for ch in vp.get_children():
			ch.queue_free()
		var data := _setup_portrait(vp, sp, turn)
		r.model = data.model
		_frame_portrait(data, true, float(px.x) / maxf(px.y, 1.0))
	if r.model:
		r.model.rotation.y = PI + r.turn + sin(_t * 0.6) * 0.2
	return vp.get_texture()


func _free_renders() -> void:
	for slot in _renders:
		_renders[slot].vp.queue_free()
	_renders.clear()


# ---------------------------------------------------------------- portraits

## Grid icons: each Pokémon rendered once to a texture.
func _generate_portraits() -> void:
	_generating = true
	for sp in pokemon_list():
		var vp := SubViewport.new()
		vp.own_world_3d = true
		vp.transparent_bg = true
		vp.size = Vector2i(128, 128)
		vp.msaa_3d = Viewport.MSAA_4X
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(vp)
		var data := _setup_portrait(vp, sp, 0.5)
		# Wait for the animation to place the skeleton: before that, the locators are in
		# the rest pose and the framing ends up on the belly.
		for i in 18:
			await get_tree().process_frame
		_frame_portrait(data)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		if DisplayServer.get_name() != "headless":
			var img := vp.get_texture().get_image()
			portraits[sp] = ImageTexture.create_from_image(img)
		vp.queue_free()
	_generating = false


func _setup_portrait(vp: SubViewport, sp: String, turn: float) -> Dictionary:
	var m := PokeModel.new()
	m.setup(sp)
	var box: AABB = m._res.mesh.get_aabb()
	m.scale = Vector3.ONE * Roster.POKEMON[sp].height / maxf(box.size.y, 0.05)
	m.rotation.y = PI + turn
	vp.add_child(m)
	m.play("battle_idle" if m.has_anim("battle_idle") else "ground_idle", 0.0)
	var cam := Camera3D.new()
	cam.fov = 30.0
	# With physics interpolation the camera would only move on the next physics step,
	# and the picture would be taken from inside the model.
	cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	m.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	vp.add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.7, 0.5, 0.0)
	sun.light_energy = 1.25
	vp.add_child(sun)
	var amb := WorldEnvironment.new()
	amb.environment = Environment.new()
	amb.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	amb.environment.ambient_light_color = Color(0.85, 0.87, 0.95)
	amb.environment.ambient_light_energy = 0.75
	amb.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	vp.add_child(amb)
	return {"model": m, "cam": cam, "height": Roster.POKEMON[sp].height}


func _frame_portrait(r: Dictionary, body := false, aspect := 1.0) -> void:
	var m: PokeModel = r.model
	if body:
		# The whole body, wings and tails included: far enough for its height and for its
		# width (seen from any side as it turns) in a frame of this aspect.
		var box: AABB = m._res.mesh.get_aabb()
		var k: float = m.scale.x
		var half_w: float = maxf(box.size.x, box.size.z) * 0.5 * k
		var half_h: float = r.height * 0.5
		var t := tan(deg_to_rad(15.0))
		var dist: float = maxf(half_h / t, half_w / (t * aspect)) * 1.06
		var center := Vector3(0, half_h, 0)
		r.cam.position = center + Vector3(0, r.height * 0.1, dist)
		r.cam.look_at(center)
		return
	var points: Array = []
	for bone in ["locator_face", "locator_head", "head"]:
		if m.skel.find_bone(bone) >= 0:
			points.append(m.bone_world(bone))
	var face := Vector3(0, r.height * 0.75, 0)
	if points.size() >= 2:
		face = (points[0] + points[1]) * 0.5
	elif points.size() == 1:
		face = points[0]
	var box_height: float = clampf(r.height * 0.6, 0.6, 1.4)
	var dist := box_height * 0.5 / tan(deg_to_rad(15.0))
	var looks := face - Vector3(0, box_height * 0.08, 0)
	r.cam.position = looks + Vector3(0, box_height * 0.1, dist)
	r.cam.look_at(looks)


# ---------------------------------------------------------------- drawing

func draw_ui(h: Hud) -> void:
	draw.draw(h)


# ---------------------------------------------------------------- mouse

## The mouse works everywhere the keys do: over something (MenuDraw's zones) it moves the
## cursor there, a left click accepts it, a right click goes back. Keys on the on-screen
## keyboards are pressed straight away.
func _mouse(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
		_back_click = true
		return
	# The wheel scrolls like the arrows: up and down (lists, options, the setup tab under
	# the pointer), left and right along the selection's row of Pokémon.
	if ev is InputEventMouseButton and ev.pressed and ev.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var up: bool = ev.button_index == MOUSE_BUTTON_WHEEL_UP
		var along := screen == "selection" and sel_phase != "setup"
		_tap(("move_left" if up else "move_right") if along else ("move_up" if up else "move_down"))
		return
	if draw == null:
		return
	var z: Dictionary = draw.zone_at(ev.position)
	if z.is_empty():
		return
	# A question on top: only its answers count.
	if not confirm.is_empty() and z.kind != "confirm":
		return
	_hover(z)
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		match z.kind:
			"nkey":
				_press_name_key()
			"accfield":
				if not acc_busy:
					acc_field = z.i
					_sound("move")
			"acctab":
				account_switch("register" if z.i == 1 else "login")
			"accgo":
				_account_submit()
			"logout":
				_ask_logout()
			"friend":
				room_open()
			"modetab":
				_set_mode(z.i == 1)
			"leave_lobby":
				main.ranked.party_leave()
				_sound("back")
			"dpick":
				var dl := pokemon_list()
				if z.i < dl.size():
					draft_cursor = z.i
					_draft_confirm(dl[z.i])
			"replays":
				replays_open(z.i)
			"rprow":
				if main.net is not ReplayPlayer and z.i < rp_rows().size():
					rp_cursor = z.i
					_sound("ok")
					main.start_replay(int(rp_rows()[z.i].match_id), rp_tab == 1)
			"roomcreate":
				if not room_busy:
					room_focus = 0
					_room_create()
			"roomcode":
				room_focus = 1
			"roomgo":
				_room_join()
			"secure":
				account_open("secure")
			"confirm":
				_clicked = z.i >= 0
			"restore":
				ask_restore()
			"mvp":
				_click_moves_pokemon(z.i)
			"slot":
				# From the list of Pokémon, straight to that slot of the highlighted one.
				if edit_phase == "pokemon":
					_sound("ok")
					edit_sp = pokemon_list()[cursor]
					edit_slot = z.i
					edit_phase = "slots"
				else:
					_clicked = edit_phase == "slots"
			"opt":
				_clicked = edit_phase == "list"
			_:
				_clicked = true


## A click on a Pokémon of the Moves screen: picks it, or from its slots or options
## changes to it (not when it came from the selection, which is for one Pokémon).
func _click_moves_pokemon(i: int) -> void:
	if edit_phase == "pokemon":
		_clicked = true
	elif _edit_return != "selection" and pokemon_list()[i] != edit_sp:
		_sound("ok")
		cursor = i
		edit_sp = pokemon_list()[i]
		edit_slot = 0
		edit_phase = "slots"
		details = false
		main.audio.cry(edit_sp, main.camera.global_position, 1.0, -22.0)


## Presses an action for one frame, as if a key had been tapped.
func _tap(action: String) -> void:
	Input.action_press(action)
	await get_tree().process_frame
	await get_tree().process_frame
	Input.action_release(action)


func _hover(z: Dictionary) -> void:
	var before := [cursor, profile_cursor, setup_cursor, _key, name_key, edit_slot, edit_cursor, confirm.get("on")]
	match z.kind:
		"confirm":
			if z.i >= 0:
				confirm.on = z.i
		"mvp":
			if screen == "moves" and edit_phase == "pokemon" and z.i != cursor:
				cursor = z.i
				edit_sp = pokemon_list()[cursor]
				main.audio.cry(edit_sp, main.camera.global_position, 1.0, -22.0)
		"slot":
			if edit_phase == "slots":
				edit_slot = z.i
		"opt":
			if edit_phase == "list":
				edit_cursor = z.i
		"main":
			if screen == z.kind:
				cursor = z.i
		"pf":
			if not name_edit:
				profile_cursor = z.i
		"wall":
			if screen == "selection" and sel_phase != "setup" and z.i != cursor:
				_pick_on_wall(z.i)
				return
		"tab":
			if screen == "selection" and sel_phase == "setup" and not (online and me_ready):
				setup_cursor = z.i
		"nkey":
			name_key = Vector2i(z.i % 10, z.i / 10)
	if [cursor, profile_cursor, setup_cursor, _key, name_key, edit_slot, edit_cursor, confirm.get("on")] != before:
		_sound("move")


## The selection's cursor onto Pokémon "i" (keys and mouse alike).
func _pick_on_wall(i: int) -> void:
	var list := pokemon_list()
	cursor = clampi(i, 0, list.size() - 1)
	_sound("move")
	choice[sel_phase] = list[cursor]
	main.audio.cry(choice[sel_phase], main.camera.global_position, 1.0, -22.0)
	if online:
		_send_choice()
