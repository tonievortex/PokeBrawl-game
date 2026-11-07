extends Node3D
## Main battle scene. Builds the stage, both fighters, the camera, the HUD, effects,
## sound and the AI, and runs the battle: start, KO, rematch, pause and training.
##
## Launch: godot --path game -- [--p1=pikachu] [--p2=snorlax] [--diff=normal]
##         [--stage=night|floating] [--training] [--aivsai] [--test=name] [--lang=en|es]
## Online:  --host [--p1=species]            hosts a game (port 7777)
##          --join=IP [--p1=species]         joins someone else's
##          --bot (the AI plays your own Pokémon), --lag=ms --jitter=ms --loss=%

var options: Settings
var music: Music
var ground_y := 0.0
var mode := "combat"            # combat, training
var paused := false

var arena: Arena
var vfx: Vfx
var weather: Weather
var fx: Fx
var audio: Audio
var combat: Combat
var camera: BattleCamera
var hud: Hud
var menu: Menu
var ai: AI
var player_ai: AI               # only with --aivsai (tests)
var net: Net                     # online only
var ranked: Ranked               # the ranking backend's client (idle until the Ranked screen is used)
var fighters: Array = []
var trainers: Array = []          # Trainer of each fighter, same order (only for show)
## The opening: each trainer throws their Poké Ball and their Pokémon comes out; nobody
## moves until it ends. Tests skip it (unless --intro).
const INTRO := 2.5
var intro_t := 0.0
var start_t := -1.0               # seconds since the opening ended ("START"); -1 without one
var player: Fighter
var _fonts := {}
var _end_t := -1.0
## Online, on the result screen: who wants a rematch (Net.me ids). The host keeps the count
## and starts it once everyone is in ("rematch"); everyone sees "votes" as they come.
var rematch_votes := {}
var rematch_of := 0
## After the final blow: the result shows up once the stadium has had its moment (the
## strip's WINNER), and its options a little later; only then do A and B work.
const RESULT_AT := 2.4
const CHOICES_AT := 3.2
## With nobody choosing, the result screen goes on by itself this long after its options
## show: to the selection screen (online, both, still connected: the room). The stage stops
## then instead of running on behind.
const AUTO_LEAVE := 15.0
var _no_input := 0.0          # at the start, so the menu's A press does not make it jump
var _args := {}
## --server: this copy of the game is a match server (no screen, no menu, nobody plays it):
## the fight is computed here from the players' inputs, see match_server.gd.
var server_mode := false
var match_server: MatchServer
var session: SessionLog
## Ranked arena: the server's "start" (stage and both picks) and, once it ends, who it says won.
var _arena_info := {}
var forced_winner: Fighter
var tutorial: Tutorial            # Training's lessons (see tutorial.gd); only in Training

func _ready() -> void:
	session = SessionLog.new()
	session.main = self
	add_child(session)
	Controls.configure()
	# Less input lag: "mailbox" VSync does not wait on the frame queue and does not
	# tear. If the system does not support it, the normal mode stays.
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_MAILBOX)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var parts := a.substr(2).split("=")
			_args[parts[0]] = parts[1] if parts.size() > 1 else "1"
	# The language follows the system; --lang=en or --lang=es forces one.
	if _args.has("lang"):
		TranslationServer.set_locale(_args.lang)
	process_physics_priority = -20
	set_stage(_args.get("stage", "night"))
	combat = Combat.new()
	combat.main = self
	combat.process_physics_priority = 10
	add_child(combat)
	vfx = Vfx.new()
	vfx.main = self
	add_child(vfx)
	weather = Weather.new()
	weather.main = self
	add_child(weather)
	fx = Fx.new()
	fx.main = self
	add_child(fx)
	audio = Audio.new()
	audio.main = self
	add_child(audio)
	music = Music.new()
	add_child(music)
	options = Settings.new()
	options.main = self
	add_child(options)
	options.load_saved()
	if _args.has("lang"):
		TranslationServer.set_locale(_args.lang)
	camera = BattleCamera.new()
	camera.main = self
	camera.fov = 62.0
	add_child(camera)
	camera.current = true
	hud = Hud.new()
	hud.main = self
	add_child(hud)
	ranked = Ranked.new()
	ranked.main = self
	add_child(ranked)
	menu = Menu.new()
	menu.main = self
	menu.choice.stage = arena.stage
	add_child(menu)
	if _args.has("training"):
		mode = "training"
		menu.choice.mode = "training"
	# With --p1, --test or --aivsai it goes straight into battle; otherwise, to the menu.
	# --server: a match server (nobody plays this copy; the fight is run for two remote players).
	if _args.has("server"):
		server_mode = true
		_start_match_server()
	elif _args.has("host") or _args.has("join"):
		var err := start_net(_args.has("host"), _args.get("join", ""), _args.get("p1", "pikachu"))
		if err != "":
			push_error(err)
	elif _args.has("p1") or _args.has("aivsai") or (_args.has("test") and not _args.test.begins_with("menu")):
		start_battle(_args.get("p1", "pikachu"), _args.get("p2", "snorlax"), _args.get("diff", "normal"))
	else:
		menu.open_menu()
	if _args.has("test"):
		var p: Node = preload("res://scripts/tests.gd").new()
		p.main = self
		p.test_name = _args.test
		add_child(p)
	elif not menu.is_open and net == null:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func font(bold := true) -> Font:
	var k := "n" if bold else "r"
	if not _fonts.has(k):
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["Bahnschrift", "Segoe UI", "Arial"])
		f.font_weight = 700 if bold else 500
		_fonts[k] = f
	return _fonts[k]


## Builds the stage: "night" (the night stadium, the default) or "floating" (a platform
## over a void: falling off is a KO). It can be
## changed in the menu (online, the host picks it); it is rebuilt from scratch.
func set_stage(stage_id: String) -> void:
	if arena and arena.stage == stage_id:
		return
	if arena:
		arena.queue_free()
		remove_child(arena)
	match stage_id:
		"floating": arena = FloatingStadium.new()
		"league": arena = LeagueStadium.new()
		_:
			arena = NightStadium.new()
			stage_id = "night"
	arena.stage = stage_id
	arena.main = self
	add_child(arena)
	move_child(arena, 0)
	arena.build()
	_put_trainers()
	if hud and fighters.size() == 2:
		portraits(fighters[0].species, fighters[1].species)


## My Pokémon's moves and ability: what I saved in the Moves menu. Tests and AI against AI
## use the defaults (or --moves=a,b,c,d for p1), so they always play the same.
func my_loadout(sp: String) -> Dictionary:
	if _args.has("moves"):
		return Loadout.valid(sp, {"moves": Array(str(_args.moves).split(",")), "ability": Roster.POKEMON[sp].passive.id})
	if _args.has("test") or _args.has("aivsai"):
		return Loadout.default_for(sp)
	return Loadout.saved(sp)


## A match server: builds the fight for two remote players and runs it (see match_server.gd).
func _start_match_server() -> void:
	Engine.max_fps = 60
	match_server = MatchServer.new()
	match_server.main = self
	match_server.port = int(_args.get("port", "0"))
	match_server.match_id = str(_args.get("match", "0"))
	match_server.result_path = str(_args.get("result", ""))
	match_server.match_max = float(_args.get("match_max", str(MatchServer.MATCH_MAX)))
	match_server.replay_path = str(_args.get("replay", ""))
	match_server.draft_on = str(_args.get("draft", "0")) == "1"
	match_server.players = clampi(int(_args.get("players", "2")), 2, 4)
	if _args.has("draft_time"):
		match_server.ban_time = float(_args.draft_time)
		match_server.pick_time = float(_args.draft_time)
	add_child(match_server)


## The fight of a match server: both Pokémon are computed here (nobody controls them with
## this copy's keyboard), each one fed with the inputs of its remote player. "picks" are the
## two players' validated choices: {species, loadout}.
func start_server_battle(picks: Array, stage_id: String) -> void:
	set_stage(stage_id)
	vfx.clear()
	weather.clear()
	for l in fighters:
		l.queue_free()
	fighters.clear()
	combat.clear()
	if ai:
		ai.queue_free()
		ai = null
	# Two players: one against one. Four: slots 0 and 2 against 1 and 3 (the team of a slot is slot % 2),
	# each pair side by side.
	var n := picks.size()
	for i in n:
		var team := i % 2
		var z := 0.0 if n == 2 else (-3.0 if i / 2 == 0 else 3.0)
		_create(picks[i].species, team, Vector3(-7.0 if team == 0 else 7.0, 0, z), PI * 0.5 if team == 0 else -PI * 0.5, picks[i].loadout)
	fighters[0].rival = fighters[1]
	fighters[1].rival = fighters[0]
	player = null
	# They are driven by remote players' inputs; is_player enables manual aiming from them.
	for f in fighters:
		f.is_player = true
	combat.targets = fighters.duplicate()
	_end_t = -1.0
	_no_input = 0.0
	intro_t = 0.0
	start_t = -1.0
	Engine.time_scale = 1.0
	arena.on_rematch()
	for f in fighters:
		f.appear = 1.0
		f.appear_glow = 0.0


## "rival_loadout": what the online rival sent with its choice (against the AI, its defaults).
## "rival_trainer": the online rival's trainer (against the AI, one from TrainerData).
func start_battle(p1: String, p2: String, diff: String, rival_loadout := {}, rival_trainer := "") -> void:
	music.play(arena.stage, true)
	vfx.clear()
	weather.clear()
	for l in fighters:
		l.queue_free()
	fighters.clear()
	combat.clear()
	if ai:
		ai.queue_free()
	if player_ai:
		player_ai.queue_free()
	var side := 1.0 if net and not net.host else -1.0
	var a := _create(p1, 0, Vector3(7 * side, 0, 0), -PI * 0.5 * side, my_loadout(p1))
	var b := _create(p2, 1, Vector3(-7 * side, 0, 0), PI * 0.5 * side,
		Loadout.valid(p2, rival_loadout) if net else Loadout.default_for(p2))
	a.rival = b
	b.rival = a
	player = a
	a.is_player = true
	ai = null
	if net:
		_setup_net(a, b)
	else:
		_setup_ai(a, b, diff)
		if mode == "training":
			a.immortal = true            # nobody faints in training (see Fighter.immortal)
			b.immortal = true
			_setup_tutorial()
	combat.targets = fighters.duplicate()
	camera.target = a
	camera.yaw = -PI * 0.5 * -side
	_end_t = -1.0
	_no_input = 0.25
	Engine.time_scale = 1.0
	portraits(p1, p2)
	var mine: String = options.trainer
	_place_trainers([mine, rival_trainer if net and rival_trainer != "" else TrainerData.rival_for(mine, p2)])
	_introduce()
	session.battle_started(p1, p2, arena.stage, net != null, ("host" if net.host else "guest") if net else mode)
	if net:
		ranked.battle_started()
	if _args.has("weather"):
		weather.start(_args.weather)          # tests: --weather=sun|rain|sand|snow


## Training has a tutorial: it starts by itself the first time, F1 starts or ends it later.
func _setup_tutorial() -> void:
	if tutorial == null or not is_instance_valid(tutorial):
		tutorial = Tutorial.new()
		tutorial.main = self
		add_child(tutorial)
	tutorial.active = false
	tutorial.finished_t = -1.0
	if not _args.has("test") and not Tutorial.done_before():
		get_tree().create_timer(INTRO + 0.6, false).timeout.connect(func():
			if is_instance_valid(tutorial) and fighters.size() == 2 and mode == "training":
				tutorial.start())
	else:
		hud.log_entry(tr("F1: tutorial."))


func _setup_ai(a: Fighter, b: Fighter, diff: String) -> void:
	ai = AI.new()
	ai.main = self
	ai.me = b
	ai.rival = a
	ai.difficulty = diff
	ai.process_physics_priority = -10
	add_child(ai)
	if _args.has("aivsai"):
		player_ai = AI.new()
		player_ai.main = self
		player_ai.me = a
		player_ai.rival = b
		player_ai.difficulty = diff
		player_ai.process_physics_priority = -10
		add_child(player_ai)
		a.is_player = false


func _introduce() -> void:
	var a: Fighter = fighters[0]
	var b: Fighter = fighters[1]
	hud.clear_log()
	arena.on_rematch()
	_opening()
	if trainers.size() == 2:
		hud.log_entry(tr("%s sends out %s!") % [trainers[0].display_name, tr(a.data.display_name)])
		hud.log_entry(tr("%s sends out %s!") % [trainers[1].display_name, tr(b.data.display_name)])
	else:
		hud.log_entry(tr("Go, %s!") % tr(a.data.display_name))
		hud.log_entry(tr("%s jumps onto the field!") % tr(b.data.display_name))
	if mode == "training":
		hud.log_entry(tr("Training. R resets, T stops or frees the rival, F3 shows the hitboxes."))


# ---------------------------------------------------------------- trainers and the opening

## A trainer for each fighter, in their side's trainer area of the stage.
func _place_trainers(ids: Array) -> void:
	for t in trainers:
		t.queue_free()
	trainers.clear()
	for i in fighters.size():
		var t := Trainer.new()
		add_child(t)
		t.setup(self, ids[i], fighters[i])
		t.display_name = tr(TrainerData.LIST[t.id].name)
		trainers.append(t)
	trainers[0].display_name = online_name() if net else options.shown_name()
	if net and menu.rival_name != "" and trainers.size() > 1:
		trainers[1].display_name = menu.rival_name
	_put_trainers()


func _clear_trainers() -> void:
	for t in trainers:
		if is_instance_valid(t):
			t.queue_free()
	trainers.clear()


func _put_trainers() -> void:
	for t in trainers:
		# Back in the menus the fighters may be gone already: nothing to place then.
		if not is_instance_valid(t) or not is_instance_valid(t.fighter):
			continue
		var f: Fighter = t.fighter
		t.global_position = arena.trainer_spot(signf(f.start_pos.x) if f.start_pos.x != 0.0 else 1.0)
		if fighters.size() > 2:
			t.global_position.z += f.start_pos.z * 1.3          # two trainers on a side: one each way


## Visual reactions of a fighter's trainer: "command" (it used a move), "cheer" (it landed a
## hit), "flinch" (it took a heavy one).
func trainer_react(f: Node, kind: String) -> void:
	for t in trainers:
		if t.fighter == f and is_instance_valid(t):
			t.call(kind)


func _opening() -> void:
	for t in trainers:
		t.reset()
	var play := not (_args.has("test") or _args.has("aivsai")) or _args.has("intro")
	start_t = -1.0
	if not play:
		intro_t = 0.0
		for f in fighters:
			f.appear = 1.0
			f.appear_glow = 0.0
		audio.cry(fighters[0].species, fighters[0].global_position)
		return
	intro_t = INTRO
	_no_input = INTRO
	for i in fighters.size():
		var f: Fighter = fighters[i]
		f.appear = 0.0
		f.appear_glow = 0.0
		var t: Trainer = trainers[i]
		var wait := 0.2 + 0.25 * i
		get_tree().create_timer(wait, false).timeout.connect(func():
			if is_instance_valid(t):
				t.throw())
		get_tree().create_timer(wait + 0.25, false).timeout.connect(func():
			if is_instance_valid(t) and is_instance_valid(f):
				_throw_ball(t, f))


## The ball flies in an arc from the trainer's hand to where the Pokémon stands, spinning,
## and opens there in a burst of light; the Pokémon grows out of it, white, and cries.
func _throw_ball(t: Trainer, f: Fighter) -> void:
	var from := t.hand()
	var to := f.global_position + Vector3.UP * 0.7
	var flight := 0.75
	var top := 0.8 + from.distance_to(to) * 0.06
	var ball := vfx.pixel_ball("pokeball", 4, 0.5, Color.WHITE, 14.0, false)
	ball.global_position = from
	audio.play_sound("ball_throw", from, -2.0)
	vfx.live(ball, flight, func(k: float):
		ball.global_position = from.lerp(to, k) + Vector3.UP * sin(k * PI) * top)
	get_tree().create_timer(flight, false).timeout.connect(func():
		if not is_instance_valid(f):
			return
		audio.play_sound("ball_open", to, 0.0)
		audio.play_sound("ball_send", to, -4.0)
		vfx.light(to, Color.WHITE, 6.0, 6.0, 0.4)
		vfx.burst("stars", to, Vector3.UP, Color(0, 0, 0, 0), 1.2)
		vfx.wave(Vector3(to.x, ground_y, to.z), 2.2, 0.35, Color(1.0, 0.95, 0.9), 0.08)
		vfx.live(Node3D.new(), 0.4, func(k: float):
			if is_instance_valid(f):
				f.appear = k
				f.appear_glow = 1.0 - k)
		get_tree().create_timer(0.3, false).timeout.connect(func():
			if is_instance_valid(f):
				audio.cry(f.species, f.global_position)))


func _create(sp: String, eq: int, pos: Vector3, yaw: float, loadout := {}) -> Fighter:
	var l := Fighter.new()
	add_child(l)
	l.setup(self, sp, eq, loadout)
	l.global_position = pos
	l.face_yaw = yaw
	l.start_pos = pos
	l.start_yaw = yaw
	l.reset_physics_interpolation()
	l.defeated.connect(_on_defeat)
	fighters.append(l)
	return l


func rematch() -> void:
	session.event("rematch")
	if net:
		net.epoch += 1          # the rival's states from the round that just ended are dropped
	rematch_votes.clear()
	var a: Fighter = fighters[0]
	var b: Fighter = fighters[1]
	weather.clear()
	combat.clear()
	vfx.clear()
	a.reset(a.start_pos, a.start_yaw)
	b.reset(b.start_pos, b.start_yaw)
	camera.yaw = a.start_yaw + PI
	_end_t = -1.0
	Engine.time_scale = 1.0
	_introduce()
	# A ranked rematch is a new ranked match: the server is told it started.
	if net:
		ranked.battle_started()


## How many Pokémon of a team are still standing.
func team_alive(team: int) -> int:
	var n := 0
	for f in fighters:
		if is_instance_valid(f) and f.team == team and f.state != "ko":
			n += 1
	return n


func _on_defeat(who: Fighter) -> void:
	if _end_t >= 0.0:
		return
	if fighters.size() > 2 and team_alive(who.team) > 0:
		# A 2 vs 2 goes on while a team-mate stands: this one is only out of the fight.
		hud.log_entry(tr("%s fainted!") % tr(who.data.display_name))
		audio.play_sound("ko", who.global_position, -2.0)
		trainer_react(who, "lose")
		if who == player:
			for f in fighters:
				if f.team == who.team and f.state != "ko":
					camera.target = f
					break
		return
	_finish_battle(who.rival, who)


## The battle is over: `winner` stands (or leads, for the server's verdict), `who` is the one that fell.
func _finish_battle(winner: Fighter, who: Fighter) -> void:
	_end_t = 0.0
	# Brief slow motion: the last hit is visible, without taking control away. Not
	# online: time has to run the same on both machines.
	if net == null and not server_mode:
		Engine.time_scale = 0.35
	hud.log_entry(tr("%s fainted!") % tr(who.data.display_name))
	hud.log_entry(tr("%s wins.") % tr(winner.data.display_name))
	audio.play_sound("ko", who.global_position, -2.0)
	arena.on_ko(winner)
	for f in fighters:
		if is_instance_valid(f) and f.team == winner.team:
			trainer_react(f, "win")
		elif is_instance_valid(f):
			trainer_react(f, "lose")
	var hps: Array = []
	for f in fighters:
		hps.append(int(f.hp))
	session.battle_ended(winner.species + (" (me)" if winner == player or (player != null and winner.team == player.team) else ""), hps)
	if net and not (net is ArenaClient or net is ReplayPlayer):
		ranked.battle_ended(winner == player)


# ---------------------------------------------------------------- online

## Hosts a game or joins someone else's. Returns an error or "".
## With "species" (a shortcut for arguments and tests) it is picked and marked ready on
## connecting; without it, once connected both go to the menu's selection.
## With "relay" ({host, port, match_id, token}: ranked matches) the fight goes through the
## ranking server instead of straight between the players: no port to open.
func start_net(as_host: bool, ip: String, species := "", relay := {}) -> String:
	close_net()
	net = Net.new()
	net.main = self
	net.lag_sim = float(_args.get("lag", "0")) / 1000.0
	net.jitter_sim = float(_args.get("jitter", "0")) / 1000.0
	net.loss_sim = float(_args.get("loss", "0"))
	add_child(net)
	menu.rival_choice_id = ""
	menu.rival_version = ""
	menu.rival_ready = false
	net.connected.connect(func():
		if species != "":
			menu.online = true
			menu.choice.p1 = species
			menu.me_ready = true
			net.send_event({"t": "choice", "species": species, "ready": true, "loadout": my_loadout(species), "trainer": options.trainer, "name": online_name(), "ver": Menu.version()})
			check_start()
		else:
			menu.online_connected())
	net.event.connect(_net_event)
	net.disconnected.connect(_disconnection)
	var err := ""
	if not relay.is_empty():
		err = net.create_via(relay) if as_host else net.join_via(relay)
	else:
		err = net.create() if as_host else net.join(ip)
	session.event("net_start", {"role": "host" if as_host else "guest", "error": err})
	net.connected.connect(func(): session.event("connected"))
	return err


## The name the rival sees: the ranked account's, else the profile's.
func online_name() -> String:
	if ranked and ranked.logged_in() and ranked.me.has("name"):
		return str(ranked.me.name)
	return options.shown_name()


func close_net() -> void:
	if ranked:
		ranked.on_room_closed()
	if net:
		net.close()
		net.queue_free()
		net = null


# ---------------------------------------------------------------- ranked arena

## Opens the connection to the ranked server of a match (cfg: {host, port, match_id, token,
## slot}). The picks go through the same selection screen as always; once both are ready the
## server starts the fight. With "species" (tests) it is picked and marked ready on connecting.
func start_arena(cfg: Dictionary, species := "") -> String:
	close_net()
	var c := ArenaClient.new()
	c.main = self
	c.lag_sim = float(_args.get("lag", "0")) / 1000.0
	c.jitter_sim = float(_args.get("jitter", "0")) / 1000.0
	c.loss_sim = float(_args.get("loss", "0"))
	c.bot = _args.has("bot")
	net = c
	add_child(c)
	menu.rival_choice_id = ""
	menu.rival_version = ""
	menu.rival_ready = false
	menu.team_picks = {}
	forced_winner = null
	c.connected.connect(func():
		session.event("connected")
		if species != "":
			menu.online = true
			menu.choice.p1 = species
			menu.me_ready = true
			c.send_event({"t": "choice", "species": species, "ready": true, "loadout": my_loadout(species), "trainer": options.trainer, "name": online_name(), "ver": Menu.version()})
		else:
			menu.online_connected())
	c.event.connect(_net_event)
	c.disconnected.connect(_disconnection)
	var err := c.open(cfg)
	session.event("net_start", {"role": "arena", "error": err})
	return err


## Watches a recorded match (or, live, one being played a few seconds behind): see ReplayPlayer.
func start_replay(match_id: int, live: bool) -> void:
	close_net()
	var r := ReplayPlayer.new()
	r.main = self
	net = r
	add_child(r)
	r.event.connect(_net_event)
	r.disconnected.connect(_disconnection)
	r.open(match_id, live)


## A replay file on this computer (tests).
func start_replay_file(path: String) -> void:
	close_net()
	var r := ReplayPlayer.new()
	r.main = self
	net = r
	add_child(r)
	r.event.connect(_net_event)
	r.disconnected.connect(_disconnection)
	r.open_file(path)


## The battle of a replay: the two Pokémon as the match server had them, both copies of the file's.
func start_replay_battle(info: Dictionary) -> void:
	_arena_info = info
	var n: int = info.slots.size()
	set_stage(str(info.get("stage", "night")))
	music.play(arena.stage, true)
	vfx.clear()
	weather.clear()
	for l in fighters:
		l.queue_free()
	fighters.clear()
	combat.clear()
	if ai:
		ai.queue_free()
		ai = null
	# In slot order, as the match server placed them (team = slot % 2; a 2 vs 2 has the pairs side by side).
	for i in n:
		var si: Dictionary = info.slots[i]
		var z := 0.0 if n == 2 else (-3.0 if i / 2 == 0 else 3.0)
		var f := _create(str(si.species), i % 2, Vector3(-7.0 if i % 2 == 0 else 7.0, 0.0, z), PI * 0.5 if i % 2 == 0 else -PI * 0.5,
			Loadout.valid(str(si.species), si.get("loadout", {})))
		f.is_remote = true
		f.is_player = false
	var a: Fighter = fighters[0]
	var b: Fighter = fighters[1]
	a.rival = b
	b.rival = a
	player = null
	net.local = a
	net.remote = b
	net.in_battle = true
	combat.targets = fighters.duplicate()
	camera.target = a
	camera.yaw = -PI * 0.5
	_end_t = -1.0
	_no_input = 0.0
	forced_winner = null
	Engine.time_scale = 1.0
	var more: Array = []
	for i in range(2, n):
		more.append(str(info.slots[i].species))
	portraits(a.species, b.species, more)
	var ids: Array = []
	for s in info.slots:
		var t := str(s.get("trainer", ""))
		ids.append(TrainerData.valid(t) if t != "" else TrainerData.rival_for(options.trainer, str(s.species)))
	_place_trainers(ids)
	for i in n:
		trainers[i].display_name = str(info.slots[i].get("name", ""))
	_introduce()


## The server: both are ready, here is the stage and what each one picked.
func _arena_start(d: Dictionary) -> void:
	if not d.get("slots") is Array or d.slots.size() != net.players():
		return
	_arena_info = d
	var slot: int = net.slot
	var mine: Dictionary = d.slots[slot]
	var theirs: Dictionary = d.slots[net.enemy_slots()[0]]
	menu.me_ready = false
	menu.rival_ready = false
	menu.rival_name = str(theirs.get("name", "")).substr(0, Menu.NAME_MAX)
	menu.rival_trainer = TrainerData.valid(str(theirs.get("trainer", ""))) if str(theirs.get("trainer", "")) != "" else ""
	menu.rival_loadout = Loadout.valid(str(theirs.species), theirs.get("loadout", {}))
	set_stage(str(d.get("stage", menu.choice.stage)))
	# From the menu, with the VS screen (the battle itself starts when it ends); from
	# arguments (tests), straight in.
	if menu.is_open:
		menu.show_vs(str(mine.species), str(theirs.species))
	else:
		start_arena_battle()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if not _args.has("test") else Input.MOUSE_MODE_VISIBLE


## The fight of a ranked match: both Pokémon are copies of the server's. The first one is
## yours, whichever slot you have.
func start_arena_battle() -> void:
	if _arena_info.is_empty() or not net is ArenaClient:
		return
	if net.players() == 4:
		_start_team_battle()
		return
	var slot: int = net.slot
	var mine: Dictionary = _arena_info.slots[slot]
	var theirs: Dictionary = _arena_info.slots[1 - slot]
	music.play(arena.stage, true)
	vfx.clear()
	weather.clear()
	for l in fighters:
		l.queue_free()
	fighters.clear()
	combat.clear()
	if ai:
		ai.queue_free()
		ai = null
	var side := 1.0 if slot == 1 else -1.0       # as the server places them: slot 0 on the left
	var a := _create(str(mine.species), 0, Vector3(7 * side, 0, 0), -PI * 0.5 * side, Loadout.valid(str(mine.species), mine.get("loadout", {})))
	var b := _create(str(theirs.species), 1, Vector3(-7 * side, 0, 0), PI * 0.5 * side, Loadout.valid(str(theirs.species), theirs.get("loadout", {})))
	a.rival = b
	b.rival = a
	player = a
	a.is_player = false          # its keys are read by the ArenaClient and go to the server
	a.is_mine = true
	a.is_remote = true
	b.is_remote = true
	net.local = a
	net.remote = b
	net.in_battle = true
	combat.targets = fighters.duplicate()
	camera.target = a
	camera.yaw = PI * 0.5 * side
	_end_t = -1.0
	_no_input = 0.0
	forced_winner = null
	Engine.time_scale = 1.0
	portraits(a.species, b.species)
	var trainer: String = options.trainer
	var theirs_trainer := TrainerData.valid(str(theirs.get("trainer", ""))) if str(theirs.get("trainer", "")) != "" else ""
	_place_trainers([trainer, theirs_trainer if theirs_trainer != "" else TrainerData.rival_for(trainer, b.species)])
	_introduce()
	session.battle_started(a.species, b.species, arena.stage, true, "arena")
	ranked.battle_started()
	if net.phase == "fight":
		intro_t = 0.0001          # the server's fight began while the VS screen was still up


## A 2 vs 2 of the ranked server. The fighters are in this order: mine, the first rival, my team-mate, the second
## rival (so fighters[0] and fighters[1] are still "me" and "my rival" for everything that thinks of two); the
## team is 0 for mine and 1 for theirs. net.slot_fighters has them by the server's slot.
func _start_team_battle() -> void:
	var c: ArenaClient = net
	var enemies: Array = c.enemy_slots()
	var order: Array = [c.slot, enemies[0], c.ally_slot(), enemies[1]]
	music.play(arena.stage, true)
	vfx.clear()
	weather.clear()
	for l in fighters:
		l.queue_free()
	fighters.clear()
	combat.clear()
	if ai:
		ai.queue_free()
		ai = null
	var by_slot: Array = [null, null, null, null]
	var ids: Array = []
	var extra: Array = []
	for k in 4:
		var s: int = order[k]
		var info: Dictionary = _arena_info.slots[s]
		var team := 0 if s % 2 == c.slot % 2 else 1
		var pos := Vector3(-7.0 if s % 2 == 0 else 7.0, 0.0, -3.0 if s / 2 == 0 else 3.0)
		var f := _create(str(info.species), team, pos, PI * 0.5 if s % 2 == 0 else -PI * 0.5, Loadout.valid(str(info.species), info.get("loadout", {})))
		f.is_player = false
		f.is_remote = true
		f.is_mine = k == 0
		by_slot[s] = f
		var tid := TrainerData.valid(str(info.get("trainer", ""))) if str(info.get("trainer", "")) != "" else ""
		ids.append(tid if tid != "" else TrainerData.rival_for(options.trainer, f.species))
		if k >= 2:
			extra.append(f.species)
	player = fighters[0]
	fighters[0].is_mine = true
	c.slot_fighters = by_slot
	c.local = fighters[0]
	c.remote = fighters[1]
	c.in_battle = true
	combat.targets = fighters.duplicate()
	camera.target = fighters[0]
	camera.yaw = PI * 0.5 * (1.0 if c.slot % 2 == 1 else -1.0)
	_end_t = -1.0
	_no_input = 0.0
	forced_winner = null
	Engine.time_scale = 1.0
	portraits(fighters[0].species, fighters[1].species, extra)
	_place_trainers(ids)
	for k in 4:
		trainers[k].display_name = str(_arena_info.slots[order[k]].get("name", "")).substr(0, Menu.NAME_MAX)
	_introduce()
	session.battle_started(fighters[0].species, fighters[1].species, arena.stage, true, "arena2v2")
	ranked.battle_started()
	if net.phase == "fight":
		intro_t = 0.0001


## The server's verdict (a knockout was probably seen already; time, forfeit and a rival who
## left come only this way).
func _arena_result(d: Dictionary) -> void:
	var winner := int(d.get("winner", -1))
	if fighters.size() == 4:
		# The winner is a team (0 or 1, the server's slot % 2); my team is the one of my slot.
		if winner in [0, 1]:
			var won_team := 0 if winner == net.slot % 2 else 1
			forced_winner = null
			for f in fighters:
				if f.team == won_team and (forced_winner == null or (forced_winner.state == "ko" and f.state != "ko")):
					forced_winner = f
			if _end_t < 0.0:
				for f in fighters:
					if f.team != won_team:
						_finish_battle(forced_winner, f)
						break
		elif _end_t < 0.0:
			_finish_battle(fighters[0], fighters[1])
	elif fighters.size() == 2 and winner in [0, 1]:
		forced_winner = fighters[0] if winner == net.slot else fighters[1]
		if _end_t < 0.0:
			_on_defeat(forced_winner.rival)
	elif fighters.size() == 2 and _end_t < 0.0:
		_on_defeat(fighters[1])
	ranked.arena_result(d)


## The host starts the battle when both are ready.
func check_start() -> void:
	if net == null or not net.host or not menu.me_ready or not menu.rival_ready or menu.rival_choice_id == "":
		return
	if menu.version_mismatch():
		return
	var mine: String = menu.choice.p1
	var theirs: String = menu.rival_choice_id
	menu.me_ready = false
	menu.rival_ready = false
	net.send_event({"t": "start", "host": mine, "guest": theirs, "stage": menu.choice.stage})
	set_stage(menu.choice.stage)
	_start_online(mine, theirs)


func _setup_net(a: Fighter, b: Fighter) -> void:
	b.is_remote = true
	b.is_player = false
	net.local = a
	net.remote = b
	# net.frame counts the whole connection: reset, the rival would drop a second
	# battle's packets as old.
	net.in_battle = true
	net.epoch = 0
	if _args.has("bot"):
		ai = AI.new()
		ai.main = self
		ai.me = a
		ai.rival = b
		ai.difficulty = _args.get("diff", "normal")
		ai.process_physics_priority = -10
		add_child(ai)
		a.is_player = false


func _net_event(d: Dictionary) -> void:
	if net is ArenaClient or net is ReplayPlayer:
		# The ranked arena: the server runs the fight and tells how it goes.
		match d.t:
			"choice":
				var sender := int(d.get("slot", -1))
				if net is ArenaClient and net.players() == 4 and sender >= 0:
					menu.team_choice(sender, d)
					if sender != net.enemy_slots()[0]:
						return
				menu.rival_choice(str(d.get("species", "")), bool(d.get("ready", false)), d.get("loadout", {}),
					str(d.get("trainer", "")), str(d.get("name", "")), str(d.get("ver", Menu.version())))
			"start":
				_arena_start(d)
			"draft":
				menu.on_draft(d)
			"fight":
				if intro_t > 0.0:
					intro_t = 0.0001          # the opening is cut short if the fight starts first
			"result":
				_arena_result(d)
		return
	match d.t:
		"choice":
			if d.has("stage") and menu.STAGES.has(d.stage):
				menu.choice.stage = d.stage
			menu.rival_choice(d.species, d.ready, d.get("loadout", {}), str(d.get("trainer", "")), str(d.get("name", "")), str(d.get("ver", "")))
			check_start()
		"start":
			menu.me_ready = false
			menu.rival_ready = false
			menu.choice.stage = d.get("stage", menu.choice.stage)
			set_stage(menu.choice.stage)
			_start_online(d.guest, d.host)
		"stage":
			# The host changed the stage in the selection (it is built when the battle starts).
			if menu.STAGES.has(d.id):
				menu.choice.stage = d.id
		"to_selection":
			_to_selection(false)
		"hit":
			# Confirmation from the rival: my hit landed. Number and type, like offline.
			if fighters.size() > 1 and d.damage > 0.5:
				vfx.number(d.point, d.damage, d.affinity)
				if d.affinity > 1.05:
					hud.log_entry(tr("It's super effective!"))
				elif d.affinity < 0.95:
					hud.log_entry(tr("It's not very effective..."))
		"effect":
			if net.local:
				net.local.effect(d.type, d.v, d.get("move", ""))
		"clash":
			# The host saw two shots meet: the same here ("h" is the host's shot, "g" mine).
			if net.local and net.remote:
				var mine = null
				var theirs = null
				for p in combat.projectiles:
					if p.get("shooter") == net.local and p.get("seq", -2) == int(d.g):
						mine = p
					elif p.get("shooter") == net.remote and p.get("seq", -2) == int(d.h):
						theirs = p
				if mine != null and theirs != null:
					combat.clash(theirs, mine)
		"deflect":
			# The rival deflected one of my projectiles: the same here.
			if net.local and net.remote:
				for p in combat.projectiles:
					if p.get("shooter") == net.local and p.get("seq", -2) == int(d.seq):
						combat.deflect(p, net.remote, int(d.level))
						break
		"boost":
			# The rival's Pokémon changed a stat stage: its copy here needs it for damage.
			if net.remote and net.remote.stages.has(d.stat):
				net.remote.stages[d.stat] = int(d.stages)
		"rematch":
			rematch()
		"rm_ask":
			ranked.on_rematch_ask()
		"rm_yes":
			ranked.on_rematch_yes()
		"rm_no":
			ranked.on_rematch_no()
		"asks_rematch":
			if net.host and _end_t > 1.0:
				_vote_rematch(str(d.get("id", "guest")))
		"votes":
			rematch_votes = {}
			for id in d.get("ids", []):
				rematch_votes[str(id)] = true
			rematch_of = int(d.get("of", 2))


func _start_online(mine: String, theirs: String) -> void:
	# From the menu, with the VS screen; from arguments (tests), straight in.
	if menu.is_open:
		menu.show_vs(mine, theirs)
		return
	start_battle(mine, theirs, "normal", menu.rival_loadout, menu.rival_trainer)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if not _args.has("test") else Input.MOUSE_MODE_VISIBLE


## Online rematch vote: everyone must ask for it. A guest's vote goes to the host; the host
## counts, tells everyone how many are in, and starts the rematch for all when the last one
## asks. Until then nobody's battle starts.
func _vote_rematch(id: String) -> void:
	if net == null or _end_t < 0.0:
		return
	if not net.host:
		if rematch_votes.has(id):
			return
		rematch_votes[id] = true
		net.send_event({"t": "asks_rematch", "id": id})
		return
	rematch_votes[id] = true
	rematch_of = net.players()
	net.send_event({"t": "votes", "ids": rematch_votes.keys(), "of": rematch_of})
	if rematch_votes.size() >= rematch_of:
		net.send_event({"t": "rematch"})
		rematch()


## Online, after a battle: both pick again without dropping the connection.
func _to_selection(warn: bool) -> void:
	if net == null:
		return
	session.event("to_selection", {"asked_by_me": warn})
	rematch_votes.clear()
	if warn:
		net.send_event({"t": "to_selection"})
	net.in_battle = false
	net.local = null
	net.remote = null
	for l in fighters:
		l.queue_free()
	fighters.clear()
	player = null
	combat.clear()
	combat.targets = []
	vfx.clear()
	if ai:
		ai.queue_free()
		ai = null
	_end_t = -1.0
	_clear_trainers()
	hud.clear_log()
	menu.online = true
	menu.open_menu("selection")


func _disconnection(reason: String) -> void:
	session.event("disconnected", {"reason": reason})
	# Before leaving the battle (back_to_menu would count it as mine): in a ranked match
	# whoever stays wins.
	ranked.on_disconnect(reason)
	hud.log_entry(reason)
	push_warning(reason)
	if net:
		net.queue_free()
		net = null
	if _args.get("test", "") == "net":
		return
	back_to_menu()
	menu.disconnected(reason)


## For the Cobblemon particle interpreter: ground height under a point.
func ground_at(_p: Vector3, _from: float) -> float:
	return ground_y


func shake_camera(k: float, pos: Vector3) -> void:
	var d := camera.global_position.distance_to(pos)
	camera.shake_camera(k * clampf(1.4 - d / 25.0, 0.3, 1.0))


# ---------------------------------------------------------------- player input

func _physics_process(delta: float) -> void:
	if intro_t > 0.0:
		intro_t -= delta
		if intro_t <= 0.0:
			start_t = 0.0
	elif start_t >= 0.0:
		start_t += delta
	if _end_t >= 0.0:
		_end_t += delta / maxf(Engine.time_scale, 0.01)
		if _end_t > 0.9:
			Engine.time_scale = 1.0
		if _end_t > CHOICES_AT + AUTO_LEAVE and not paused and not server_mode and not _args.has("test") and not _args.has("aivsai"):
			_leave_result()
	if _no_input > 0.0:
		_no_input -= delta
		if player:
			player.ctrl.clear()
		return
	if player == null or not player.is_player:
		return
	if paused:
		# Online the battle goes on under the pause menu: your Pokémon just stands still.
		player.ctrl.clear()
		return
	var c := player.ctrl
	c.move_input = Input.get_vector("move_left", "move_right", "move_down", "move_up")
	c.yaw = camera.yaw
	for a in ["jump", "dodge", "lock_on", "mov1", "mov2", "mov3", "mov4", "descend"]:
		if Input.is_action_just_pressed(a):
			c.press(a)
		elif Input.is_action_pressed(a):
			c.held[a] = true
		else:
			c.release(a)


func _unhandled_input(ev: InputEvent) -> void:
	Controls.notice(ev)
	# Watching a replay: Space pauses, Left / Right change the speed, Tab swaps the camera, and the
	# result screen has one way out.
	if net is ReplayPlayer:
		if ev is InputEventKey and ev.pressed and not ev.echo:
			match ev.physical_keycode:
				KEY_SPACE:
					net.toggle_pause()
					get_viewport().set_input_as_handled()
					return
				KEY_RIGHT:
					net.faster()
					return
				KEY_LEFT:
					net.slower()
					return
				KEY_TAB:
					net.swap_camera()
					return
		if _end_t > CHOICES_AT and (ev.is_action_pressed("menu_back") or ev.is_action_pressed("jump")):
			back_to_menu("replays")
			get_viewport().set_input_as_handled()
			return
	# Result screen of a ranked match: F5 reports the rival, 1 to 4 picks why, Esc cancels.
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.physical_keycode == KEY_F1 and mode == "training" and net == null \
			and tutorial != null and fighters.size() == 2 and not menu.is_open:
		tutorial.toggle()
		return
	if _end_t > CHOICES_AT and ev is InputEventKey and ev.pressed and not ev.echo and ranked.in_ranked_room():
		if ranked.report_state in ["choose", "target"]:
			var pick: int = ev.physical_keycode - KEY_1
			if ranked.report_state == "target":
				if pick >= 0 and pick < ranked.report_targets().size():
					ranked.report_send_target(pick)
			elif pick >= 0 and pick < Ranked.REPORT_REASONS.size():
				ranked.report_send(pick)
			elif ev.physical_keycode == KEY_ESCAPE:
				ranked.report_state = ""
			get_viewport().set_input_as_handled()
			return
		if ev.physical_keycode == KEY_F5 and ranked.can_report():
			ranked.report_open()
			get_viewport().set_input_as_handled()
			return
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.physical_keycode == KEY_F9:
		session.open_folder()
	if ev.is_action_pressed("debug"):
		hud.debug = not hud.debug
	if fighters.size() < 2:
		return
	if ev.is_action_pressed("reset") and net == null and (mode == "training" or _end_t > 1.0):
		rematch()
	if ev is InputEventKey and ev.pressed and ev.physical_keycode == KEY_T and mode == "training" and ai:
		ai.mode = "still" if ai.mode == "active" else "active"
		ai.me.ctrl.move_input = Vector2.ZERO
	if _end_t > CHOICES_AT and ev.is_action_pressed("jump"):
		if ranked.in_ranked_room():
			_ranked_result_key(true)
		elif net == null:
			rematch()
		else:
			_vote_rematch(net.me)
	elif _end_t > CHOICES_AT and ev.is_action_pressed("menu_back"):
		if ranked.in_ranked_room():
			_ranked_result_key(false)
		elif net:
			_to_selection(true)
		else:
			back_to_menu()
	if ev is InputEventMouseButton and ev.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not paused and not menu.is_open and not _args.has("test"):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## HUD and jumbotron portraits for this matchup.
func portraits(p1: String, p2: String, more := []) -> void:
	hud.prepare_portraits([p1, p2] + more)
	arena.screens(hud._portraits[0].vp.get_texture(), hud._portraits[1].vp.get_texture(),
		Roster.TYPE_COLOR[Roster.POKEMON[p1].types[0]], Roster.TYPE_COLOR[Roster.POKEMON[p2].types[0]])


## Nobody chose on the result screen: back to the selection (online the host takes both,
## still connected; the guest waits for it).
func _leave_result() -> void:
	if net is ReplayPlayer:
		back_to_menu("replays")
		return
	if ranked.in_ranked_room():
		# A rematch being asked keeps the screen (it has its own time limit).
		if ranked.rematch == "":
			_leave_ranked()
		return
	if net:
		if net.host:
			_to_selection(true)
		return
	back_to_menu("selection")


## A ranked match is over: out of its room, back to the Ranked screen (the rating is there).
func _leave_ranked() -> void:
	back_to_menu("ranked")


## The result screen's keys in a ranked room. A: the loser asks for a rematch, the other
## accepts one that was asked, otherwise leave. B: decline, cancel the request or leave.
func _ranked_result_key(accept: bool) -> void:
	match ranked.rematch:
		"asked":
			ranked.answer_rematch(accept)
		"asking":
			if not accept:
				_leave_ranked()
		"starting":
			pass
		_:
			if accept and ranked.can_ask_rematch():
				ranked.ask_rematch()
			else:
				_leave_ranked()


## Leaves the battle and returns to the menu with the last picks ("screen": which one).
func back_to_menu(screen := "") -> void:
	session.event("back_to_menu", {"online": net != null, "battle_over": _end_t >= 0.0})
	if net:
		ranked.on_leave(_end_t >= 0.0)
		net.close()
		net.queue_free()
		net = null
	if paused:
		paused = false
		get_tree().paused = false
	vfx.clear()
	for l in fighters:
		l.queue_free()
	fighters.clear()
	player = null
	combat.clear()
	combat.targets = []
	if ai:
		ai.queue_free()
		ai = null
	if player_ai:
		player_ai.queue_free()
		player_ai = null
	_end_t = -1.0
	Engine.time_scale = 1.0
	_clear_trainers()
	hud.clear_log()
	menu.open_menu(screen)


func toggle_pause() -> void:
	paused = not paused
	session.event("pause" if paused else "resume", {"online": net != null})
	# Online the game cannot stop (the rival keeps playing): the menu opens on top so you
	# can leave, and the battle goes on.
	if net == null:
		get_tree().paused = paused
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if paused else Input.MOUSE_MODE_CAPTURED
