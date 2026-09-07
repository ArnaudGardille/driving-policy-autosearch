class_name VisionInferenceClient
extends RefCounted
## Tier C Phase 2: thin TCP client for the external real-time inference
## server (../truck-town-vision-training/infer_server.py). Pure GDScript
## (StreamPeerTCP, built into Godot) -- no GDExtension/native dependency,
## matching this repo's existing "no new native deps" pattern (see
## ai/vision/README.md).
##
## Wire protocol (see infer_server.py's own header for the authoritative
## description, this must stay in lockstep with it):
##   request:  uint32 width (LE) + uint32 height (LE) + width*height*3 raw
##             RGB8 bytes (row-major, top-down)
##   response: float32 steer_rad (LE) + float32 engine_force (LE), already
##             denormalized to real units -- callers apply the response
##             directly, no unnormalization needed here.
##
## One persistent connection is reused across the whole race (connecting
## fresh per decision tick would add a TCP handshake -- ~0.1-1ms locally,
## fine as a bound but pointless to pay every 10th of a second).

const CONNECT_TIMEOUT_S := 5.0
const RESPONSE_TIMEOUT_S := 0.5

var _peer: StreamPeerTCP
var _connected := false


## Blocks (short busy-poll, see RESPONSE_TIMEOUT_S) until connected or the
## timeout elapses. Returns false on failure -- callers should treat that
## as "server not up yet / crashed", not a fatal error, and keep driving
## on the last known-good action (see vision_drive_task.gd).
func connect_to_server(host: String, port: int) -> bool:
	_peer = StreamPeerTCP.new()
	var err: Error = _peer.connect_to_host(host, port)
	if err != OK:
		push_warning("VisionInferenceClient: connect_to_host failed: %s" % error_string(err))
		_connected = false
		return false

	var deadline: int = Time.get_ticks_msec() + int(CONNECT_TIMEOUT_S * 1000.0)
	while Time.get_ticks_msec() < deadline:
		_peer.poll()
		var status: int = _peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			_peer.set_no_delay(true) # Match infer_server.py's TCP_NODELAY -- avoid Nagle-induced latency on this small-packet, low-throughput link.
			_connected = true
			return true
		if status == StreamPeerTCP.STATUS_ERROR:
			break
		OS.delay_msec(1)

	push_warning("VisionInferenceClient: could not connect to %s:%d within %.1fs -- is infer_server.py running?" % [host, port, CONNECT_TIMEOUT_S])
	_connected = false
	return false


## Sends one (width, height, RGB8 bytes) frame and blocks for the matching
## response. Returns Vector2(steer_rad, engine_force) on success, or null
## on any failure (disconnect, timeout, malformed response) -- caller
## decides the fallback (vision_drive_task.gd holds the last good action).
func predict(width: int, height: int, rgb_bytes: PackedByteArray) -> Variant:
	if not _connected or _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return null

	var expected_len: int = width * height * 3
	if rgb_bytes.size() != expected_len:
		push_warning("VisionInferenceClient: rgb_bytes.size()=%d, expected %d for %dx%d -- dropping this frame." % [rgb_bytes.size(), expected_len, width, height])
		return null

	var header := PackedByteArray()
	header.resize(8)
	header.encode_u32(0, width)
	header.encode_u32(4, height)

	var send_err: Error = _peer.put_data(header)
	if send_err == OK:
		send_err = _peer.put_data(rgb_bytes)
	if send_err != OK:
		push_warning("VisionInferenceClient: put_data failed: %s" % error_string(send_err))
		_connected = false
		return null

	var deadline: int = Time.get_ticks_msec() + int(RESPONSE_TIMEOUT_S * 1000.0)
	while Time.get_ticks_msec() < deadline:
		_peer.poll()
		if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			push_warning("VisionInferenceClient: connection dropped while waiting for a response.")
			_connected = false
			return null
		if _peer.get_available_bytes() >= 8:
			var result: Array = _peer.get_data(8)
			var read_err: Error = result[0]
			var resp: PackedByteArray = result[1]
			if read_err != OK or resp.size() != 8:
				push_warning("VisionInferenceClient: get_data failed: %s" % error_string(read_err))
				return null
			var steer: float = resp.decode_float(0)
			var engine_force: float = resp.decode_float(4)
			return Vector2(steer, engine_force)
		OS.delay_msec(1)

	push_warning("VisionInferenceClient: no response within %.2fs -- inference server may be overloaded or stuck." % RESPONSE_TIMEOUT_S)
	return null


func is_connected_to_server() -> bool:
	return _connected and _peer != null and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


func close() -> void:
	if _peer:
		_peer.disconnect_from_host()
	_connected = false
