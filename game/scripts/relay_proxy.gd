class_name RelayProxy
extends Node
## Lets two players fight without opening any port, and as fast as the connection allows.
##
## The game's network (ENet) is left as it is. Each side talks to this little proxy on its own
## computer as if it were the other player, and the proxy carries every datagram to the other
## side by the best way there is:
##   1. DIRECT, when the two routers let it ("hole punching"): the ranking server tells each
##      player where the other can be reached and both send to each other at the same time,
##      which makes each router let the other's packets in. Fast: the ping of a normal
##      connection. No port is opened by hand.
##   2. through the server's RELAY, always possible: everyone only sends out to the server.
##      Slower (the packets take a detour), but it works whatever the routers are.
## The direct path is proven both ways before it is used (a PUNCH answered by a PUNCH_ACK) and
## dropped back to the relay if it goes quiet. Packets are accepted from both paths; ENet
## drops the duplicates.
##   host :  the ENet server listens on 127.0.0.1 only; the proxy sends to it
##   guest:  the proxy listens on 127.0.0.1 and the ENet client connects to it
##
## Packets with the relay: 1 HELLO (match, role, token, local port: "this address is me";
## repeated to keep the hole in the router open), 2 DATA (the game's own packet), 3 ACK (answer
## to a HELLO: whether the other player is there, and the addresses to try for the direct
## path). Between players: 5 PUNCH (match, role), 6 PUNCH_ACK, and 2 DATA.

const HELLO := 1
const DATA := 2
const ACK := 3
const PUNCH := 5
const PUNCH_ACK := 6
const FIRST_LOCAL_PORT := 17770       # the guest's proxy looks for a free port from here
const LAST_LOCAL_PORT := 17799
const FIRST_UDP_PORT := 17800         # the proxy's own port for the internet, from here
const LAST_UDP_PORT := 17899
const DIRECT_TIMEOUT := 2.0           # the direct path is dropped after this long without an answer

var local_port := 0                    # guest: where its ENet client has to connect
var registered := false                # the relay answered (it knows this player)
var rival_here := false                # ... and the other player is there too
var direct := false                    # the packets go straight to the other player
var server_ping := 0                   # ms to the relay server (HELLO to ACK)
var sent := 0
var received := 0

var _up := PacketPeerUDP.new()         # to and from the internet: the relay and the other player
var _local := PacketPeerUDP.new()      # to and from this computer's ENet
var _is_host := false
var _role := 0
var _match_id := 0
var _use_direct := true
var _server_ip := ""
var _server_port := 0
var _hello := PackedByteArray()
var _punch := PackedByteArray()
var _hello_t := 0.0
var _hello_at := 0.0
var _punch_t := 0.0
var _t := 0.0
var _cands: Array = []                 # the other player's addresses to try: [[ip, port], ...]
var _direct_ip := ""
var _direct_port := 0
var _direct_ok_at := -100.0            # when a PUNCH_ACK last came back
var _enet_ip := ""                     # guest: where the ENet client sends from (learned)
var _enet_port := 0


## relay: {host, port, match_id, token (hex), no_direct}. As the host, `enet_port` is the local
## port its ENet server listens on. Returns whether it is ready.
func setup(relay: Dictionary, as_host: bool, enet_port := 0) -> bool:
	_is_host = as_host
	_role = 0 if as_host else 1
	_match_id = int(relay.match_id)
	_use_direct = not bool(relay.get("no_direct", false))
	var host := str(relay.host)
	_server_ip = host if host.is_valid_ip_address() else IP.resolve_hostname(host, IP.TYPE_IPV4)
	_server_port = int(relay.port)
	if _server_ip == "":
		return false
	# The one socket for the internet: bound, so it hears the server and the other player alike.
	var up_port := 0
	for p in range(FIRST_UDP_PORT, LAST_UDP_PORT + 1):
		if _up.bind(p, "*") == OK:
			up_port = p
			break
	if up_port == 0:
		return false
	var b := StreamPeerBuffer.new()
	b.big_endian = true
	b.put_u8(HELLO)
	b.put_u32(_match_id)
	b.put_u8(_role)
	b.put_data(str(relay.token).hex_decode())
	b.put_u16(up_port)
	_hello = b.data_array
	var p2 := StreamPeerBuffer.new()
	p2.big_endian = true
	p2.put_u8(PUNCH)
	p2.put_u32(_match_id)
	p2.put_u8(_role)
	_punch = p2.data_array
	if as_host:
		if _local.connect_to_host("127.0.0.1", enet_port) != OK:
			return false
	else:
		for p in range(FIRST_LOCAL_PORT, LAST_LOCAL_PORT + 1):
			if _local.bind(p, "127.0.0.1") == OK:
				local_port = p
				break
		if local_port == 0:
			return false
	return true


## Net calls pump() at the start of its step (what arrived goes to ENet before it polls) and at
## the end (what ENet just sent goes out at once); this one only moves packets on drawn frames.
func _process(_delta: float) -> void:
	pump(0.0)


func pump(delta: float) -> void:
	_t += delta
	direct = _t - _direct_ok_at < DIRECT_TIMEOUT
	_hello_t -= delta
	if _hello_t <= 0.0:
		# Often until the relay has answered and told where the other player is, then now and
		# then (it keeps the router's hole to the relay open).
		var settled := registered and rival_here and (not _cands.is_empty() or not _use_direct)
		_hello_t = 2.0 if settled else 0.4
		_hello_at = _t
		_send_to(_server_ip, _server_port, _hello)
	if _use_direct and not _cands.is_empty():
		_punch_t -= delta
		if _punch_t <= 0.0:
			if direct:
				_punch_t = 0.5                      # keeps the direct path's holes open
				_send_to(_direct_ip, _direct_port, _punch)
			else:
				_punch_t = 0.25                     # trying every address until one answers
				for c in _cands:
					_send_to(str(c[0]), int(c[1]), _punch)
	while _up.get_available_packet_count() > 0:
		var pkt := _up.get_packet()
		var ip := _up.get_packet_ip()
		var port := _up.get_packet_port()
		if pkt.is_empty():
			continue
		var from_server := ip == _server_ip and port == _server_port
		match pkt[0]:
			ACK:
				if from_server:
					_on_ack(pkt)
			DATA:
				if from_server or _is_rival(ip, port):
					received += 1
					_to_enet(pkt.slice(1))
			PUNCH:
				# The other player reaches me: answer from the same door, so its router lets
				# the answer in (and mine let it in).
				if _use_direct and _valid_punch(pkt) and _knows_ip(ip):
					_send_to(ip, port, _punch_ack())
			PUNCH_ACK:
				if _use_direct and _valid_punch(pkt) and _knows_ip(ip):
					_direct_ip = ip
					_direct_port = port
					_direct_ok_at = _t
					direct = true
	while _local.get_available_packet_count() > 0:
		var pkt := _local.get_packet()
		if not _is_host:
			_enet_ip = _local.get_packet_ip()
			_enet_port = _local.get_packet_port()
		var out := PackedByteArray([DATA])
		out.append_array(pkt)
		# Straight to the other player when that path is proven, else through the relay.
		if direct:
			_send_to(_direct_ip, _direct_port, out)
		else:
			_send_to(_server_ip, _server_port, out)
		sent += 1


func _on_ack(pkt: PackedByteArray) -> void:
	registered = true
	server_ping = int(round((_t - _hello_at) * 1000.0))
	rival_here = pkt.size() > 1 and pkt[1] == 1
	if pkt.size() > 2:
		var n := int(pkt[2])
		var found: Array = []
		for i in n:
			var o := 3 + i * 6
			if o + 6 > pkt.size():
				break
			found.append(["%d.%d.%d.%d" % [pkt[o], pkt[o + 1], pkt[o + 2], pkt[o + 3]], (int(pkt[o + 4]) << 8) | int(pkt[o + 5])])
		_cands = found


func _to_enet(payload: PackedByteArray) -> void:
	if _is_host:
		_local.put_packet(payload)
	elif _enet_port != 0:
		_local.set_dest_address(_enet_ip, _enet_port)
		_local.put_packet(payload)


func _send_to(ip: String, port: int, data: PackedByteArray) -> void:
	_up.set_dest_address(ip, port)
	_up.put_packet(data)


func _punch_ack() -> PackedByteArray:
	var a := _punch.duplicate()
	a[0] = PUNCH_ACK
	return a


## A PUNCH or PUNCH_ACK of this match, sent by the other role.
func _valid_punch(pkt: PackedByteArray) -> bool:
	if pkt.size() != 6:
		return false
	var id := (int(pkt[1]) << 24) | (int(pkt[2]) << 16) | (int(pkt[3]) << 8) | int(pkt[4])
	return id == _match_id and int(pkt[5]) != _role


func _knows_ip(ip: String) -> bool:
	for c in _cands:
		if str(c[0]) == ip:
			return true
	return false


func _is_rival(ip: String, port: int) -> bool:
	if direct and ip == _direct_ip and port == _direct_port:
		return true
	for c in _cands:
		if str(c[0]) == ip and int(c[1]) == port:
			return true
	return false


func _exit_tree() -> void:
	_up.close()
	_local.close()
