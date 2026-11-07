class_name ReplayPlayer
extends Net
## Plays a match back from its replay file (see match_server.gd for the format): the backend serves
## the file in pieces, and each recorded frame (both Pokémon and what happened) is fed to the same
## copies of the Pokémon a real match uses. A match still being played is watched a few seconds
## behind (LIVE_DELAY), the file growing as it goes.
##
## Controls while it plays: Space pauses, Left / Right change the speed, Tab swaps the camera
## between the two Pokémon (Main reads those keys and calls the methods below).

const FPS := 30.0                # frames per second in the file
const LIVE_DELAY := 10.0         # seconds behind the live match
const LIVE_ASK := 1.0            # a live replay is asked for more this often
const SPEEDS := [0.5, 1.0, 2.0, 4.0]

var match_id := 0
var live := false
var info := {}                   # the header: stage, slots...
var slot := 0                    # for Main: the first Pokémon is "slot 0"
var speed_i := 1
var paused := false
var frames: Array = []           # PackedByteArray of each frame
var position := 0.0              # index of the frame being shown (fractional)

var _buf := PackedByteArray()
var _parse_at := 0
var _have_header := false
var _fetching := false
var _closed := false
var _size := 0                   # the file's size, as the server last said
var _still_live := false
var _next_ask := 0.0
var _applied := -1
var _started := false
var _seen: Array = [{}, {}, {}, {}]
var _follow := 0


func open(id: int, as_live: bool) -> void:
	match_id = id
	live = as_live
	_t = 0.0
	_fetch()


## From a file on this computer instead of the backend (tests, and replays saved by hand).
func open_file(path: String) -> void:
	_closed = false
	_buf = FileAccess.get_file_as_bytes(path)
	_size = _buf.size()
	_still_live = false
	_parse()


func close() -> void:
	_closed = true
	super.close()


## (Net's version stays quiet when there was never a connection: a replay that fails must say so.)
func _lost(reason: String) -> void:
	_closed = true
	push_warning("replay: " + reason)
	disconnected.emit(reason)


func relay_registered() -> bool:
	return true


func ping_ms() -> int:
	return 0


func players() -> int:
	return int(info.get("slots", [0, 0]).size())


func send_event(_data: Dictionary) -> void:
	pass


func ping_label() -> String:
	var total := maxi(frames.size() - 1, 0) / FPS
	var text := "%s  %s %s / %s" % [tr("LIVE") if _still_live else tr("REPLAY"), "x%s" % str(SPEEDS[speed_i]), _clock(position / FPS), _clock(total)]
	if paused:
		text += "  " + tr("(paused)")
	return text


func _clock(sec: float) -> String:
	return "%d:%02d" % [int(sec) / 60, int(sec) % 60]


func toggle_pause() -> void:
	paused = not paused


func faster() -> void:
	speed_i = mini(speed_i + 1, SPEEDS.size() - 1)


func slower() -> void:
	speed_i = maxi(speed_i - 1, 0)


func swap_camera() -> void:
	if main.fighters.size() < 2:
		return
	_follow = (_follow + 1) % main.fighters.size()
	main.camera.target = main.fighters[_follow]


# ---------------------------------------------------------------- download

func _fetch() -> void:
	if _fetching or _closed:
		return
	_fetching = true
	main.ranked.fetch_replay(match_id, _buf.size(), _on_piece)


func _on_piece(code: int, headers: Dictionary, body: PackedByteArray) -> void:
	_fetching = false
	if _closed:
		return
	if code != 200:
		_lost.call_deferred(tr("That replay is not there any more.") if code == 404 else tr("Could not download the replay."))
		return
	_buf.append_array(body)
	_size = int(headers.get("x-replay-size", str(_buf.size())))
	_still_live = str(headers.get("x-replay-live", "0")) == "1"
	_parse()
	if _buf.size() < _size:
		_fetch()
	else:
		_next_ask = _t + LIVE_ASK


## What has arrived so far, cut into the header and the frames.
func _parse() -> void:
	if not _have_header:
		if _buf.size() < 8:
			return
		if _buf.slice(0, 4).get_string_from_ascii() != "PBR1":
			_lost.call_deferred(tr("That is not a replay."))
			return
		var hl: int = _buf.decode_u32(4)
		if _buf.size() < 8 + hl:
			return
		var parsed = JSON.parse_string(_buf.slice(8, 8 + hl).get_string_from_utf8())
		if not parsed is Dictionary or not parsed.get("slots") is Array or not parsed.slots.size() in [2, 4]:
			_lost.call_deferred(tr("That replay is damaged."))
			return
		info = parsed
		_have_header = true
		_parse_at = 8 + hl
	while _parse_at + 4 <= _buf.size():
		var ln: int = _buf.decode_u32(_parse_at)
		if _parse_at + 4 + ln > _buf.size():
			break
		frames.append(_buf.slice(_parse_at + 4, _parse_at + 4 + ln))
		_parse_at += 4 + ln


# ---------------------------------------------------------------- playback

func _physics_process(delta: float) -> void:
	_t += delta
	if _closed:
		return
	if _still_live and not _fetching and _t >= _next_ask and _buf.size() >= _size:
		_next_ask = _t + LIVE_ASK
		_fetch()
	if not _started:
		_try_start()
		return
	if main.fighters.size() < 2:
		return
	var last := frames.size() - 1
	if not paused:
		position = minf(position + delta * FPS * float(SPEEDS[speed_i]), float(last))
	# A live match: never get closer to the live end than the delay.
	var target := int(position)
	while _applied < target:
		_applied += 1
		_show(_applied, _applied == target)
	rtt = 0.0


## Starts once enough is here: the whole file, or for a live match the delay's worth of it.
func _try_start() -> void:
	if not _have_header:
		return
	var whole := not _still_live and _buf.size() >= _size
	var enough := frames.size() >= (int(LIVE_DELAY * FPS) + 30 if _still_live else 60)
	if not (whole or enough):
		return
	_started = true
	if main.menu.is_open:
		main.menu.close()
	main.start_replay_battle(info)
	local = main.fighters[0]
	remote = main.fighters[1]
	in_battle = true
	linked = true
	# A live match: begin the delay's length behind its end.
	position = maxf(0.0, float(frames.size() - 1) - LIVE_DELAY * FPS) if _still_live else 0.0
	_applied = int(position) - 1
	connected.emit()


## One frame: the events always, the Pokémon only when it is the one being shown.
func _show(i: int, last: bool) -> void:
	var b := StreamPeerBuffer.new()
	b.data_array = frames[i]
	b.get_u32()
	var phase := b.get_u8()
	var n := b.get_u8()
	for k in n:
		var start := b.get_position()
		if last and k < main.fighters.size() and main.fighters.size() == players() and is_instance_valid(main.fighters[k]):
			_apply_state(main.fighters[k], b, _seen[k], true)
			states_applied += 1
		b.seek(start + Net.RECORD_BYTES)
	if b.get_available_bytes() < 1:
		return
	var count := b.get_u8()
	for k in count:
		if b.get_available_bytes() < 4:
			return
		var _id := b.get_u16()
		var ln := b.get_u16()
		if b.get_available_bytes() < ln:
			return
		var raw: PackedByteArray = b.get_data(ln)[1]
		var d = JSON.parse_string(raw.get_string_from_utf8())
		if d is Dictionary and str(d.get("t", "")) == "result":
			event.emit(d)
	if phase == 3 and i >= frames.size() - 1 and not _still_live:
		paused = true          # the end of the file: it stays on the last picture
