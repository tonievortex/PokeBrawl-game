class_name Tutorial
extends Node
## The tutorial of Training: a short list of things to try, each one ticked off by itself when the
## player does it, with the keys named as they are set up in Options. The rival stands still until
## the end, then fights back. It starts by itself the first time Training is opened and F1 starts
## it again (or ends it).

static var done_file := "user://tutorial_done"
## text: what to do; keys: actions to name (their glyphs are shown); need: how it is ticked off.
const STEPS := [
	{"text": "Move around the stadium.", "keys": ["move_up", "move_left", "move_down", "move_right"], "need": "move"},
	{"text": "Lock on to your rival.", "keys": ["lock_on"], "need": "lock"},
	{"text": "Use your first move.", "keys": ["mov1"], "need": "mov1"},
	{"text": "Try the other three moves.", "keys": ["mov2", "mov3", "mov4"], "need": "others"},
	{"text": "Dodge: it makes you untouchable for a moment.", "keys": ["dodge"], "need": "dodge"},
	{"text": "Jump.", "keys": ["jump"], "need": "jump"},
	{"text": "Hit your rival with a move.", "keys": ["mov1"], "need": "hit"},
	{"text": "Land a combo of three hits.", "keys": [], "need": "combo"},
]
const MOVE_NEEDED := 4.0         # metres walked for the first step
const END_SHOWN := 5.0           # the closing message stays this long

var main: Node
var active := false
var step := 0
var finished_t := -1.0           # seconds since the end (the closing message), -1 while not over
var _walked := 0.0
var _last_pos := Vector3.ZERO
var _seen := {}                  # actions pressed during this step
var _t := 0.0


func _ready() -> void:
	process_physics_priority = 5


## Whether this player has been through it (or skipped it) before.
static func done_before() -> bool:
	return FileAccess.file_exists(done_file)


func start() -> void:
	active = true
	step = 0
	finished_t = -1.0
	_begin_step()
	if main.ai:
		main.ai.mode = "still"
	main.hud.log_entry(tr("Tutorial: do what the top of the screen says. F1 ends it."))


func stop(completed := false) -> void:
	if not active:
		return
	active = false
	if main.ai:
		main.ai.mode = "active"
	_mark_done()
	if completed:
		finished_t = 0.0


func toggle() -> void:
	if active:
		stop()
	else:
		start()


func _mark_done() -> void:
	var f := FileAccess.open(done_file, FileAccess.WRITE)
	if f:
		f.store_string("1")


func _begin_step() -> void:
	_seen.clear()
	_walked = 0.0
	if main.player:
		_last_pos = main.player.global_position


## An action the player pressed (from the keyboard each tick; the tests call it too).
func note(action: String) -> void:
	_seen[action] = true


func current() -> Dictionary:
	return STEPS[mini(step, STEPS.size() - 1)]


func _physics_process(delta: float) -> void:
	_t += delta
	if finished_t >= 0.0:
		finished_t += delta
		return
	if not active or main.fighters.size() < 2 or main.intro_t > 0.0 or main.player == null or not is_instance_valid(main.player):
		return
	for a in ["mov1", "mov2", "mov3", "mov4", "dodge", "jump", "lock_on"]:
		if Input.is_action_just_pressed(a):
			note(a)
	var me: Fighter = main.player
	var rival: Fighter = main.fighters[1]
	_walked += Vector2(me.global_position.x - _last_pos.x, me.global_position.z - _last_pos.z).length()
	_last_pos = me.global_position
	if _satisfied(STEPS[step].need, me, rival):
		step += 1
		if step >= STEPS.size():
			stop(true)
			main.hud.log_entry(tr("Tutorial done. The rival fights back now: F1 to do it again."))
		else:
			_begin_step()


func _satisfied(need: String, me: Fighter, rival: Fighter) -> bool:
	match need:
		"move":
			return _walked >= MOVE_NEEDED
		"lock":
			return me.locked
		"mov1":
			return _seen.has("mov1")
		"others":
			return _seen.has("mov2") and _seen.has("mov3") and _seen.has("mov4")
		"dodge":
			return _seen.has("dodge") or me.state == "dodge"
		"jump":
			return _seen.has("jump")
		"hit":
			return rival.train_hits >= 1
		"combo":
			return rival.train_hits >= 3 and rival.train_t < 1.6
	return false

