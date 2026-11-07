class_name ArenaClient
extends Net
## The player's side of a ranked match that the SERVER runs (match_server.gd). It replaces the
## Net of a peer-to-peer room: the game is the same everywhere else (it is a Net for the rest
## of the code), but nothing here decides anything about the fight.
##
## Sends to the server, through the ranking backend's UDP gateway (one datagram = 0x02 +
## kind + data):
##   HELLO  0x01 match id (u32, big-endian), slot (u8), token (16 bytes): until the gateway answers
##   MSG    0x11 JSON: the Pokémon pick and ready (resent in the lobby), or "leave"
##   INPUT  0x12 ack of the last event, n, then the last n inputs (move, camera, buttons)
##   PING   0x14 id
## Receives: SNAPSHOT 0x80 (both Pokémon, 30 per second, plus events) and PONG 0x84.
## Both Pokémon on this screen are copies of the server's (is_remote): moved by the inputs the
## server saw and pulled to its real state, exactly like a rival in a peer-to-peer match.
##
## Tests: --lag=ms (round trip), --loss=% simulate a bad network; --bot plays by itself.

const C_MSG := 0x11
const C_INPUT := 0x12
const C_PING := 0x14
const S_SNAPSHOT := 0x80
const S_PONG := 0x84
const PHASES := ["lobby", "countdown", "fight", "over"]
const HELLO_FIRST := 0.4          # a hello until the gateway answers: this often
const HELLO_KEEP := 1.0           # ...and afterwards, to keep the door open
const SILENCE := 6.0              # nothing from the server for this long: the connection is lost
const INPUTS_PER_PACKET := 4      # the newest inputs: a lost packet costs nothing
const PING_EVERY := 0.25

var slot := 0
var players_n := 2                 # 2 (one against one) or 4 (two against two: slots 0 and 2 against 1 and 3)
var slot_fighters: Array = []      # the fighter of each slot (set by Main when the fight is built)
var phase := "connecting"          # connecting, lobby, countdown, fight, over
var server_tick := 0
var applied_frame := 0             # the last input of mine the server has used
var bot := false                   # plays by itself (tests)

var _udp := PacketPeerUDP.new()
var _open := false
var _hello := PackedByteArray()
var _hello_t := 0.0
var _hist: Array = []              # the newest input records
var _intent := Intent.new()
var _event_ack := 0
var _last_choice := {}
var _choice_t := 0.0
var _seen: Array = [{}, {}, {}, {}]  # per slot: press counters last seen in snapshots
var _last_rx := 0.0
var _rtts: Array = []
var _ping_n := 0
var _ping_sent := {}
var _ping_clock := 0.0
var _left := false
## The ping is measured by a thread of its own, with the microsecond clock, on a socket of its own:
## in the game's physics tick every answer would be rounded to a multiple of 16.7 ms and the number
## would jump around. (The gateway answers these at once, see "type 5" in the backend.)
var _ping_thread: Thread
var _ping_run := false
var _ping_mutex := Mutex.new()
var _ping_samples: Array = []


## cfg: {host, port, match_id, token, slot}. Returns an error or "".
func open(cfg: Dictionary) -> String:
	close()
	slot = int(cfg.get("slot", 0))
	players_n = 4 if int(cfg.get("players", 2)) == 4 else 2
	slot_fighters = []
	var b := StreamPeerBuffer.new()
	b.big_endian = true
	b.put_u8(0x01)
	b.put_u32(int(cfg.match_id))
	b.put_u8(slot)
	b.put_data(str(cfg.token).hex_decode())
	_hello = b.data_array
	if _udp.bind(0) != OK:
		return tr("Could not open a local port")
	if _udp.set_dest_address(str(cfg.host), int(cfg.port)) != OK:
		return tr("Could not reach the game server")
	_open = true
	_start_pinger(str(cfg.host), int(cfg.port))
	phase = "connecting"
	_last_rx = _t
	_hello_t = 0.0
	_reset_counters()
	return ""


func _reset_counters() -> void:
	frame = 0
	_hist.clear()
	_event_ack = 0
	_intent = Intent.new()
	_seen = [{}, {}, {}, {}]
	_rtts.clear()
	_ping_sent.clear()
	rtt = 0.0
	_left = false


func relay_registered() -> bool:
	return linked


func path() -> String:
	return "server"


func ping_label() -> String:
	return "Ping %d ms" % ping_ms()


func players() -> int:
	return players_n


## The slots of the other team (they alternate: team = slot % 2), in order.
func enemy_slots() -> Array:
	var out: Array = []
	for i in players_n:
		if i % 2 != slot % 2:
			out.append(i)
	return out


## My team-mate's slot in a 2 vs 2 (-1 in a 1 vs 1).
func ally_slot() -> int:
	return (slot ^ 2) if players_n == 4 else -1


## The only events that leave this game are the player's picks. Hits, effects, clashes and
## everything else the peer-to-peer game used to tell its rival are now the server's business.
func send_event(data: Dictionary) -> void:
	match str(data.get("t", "")):
		"choice":
			_last_choice = data.duplicate()
			_last_choice.erase("stage")
			_message(_last_choice)
		"ban", "pick":
			_message(data)


func close() -> void:
	if _open and linked and not _left and phase != "over" and phase != "connecting":
		# Leaving on purpose: tell the server (a few times: nothing waits for an answer).
		_left = true
		for i in 3:
			_message({"t": "leave"}, true)
	_open = false
	_stop_pinger()
	_udp.close()
	phase = "connecting"
	super.close()


# ---------------------------------------------------------------- loop

func _physics_process(delta: float) -> void:
	_t += delta
	if not _open:
		return
	# The simulated bad network: delayed output.
	var i := 0
	while i < _exit_t.size():
		if _exit_t[i][0] <= _t:
			_udp.put_packet(_exit_t[i][2])
			_exit_t.remove_at(i)
		else:
			i += 1
	_poll()
	if not _open:
		return
	_hello_t -= delta
	if _hello_t <= 0.0:
		_hello_t = HELLO_KEEP if linked else HELLO_FIRST
		_udp.put_packet(_hello)       # not delayed or dropped by the simulation: it is the door
	if not linked:
		if _t - _last_rx > 30.0:
			_lost.call_deferred(tr("Could not reach the game server."))
			_open = false
		return
	if _t - _last_rx > SILENCE:
		_open = false
		_lost.call_deferred(tr("The connection to the game server was lost."))
		return
	_take_pings()
	match phase:
		"lobby":
			_choice_t -= delta
			if _choice_t <= 0.0:
				_choice_t = 1.0
				# Until there is a pick to repeat, a plain "hi": the server learns this player's address from
				# any packet (a draft starts when it knows both) and it keeps the connection alive.
				_message(_last_choice if not _last_choice.is_empty() else {"t": "hi"})
		"countdown", "fight":
			_send_input()


## One datagram for the server (the gateway wants 0x02 first).
func _send_packet(body: PackedByteArray, direct := false) -> void:
	var pkt := PackedByteArray([0x02])
	pkt.append_array(body)
	if direct or (lag_sim <= 0.0 and loss_sim <= 0.0):
		_udp.put_packet(pkt)
		return
	if randf() * 100.0 < loss_sim:
		return
	_exit_t.append([_t + maxf(lag_sim + randf_range(-jitter_sim, jitter_sim), 0.0), 0, pkt])


func _message(d: Dictionary, direct := false) -> void:
	var b := StreamPeerBuffer.new()
	b.put_u8(C_MSG)
	b.put_data(JSON.stringify(d).to_utf8_buffer())
	_send_packet(b.data_array, direct)


# ---------------------------------------------------------------- ping

func _start_pinger(host: String, port: int) -> void:
	_stop_pinger()
	_ping_run = true
	_ping_samples.clear()
	_ping_thread = Thread.new()
	_ping_thread.start(_pinger.bind(host, port))


func _stop_pinger() -> void:
	_ping_run = false
	if _ping_thread:
		_ping_thread.wait_to_finish()
		_ping_thread = null


func _exit_tree() -> void:
	_stop_pinger()


## The thread: a ping every PING_EVERY seconds, the answers timed against the sending clock.
func _pinger(host: String, port: int) -> void:
	var sock := PacketPeerUDP.new()
	sock.set_dest_address(host, port)
	var next_at := 0
	var n := 0
	while _ping_run:
		var now := Time.get_ticks_usec()
		if now >= next_at:
			next_at = now + int(PING_EVERY * 1000000.0)
			n = (n + 1) & 0xFFFF
			var b := StreamPeerBuffer.new()
			b.put_u8(5)
			b.put_u16(n)
			b.put_u64(now)
			sock.put_packet(b.data_array)
		while sock.get_available_packet_count() > 0:
			var pkt := sock.get_packet()
			if pkt.size() == 11 and pkt[0] == 5:
				var r := StreamPeerBuffer.new()
				r.data_array = pkt
				r.get_u8()
				r.get_u16()
				var sent := r.get_u64()
				_ping_mutex.lock()
				_ping_samples.append(float(Time.get_ticks_usec() - sent) / 1000000.0)
				_ping_mutex.unlock()
		OS.delay_usec(400)
	sock.close()


## From the physics tick: the thread's new samples become the ping shown. The middle of the last
## few, then eased: one late packet does not move the number.
func _take_pings() -> void:
	_ping_mutex.lock()
	var fresh := _ping_samples.duplicate()
	_ping_samples.clear()
	_ping_mutex.unlock()
	for x in fresh:
		_rtts.append(float(x) + lag_sim)
		if _rtts.size() > 8:
			_rtts.pop_front()
		var sorted := _rtts.duplicate()
		sorted.sort()
		var mid: float = sorted[sorted.size() >> 1]
		rtt = mid if rtt <= 0.0 else lerpf(rtt, mid, 0.2)


# ---------------------------------------------------------------- input

## What the keyboard (or the test bot) does this tick, sent as the server expects it.
func _send_input() -> void:
	_sample()
	_drive_own()
	frame += 1
	var c := _intent
	var rec := StreamPeerBuffer.new()
	rec.put_u32(frame)
	rec.put_float(c.move_input.x)
	rec.put_float(c.move_input.y)
	rec.put_float(c.yaw)
	var mask := 0
	for k in ACTIONS.size():
		if c.keeps(ACTIONS[k]):
			mask |= 1 << k
	rec.put_u16(mask)
	for a in ACTIONS:
		rec.put_u8(int(c.counter.get(a, 0)))
	_hist.append(rec.data_array)
	while _hist.size() > INPUTS_PER_PACKET:
		_hist.pop_front()
	var b := StreamPeerBuffer.new()
	b.put_u8(C_INPUT)
	b.put_u16(_event_ack & 0xFFFF)
	b.put_u8(_hist.size())
	for r in _hist:
		b.put_data(r)
	_send_packet(b.data_array)


## Prediction: your own Pokémon obeys the same input at once, without waiting for the server
## (which will confirm or correct its position and state).
func _drive_own() -> void:
	if local == null or not is_instance_valid(local) or phase != "fight":
		return
	var c := local.ctrl
	c.move_input = _intent.move_input
	c.yaw = _intent.yaw
	for a in ACTIONS:
		if _intent.pressed.get(a, false):
			c.press(a)
		elif _intent.keeps(a):
			c.held[a] = true
		else:
			c.release(a)


func _sample() -> void:
	var c := _intent
	c.clear()
	var live: bool = phase == "fight" and main.fighters.size() == players_n and main.intro_t <= 0.0 \
		and main._end_t < 0.0 and not main.paused and local != null and is_instance_valid(local)
	if not live:
		c.move_input = Vector2.ZERO
		for a in ACTIONS:
			c.release(a)
		return
	if bot:
		_bot(c)
		return
	c.move_input = Input.get_vector("move_left", "move_right", "move_down", "move_up")
	c.yaw = main.camera.yaw
	for a in ACTIONS:
		if Input.is_action_just_pressed(a):
			c.press(a)
		elif Input.is_action_pressed(a):
			c.held[a] = true
		else:
			c.release(a)


## A simple scripted player for tests: walks at the rival and keeps using moves and dodges.
func _bot(c: Intent) -> void:
	if remote == null or not is_instance_valid(remote):
		return
	var d: Vector3 = remote.global_position - local.global_position
	var dist := Vector2(d.x, d.z).length()
	c.yaw = 0.0
	c.move_input = Vector2(d.x, -d.z) / maxf(dist, 0.001) if dist > 4.0 else Vector2.ZERO
	var n := frame
	if n == 1:
		c.press("lock_on")
	if n % 36 == 0:
		c.press("mov1")
	if n % 67 == 0:
		c.press("mov2")
	if n % 150 == 0:
		c.press("dodge")


# ---------------------------------------------------------------- what the server sends

func _poll() -> void:
	while _open and _udp.get_available_packet_count() > 0:
		var pkt := _udp.get_packet()
		if pkt.is_empty():
			continue
		_last_rx = _t
		match pkt[0]:
			0x03:
				if not linked:
					linked = true
					_last_packet = _t
					phase = "lobby"
					connected.emit()
			0x02:
				if pkt.size() > 1:
					_from_server(pkt.slice(1))


func _from_server(p: PackedByteArray) -> void:
	match p[0]:
		S_SNAPSHOT:
			_snapshot(p)
		S_PONG:
			if p.size() >= 3:
				var id := int(p[1]) | (int(p[2]) << 8)
				if _ping_sent.has(id):
					_rtts.append(_t - float(_ping_sent[id]))
					_ping_sent.erase(id)
					if _rtts.size() > 8:
						_rtts.pop_front()
					# The middle of the last few: one late packet does not move the number.
					var sorted := _rtts.duplicate()
					sorted.sort()
					var mid: float = sorted[sorted.size() >> 1]
					rtt = mid if rtt <= 0.0 else lerpf(rtt, mid, 0.2)


func _snapshot(p: PackedByteArray) -> void:
	var b := StreamPeerBuffer.new()
	b.data_array = p
	b.get_u8()
	var tick := b.get_u32()
	if tick <= server_tick and server_tick - tick < 1000000:
		return          # old or repeated
	server_tick = tick
	applied_frame = b.get_u32()
	var ph := b.get_u8()
	phase = PHASES[clampi(ph, 0, PHASES.size() - 1)]
	var n := b.get_u8()
	var ready: bool = main.fighters.size() == players_n and local != null and remote != null and is_instance_valid(local) and is_instance_valid(remote)
	for i in n:
		var start := b.get_position()
		if ready and i < players_n:
			# Your own Pokémon already runs on your keys: only the server's real state is taken.
			var who: Fighter = null
			if players_n == 2:
				who = local if i == slot else remote
			elif i < slot_fighters.size():
				who = slot_fighters[i]
			if who != null and is_instance_valid(who):
				_apply_state(who, b, _seen[i], i != slot)
				states_applied += 1
		b.seek(start + Net.RECORD_BYTES)
	_events(b)


func _events(b: StreamPeerBuffer) -> void:
	if b.get_available_bytes() < 1:
		return
	var count := b.get_u8()
	for i in count:
		if b.get_available_bytes() < 4:
			return
		var id := b.get_u16()
		var ln := b.get_u16()
		if b.get_available_bytes() < ln:
			return
		var raw: PackedByteArray = b.get_data(ln)[1]
		if id <= _event_ack:
			continue        # seen already (the server repeats them until acknowledged)
		_event_ack = id
		var d = JSON.parse_string(raw.get_string_from_utf8())
		if d is Dictionary:
			event.emit(d)
