class_name RelayProxy
extends Node
## Lets two players fight without opening any port: their game's packets go through the
## ranking server (its UDP relay, see the backend) instead of straight to each other.
##
## The game's network (ENet) is left as it is. Each side talks to this little proxy on its own
## computer as if it were the other player, and the proxy passes every datagram to the relay
## and back:
##   host :  the ENet server listens on 127.0.0.1 only; the proxy sends to it
##   guest:  the proxy listens on 127.0.0.1 and the ENet client connects to it
## Everything the proxy does is outgoing UDP, which every router lets through.
##
## Packets to and from the relay: 1 HELLO (match, role, token: "this address is me"; repeated
## to keep the hole in the router open), 2 DATA (the game's own packet), 3 ACK (answer to a
## HELLO: whether the other player is already there).

const HELLO := 1
const DATA := 2
const ACK := 3
const FIRST_LOCAL_PORT := 17770       # the guest's proxy looks for a free port from here
const LAST_LOCAL_PORT := 17799

var local_port := 0                    # guest: where its ENet client has to connect
var registered := false                # the relay answered (it knows this player)
var rival_here := false                # ... and the other player is there too
var sent := 0
var received := 0

var _up := PacketPeerUDP.new()         # to and from the relay
var _local := PacketPeerUDP.new()      # to and from this computer's ENet
var _is_host := false
var _hello := PackedByteArray()
var _hello_t := 0.0
var _enet_ip := ""                     # guest: where the ENet client sends from (learned)
var _enet_port := 0


## relay: {host, port, match_id, token (hex)}. As the host, `enet_port` is the local port its
## ENet server listens on. Returns whether it is ready.
func setup(relay: Dictionary, as_host: bool, enet_port := 0) -> bool:
	_is_host = as_host
	var b := StreamPeerBuffer.new()
	b.big_endian = true
	b.put_u8(HELLO)
	b.put_u32(int(relay.match_id))
	b.put_u8(0 if as_host else 1)
	b.put_data(str(relay.token).hex_decode())
	_hello = b.data_array
	if _up.connect_to_host(str(relay.host), int(relay.port)) != OK:
		return false
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
	# Before Net (-15) would be one frame late for what arrives; after it, for what leaves:
	# both directions are pumped on every physics frame and every drawn one.
	process_physics_priority = -5
	return true


func _physics_process(delta: float) -> void:
	pump(delta)


func _process(_delta: float) -> void:
	pump(0.0)


func pump(delta: float) -> void:
	_hello_t -= delta
	if _hello_t <= 0.0:
		# Often until the relay answers, then now and then (keeps the router's hole open).
		_hello_t = 2.0 if registered else 0.4
		_up.put_packet(_hello)
	while _up.get_available_packet_count() > 0:
		var pkt := _up.get_packet()
		if pkt.is_empty():
			continue
		if pkt[0] == ACK:
			registered = true
			rival_here = pkt.size() > 1 and pkt[1] == 1
		elif pkt[0] == DATA:
			received += 1
			var payload := pkt.slice(1)
			if _is_host:
				_local.put_packet(payload)
			elif _enet_port != 0:
				_local.set_dest_address(_enet_ip, _enet_port)
				_local.put_packet(payload)
	while _local.get_available_packet_count() > 0:
		var pkt := _local.get_packet()
		if not _is_host:
			_enet_ip = _local.get_packet_ip()
			_enet_port = _local.get_packet_port()
		var out := PackedByteArray([DATA])
		out.append_array(pkt)
		_up.put_packet(out)
		sent += 1


func _exit_tree() -> void:
	_up.close()
	_local.close()

