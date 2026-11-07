class_name MatchServer
extends Node
## The referee of one ranked match: the fight is computed HERE, from the inputs of the two
## players, and nobody else decides anything (hits, damage, HP, KO, who won). The players'
## games only send their inputs and show what this server tells them, so a changed game
## cannot give itself HP, move faster or report a win it did not get.
##
## Runs inside a headless copy of the game (`godot --headless -- --server --port=P --match=ID
## --result=file.json`), one per match, started and watched by the ranking backend. It
## listens on 127.0.0.1:P: the backend's UDP gateway passes the players' datagrams here and
## carries the answers back. Every datagram starts with the player's slot (0 or 1).
##
## Players -> server (after the slot byte):
##   0x11 MSG    JSON: {"t": "choice", species, loadout, trainer, name, ready} or {"t": "leave"}
##   0x12 INPUT  ack of the last event (u16), n (u8, up to 4 inputs: the newest ones, so a lost
##               packet costs nothing), then for each: frame (u32), move x, y, yaw (3 floats),
##               held-buttons mask (u16), 8 press counters (u8). Same meaning as in net.gd.
##   0x14 PING   id (u16), answered at once with 0x84 PONG and the same id.
## Server -> player (after the slot byte):
##   0x80 SNAPSHOT  server tick (u32), last input frame applied for this player (u32), phase
##               (u8), number of Pokémon (u8, 0 or 2) and each one's state (Net.write_fighter),
##               then the events this player has not acknowledged: n (u8), each: id (u16),
##               length (u16), JSON. Events are repeated until acknowledged.
##
## Phases: lobby (waiting for both choices) -> countdown -> fight -> over. The result (winner,
## reason, HP) is an event for both players, a MATCH_RESULT line on the console and, with
## --result, a JSON file the backend reads. A player who is silent for SILENCE_FORFEIT seconds
## in a fight forfeits; so does one who sends "leave".

const C_MSG := 0x11
const C_INPUT := 0x12
const C_PING := 0x14
const S_SNAPSHOT := 0x80
const S_PONG := 0x84

const PHASES := ["lobby", "countdown", "fight", "over"]
const LOBBY_TIMEOUT := 90.0       # both choices must be in by then
const COUNTDOWN := 5.0            # the clients' VS screen and trainers' opening take ~4.7 s
const SILENCE_FORFEIT := 10.0     # in a fight, a player who sends nothing for this long forfeits (a lag spike is not a forfeit)
const MATCH_MAX := 300.0          # then whoever has more HP left wins
const END_GRACE := 4.0            # after the result the process stays a bit: everyone gets it
const SNAPSHOT_EVERY := 2         # physics ticks (60 per second) between snapshots: 30 per second
const PACKET_MAX := 1100          # bytes: events are left for the next packet beyond this

var main: Node
var port := 0
var match_id := "0"
var result_path := ""
var match_max := MATCH_MAX        # --match_max=N shortens it (tests)
var phase := "lobby"
## --replay=file: every snapshot (30 per second, both Pokémon and the events everyone sees) is written
## to this file as the match goes, so it can be watched later or, a few seconds behind, while it is
## on. Format (all little-endian): "PBR1", u32 header length, header JSON {v, match, stage, slots},
## then frames: u32 length + [tick u32, phase u8, n u8, n x Net.RECORD_BYTES, events u8, each:
## id u16, length u16, JSON].
var replay_path := ""
## --draft=1: before the match each player bans one Pokémon (all at once, hidden until all are
## in), then they pick one each, one after the other (a 1 vs 1: a random player first, then the
## other; a 2 vs 2: a random team first, then the other team's two, then the first team's second
## player): nothing banned or already picked can be taken. Whoever is late gets a random ban or pick. Only then do the players
## send their moves and "ready" (the species must be the one they picked). --draft_time=N shortens
## the waits (tests).
var draft_on := false
## --players=4: a 2 vs 2. The team of a slot is slot % 2 (slots 0 and 2 against 1 and 3); the match is
## won by a team (0 or 1, the "winner" of the result) when both of the other team's Pokémon are out.
## A player who leaves or goes silent only takes their own Pokémon out of the fight.
var players := 2
var ban_time := 20.0
var pick_time := 25.0

var _udp := PacketPeerUDP.new()
var _addr: Array = [null, null]   # where each player was last heard from: [ip, port] (the gateway's)
var _picks: Array = [{}, {}]
var _ready_picks := [false, false]
var _last_rx := [0.0, 0.0]
var _applied := [0, 0]            # the last input frame applied for each player
var _seen: Array = [{}, {}]       # action -> last press counter seen, per player
var _events: Array = []           # {id, to (-1 both, else a slot), data}
var _next_id := 1
var _acked := [0, 0]
var _left: Array = []               # slots whose player left the fight on purpose (2 vs 2)
var _gone: Array = []               # slots whose player went silent (2 vs 2)
var _t := 0.0
var _phase_t := 0.0
var _fight_t := 0.0
var _tick := 0
var _stage := ""
var _finished := false
var _draft := {"stage": "wait", "bans": [null, null], "picks": [null, null], "turn": 0, "idx": 0, "order": [0, 1]}
var _draft_t := 0.0
var _replay: FileAccess
var _replay_event := 0              # the last event written to the replay
var _replay_frames := 0


func _ready() -> void:
	# Before the fighters (their step reads the inputs set here).
	process_physics_priority = -15
	_addr = []
	_picks = []
	_ready_picks = []
	_last_rx = []
	_applied = []
	_seen = []
	_acked = []
	for i in players:
		_addr.append(null)
		_picks.append({})
		_ready_picks.append(false)
		_last_rx.append(0.0)
		_applied.append(0)
		_seen.append({})
		_acked.append(0)
	_draft.bans = []
	_draft.picks = []
	for i in players:
		_draft.bans.append(null)
		_draft.picks.append(null)
	if port <= 0 or _udp.bind(port, "127.0.0.1") != OK:
		push_error("match server: cannot listen on port %d" % port)
		get_tree().quit(2)
		return
	print("MATCH_SERVER ready match=%s port=%d" % [match_id, port])


func _physics_process(delta: float) -> void:
	_t += delta
	_phase_t += delta
	_tick += 1
	_poll()
	match phase:
		"lobby":
			if draft_on:
				_draft_step(delta)
			if not _ready_picks.has(false):
				_start()
			elif _phase_t > LOBBY_TIMEOUT:
				_finish("no_show", -1)
		"countdown":
			if _phase_t >= COUNTDOWN:
				_set_phase("fight")
				_emit(-1, {"t": "fight"})
		"fight":
			_fight_t += delta
			_fight_step()
		"over":
			if _phase_t >= END_GRACE:
				_close_replay()
				get_tree().quit()
	if _tick % SNAPSHOT_EVERY == 0:
		_send_snapshots()
		_record_frame()


# ---------------------------------------------------------------- the match

func _set_phase(p: String) -> void:
	phase = p
	_phase_t = 0.0


## Both are ready: a random stage, the Pokémon on their starting places, a short countdown.
func _start() -> void:
	_stage = Menu.STAGES[randi() % Menu.STAGES.size()]
	main.start_server_battle(_picks.duplicate(), _stage)
	for i in players:
		main.fighters[i].hit_taken.connect(_on_hit.bind(i))
		main.fighters[i].defeated.connect(_on_ko.bind(i))
	_set_phase("countdown")
	var slots: Array = []
	for i in players:
		slots.append({"species": _picks[i].species, "loadout": _picks[i].loadout,
			"trainer": _picks[i].trainer, "name": _picks[i].name})
	_emit(-1, {"t": "start", "stage": _stage, "slots": slots})
	_open_replay(slots)


func _fight_step() -> void:
	if players > 2:
		_team_fight_step()
		return
	var silent := [_t - _last_rx[0] > SILENCE_FORFEIT, _t - _last_rx[1] > SILENCE_FORFEIT]
	if silent[0] and silent[1]:
		_finish("abandoned", -1)
	elif silent[0] or silent[1]:
		_finish("forfeit", 1 if silent[0] else 0)
	elif _fight_t > match_max:
		var left: Array = [main.fighters[0].hp / main.fighters[0].hp_max, main.fighters[1].hp / main.fighters[1].hp_max]
		_finish("time", 0 if left[0] >= left[1] else 1)


## 2 vs 2: someone silent for too long is out of the fight (their Pokémon faints); when all are silent
## it is abandoned; at the time limit the team with more HP left wins.
func _team_fight_step() -> void:
	var silent_n := 0
	for s in players:
		if _t - _last_rx[s] > SILENCE_FORFEIT:
			silent_n += 1
			if not _gone.has(s) and not _left.has(s) and main.fighters[s].state != "ko":
				_gone.append(s)
				main.fighters[s]._die({})
	if silent_n == players:
		_finish("abandoned", -1)
	elif _fight_t > match_max and not _finished:
		var left := [0.0, 0.0]
		for s in players:
			left[s % 2] += main.fighters[s].hp / main.fighters[s].hp_max
		_finish("time", 0 if left[0] >= left[1] else 1)


func _on_hit(who: Fighter, info: Dictionary, slot: int) -> void:
	if phase != "fight":
		return
	var point := [0.0, 0.0, 0.0]
	if info.get("point") is Vector3:
		var p: Vector3 = info.point
		point = [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)]
	_emit(-1, {"t": "hit", "slot": slot, "hp": snappedf(who.hp, 0.1),
		"affinity": snappedf(float(info.get("affinity", 1.0)), 0.01), "point": point})


## A Pokémon is out. A team loses when all of its Pokémon are (in a 1 vs 1 that is the first KO).
func _on_ko(_who: Fighter, slot: int) -> void:
	if phase != "fight":
		return
	var team := slot % 2
	for s in players:
		if s % 2 == team and main.fighters[s].state != "ko":
			return
	var reason := "ko"
	for s in _left:
		if s % 2 == team:
			reason = "left"
	if reason == "ko":
		for s in _gone:
			if s % 2 == team:
				reason = "forfeit"
	_finish(reason, 1 - team)


## The match is settled: tell both players, the console and (with --result) the backend.
func _finish(reason: String, winner: int) -> void:
	if _finished:
		return
	_finished = true
	var hp: Array = []
	var species: Array = []
	for f in main.fighters:
		hp.append(snappedf(f.hp, 0.1))
		species.append(f.species)
	_set_phase("over")
	_emit(-1, {"t": "result", "winner": winner, "reason": reason, "hp": hp})
	var res := {"match": match_id, "winner": winner, "reason": reason, "hp": hp, "species": species,
		"stage": _stage, "duration": snappedf(_fight_t, 0.1), "players": players, "left": _left}
	print("MATCH_RESULT " + JSON.stringify(res))
	if result_path != "":
		var f := FileAccess.open(result_path, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(res))
			f.close()


# ---------------------------------------------------------------- the draft

func _draft_step(delta: float) -> void:
	match str(_draft.stage):
		"wait":
			if not _addr.has(null):
				_draft.stage = "ban"
				_draft_t = ban_time
				_draft_emit()
		"ban":
			_draft_t -= delta
			if not _draft.bans.has(null) or _draft_t <= 0.0:
				for s in players:
					if _draft.bans[s] == null:
						_draft.bans[s] = _draft_random(false)
				_draft.stage = "pick"
				var first := randi() % 2          # the team that picks first
				_draft.order = [first, 1 - first] if players == 2 else [first, 1 - first, 1 - first + 2, first + 2]
				_draft.idx = 0
				_draft.turn = _draft.order[0]
				_draft_t = pick_time
				_draft_emit()
		"pick":
			_draft_t -= delta
			if _draft_t <= 0.0:
				_draft_pick(int(_draft.turn), _draft_random(true))


## The Pokémon that may still be taken (for a ban: any; for a pick: not banned, not picked).
func _draft_free(for_pick: bool) -> Array:
	var out: Array = []
	for sp in main.menu.pokemon_list():
		if for_pick and (_draft.bans.has(sp) or _draft.picks.has(sp)):
			continue
		out.append(sp)
	return out


func _draft_random(for_pick: bool) -> String:
	var free := _draft_free(for_pick)
	return str(free[randi() % free.size()])


func _draft_pick(s: int, sp: String) -> void:
	_draft.picks[s] = sp
	if not _draft.picks.has(null):
		_draft.stage = "done"
	else:
		_draft.idx = int(_draft.idx) + 1
		_draft.turn = _draft.order[int(_draft.idx)]
		_draft_t = pick_time
	_draft_emit()


## Everyone is told the state of the draft. Bans stay hidden while the bans are being made.
func _draft_emit() -> void:
	var shown: bool = str(_draft.stage) != "ban" and str(_draft.stage) != "wait"
	var hidden: Array = []
	var done: Array = []
	for i in players:
		hidden.append(null)
		done.append(_draft.bans[i] != null)
	_emit(-1, {"t": "draft", "stage": _draft.stage, "bans": _draft.bans.duplicate() if shown else hidden,
		"ban_done": done, "picks": _draft.picks.duplicate(),
		"turn": _draft.turn, "left": snappedf(maxf(_draft_t, 0.0), 0.1)})


func _on_draft_msg(s: int, kind: String, d: Dictionary) -> void:
	if not draft_on or phase != "lobby":
		return
	var sp := str(d.get("species", ""))
	if not main.menu.pokemon_list().has(sp):
		return
	if kind == "ban":
		if str(_draft.stage) == "ban" and _draft.bans[s] == null:
			_draft.bans[s] = sp
			_draft_emit()
	elif kind == "pick":
		if str(_draft.stage) == "pick" and int(_draft.turn) == s and not _draft.bans.has(sp) and not _draft.picks.has(sp):
			_draft_pick(s, sp)


# ---------------------------------------------------------------- the replay

func _open_replay(slots: Array) -> void:
	if replay_path == "":
		return
	_replay = FileAccess.open(replay_path, FileAccess.WRITE)
	if _replay == null:
		push_error("match server: cannot write the replay %s" % replay_path)
		return
	var head := JSON.stringify({"v": 1, "match": match_id, "stage": _stage, "slots": slots,
		"started": Time.get_unix_time_from_system()}).to_utf8_buffer()
	_replay.store_buffer("PBR1".to_utf8_buffer())
	_replay.store_32(head.size())
	_replay.store_buffer(head)
	_replay.flush()


## One frame: where both Pokémon are and what happened since the last one.
func _record_frame() -> void:
	if _replay == null or phase == "lobby" or main.fighters.size() < 2:
		return
	var b := StreamPeerBuffer.new()
	b.put_u32(_tick)
	b.put_u8(PHASES.find(phase))
	b.put_u8(main.fighters.size())
	for i in main.fighters.size():
		Net.write_fighter(b, main.fighters[i])
	var out: Array = []
	for e in _events:
		if int(e.id) > _replay_event and int(e.to) < 0 and out.size() < 12:
			out.append(e)
	b.put_u8(out.size())
	for e in out:
		var j: PackedByteArray = JSON.stringify(e.data).to_utf8_buffer()
		b.put_u16(int(e.id))
		b.put_u16(j.size())
		b.put_data(j)
		_replay_event = int(e.id)
	_replay.store_32(b.get_size())
	_replay.store_buffer(b.data_array)
	_replay_frames += 1
	if _replay_frames % 15 == 0:
		_replay.flush()          # readable while the match is on (watching live)


func _close_replay() -> void:
	if _replay:
		_replay.flush()
		_replay.close()
		_replay = null


# ---------------------------------------------------------------- what players send

func _poll() -> void:
	while _udp.get_available_packet_count() > 0:
		var pkt := _udp.get_packet()
		var ip := _udp.get_packet_ip()
		var from_port := _udp.get_packet_port()
		if pkt.size() < 2 or int(pkt[0]) >= players:
			continue
		var s := int(pkt[0])
		_addr[s] = [ip, from_port]
		_last_rx[s] = _t
		match pkt[1]:
			C_MSG:
				_on_msg(s, pkt.slice(2).get_string_from_utf8())
			C_INPUT:
				_on_input(s, pkt.slice(2))
			C_PING:
				if pkt.size() >= 4:
					_udp.set_dest_address(ip, from_port)
					_udp.put_packet(PackedByteArray([s, S_PONG, pkt[2], pkt[3]]))


func _on_msg(s: int, text: String) -> void:
	var d = JSON.parse_string(text)
	if not d is Dictionary:
		return
	match str(d.get("t", "")):
		"choice":
			if phase != "lobby":
				return
			var sp := str(d.get("species", ""))
			if not main.menu.pokemon_list().has(sp):
				return          # not a Pokémon of this game: nobody makes up their own
			if draft_on and (str(_draft.stage) != "done" or sp != str(_draft.picks[s])):
				return          # in a draft only what was picked can be played
			# The moves and ability are checked against what the species may have.
			var pick := {"species": sp, "loadout": Loadout.valid(sp, d.get("loadout", {})),
				"trainer": str(d.get("trainer", "")).left(24), "name": str(d.get("name", "")).left(24)}
			_picks[s] = pick
			_ready_picks[s] = bool(d.get("ready", false))
			var forward := pick.duplicate()
			forward["t"] = "choice"
			forward["slot"] = s
			forward["ready"] = _ready_picks[s]
			for o in players:
				if o != s:
					_emit(o, forward)
		"ban", "pick":
			_on_draft_msg(s, str(d.t), d)
		"leave":
			if phase == "fight" and players > 2:
				if not _left.has(s) and main.fighters[s].state != "ko":
					_left.append(s)
					main.fighters[s]._die({})
			elif phase == "fight":
				_finish("left", 1 - s)
			elif phase in ["lobby", "countdown"]:
				_finish("left_early", -1)


func _on_input(s: int, data: PackedByteArray) -> void:
	var b := StreamPeerBuffer.new()
	b.data_array = data
	if b.get_available_bytes() < 3:
		return
	_acked[s] = maxi(_acked[s], b.get_u16())
	var n := mini(b.get_u8(), 4)
	for i in n:
		if b.get_available_bytes() < 26:
			break
		var frame := b.get_u32()
		var mx := b.get_float()
		var my := b.get_float()
		var yaw := b.get_float()
		var mask := b.get_u16()
		var counters: Array = []
		for k in Net.ACTIONS.size():
			counters.append(b.get_u8())
		if frame <= _applied[s]:
			continue        # old or repeated
		_applied[s] = frame
		_apply_input(s, mx, my, yaw, mask, counters)


## The same reading of an input as a copy of the rival makes in net.gd, with its checks:
## nothing a player sends can be bigger or stranger than a keyboard.
func _apply_input(s: int, mx: float, my: float, yaw: float, mask: int, counters: Array) -> void:
	if phase != "fight" or main.fighters.size() < 2:
		return
	if not (is_finite(mx) and is_finite(my) and is_finite(yaw)):
		return
	var c: Intent = main.fighters[s].ctrl
	c.move_input = Vector2(mx, my).limit_length(1.0)
	c.yaw = yaw
	for k in Net.ACTIONS.size():
		var a: String = Net.ACTIONS[k]
		var n: int = counters[k]
		var new_ones := (n - int(_seen[s].get(a, 0)) + 256) % 256
		_seen[s][a] = n
		if new_ones > 0 and new_ones < 30:
			c.press(a)
		elif mask & (1 << k):
			c.held[a] = true
		else:
			c.release(a)


# ---------------------------------------------------------------- what the server sends

func _emit(to: int, data: Dictionary) -> void:
	_events.append({"id": _next_id, "to": to, "data": data})
	_next_id = (_next_id % 65535) + 1
	# What both players have acknowledged is dropped; a player who never answers cannot make
	# the list grow without end.
	var low: int = _acked.min()
	while not _events.is_empty() and (int(_events[0].id) <= low or _events.size() > 200):
		_events.pop_front()


func _send_snapshots() -> void:
	for s in players:
		if _addr[s] == null:
			continue
		var b := StreamPeerBuffer.new()
		b.put_u8(s)
		b.put_u8(S_SNAPSHOT)
		b.put_u32(_tick)
		b.put_u32(_applied[s])
		b.put_u8(PHASES.find(phase))
		var n: int = main.fighters.size() if phase != "lobby" else 0
		b.put_u8(n)
		for i in n:
			Net.write_fighter(b, main.fighters[i])
		var out: Array = []
		var bytes := b.get_size() + 1
		for e in _events:
			if int(e.id) > _acked[s] and (int(e.to) < 0 or int(e.to) == s):
				var j: PackedByteArray = JSON.stringify(e.data).to_utf8_buffer()
				if bytes + j.size() + 4 > PACKET_MAX and not out.is_empty():
					break
				out.append([e.id, j])
				bytes += j.size() + 4
		b.put_u8(out.size())
		for e in out:
			b.put_u16(e[0])
			b.put_u16(e[1].size())
			b.put_data(e[1])
		_udp.set_dest_address(_addr[s][0], _addr[s][1])
		_udp.put_packet(b.data_array)
