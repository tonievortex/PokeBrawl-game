class_name MenuDraw
extends RefCounted
## Draws the menus (Menu keeps the logic) in Smash Ultimate's dark look (UiKit): a
## hatched charcoal floor, solid slanted blocks, big italic names and very little text.
## Each screen weighs differently: the main menu is a wall of tiles of different sizes,
## the selection a row of portraits over two big player cards, the Moves screen a list
## with a sheet. Highlights ease in and out; text that could run long is fitted to its
## block so nothing spills out.

const ITEM_COLOR := {"combat": UiKit.RED, "training": UiKit.ORANGE, "moves": UiKit.BLUE,
	"options": UiKit.GREY, "quit": Color("3a3a42"), "profile": Color("6a4bb8"), "ranked": UiKit.GREEN}
## Tiles of the main menu: [x, y, w, h] in the 1920 × 1080 space, x
## measured on the wall's base line (TILE_BASE). All their sides lean on that same line, so
## the gaps between tiles stay the same from top to bottom whatever their height.
const TILE_BASE := 840.0
const MAIN_TILES := [[70, 150, 760, 690], [870, 150, 520, 330], [1430, 150, 300, 330],
	[870, 510, 520, 330], [1430, 510, 300, 150], [1430, 690, 300, 150]]
## The color of each division (badge, bar and the ranking's names).
const DIVISION_COLOR := {"Bronze": Color("c27a3b"), "Silver": Color("b9c0cc"), "Gold": Color("ffd23f"), "Platinum": Color("4fd1c5"),
	"Diamond": Color("5ab4ff"), "Master": Color("c97bff")}
## Credits at the bottom of the main menu, small. Cobblemon's assets are CC BY-NC 3.0:
## the team, the license and the non-profit nature are named.
const CREDITS := ["Created by xjoje6. Made with Godot Engine.",
	"Models, animations, effects, sounds and battle UI: the Cobblemon team (CC BY-NC 3.0, adapted)",
	"Music: Pokémon arrangements by The Noble Demon, used with credit as permitted by the artist. Original compositions by GAME FREAK.",
	"Trainer sprites from the Pokémon games, via Pokémon Showdown. Full credits in CREDITS.txt.",
	"Non-profit fan project. Pokémon belongs to Nintendo, Creatures Inc., GAME FREAK and The Pokémon Company."]

var m: Menu
var u := UiKit.new()
## What the mouse can point at, gathered while drawing: {kind, i, rect} in screen pixels,
## the last drawn on top.
var zones: Array = []
var _on := {}                    # eased highlight of each element (0 to 1)
var _want := {}                  # where each one is going
var _t := 0.0
var _stage_tex := {}


func step(delta: float) -> void:
	_t += delta
	for key in _on.keys():
		_on[key] = move_toward(_on[key], _want.get(key, 0.0), delta * 7.0)


## Eased highlight: "want" is where it is going; returns where it is now.
func on(key: String, want: bool) -> float:
	_want[key] = 1.0 if want else 0.0
	if not _on.has(key):
		_on[key] = 1.0 if want else 0.0
	return _on[key]


func _stage_picture(id: String) -> Texture2D:
	if not _stage_tex.has(id):
		var path := "res://gui/stages/%s.png" % id
		_stage_tex[id] = load(path) if ResourceLoader.exists(path) else null
	return _stage_tex[id]


# ---------------------------------------------------------------- frame

func draw(h: Hud) -> void:
	u.begin(h._c)
	zones.clear()
	u.floor_hatch(_t)
	match m.screen:
		"title":
			_title()
		"nick":
			_nick()
		"account":
			_account()
		"room":
			_room()
		"replays":
			_replays()
		"draft":
			_draft()
		"main":
			_header(tr("Menu"), ITEM_COLOR.get(Menu.MAIN_MENU[m.cursor][0], UiKit.RED))
			_tiles(Menu.MAIN_MENU, MAIN_TILES)
			_profile_badge()
			_credits()
			u.hints([[Controls.glyph("jump"), tr("Choose")], [Controls.glyph("menu_back"), tr("Back")]])
		"ranked":
			_ranked()
		"selection":
			_selection()
		"moves":
			_moves()
		"options":
			_options()
		"profile":
			_profile()
		"vs":
			_vs()
	if not m.confirm.is_empty():
		_confirm()


## Black slanted block with the screen's name, a color edge sliding in with it.
func _header(text: String, col: Color) -> void:
	var k := UiKit.ease(m.enter_t / 0.3)
	var x := lerpf(-900.0, -80.0, k)
	u.slant(x, 30.0, 840.0, 92.0, UiKit.DARK)
	u.slant(x + 840.0, 30.0, 16.0, 92.0, col)
	u.title(x + 170.0, 42.0, text.to_upper(), 64.0, UiKit.INK, -1, 600.0)


# ---------------------------------------------------------------- title

func _title() -> void:
	var k := UiKit.ease(m.enter_t / 0.6)
	u.slant(lerpf(-1600.0, -300.0, k), 330.0, 1500.0, 190.0, UiKit.RED)
	u.slant(lerpf(-1800.0, -300.0, k), 532.0, 1260.0, 26.0, UiKit.YELLOW)
	u.title(150.0, 336.0, "POKEBRAWL", 176.0, UiKit.INK)
	if Menu.version().begins_with("demo"):
		u.title(156.0, 574.0, "DEMO", 40.0, UiKit.YELLOW)
	u.tex(m.render("title", m.choice.p1, Vector2i(760, 820), 0.6), 1080.0, 160.0, 760.0, 820.0)
	var a := 0.7 + 0.3 * sin(_t * TAU * 0.5)
	u.text(156.0, 800.0, tr("%s to start") % Controls.glyph("jump"), 34.0, Color(UiKit.YELLOW, a), u.heavy)
	# The demo says so under the name; a numbered version, in the corner.
	if not Menu.version().begins_with("demo"):
		u.text(1860.0, 1030.0, "v" + Menu.version(), 22.0, UiKit.SOFT, u.body, 1)


# ---------------------------------------------------------------- tile menus

## A wall of tiles of different sizes in their own colors, Smash style. The highlighted one
## grows a little and gets a white frame; the others darken. Under them, what it does.
func _tiles(list: Array, tiles: Array) -> void:
	for i in mini(list.size(), tiles.size()):
		var id: String = list[i][0]
		var r: Array = tiles[i]
		var delay := UiKit.ease((m.enter_t - i * 0.05) / 0.3)
		var x: float = r[0] + (1.0 - delay) * 120.0
		var y: float = r[1]
		var w: float = r[2]
		var hgt: float = r[3]
		var o := on(m.screen + id, i == m.cursor)
		var col: Color = ITEM_COLOR.get(id, UiKit.GREY)
		var grow := 10.0 * o
		if o > 0.01:
			_tile(x, y, w, hgt, grow + 6.0 * o, UiKit.INK)
		_tile(x, y, w, hgt, grow, col.darkened(0.45 * (1.0 - o)))
		_tile_art(id, x, y, w, hgt, o)
		zone(m.screen, i, _tile_x(x, y + hgt), y, w + (y + hgt - y) * UiKit.SLANT, hgt)
		var size := 92.0 if hgt > 500.0 else (64.0 if hgt > 200.0 else 44.0)
		u.title(_tile_x(x, y + hgt - 30.0) + 36.0, y + hgt - size - 30.0, tr(list[i][1]).to_upper(), size, UiKit.INK, -1, w - 90.0)
	# What the highlighted tile does, under the wall.
	var desc: String = list[m.cursor][2]
	if desc != "":
		u.text_fit(70.0, 880.0, tr(desc), 1780.0, 30.0, UiKit.INK, u.bold)
	if m.message != "":
		var mw := minf(u.width(m.message, 26.0, u.bold), 1700.0)
		u.slant(70.0, 926.0, mw + 60.0, 48.0, UiKit.RED)
		u.text_fit(100.0, 936.0, m.message, 1700.0, 26.0, UiKit.INK, u.bold)


## A tile whose sides lean on the wall's base line, "grow" bigger on every side.
func _tile(x: float, y: float, w: float, hgt: float, grow: float, col: Color) -> void:
	var y0 := y - grow
	var y1 := y + hgt + grow
	u.c.draw_colored_polygon(PackedVector2Array([u.p(_tile_x(x, y0) - grow, y0), u.p(_tile_x(x, y0) + w + grow, y0),
		u.p(_tile_x(x, y1) + w + grow, y1), u.p(_tile_x(x, y1) - grow, y1)]), col)


## The left side of a tile at height at_y.
func _tile_x(x: float, at_y: float) -> float:
	return x + (TILE_BASE - at_y) * UiKit.SLANT


## What each tile shows besides its name.
func _tile_art(id: String, x: float, y: float, w: float, _hgt: float, o: float) -> void:
	match id:
		"combat":
			u.tex(m.render("menu_b", m.choice.p2, Vector2i(300, 340), -0.5), _tile_x(x, y + 230.0) + 10.0, y + 60.0, 300.0, 340.0, Color(1, 1, 1, 0.35 + 0.65 * o))
			u.tex(m.render("menu_a", m.choice.p1, Vector2i(420, 470), 0.5), _tile_x(x, y + 300.0) + w - 430.0, y + 10.0, 420.0, 470.0)
		"moves":
			var lo := Loadout.saved(m.choice.p1)
			var ix := _tile_x(x, y + 90.0) + w - 70.0
			for mv in lo.moves:
				u.type_icon(Moves.DATA[mv].type, ix - 10.0, y + 30.0, 56.0, 0.5 + 0.5 * o)
				ix -= 66.0
		"ranked":
			var rating = m.main.ranked.me.get("rating", "")
			u.title(_tile_x(x, y + 150.0) + w - 50.0, y + 30.0, str(int(rating)) if rating != "" else "RATED", 150.0, Color(1, 1, 1, 0.16), 1)


func _credits() -> void:
	var y := 1034.0 - CREDITS.size() * 24.0
	for i in CREDITS.size():
		u.text(70.0, y, tr(CREDITS[i]), 17.0, Color(UiKit.INK, 0.6 if i == 0 else 0.4), u.body)
		y += 24.0


## A dark block of text lines ("!" in front marks a warning, in red).
func _card(x: float, y: float, w: float, lines: Array, col: Color) -> void:
	var hgt := 50.0
	for ln in lines:
		hgt += u.wrap_lines(str(ln).trim_prefix("!"), w - 110.0, 30.0, u.bold).size() * 39.0 + 10.0
	u.slant(x, y, w, hgt, UiKit.PANEL, UiKit.TALL)
	u.slant(x, y, 14.0, hgt, col, UiKit.TALL)
	var ly := y + 26.0
	for ln in lines:
		var text: String = ln
		var c := UiKit.INK
		if text.begins_with("!"):
			text = text.substr(1)
			c = UiKit.RED.lightened(0.25)
		ly = u.para(u.edge(x, y, hgt, ly, UiKit.TALL) + 50.0, ly, text, w - 110.0, 30.0, c, u.bold) + 10.0


## Ranked: your rating and place on the left, the top of the ranking on the right, and
## under your card the button to look for a rival (or how the search is going).
func _ranked() -> void:
	var r: Ranked = m.main.ranked
	_header(tr("Ranked"), UiKit.ORANGE)
	var dots := ".".repeat(int(_t * 2.0) % 4)
	# Your card.
	u.slant(150.0, 180.0, 760.0, 430.0, UiKit.PANEL, UiKit.TALL)
	u.slant(150.0, 180.0, 14.0, 430.0, UiKit.ORANGE, UiKit.TALL)
	u.text(220.0, 205.0, tr("TRAINER"), 24.0, UiKit.SOFT, u.bold)
	u.title(220.0, 235.0, str(r.me.get("name", "...")), 64.0, UiKit.INK, -1, 620.0)
	_rating_block(r)
	if not r.me.is_empty():
		var rank: int = int(r.me.get("rank", 0))
		var line := tr("%d wins, %d losses") % [int(r.me.wins), int(r.me.losses)]
		if rank > 0 and int(r.me.wins) + int(r.me.losses) > 0:
			line = tr("Rank %d") % rank + "   " + line
		u.text_fit(220.0, 535.0, line, 640.0, 30.0, UiKit.INK, u.bold)
		var left: int = r.season_left()
		if left >= 0:
			var s: Dictionary = r.me.season
			var when := tr("%d d %d h") % [left / 86400, left % 86400 / 3600] if left >= 86400 else tr("%d h %d min") % [left / 3600, left % 3600 / 60]
			var last := str(r.me.get("last_division", ""))
			var text := tr("Season %s ends in %s") % [str(s.get("name", "")), when]
			if last != "":
				text += "   " + tr("Last season: %s") % tr(last)
			u.text_fit(220.0, 577.0, text, 660.0, 22.0, UiKit.SOFT, u.bold)
	# The ranking.
	u.slant(950.0, 180.0, 830.0, 640.0, UiKit.PANEL, UiKit.TALL)
	u.slant(950.0, 180.0, 14.0, 640.0, UiKit.YELLOW, UiKit.TALL)
	u.text(1020.0, 200.0, tr("TOP PLAYERS"), 24.0, UiKit.SOFT, u.bold)
	if r.board.is_empty():
		u.text(1020.0, 270.0, tr("Nobody has played a ranked match yet."), 28.0, UiKit.SOFT, u.bold)
	for i in mini(r.board.size(), 10):
		var p: Dictionary = r.board[i]
		var ry := 245.0 + i * 55.0
		if int(p.get("id", -1)) == int(r.me.get("id", -2)):
			u.rect(990.0, ry - 4.0, 760.0, 48.0, Color(UiKit.ORANGE, 0.3))
		u.text(1020.0, ry, "%d" % int(p.rank), 30.0, UiKit.SOFT, u.heavy)
		u.text_fit(1100.0, ry, str(p.name), 330.0, 30.0, UiKit.INK, u.bold)
		var dv := str(p.get("division", ""))
		if dv != "":
			u.text(1450.0, ry + 4.0, tr(dv), 24.0, DIVISION_COLOR.get(dv, UiKit.SOFT), u.heavy)
		u.text(1730.0, ry, str(int(p.rating)), 30.0, UiKit.YELLOW, u.heavy, 1)
	# The action.
	var y := 650.0
	match r.state:
		"idle":
			if r.loading:
				_card(150.0, y, 760.0, [tr("Connecting to the ranking server") + dots], UiKit.ORANGE)
			elif r.can_search():
				u.slant(150.0, y, 760.0, 110.0, UiKit.ORANGE.lerp(UiKit.YELLOW, 0.2 * (0.5 + 0.5 * sin(_t * TAU * 0.6))))
				zone("ranked", 0, 150.0, y, 760.0, 110.0)
				u.title(530.0, y + 22.0, tr("FIND MATCH"), 64.0, UiKit.INK, 0, 700.0)
				u.slant(150.0, y + 125.0, 760.0, 64.0, UiKit.PANEL_HI)
				zone("friend", 0, 150.0, y + 125.0, 760.0, 64.0)
				u.text(530.0, y + 140.0, tr("F4  PLAY WITH A FRIEND (NO RATING)"), 28.0, UiKit.INK, u.heavy, 0)
				u.text(340.0, y + 84.0, tr("F8  DRAFT: %s") % (tr("ON") if r.draft_pref else tr("OFF")), 22.0, UiKit.DARK, u.heavy, 0)
				zone("draftpref", 0, 150.0, y + 80.0, 380.0, 30.0)
				u.text(720.0, y + 84.0, tr("F10  2 VS 2: %s") % (tr("ON") if r.team_pref else tr("OFF")), 22.0, UiKit.DARK, u.heavy, 0)
				zone("teampref", 0, 530.0, y + 80.0, 380.0, 30.0)
				for k in 2:
					u.slant(150.0 + k * 390.0, y + 205.0, 370.0, 56.0, UiKit.PANEL_HI)
					zone("replays", k, 150.0 + k * 390.0, y + 205.0, 370.0, 56.0)
					u.text(335.0 + k * 390.0, y + 218.0, tr("F6  MY REPLAYS") if k == 0 else tr("F7  WATCH LIVE"), 24.0, UiKit.INK, u.heavy, 0)
		"searching":
			var crowd := tr("%d players are searching") % r.in_queue if r.in_queue > 1 else tr("You are the only one searching: another player has to look for a match too.")
			if r.room_code != "":
				if r.room_size == 4:
					_card(150.0, y, 760.0, [tr("Your 2 vs 2 room: %s") % r.room_code, tr("Three friends type this code (Friendly match, Join): %d / 4 here") % maxi(r.room_players, 1) + dots, tr("%d s") % int(r.waited)], UiKit.BLUE)
				else:
					_card(150.0, y, 760.0, [tr("Your room: %s") % r.room_code, tr("Tell your friend this code (Friendly match, Join). Waiting for them") + dots, tr("%d s") % int(r.waited)], UiKit.BLUE)
			elif r.room_size == 4 and r.friendly:
				_card(150.0, y, 760.0, [tr("In the 2 vs 2 room") + dots, tr("%d / 4 players here: the match starts when it is full.") % maxi(r.room_players, 1)], UiKit.BLUE)
			elif r.team_pref:
				_card(150.0, y, 760.0, [tr("Searching for a 2 vs 2") + dots, tr("%d s") % int(r.waited), tr("Four players are needed: %d searching now.") % maxi(r.in_queue, 1)], UiKit.ORANGE)
			else:
				_card(150.0, y, 760.0, [tr("Searching for a rival") + dots, tr("%d s") % int(r.waited), tr("A rival is ready: waiting for a free game server.") if r.busy else crowd], UiKit.ORANGE)
		"connecting":
			var rival := str(r.opponent.get("name", "?"))
			var lines2: Array = [(tr("Rival found: %s (%d)") % [rival, int(r.opponent.get("rating", 0))]) if not bool(r.opponent.get("calibrating", false))
				else tr("Rival found: %s (placement games)") % rival]
			var net: Net = m.main.net
			if r.team_match:
				lines2 = [tr("Team found: you and %s") % str(r.allies[0].get("name", "?")) if not r.allies.is_empty() else tr("Team found"),
					tr("against %s and %s") % [str(r.enemies[0].get("name", "?")), str(r.enemies[1].get("name", "?"))] if r.enemies.size() >= 2 else ""]
			if r.team_match:
				lines2.append(tr("Connecting to the game server") + dots)
				if r.connecting_for() > 6.0 and not r.relay_ok():
					lines2.append("!" + tr("The game server does not answer on UDP: its UDP port may be closed."))
			elif r.match_mode() == "relay":
				# Through the ranking server: nothing to open anywhere.
				lines2.append(tr("Connecting through the PokeBrawl server") + dots)
				if r.connecting_for() > 6.0 and not r.relay_ok():
					lines2.append("!" + tr("The game server does not answer on UDP: its UDP port may be closed."))
			elif r.match_role() == "host":
				lines2.append(tr("Waiting for %s to connect") % rival + dots)
				if net and net.upnp_testing:
					lines2.append(tr("Opening port 7777 on the router") + dots)
				elif net and net.upnp_ok:
					lines2.append(tr("Port 7777 open on the router."))
				else:
					lines2.append("!" + tr("The router did not open port 7777 (UDP): your rival may not be able to connect."))
			else:
				lines2.append(tr("Joining %s") % r.match_host_ip() + dots)
			_card(150.0, y, 760.0, lines2, UiKit.GREEN)
		"playing":
			_card(150.0, y, 760.0, [tr("Connected. Pick your Pokémon.")], UiKit.GREEN)
	var lines: Array = []
	if not r.result.is_empty() and r.state == "idle":
		lines.append((tr("Victory") if r.result.won else tr("Defeat")) + "   " + ("%+d" % int(r.result.delta)))
	if r.notice != "" and r.state == "idle":
		lines.append(r.notice)
	if not lines.is_empty():
		# Under the button when there is one, otherwise where the status card would be.
		_card(150.0, 940.0 if r.can_search() else y, 760.0, lines,
			UiKit.RED if r.notice.begins_with("!") else UiKit.GREEN)
	if r.state in ["idle", "searching"] and r.logged_in() and not r.loading:
		u.slant(700.0, 192.0, 190.0, 44.0, UiKit.PANEL_HI)
		zone("logout", 0, 700.0, 192.0, 190.0, 44.0)
		u.text(795.0, 198.0, tr("F2  Log out"), 24.0, UiKit.INK, u.bold, 0)
		if not r.me.is_empty() and not bool(r.me.get("has_password", true)):
			u.slant(950.0, 850.0, 830.0, 100.0, UiKit.YELLOW.lerp(UiKit.ORANGE, 0.3))
			zone("secure", 0, 950.0, 850.0, 830.0, 100.0)
			u.text(1365.0, 862.0, tr("F3  SECURE YOUR ACCOUNT"), 34.0, UiKit.DARK, u.heavy, 0)
			u.text_fit(1365.0, 908.0, tr("Add an email and a password: you will keep it on any computer."), 780.0, 22.0, UiKit.DARK, u.bold, 0)
	if r.state == "idle":
		u.hints([[Controls.glyph("jump"), tr("Find match") if r.can_search() else tr("Retry")], [Controls.glyph("menu_back"), tr("Back")]])
	else:
		u.hints([[Controls.glyph("menu_back"), tr("Cancel")]])


## The card's big number: the rating under a division badge and the way to the next division;
## while still calibrating, the placement games instead (the rating stays hidden).
func _rating_block(r: Ranked) -> void:
	if r.me.is_empty():
		u.text(220.0, 335.0, tr("RATING"), 24.0, UiKit.SOFT, u.bold)
		u.title(220.0, 360.0, "----", 140.0, UiKit.YELLOW, -1, 620.0)
		return
	if r.calibrating():
		var done := int(r.me.get("placement", 0))
		var of := int(r.me.get("placement_of", 10))
		u.text(220.0, 335.0, tr("PLACEMENT"), 24.0, UiKit.SOFT, u.bold)
		u.title(220.0, 360.0, "%d/%d" % [done, of], 140.0, UiKit.YELLOW, -1, 620.0)
		for i in of:
			u.rect(220.0 + i * 62.0, 510.0, 54.0, 12.0, UiKit.YELLOW if i < done else Color(UiKit.INK, 0.18))
		return
	var info = r.me.get("division_info")
	var name := str(r.me.get("division", ""))
	var col: Color = DIVISION_COLOR.get(name, UiKit.YELLOW)
	u.text(220.0, 335.0, tr("RATING"), 24.0, UiKit.SOFT, u.bold)
	u.slant(560.0, 330.0, 320.0, 44.0, col)
	u.text(720.0, 336.0, tr(name).to_upper(), 30.0, UiKit.DARK, u.heavy, 0)
	u.title(220.0, 360.0, str(int(r.me.get("rating", 0))), 140.0, UiKit.YELLOW, -1, 320.0)
	if info is Dictionary and str(info.get("next", "")) != "":
		var p := float(info.get("progress", 0.0))
		u.rect(220.0, 510.0, 660.0, 12.0, Color(UiKit.INK, 0.18))
		u.rect(220.0, 510.0, 660.0 * p, 12.0, col)
		u.text(880.0, 480.0, tr("%s at %d") % [tr(str(info.next)), int(info.next_at)], 22.0, UiKit.SOFT, u.bold, 1)
	elif info is Dictionary:
		u.rect(220.0, 510.0, 660.0, 12.0, col)


## The window asked the first time: type your nickname and that is all. The keyboard of the
## Profile screen is under it (keyboard, pad and mouse all work).
func _nick() -> void:
	var col := UiKit.YELLOW
	_header(tr("Welcome"), UiKit.RED)
	var opt: Settings = m.main.options
	var x := 425.0
	u.slant(x, 170.0, 1070.0, 170.0, UiKit.PANEL, UiKit.TALL)
	u.slant(x, 170.0, 14.0, 170.0, col, UiKit.TALL)
	u.text(u.edge(x, 170.0, 170.0, 190.0, UiKit.TALL) + 44.0, 188.0, tr("CHOOSE YOUR NICKNAME"), 24.0, UiKit.SOFT, u.bold)
	var name: String = opt.player_name
	var ty := 228.0
	var tx := u.edge(x, 170.0, 170.0, ty + 60.0, UiKit.TALL) + 44.0
	u.title(tx, ty, name, 72.0, UiKit.INK, -1, 960.0)
	var cw := u.width(name, 72.0, u.heavy)
	u.rect(tx + 10.0 + cw, ty + 76.0, 36.0, 8.0, Color(UiKit.YELLOW, 0.6 + 0.4 * sin(_t * TAU * 0.9)))
	if m.message != "":
		u.text_fit(x + 30.0, 352.0, m.message, 1000.0, 26.0, UiKit.RED.lightened(0.25), u.bold)
	else:
		u.text_fit(x + 30.0, 352.0, tr("Other players will see it. Enter to continue; you can change it later in Profile."), 1000.0, 24.0, UiKit.SOFT, u.bold)
	_name_keyboard(col, x, 420.0)
	u.hints([[Controls.glyph("jump"), tr("Press")], [Controls.glyph("menu_back"), tr("Delete")]])


## The draft: the roster as a grid. In the ban stage you choose a Pokémon your rival may not use, then the
## players take turns picking one; what is banned or picked is crossed out.
func _draft() -> void:
	var d: Dictionary = m.draft
	var stage := str(d.get("stage", "wait"))
	_header(tr("Draft"), UiKit.ORANGE)
	var slot: int = m.main.net.slot if m.main.net is ArenaClient else 0
	var action: String = m.draft_action()
	var left := int(ceilf(m.draft_left()))
	var line := tr("Waiting for your rival to connect") + ".".repeat(int(_t * 2.0) % 4)
	match stage:
		"ban":
			line = tr("BAN: choose a Pokémon your rival cannot use (%d s)") % left if action == "ban" else tr("Ban made. Waiting for your rival (%d s)") % left
		"pick":
			line = tr("YOUR PICK: choose your Pokémon (%d s)") % left if action == "pick" else tr("Your rival is picking (%d s)") % left
		"done":
			line = tr("Draft complete")
	u.slant(150.0, 170.0, 1500.0, 70.0, UiKit.ORANGE if action != "" else UiKit.PANEL)
	u.title(900.0, 176.0, line.to_upper(), 40.0, UiKit.DARK if action != "" else UiKit.INK, 0, 1440.0)
	var list: Array = m.pokemon_list()
	var cols: int = Menu.COLUMNS
	var tw := 292.0
	var th := 88.0
	for i in list.size():
		var sp: String = list[i]
		var tx := 150.0 + (i % cols) * (tw + 10.0)
		var ty := 262.0 + (i / cols) * (th + 10.0)
		var here: bool = i == m.draft_cursor
		var o := on("dr%d" % i, here)
		var col := UiKit.PANEL
		var tag := ""
		if d.get("bans", [null, null]).has(sp):
			col = UiKit.RED.darkened(0.45)
			tag = tr("BANNED")
		elif d.get("picks", [null, null]).has(sp):
			var mine: bool = str(d.picks[slot]) == sp
			col = UiKit.GREEN.darkened(0.2) if mine else UiKit.BLUE.darkened(0.2)
			tag = tr("YOURS") if mine else tr("RIVAL")
		elif m.draft_my_ban == sp and stage == "ban":
			col = UiKit.ORANGE.darkened(0.3)
			tag = tr("YOUR BAN")
		u.slant(tx, ty, tw, th, col.lerp(UiKit.INK, 0.25 * o))
		zone("dpick", i, tx, ty, tw, th)
		u.text_fit(tx + 26.0, ty + 14.0, tr(Roster.POKEMON[sp].display_name), tw - 50.0, 30.0, UiKit.INK, u.heavy)
		if tag != "":
			u.text(tx + 26.0, ty + 54.0, tag, 22.0, Color(UiKit.INK, 0.8), u.bold)
	u.hints([[Controls.glyph("jump"), tr("Ban") if action == "ban" else (tr("Pick") if action == "pick" else tr("Wait"))], [Controls.glyph("menu_back"), tr("Leave")]])


## Replays: the player's own latest matches, or the ones being played now (a few seconds behind).
func _replays() -> void:
	_header(tr("Replays"), UiKit.BLUE)
	for i in 2:
		var here: bool = m.rp_tab == i
		var tx := 150.0 + i * 420.0
		u.slant(tx, 180.0, 400.0, 60.0, UiKit.BLUE if here else UiKit.PANEL)
		zone("replays", i, tx, 180.0, 400.0, 60.0)
		u.title(tx + 200.0, 186.0, tr("MY MATCHES") if i == 0 else tr("LIVE NOW"), 36.0, UiKit.INK, 0, 380.0)
	var rows: Array = m.rp_rows()
	var r: Ranked = m.main.ranked
	if m.main.net is ReplayPlayer:
		_card(150.0, 280.0, 1000.0, [tr("Getting the replay ready") + ".".repeat(int(_t * 2.0) % 4)], UiKit.BLUE)
		u.hints([[Controls.glyph("menu_back"), tr("Cancel")]])
		return
	if r.replays_loading:
		_card(150.0, 280.0, 1000.0, [tr("Loading") + ".".repeat(int(_t * 2.0) % 4)], UiKit.BLUE)
	elif rows.is_empty():
		_card(150.0, 280.0, 1400.0, [tr("Nobody is playing right now.") if m.rp_tab == 1 else tr("Your matches played on the ranked server show up here (the last ones, for a week).")], UiKit.BLUE)
	for i in mini(rows.size(), 10):
		var row: Dictionary = rows[i]
		var ry := 270.0 + i * 70.0
		var on_it: bool = i == m.rp_cursor
		var o := on("rp%d" % i, on_it)
		u.slant(150.0, ry, 1500.0, 60.0, UiKit.PANEL.lerp(UiKit.BLUE, 0.5 * o))
		zone("rprow", i, 150.0, ry, 1500.0, 60.0)
		if m.rp_tab == 1:
			u.text_fit(190.0, ry + 12.0, "%s  vs  %s" % [str(row.host), str(row.guest)], 900.0, 32.0, UiKit.INK, u.heavy)
			u.text(1560.0, ry + 14.0, tr("rating %d") % int(row.rating) + ("  " + tr("friendly") if row.get("friendly", false) else ""), 26.0, UiKit.SOFT, u.bold, 1)
		else:
			u.text_fit(190.0, ry + 12.0, tr("vs %s") % str(row.opponent), 700.0, 32.0, UiKit.INK, u.heavy)
			var res := tr("Victory") if row.get("won") == true else (tr("Defeat") if row.get("won") == false else tr("..."))
			u.text(1000.0, ry + 14.0, res, 28.0, UiKit.YELLOW if row.get("won") == true else UiKit.SOFT, u.heavy)
			u.text(1560.0, ry + 14.0, Time.get_datetime_string_from_unix_time(int(row.when), true).left(16) + ("  " + tr("friendly") if row.get("friendly", false) else ""), 24.0, UiKit.SOFT, u.bold, 1)
	u.hints([[Controls.glyph("jump"), tr("Watch")], [Controls.glyph("move_left"), tr("Mine / Live")], [Controls.glyph("menu_back"), tr("Back")]])


## Friendly match: create a private room (you get a code) or join a friend's with their code.
## Nobody's rating changes.
func _room() -> void:
	_header(tr("Friendly match"), UiKit.BLUE)
	var y := 190.0
	var o0 := on("room_create", m.room_focus == 0)
	u.slant(150.0, y, 760.0, 430.0, UiKit.PANEL.lerp(UiKit.BLUE, 0.35 * o0), UiKit.TALL)
	u.slant(150.0, y, 14.0, 430.0, UiKit.BLUE, UiKit.TALL)
	zone("roomcreate", 0, 150.0, y, 760.0, 430.0)
	u.text(220.0, y + 28.0, tr("YOU HAVE A FRIEND NEARBY"), 24.0, UiKit.SOFT, u.bold)
	u.title(530.0, y + 150.0, tr("CREATE A ROOM"), 80.0, UiKit.INK, 0, 680.0)
	u.text_fit(530.0, y + 280.0, tr("You get a code. Your friend types it here and you play at once."), 660.0, 28.0, UiKit.SOFT, u.bold, 0)
	u.text(530.0, y + 342.0, tr("F8  DRAFT (BAN AND PICK): %s") % (tr("ON") if m.room_draft else tr("OFF")), 26.0, UiKit.YELLOW if m.room_draft else UiKit.SOFT, u.heavy, 0)
	u.text(530.0, y + 382.0, tr("F10  2 VS 2, FOUR PLAYERS: %s") % (tr("ON") if m.room_team else tr("OFF")), 26.0, UiKit.YELLOW if m.room_team else UiKit.SOFT, u.heavy, 0)
	var o1 := on("room_join", m.room_focus == 1)
	u.slant(950.0, y, 830.0, 430.0, UiKit.PANEL.lerp(UiKit.BLUE, 0.35 * o1), UiKit.TALL)
	u.slant(950.0, y, 14.0, 430.0, UiKit.BLUE, UiKit.TALL)
	zone("roomcode", 0, 950.0, y, 830.0, 300.0)
	u.text(1020.0, y + 28.0, tr("YOUR FRIEND GAVE YOU A CODE"), 24.0, UiKit.SOFT, u.bold)
	for i in 5:
		var cx := 1030.0 + i * 140.0
		var ch: String = m.room_input.substr(i, 1)
		var here: bool = m.room_focus == 1 and i == mini(m.room_input.length(), 4)
		u.slant(cx, y + 100.0, 120.0, 150.0, UiKit.DARK.lerp(UiKit.BLUE, 0.4 if here else 0.0))
		u.title(cx + 60.0, y + 118.0, ch if ch != "" else "·", 100.0, UiKit.INK if ch != "" else Color(UiKit.INK, 0.25), 0, 110.0)
	var ready: bool = m.room_input.length() == 5
	u.slant(1030.0, y + 320.0, 700.0, 80.0, UiKit.BLUE if ready and not m.room_busy else UiKit.PANEL_HI)
	zone("roomgo", 0, 1030.0, y + 320.0, 700.0, 80.0)
	u.title(1380.0, y + 330.0, (tr("JOIN") if not m.room_busy else tr("WAIT") + ".".repeat(int(_t * 2.0) % 4)), 52.0, UiKit.INK, 0, 640.0)
	if m.room_msg != "":
		_card(150.0, 660.0, 1630.0, ["!" + m.room_msg], UiKit.RED)
	else:
		u.text_fit(150.0, 665.0, tr("A friendly match does not change anyone's rating. Both of you need the same version of the game."), 1630.0, 26.0, UiKit.SOFT, u.bold)
	u.hints([[tr("Tab"), tr("Create / Code")], [tr("Enter"), tr("Go")], [tr("Esc"), tr("Back")]])


## Log in, create an account (name, email, password) or, for an account made before logins
## existed, add an email and a password. Typed on the keyboard; fields and buttons click too.
func _account() -> void:
	var mode: String = m.acc_mode
	var secure := mode == "secure"
	_header(tr("Secure your account") if secure else tr("Account"), UiKit.ORANGE)
	var x := 425.0
	var y := 170.0
	if not secure:
		for i in 2:
			var here: bool = (mode == "register") == (i == 1)
			var tx := x + i * 540.0
			u.slant(tx, y, 530.0, 70.0, UiKit.ORANGE if here else UiKit.PANEL)
			zone("acctab", i, tx, y, 530.0, 70.0)
			u.title(tx + 265.0, y + 8.0, tr("CREATE ACCOUNT") if i == 1 else tr("LOG IN"), 40.0, UiKit.DARK if here else UiKit.INK, 0, 480.0)
		y += 100.0
	var fields: Array = m.acc_fields()
	var labels := {"name": tr("ACCOUNT NAME") if mode == "register" else tr("ACCOUNT NAME OR EMAIL"), "email": tr("EMAIL"),
		"password": tr("PASSWORD"), "password2": tr("REPEAT THE PASSWORD")}
	for i in fields.size():
		var key: String = fields[i]
		var here: bool = i == m.acc_field
		var o := on("acc_%d" % i, here)
		var by := y + i * 118.0
		u.slant(x, by, 1070.0, 104.0, UiKit.PANEL.lerp(UiKit.ORANGE, 0.3 * o))
		u.slant(x, by, 14.0, 104.0, UiKit.ORANGE if here else UiKit.SOFT)
		zone("accfield", i, x, by, 1070.0, 104.0)
		u.text(x + 44.0, by + 10.0, labels[key], 22.0, UiKit.SOFT, u.bold)
		var val: String = str(m.acc[key])
		var shown := "*".repeat(val.length()) if key.begins_with("password") else val
		u.text_fit(x + 44.0, by + 40.0, shown, 960.0, 46.0, UiKit.INK, u.heavy)
		if here and not m.acc_busy:
			var cw := minf(u.width(shown, 46.0, u.heavy), 960.0)
			u.rect(x + 50.0 + cw, by + 88.0, 30.0, 6.0, Color(UiKit.YELLOW, 0.6 + 0.4 * sin(_t * TAU * 0.9)))
	var gy := y + fields.size() * 118.0 + 6.0
	var go_text := tr("SAVE") if secure else (tr("CREATE ACCOUNT") if mode == "register" else tr("LOG IN"))
	if m.acc_busy:
		go_text = tr("WAIT") + ".".repeat(int(_t * 2.0) % 4)
	u.slant(x, gy, 1070.0, 90.0, UiKit.ORANGE.lerp(UiKit.YELLOW, 0.2 * (0.5 + 0.5 * sin(_t * TAU * 0.6))))
	zone("accgo", 0, x, gy, 1070.0, 90.0)
	u.title(x + 535.0, gy + 12.0, go_text, 54.0, UiKit.DARK, 0, 1000.0)
	var note := tr("Your email is only for your account: other players never see it.") if mode != "login" else tr("No account yet? Press F2 or click Create account.")
	if secure:
		note = tr("Your account was made before passwords existed. Add them to keep it safe and to play on other computers.")
	if m.acc_msg != "":
		_card(x, gy + 110.0, 1070.0, ["!" + m.acc_msg], UiKit.RED)
	else:
		u.text_fit(x + 10.0, gy + 112.0, note, 1050.0, 24.0, UiKit.SOFT, u.bold)
	var hints: Array = [[tr("Tab"), tr("Next field")], [tr("Enter"), tr("Continue")]]
	if not secure:
		hints.append([tr("F2"), tr("Log in / Create account")])
	hints.append([tr("Esc"), tr("Back")])
	u.hints(hints)


# ---------------------------------------------------------------- selection

func _side_color(side: int) -> Color:
	if side == 0:
		return UiKit.RED
	return UiKit.BLUE if m.online else UiKit.GREY


func _selection() -> void:
	var list := m.pokemon_list()
	var title := tr("Pick your Pokémon")
	if m.sel_phase == "p2":
		title = tr("Pick the rival")
	elif m.sel_phase == "setup":
		title = tr("Get ready")
	_header(title, UiKit.ORANGE if m.ranked_room() else _side_color(1 if m.sel_phase == "p2" else 0))
	if m.ranked_room():
		_ranked_banner()
		_team_strip()
	# The stage, always at hand: its picture and name, top right.
	var st: String = m.choice.stage
	u.slant(1500.0, 30.0, 360.0, 92.0, UiKit.DARK)
	u.tex(_stage_picture(st), 1530.0, 38.0, 136.0, 76.0)
	u.text(1676.0, 44.0, tr("Stage"), 20.0, UiKit.SOFT, u.bold)
	u.text_fit(1676.0, 70.0, tr(Menu.STAGE_NAME[st]), 170.0, 30.0, UiKit.INK, u.heavy)
	var setup := on("setup_view", m.sel_phase == "setup")
	if setup < 0.999:
		_wall(list, setup)
	if setup > 0.001:
		_setup_bar(setup)
	for side in 2:
		_player_card(side)
	var items: Array = []
	if m.sel_phase == "setup":
		items = [[Controls.glyph("menu_back"), tr("Change")]] if m.online and m.me_ready \
			else [[Controls.glyph("jump"), tr("Choose")], [Controls.glyph("menu_back"), tr("Back")]]
	else:
		items = [[Controls.glyph("jump"), tr("Pick")], [Controls.glyph("menu_back"), tr("Leave") if m.online else tr("Back")]]
		if m.online and m.main.net and m.main.net.host:
			items.push_front([Controls.glyph("mov2"), tr("Stage")])
	if m.online and m.main.net:
		u.text(70.0, 1030.0, m.main.net.ping_label(), 22.0, UiKit.SOFT, u.bold)
	if m.online and m.version_mismatch():
		var warn := tr("Your rival has another version (%s, yours %s): use the same package to play.") % [
			m.rival_version if m.rival_version != "?" else tr("an old one"), Menu.version()]
		var ww := minf(u.width(warn, 26.0, u.bold), 1300.0)
		u.slant(70.0, 960.0, ww + 60.0, 48.0, UiKit.RED)
		u.text_fit(100.0, 970.0, warn, 1300.0, 26.0, UiKit.INK, u.bold)
	u.hints(items)


## The strip between the title and the stage in a ranked match: who plays whom, with their
## ratings.
func _ranked_banner() -> void:
	var r: Ranked = m.main.ranked
	var bx := 800.0
	var bw := 640.0
	u.slant(bx, 30.0, bw, 92.0, UiKit.DARK)
	u.slant(bx + bw, 30.0, 16.0, 92.0, UiKit.ORANGE)
	var ex := u.edge(bx, 30.0, 92.0, 70.0)
	u.text(ex + 22.0, 36.0, tr("RANKED"), 18.0, UiKit.ORANGE, u.heavy)
	var mid := ex + bw * 0.5
	u.title(mid - 44.0, 50.0, str(r.me.get("name", "")).to_upper(), 36.0, UiKit.INK, 1, 250.0)
	u.text(mid - 44.0, 92.0, str(int(r.me.get("rating", 0))), 22.0, UiKit.YELLOW, u.heavy, 1)
	u.title(mid, 52.0, "VS", 30.0, UiKit.ORANGE, 0)
	u.title(mid + 44.0, 50.0, str(r.opponent.get("name", "")).to_upper(), 36.0, UiKit.INK, -1, 250.0)
	u.text(mid + 44.0, 92.0, str(int(r.opponent.get("rating", 0))), 22.0, UiKit.YELLOW, u.heavy)


## The wall of portraits: one row of ten, no gaps. The highlighted one lights up in the
## color of whoever is picking; tokens mark what each side has.
func _wall(list: Array, setup: float) -> void:
	var tw := 1780.0 / list.size()
	var lift := -340.0 * UiKit.ease(setup)
	var picker := _side_color(1 if m.sel_phase == "p2" else 0)
	for i in list.size():
		var sp: String = list[i]
		var data: Dictionary = Roster.POKEMON[sp]
		var x := 70.0 + i * tw
		var y := 150.0 + lift
		var o := on("wall" + sp, i == m.cursor and m.sel_phase != "setup")
		if setup < 0.5:
			zone("wall", i, x, y, tw - 3.0, 200.0)
		u.rect(x, y, tw - 3.0, 200.0, UiKit.PANEL.lerp(UiKit.PANEL_HI, o))
		u.rect(x, y, tw - 3.0, 124.0, Color(Roster.TYPE_COLOR.get(data.types[0], UiKit.GREY), 0.22 + 0.2 * o))
		if m.portraits.has(sp):
			u.tex(m.portraits[sp], x + (tw - 3.0) * 0.5 - 76.0, y + 4.0 - 6.0 * o, 152.0, 152.0)
		for t in data.types.size():
			u.type_icon(data.types[t], x + tw - 34.0 - t * 28.0, y + 6.0, 26.0)
		u.rect(x, y + 160.0, tw - 3.0, 40.0, UiKit.DARK.lerp(picker, o))
		u.title(x + 12.0, y + 166.0, tr(data.display_name).to_upper(), 26.0, UiKit.INK, -1, tw - 30.0)
		if o > 0.01:
			u.rect(x - 4.0, y - 6.0 * o, tw + 5.0, 6.0 * o, picker)
		var tx := x + 6.0
		if sp == m.choice.p1 and (m.sel_phase != "p1" or m.me_ready):
			tx = _token(tx, y + 8.0, "1P", UiKit.RED)
		if not m.online and sp == m.choice.p2 and m.sel_phase == "setup":
			_token(tx, y + 8.0, "CPU", UiKit.GREY)
		if m.online and sp == m.rival_choice_id:
			_token(tx, y + 8.0, "2P", UiKit.BLUE)


## A 2 vs 2's selection: the three other players, each with what they have picked and whether they are ready.
func _team_strip() -> void:
	var c: Net = m.main.net
	if not (c is ArenaClient and c.players() == 4):
		return
	var r: Ranked = m.main.ranked
	var ac: ArenaClient = c
	var others: Array = []
	var ally := ac.ally_slot()
	for s in ac.enemy_slots() + [ally]:
		others.append(s)
	for i in others.size():
		var s: int = others[i]
		var is_ally: bool = s == ally
		var pk: Dictionary = m.team_picks.get(s, {})
		var nm := str(pk.get("name", ""))
		if nm == "":
			var rec: Array = r.allies if is_ally else r.enemies
			var idx := 0 if is_ally else ac.enemy_slots().find(s)
			if idx >= 0 and idx < rec.size():
				nm = str(rec[idx].get("name", "?"))
		var sp := str(pk.get("species", ""))
		var x := 440.0 + i * 360.0
		var col: Color = UiKit.GREEN if is_ally else UiKit.RED
		u.slant(x, 1008.0, 344.0, 60.0, Color(col, 0.85 if bool(pk.get("ready", false)) else 0.35))
		u.text_fit(x + 24.0, 1012.0, ("%s: %s" % [tr("ALLY") if is_ally else tr("RIVAL"), nm]).to_upper(), 290.0, 20.0, UiKit.INK, u.heavy)
		var line := tr("Choosing...")
		if sp != "" and Roster.POKEMON.has(sp):
			line = tr(Roster.POKEMON[sp].display_name) + ("  - " + tr("READY") if bool(pk.get("ready", false)) else "")
		u.text_fit(x + 24.0, 1038.0, line, 290.0, 22.0, Color(UiKit.INK, 0.85), u.bold)


func _token(x: float, y: float, label: String, col: Color) -> float:
	var w := u.width(label, 22.0, u.heavy) + 22.0
	u.slant(x, y, w, 34.0, col)
	u.text(x + 14.0, y + 5.0, label, 22.0, UiKit.INK, u.heavy)
	return x + w + 4.0


## The battle's options, in place of the wall once both are picked: the stage's picture
## with a line about it, and the options as tabs (stage, difficulty, edit moves, fight).
func _setup_bar(setup: float) -> void:
	var y := lerpf(-260.0, 150.0, UiKit.ease(setup))
	var st: String = m.choice.stage
	u.rect(70.0, y, 400.0, 200.0, UiKit.DARK)
	u.tex(_stage_picture(st), 82.0, y + 12.0, 376.0, 176.0)
	u.rect(70.0, y + 194.0, 400.0, 6.0, UiKit.RED)
	var items := m.setup_items()
	var host: bool = not m.online or (m.main.net != null and m.main.net.host)
	var x := 510.0
	var tw := (1850.0 - x - (items.size() - 1) * 20.0) / items.size()
	for i in items.size():
		var it: String = items[i]
		var o := on("tab" + it, i == m.setup_cursor and not (m.online and m.me_ready))
		var go := it in ["fight", "ready"]
		var col := UiKit.YELLOW if go else UiKit.RED
		if it == "ready" and m.me_ready:
			o = 1.0
		var bx := x + i * (tw + 20.0)
		u.slant(bx, y, tw, 200.0, UiKit.PANEL.lerp(col, o))
		zone("tab", i, bx, y, tw + 200.0 * UiKit.SLANT, 200.0)
		var ink := UiKit.DARK if go and o > 0.5 else UiKit.INK
		var label := ""
		var sub := ""
		match it:
			"stage":
				sub = tr("Stage") if host else tr("Stage (the host picks)")
				label = tr(Menu.STAGE_NAME[st])
			"diff":
				sub = tr("Difficulty")
				label = tr(Menu.DIFFICULTY_NAME[m.choice.diff])
			"build":
				sub = tr("Moves and ability")
				label = tr("Edit Pokémon")
			"fight":
				label = tr("Fight!")
			"ready":
				label = tr("Waiting for the rival") if m.me_ready else tr("Ready!")
		if sub != "":
			u.text_fit(u.edge(bx, y, 200.0, y + 44.0) + 24.0, y + 24.0, sub.to_upper(), tw - 70.0, 20.0, Color(ink, 0.7), u.bold)
		if go:
			# Fight / Ready: alone in its tab, centered both ways (the center follows the slant).
			var size := 72.0
			var cy := y + 100.0 - size * 0.62
			u.title(u.edge(bx, y, 200.0, y + 100.0) + tw * 0.5, cy, label.to_upper(), size, ink, 0, tw - 80.0)
		else:
			var ly := y + 64.0
			u.title(u.edge(bx, y, 200.0, ly + 50.0) + 20.0, ly, label.to_upper(), 46.0, ink, -1, tw - 80.0)
		if it == "stage":
			u.para(u.edge(bx, y, 200.0, y + 180.0) + 22.0, y + 128.0, tr(Menu.STAGE_TEXT[st]), tw - 90.0, 19.0, Color(ink, 0.75), u.body, 1.2, 3)
		if it in ["stage", "diff"] and (host or it == "diff") and o > 0.01:
			u.text(u.edge(bx, y, 200.0, y + 30.0) + tw - 30.0, y + 18.0, "^", 24.0, Color(ink, o), u.heavy, 1)
			u.text(u.edge(bx, y, 200.0, y + 190.0) + tw - 30.0, y + 160.0, "v", 24.0, Color(ink, o), u.heavy, 1)


## Each side's pick in a big card, Smash style: its color, the Pokémon in 3D spilling a
## little over the top, the name huge at the bottom, its ability and its four moves with
## their type symbol on the right. Online the rival's card says whether it is ready.
func _player_card(side: int) -> void:
	var left := side == 0
	var col := _side_color(side)
	var k := UiKit.ease((m.enter_t - 0.08 * side) / 0.4)
	var x := (70.0 if left else 990.0) + (1.0 - k) * (-900.0 if left else 900.0)
	var y := 400.0
	var w := 860.0
	var hgt := 600.0
	u.slant(x, y, w, hgt, col)
	u.slant(x + 16.0, y + 16.0, w - 32.0, hgt - 32.0, col.darkened(0.3))
	u.stripes(x + 30.0, y + 16.0, w - 60.0, hgt - 32.0, Color(1, 1, 1, 0.035), 44.0)
	var tag := "1P" if left else ("2P" if m.online else "CPU")
	# A ranked match names both players (their nicknames) and shows their rating.
	var ranked: bool = m.ranked_room()
	var who: Dictionary = {}
	if ranked:
		who = m.main.ranked.me if left else m.main.ranked.opponent
		tag = str(who.get("name", tag)).to_upper()
	var tsize := 44.0 if ranked else 56.0
	var tmax := 330.0 if ranked else 0.0
	if not left and m.online and m.rival_choice_id == "":
		u.title(u.edge(x, y, hgt, y + 90.0) + 30.0, y + 26.0, tag, 64.0, Color(UiKit.INK, 0.9), -1, 520.0 if ranked else 0.0)
		u.title(u.edge(x, y, hgt, y + 330.0) + 30.0, y + 250.0, tr("Choosing...").to_upper(), 80.0, Color(UiKit.INK, 0.6), -1, w - 120.0)
		return
	var sp: String = m.choice.p1 if left else m.choice.p2
	var data: Dictionary = Roster.POKEMON[sp]
	# The Pokémon, on the left half, a little over the card's top edge.
	u.tex(m.render("card%d" % side, sp, Vector2i(440, 520), 0.5 if left else -0.5), u.edge(x, y, hgt, y + 300.0) + 10.0, y - 60.0, 440.0, 520.0)
	var tag_x := u.edge(x, y, hgt, y + 92.0) + 20.0
	var tag_w := u.width(tag, tsize, u.heavy)
	if tmax > 0.0:
		tag_w = minf(tag_w, tmax)
	u.slant(tag_x, y + 22.0, tag_w + 44.0, 70.0, UiKit.DARK)
	u.title(tag_x + 22.0, y + 28.0 + (6.0 if ranked else 0.0), tag, tsize, UiKit.INK, -1, tmax)
	if ranked:
		var rt := "%d  %s" % [int(who.get("rating", 0)), tr("RATING")]
		var rw2 := u.width(rt, 22.0, u.heavy) + 36.0
		u.slant(u.edge(x, y, hgt, y + 126.0) + 20.0, y + 98.0, rw2, 36.0, Color(0, 0, 0, 0.55))
		u.text(u.edge(x, y, hgt, y + 126.0) + 38.0, y + 103.0, rt, 22.0, UiKit.YELLOW, u.heavy)
	# Right half: ability and moves, each in its own strip, stepping along the diagonal.
	var rw := 300.0
	var lo := _loadout(side)
	var ab: Dictionary = Loadout.ability(sp, lo.ability)
	var ax := u.edge(x, y, hgt, y + 92.0) + 430.0
	u.text(ax, y + 40.0, tr("Ability").to_upper(), 18.0, Color(UiKit.INK, 0.6), u.bold)
	u.text_fit(ax, y + 62.0, tr(ab.display_name), rw, 30.0, UiKit.INK, u.heavy)
	for i in lo.moves.size():
		var d: Dictionary = Moves.DATA[lo.moves[i]]
		var my: float = y + 116.0 + i * 64.0
		var rx := u.edge(x, y, hgt, my + 54.0) + 430.0
		u.slant(rx - 12.0, my, rw + 12.0, 54.0, Color(0, 0, 0, 0.28))
		u.type_icon(d.type, rx + 4.0, my + 7.0, 40.0)
		u.text_fit(rx + 54.0, my + 12.0, tr(d.display_name), rw - 70.0, 28.0, UiKit.INK, u.bold)
	# Name and types at the bottom, across the card.
	var tx := u.edge(x, y, hgt, y + hgt - 164.0) + 30.0
	for t in data.types:
		tx = u.type_tag(tx, y + hgt - 196.0, t, 20.0)
	u.title(u.edge(x, y, hgt, y + hgt - 40.0) + 24.0, y + hgt - 150.0, tr(data.display_name).to_upper(), 110.0, UiKit.INK, -1, w - 110.0)
	if not left and m.online and m.rival_ready:
		u.slant(x + w - 240.0, y + 30.0, 190.0, 54.0, UiKit.YELLOW)
		u.title(x + w - 214.0, y + 36.0, tr("Ready").to_upper(), 38.0, UiKit.DARK, -1, 150.0)


func _loadout(side: int) -> Dictionary:
	var sp: String = m.choice.p1 if side == 0 else m.choice.p2
	if side == 0:
		return m.main.my_loadout(sp)
	if m.online and not m.rival_loadout.is_empty():
		return m.rival_loadout
	return Loadout.default_for(sp)


# ---------------------------------------------------------------- moves

const RX := 930.0                # the right column of the Moves screen
const RW := 920.0


func _moves() -> void:
	_header(tr("Moves"), UiKit.BLUE)
	var list := m.pokemon_list()
	var sp := m.edit_sp
	var picking := m.edit_phase == "pokemon"
	# Left: the Pokémon, a column of strips.
	for i in list.size():
		var s: String = list[i]
		var o := on("mv" + s, s == sp)
		var y := 150.0 + i * 84.0
		var lit := o if picking else o * 0.45
		u.slant(60.0 + 18.0 * o, y, 330.0, 74.0, UiKit.PANEL.lerp(UiKit.BLUE, lit))
		zone("mvp", i, 60.0, y, 330.0 + 74.0 * UiKit.SLANT, 74.0)
		if m.portraits.has(s):
			u.tex(m.portraits[s], 70.0 + 18.0 * o, y - 2.0, 76.0, 76.0)
		u.title(156.0 + 18.0 * o, y + 20.0, tr(Roster.POKEMON[s].display_name).to_upper(), 32.0, UiKit.INK, -1, 210.0)
	# Middle: the Pokémon and its sheet.
	var data: Dictionary = Roster.POKEMON[sp]
	u.slant(430.0, 150.0, 460.0, 840.0, UiKit.PANEL, UiKit.TALL)
	u.tex(m.render("moves", sp, Vector2i(400, 380), 0.45), 450.0, 190.0, 400.0, 380.0)
	u.title(460.0, 160.0, tr(data.display_name).to_upper(), 56.0, UiKit.INK, -1, 400.0)
	var tx := 466.0
	for t in data.types:
		tx = u.type_tag(tx, 230.0, t, 18.0)
	var ry := 596.0
	for r in MoveInfo.stat_rows(sp):
		u.text_fit(466.0, ry, r[0], 120.0, 22.0, UiKit.SOFT, u.bold)
		u.meter(596.0, ry + 4.0, 200.0, 16.0, r[1], UiKit.ORANGE if r[2] >= 0.0 else UiKit.YELLOW, 10)
		if r[2] >= 0.0:
			# Its held item's share, in another color: what it would have without it.
			u.meter(596.0, ry + 4.0, 200.0, 16.0, r[2], UiKit.YELLOW, 10)
		u.text(860.0, ry, r[3], 24.0, UiKit.INK, u.heavy, 1)
		ry += 36.0
	# What the stats do not say.
	var b := MoveInfo.body(sp)
	ry += 14.0
	u.text(466.0, ry, tr("Weight"), 22.0, UiKit.SOFT, u.bold)
	u.text(860.0, ry, "%.1f kg" % b.kg, 24.0, UiKit.INK, u.heavy, 1)
	u.text_fit(466.0, ry + 28.0, tr("Hits send it ×%.2f as far") % b.knockback, 394.0, 20.0, Color(UiKit.INK, 0.75), u.body)
	ry += 66.0
	u.text(466.0, ry, tr("Dodges"), 22.0, UiKit.SOFT, u.bold)
	u.diamonds(860.0 - b.dodges * 26.0 + 8.0, ry + 4.0, b.dodges, 18.0, UiKit.INK)
	if b.air != "":
		ry += 36.0
		u.text(466.0, ry, tr("In the air"), 22.0, UiKit.SOFT, u.bold)
		u.text(860.0, ry, tr("Flies") if b.air == "flies" else tr("Levitates"), 24.0, UiKit.INK, u.heavy, 1)
	# Right: its moves and ability, or the options for a slot, or a move's details.
	var lo := Loadout.saved(sp)
	if m.details and m.shown_move() != "":
		_details(m.shown_move())
	elif m.edit_phase == "list":
		_choices(lo)
	else:
		_slots(lo)
	_restore_button()
	var items: Array = []
	match m.edit_phase:
		"pokemon":
			items = [[Controls.glyph("jump"), tr("Edit")], [Controls.glyph("menu_back"), tr("Back")]]
		"slots":
			items = [[Controls.glyph("jump"), tr("Change")], [Controls.glyph("menu_info"), tr("Details")], [Controls.glyph("menu_back"), tr("Back")]]
		"list":
			items = [[Controls.glyph("jump"), tr("Choose")], [Controls.glyph("menu_info"), tr("Details")], [Controls.glyph("menu_back"), tr("Back")]]
	u.hints(items)


## Top right of the Moves screen: back to the defaults, every Pokémon's from the list of
## Pokémon, the one being edited from its slots. Dimmed when there is nothing to restore.
func _restore_button() -> void:
	var all: bool = m.restore_all()
	var changed: bool = not (m.pokemon_list().all(Loadout.is_default) if all else Loadout.is_default(m.edit_sp))
	var w := 560.0
	var hgt := 84.0
	var x := RX + RW - w - hgt * UiKit.SLANT
	var y := 34.0
	var o := on("restore", changed)
	u.slant(x, y, w, hgt, UiKit.DARK.lerp(UiKit.PANEL_HI, o))
	u.slant(x, y, 12.0, hgt, Color(UiKit.ORANGE, 0.35 + 0.65 * o))
	zone("restore", 0, x, y, w + hgt * UiKit.SLANT, hgt)
	var ink := Color(UiKit.INK, 0.4 + 0.6 * o)
	var g := Controls.glyph("menu_extra")
	var gw := maxf(u.width(g, 22.0, u.heavy) + 18.0, 36.0)
	u.rect(x + 40.0, y + 24.0, gw, 34.0, UiKit.PANEL if o > 0.5 else UiKit.DARK)
	u.text(x + 40.0 + gw * 0.5, y + 28.0, g, 22.0, ink, u.heavy, 0)
	u.text_fit(x + 60.0 + gw, y + 12.0, tr("Restore defaults").to_upper(), w - gw - 110.0, 28.0, ink, u.heavy)
	var whose := tr("Every Pokémon") if all else tr(Roster.POKEMON[m.edit_sp].display_name)
	u.text_fit(x + 60.0 + gw, y + 48.0, whose, w - gw - 110.0, 20.0, Color(ink, ink.a * 0.7), u.bold)


func _slots(lo: Dictionary) -> void:
	for i in 5:
		var o := on("slot%d" % i, m.edit_phase != "pokemon" and i == m.edit_slot)
		var y := 150.0 + i * 150.0
		var x := RX + 18.0 * o
		zone("slot", i, RX, y, RW + 240.0 * UiKit.TALL, 132.0 if i < 4 else 240.0)
		if i < 4:
			var id: String = lo.moves[i]
			var d: Dictionary = Moves.DATA[id]
			var tc: Color = Roster.TYPE_COLOR.get(d.type, UiKit.GREY)
			u.slant(x, y, RW, 132.0, UiKit.PANEL.lerp(tc.darkened(0.2), o))
			u.slant(x, y, 16.0, 132.0, tc)
			u.type_icon(d.type, x + 40.0, y + 22.0, 64.0)
			u.title(x + 124.0, y + 18.0, tr(d.display_name).to_upper(), 46.0, UiKit.INK, -1, RW - 340.0)
			u.text_fit(x + 128.0, y + 82.0, ", ".join(MoveInfo.facts(id).slice(0, 3)), RW - 340.0, 22.0, Color(UiKit.INK, 0.75), u.body)
			# Right edge: power and cooldown, big figures.
			var pw: String = "%d" % d.power if d.get("power", 0) > 0 else "-"
			u.text(x + RW - 180.0, y + 22.0, pw, 46.0, UiKit.INK, u.heavy, 1)
			u.text(x + RW - 180.0, y + 78.0, tr("Power"), 18.0, Color(UiKit.INK, 0.6), u.bold, 1)
			u.text(x + RW - 50.0, y + 22.0, "%.1f" % Moves.cooldown(id), 46.0, UiKit.INK, u.heavy, 1)
			u.text(x + RW - 50.0, y + 78.0, tr("Cooldown"), 18.0, Color(UiKit.INK, 0.6), u.bold, 1)
		else:
			var ab: Dictionary = Loadout.ability(m.edit_sp, lo.ability)
			u.slant(x, y, RW, 240.0, UiKit.PANEL.lerp(UiKit.BLUE.darkened(0.2), o), UiKit.TALL)
			u.slant(x, y, 16.0, 240.0, UiKit.BLUE, UiKit.TALL)
			u.text(x + 46.0, y + 22.0, tr("Ability").to_upper(), 20.0, Color(UiKit.INK, 0.6), u.bold)
			u.title(x + 44.0, y + 50.0, tr(ab.display_name).to_upper(), 46.0, UiKit.INK, -1, RW - 100.0)
			u.para(x + 48.0, y + 118.0, tr(ab.text), RW - 110.0, 24.0, Color(UiKit.INK, 0.85), u.body, 1.25, 4)


## The options for a slot: a scrolling list, the equipped ones dimmed, and what the
## highlighted one does under it.
func _choices(lo: Dictionary) -> void:
	var options := m.edit_options()
	u.slant(RX, 150.0, RW, 840.0, UiKit.PANEL, UiKit.TALL)
	var head := (tr("Move %d") % (m.edit_slot + 1)) if m.edit_slot < 4 else tr("Ability")
	u.text(RX + 50.0, 166.0, head.to_upper(), 22.0, UiKit.SOFT, u.bold)
	if options.size() > Menu.EDIT_ROWS:
		u.text(RX + RW - 40.0, 166.0, "%d / %d" % [m.edit_cursor + 1, options.size()], 22.0, UiKit.SOFT, u.bold, 1)
	for k in range(m.edit_top, mini(m.edit_top + Menu.EDIT_ROWS, options.size())):
		var id: String = options[k]
		var y := 204.0 + (k - m.edit_top) * 72.0
		var sel := k == m.edit_cursor
		zone("opt", k, RX + 30.0, y, RW - 70.0 + 62.0 * UiKit.SLANT, 62.0)
		if m.edit_slot < 4:
			var d: Dictionary = Moves.DATA[id]
			var tc: Color = Roster.TYPE_COLOR.get(d.type, UiKit.GREY)
			var equipped: bool = id in lo.moves
			u.slant(RX + 30.0, y, RW - 70.0, 62.0, tc.darkened(0.15) if sel else UiKit.PANEL_HI)
			u.type_icon(d.type, RX + 46.0, y + 9.0, 44.0, 1.0 if not equipped or sel else 0.45)
			var ink := UiKit.INK if (sel or not equipped) else Color(UiKit.INK, 0.4)
			u.text_fit(RX + 104.0, y + 14.0, tr(d.display_name), RW - 380.0, 30.0, ink, u.heavy)
			if equipped and not sel:
				u.text(RX + RW - 160.0, y + 20.0, tr("Equipped"), 20.0, UiKit.SOFT, u.bold, 1)
			var pw: String = "%d" % d.power if d.get("power", 0) > 0 else "-"
			u.text(RX + RW - 60.0, y + 14.0, pw, 30.0, ink, u.heavy, 1)
		else:
			var ab: Dictionary = Loadout.ability(m.edit_sp, id)
			u.slant(RX + 30.0, y, RW - 70.0, 62.0, UiKit.BLUE if sel else UiKit.PANEL_HI)
			u.text_fit(RX + 60.0, y + 14.0, tr(ab.display_name), RW - 140.0, 30.0, UiKit.INK, u.heavy)
	var shown: String = options[m.edit_cursor] if not options.is_empty() else ""
	if shown != "":
		var text := tr(Moves.DATA[shown].desc) if m.edit_slot < 4 else tr(Loadout.ability(m.edit_sp, shown).text)
		u.para(RX + 50.0, 204.0 + Menu.EDIT_ROWS * 72.0 + 18.0, text, RW - 110.0, 24.0, UiKit.INK, u.body, 1.25, 3)


## A move's details: its games' numbers and ours, each as a meter in its type's color with
## the exact figure, then what it does and how to face it.
func _details(id: String) -> void:
	var d: Dictionary = Moves.DATA[id]
	var tc: Color = Roster.TYPE_COLOR.get(d.type, UiKit.GREY)
	u.slant(RX, 150.0, RW, 840.0, UiKit.PANEL, UiKit.TALL)
	var hx := u.edge(RX, 150.0, 840.0, 254.0, UiKit.TALL) + 16.0
	u.slant(hx, 166.0, RW - 60.0, 104.0, tc.darkened(0.15))
	u.type_icon(d.type, u.edge(hx, 166.0, 104.0, 226.0) + 26.0, 182.0, 72.0)
	u.title(u.edge(hx, 166.0, 104.0, 230.0) + 116.0, 178.0, tr(d.display_name).to_upper(), 54.0, UiKit.INK, -1, RW - 260.0)
	u.text_fit(u.edge(hx, 166.0, 104.0, 250.0) + 120.0, 236.0, ", ".join(MoveInfo.facts(id).slice(0, 2)), RW - 260.0, 20.0, Color(UiKit.INK, 0.85), u.bold)
	var y := 296.0
	for r in MoveInfo.rows(id):
		u.text_fit(RX + 50.0, y, r[0], 230.0, 24.0, UiKit.SOFT, u.bold)
		if r[1] >= 0.0:
			u.meter(RX + 300.0, y + 5.0, 360.0, 18.0, r[1], tc, 12)
		u.text_fit(RX + RW - 50.0, y, r[2], 190.0, 26.0, UiKit.INK, u.heavy, 1)
		y += 42.0
	var extra := MoveInfo.facts(id).slice(2)
	if not extra.is_empty():
		y = u.para(RX + 50.0, y + 8.0, ", ".join(extra), RW - 110.0, 22.0, UiKit.YELLOW, u.bold, 1.25, 2) + 6.0
	u.para(RX + 50.0, y + 4.0, tr(d.desc), RW - 110.0, 24.0, UiKit.INK, u.body, 1.3, 4)


# ---------------------------------------------------------------- options

func _options() -> void:
	var opts = m.main.options
	_header(tr("Options"), UiKit.GREY)
	var items: Array = opts.items()
	var y := 150.0
	var shown := 0
	for i in range(opts.top, items.size()):
		if shown >= opts.ROWS:
			break
		shown += 1
		var it: Dictionary = items[i]
		if it.kind == "header":
			u.title(84.0, y + 18.0, it.label.to_upper(), 34.0, UiKit.YELLOW)
			y += 66.0
			continue
		var o := on("opt" + it.id, i == opts.cursor)
		u.slant(70.0 + 16.0 * o, y, 1100.0, 60.0, UiKit.PANEL.lerp(UiKit.RED, o))
		u.text_fit(110.0 + 16.0 * o, y + 14.0, it.label, 560.0, 28.0, UiKit.INK, u.bold)
		var value: String = it.value
		if opts.waiting == it.id:
			value = tr("Press a key or button...")
		if it.kind == "slider" and opts.waiting != it.id:
			var v: float = float(value.trim_suffix("%")) / 100.0
			u.meter(720.0 + 16.0 * o, y + 22.0, 300.0, 16.0, v, UiKit.YELLOW if o < 0.5 else UiKit.INK, 10)
		u.text_fit(1150.0 + 16.0 * o, y + 14.0, value, 400.0 if it.kind != "slider" else 110.0, 28.0, UiKit.INK, u.heavy, 1)
		y += 68.0
	var cur: Dictionary = items[opts.cursor]
	u.slant(1260.0, 150.0, 600.0, 330.0, UiKit.PANEL, UiKit.TALL)
	u.slant(1260.0, 150.0, 14.0, 330.0, UiKit.RED, UiKit.TALL)
	u.para(1320.0, 186.0, cur.get("help", ""), 500.0, 26.0, UiKit.INK, u.bold, 1.3, 8)
	u.hints([[Controls.glyph("jump"), tr("Change")], [tr("< >"), tr("Adjust")], [Controls.glyph("menu_back"), tr("Back")]])


# ---------------------------------------------------------------- VS

func _vs() -> void:
	var pair: Array = m.vs_pair()
	var t := m.vs_time()
	var k := UiKit.ease(t / 0.4)
	u.full(UiKit.DARK)
	u.slant(lerpf(-1700.0, -560.0, k), 0.0, 1560.0, 1080.0, UiKit.RED, 0.25)
	u.slant(lerpf(2400.0, 980.0, k), 0.0, 1500.0, 1080.0, _side_color(1), 0.25)
	for i in 2:
		var sp: String = pair[i]
		var x := 470.0 if i == 0 else 1460.0
		var slide := (1.0 - k) * (-700.0 if i == 0 else 700.0)
		u.tex(m.render("vs%d" % i, sp, Vector2i(560, 600), 0.45 if i == 0 else -0.45), x - 280.0 + slide, 140.0, 560.0, 600.0)
		u.title(x + slide, 750.0, tr(Roster.POKEMON[sp].display_name).to_upper(), 110.0, UiKit.INK, 0, 760.0)
		var who := tr("You") if i == 0 else (tr("Rival") if m.online else tr("AI, %s") % tr(Menu.DIFFICULTY_NAME[m.choice.diff]).to_lower())
		u.text(x + slide, 880.0, who, 34.0, Color(UiKit.INK, 0.85), u.bold, 0)
	var vk := UiKit.ease((t - 0.25) / 0.3)
	u.title(980.0, 400.0 - 30.0 * (1.0 - vk), "VS", 220.0 * (0.6 + 0.4 * vk), Color(UiKit.YELLOW, vk), 0)


# ---------------------------------------------------------------- confirm

func _confirm() -> void:
	var c: Dictionary = m.confirm
	var k := UiKit.ease(c.get("t", 0.0) / 0.2)
	u.full(Color(0, 0, 0, 0.6 * k))
	# The whole screen is the question's: the mouse reaches nothing under it.
	zone("confirm", -1, 0.0, 0.0, 1920.0, 1080.0)
	var y := lerpf(1100.0, 380.0, k)
	u.slant(440.0, y, 1040.0, 320.0, UiKit.PANEL, UiKit.TALL)
	u.slant(440.0 + 306.0 * UiKit.TALL, y, 1040.0, 14.0, UiKit.RED, UiKit.TALL)
	u.para(500.0, y + 50.0, c.text, 920.0, 38.0, UiKit.INK, u.heavy, 1.25, 2)
	for i in 2:
		var sel: bool = int(c.on) == i
		var bx := 540.0 + i * 440.0
		u.slant(bx, y + 190.0, 360.0, 84.0, (UiKit.RED if i == 1 else UiKit.GREY) if sel else UiKit.PANEL_HI)
		zone("confirm", i, bx, y + 190.0, 360.0 + 84.0 * UiKit.SLANT, 84.0)
		u.title(bx + 40.0, y + 204.0, (tr("No") if i == 0 else tr("Yes")).to_upper(), 50.0, UiKit.INK)


# ---------------------------------------------------------------- profile

## Your profile in the main menu's top right corner: your trainer's head and shoulders,
## "Profile" and your name. Up from Online or Training gets to it.
func _profile_badge() -> void:
	var k := UiKit.ease((m.enter_t - 0.3) / 0.3)
	var x := lerpf(1980.0, 1220.0, k)
	var y := 30.0
	var w := 640.0
	var hgt := 92.0
	var o := on("mainprofile", m.cursor == 6)
	var col: Color = ITEM_COLOR.profile
	if o > 0.01:
		u.slant(x - 8.0 * o, y - 6.0 * o, w + 16.0 * o, hgt + 12.0 * o, Color(UiKit.INK, o))
	u.slant(x, y, w, hgt, UiKit.DARK.lerp(col, 0.35 + 0.65 * o))
	zone("main", 6, x, y, w + hgt * UiKit.SLANT, hgt)
	# Head and shoulders: the sprite's top half, enlarged.
	var tex := TrainerData.texture(m.main.options.trainer)
	u.tex_region(tex, u.edge(x, y, hgt, y + hgt) + 30.0, y + 2.0, 104.0, 88.0, Rect2(14, 4, 52, 44))
	var tx := u.edge(x, y, hgt, y + 40.0) + 160.0
	u.text(tx, y + 10.0, tr("Profile").to_upper(), 18.0, Color(UiKit.INK, 0.7), u.bold)
	u.title(u.edge(x, y, hgt, y + 80.0) + 160.0, y + 30.0, m.main.options.shown_name().to_upper(), 48.0, UiKit.INK, -1, w - 200.0)


## The profile screen: your trainer big on the left with your name; on the right the name
## to type and the trainers to pick from.
func _profile() -> void:
	var col: Color = ITEM_COLOR.profile
	_header(tr("Profile"), col)
	var opt: Settings = m.main.options
	var k := UiKit.ease(m.enter_t / 0.35)
	# Your card.
	var cx := lerpf(-700.0, 70.0, k)
	u.slant(cx, 150.0, 640.0, 760.0, col.darkened(0.35), UiKit.TALL)
	u.stripes(cx + 30.0, 150.0, 600.0, 760.0, Color(1, 1, 1, 0.035), 44.0)
	u.tex(TrainerData.texture(opt.trainer), cx + 60.0, 170.0, 560.0, 560.0)
	u.title(u.edge(cx, 150.0, 760.0, 860.0, UiKit.TALL) + 40.0, 760.0, opt.shown_name().to_upper(), 84.0, UiKit.INK, -1, 560.0)
	if opt.player_name != "":
		u.text(u.edge(cx, 150.0, 760.0, 880.0, UiKit.TALL) + 44.0, 860.0, tr(TrainerData.LIST[opt.trainer].name), 26.0, Color(UiKit.INK, 0.7), u.bold)
	# The name.
	var nx := 780.0
	var on_name := on("pfname", m.profile_cursor < 0)
	u.slant(nx, 150.0, 1070.0, 130.0, UiKit.PANEL.lerp(col, on_name))
	zone("pf", -1, nx, 150.0, 1070.0, 130.0)
	u.text(u.edge(nx, 150.0, 130.0, 170.0) + 30.0, 166.0, tr("Name").to_upper(), 20.0, Color(UiKit.INK, 0.7), u.bold)
	var shown: String = opt.player_name if opt.player_name != "" or m.name_edit else ""
	var ny := 196.0
	if shown == "" and not m.name_edit:
		u.title(u.edge(nx, 150.0, 130.0, ny + 60.0) + 30.0, ny, opt.shown_name().to_upper(), 56.0, Color(UiKit.INK, 0.45), -1, 700.0)
	else:
		u.title(u.edge(nx, 150.0, 130.0, ny + 60.0) + 30.0, ny, shown, 56.0, UiKit.INK, -1, 700.0)
	if m.name_edit:
		var cw := u.width(shown, 56.0, u.heavy)
		u.rect(u.edge(nx, 150.0, 130.0, ny + 60.0) + 40.0 + cw, ny + 58.0, 30.0, 7.0, Color(UiKit.YELLOW, 0.6 + 0.4 * sin(_t * TAU * 0.9)))
		u.text_fit(u.edge(nx, 150.0, 130.0, 260.0) + 860.0, 250.0, tr("Type with the keyboard (Enter ends) or use the keys below."), 1000.0, 18.0, Color(UiKit.INK, 0.8), u.bold, 1)
		_name_keyboard(col)
		u.hints([[Controls.glyph("jump"), tr("Press")], [Controls.glyph("menu_back"), tr("Delete")]])
		return
	# The trainers.
	var list := TrainerData.ids()
	var gx := 780.0
	var gy := 310.0
	var tw := 340.0
	var th := 190.0
	for i in list.size():
		var id: String = list[i]
		var x := gx + (i % Menu.PROFILE_COLUMNS) * (tw + 25.0)
		var y := gy + (i / Menu.PROFILE_COLUMNS) * (th + 15.0)
		var o := on("pf" + id, i == m.profile_cursor)
		var mine: bool = id == opt.trainer
		u.slant(x, y, tw, th, UiKit.PANEL.lerp(col, o))
		zone("pf", i, x, y, tw + th * UiKit.SLANT, th)
		if mine:
			u.slant(x, y + th - 8.0, tw, 8.0, UiKit.YELLOW)
			u.text(u.edge(x, y, th, y + 30.0) + 24.0, y + 14.0, tr("Yours").to_upper(), 20.0, UiKit.YELLOW, u.heavy)
		u.tex(TrainerData.texture(id), u.edge(x, y, th, y + th) + tw - 190.0, y - 4.0 - 6.0 * o, 190.0, 190.0)
		u.title(u.edge(x, y, th, y + th - 20.0) + 24.0, y + th - 66.0, tr(TrainerData.LIST[id].name).to_upper(), 40.0, UiKit.INK, -1, tw - 160.0)
	u.hints([[Controls.glyph("jump"), tr("Select")], [Controls.glyph("menu_back"), tr("Back")]])


# ---------------------------------------------------------------- mouse zones

func zone(kind: String, i: int, x: float, y: float, w: float, h: float) -> void:
	zones.append({"kind": kind, "i": i, "rect": Rect2(u.p(x, y), Vector2(w, h) * u.k)})


func zone_at(pos: Vector2) -> Dictionary:
	for k in range(zones.size() - 1, -1, -1):
		if zones[k].rect.has_point(pos):
			return zones[k]
	return {}


## The on-screen keyboard for the name, under it (in place of the trainers while editing).
func _name_keyboard(col: Color, x0 := 780.0, y0 := 320.0) -> void:
	var kw := 98.0
	var kh := 92.0
	var gap := 9.0
	var on_key: String = m.name_key_id()
	for row in 5:
		var keys: Array = Menu.NAME_KEYS[row]
		for c in keys.size():
			var key: String = keys[c]
			var w := kw if row < 4 else (kw + gap) * 2.5 - gap
			var x := x0 + c * (w + gap)
			var y := y0 + row * (kh + gap)
			var here: bool = m.name_key.y == row and (on_key == key)
			var o := on("nk%d_%d" % [row, c], here)
			u.slant(x, y, w, kh, UiKit.PANEL.lerp(col, o))
			# The wide keys of the last row stand for the columns they cover (Menu.name_key_id).
			zone("nkey", row * 10 + (int(ceilf(c * 2.5)) if row == 4 else c), x, y, w, kh)
			var label := key
			match key:
				"shift":
					label = "abc" if not m.name_lower else "ABC"
				"space":
					label = tr("Space")
				"del":
					label = "<-"
				"done":
					label = tr("Done")
				_:
					label = key.to_lower() if m.name_lower else key
			u.text_fit(x + w * 0.5 + 8.0, y + 24.0, label, w - 20.0, 38.0, UiKit.INK, u.heavy, 0)
