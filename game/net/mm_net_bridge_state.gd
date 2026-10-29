extends Node

## The state of [code]mm_net_bridge.gd[/code]: constants, signals and variables, with the lookups and sends
## every other part uses. Path-based base, no class_name.

const MmEvent := preload("mm_event.gd")
const MmEvents := preload("mm_events.gd")
const MmNetCommand := preload("mm_net_command.gd")
const MmNetLink := preload("mm_net_link.gd")
const MmPlayerNet := preload("mm_player_net.gd")
const MmToyNet := preload("mm_toy_net.gd")
const MmRequest := preload("mm_request.gd")

const MmGame := preload("../mm_game.gd")
const MmMapDoc := preload("../mm_map_doc.gd")
const MmPlayer := preload("../mm_player.gd")

const CHANNEL := "mm.net"

## Bytes of acknowledgement in front of every input packet. [method DotNetManager.encode_ack].
const ACK_BYTES := 4

## Commands in every input packet: this tick's and the four before it, so over ENet a dropped
## packet costs the server no tick unless the next four are lost too.
const INPUT_COPIES := 5

## How often the round clock and the numbers behind it go out, in ticks: twice a second, since
## they change when somebody dies or a second passes. See [method _apply_clock].
const CLOCK_EVERY := 32

## The client has been told who it is. [param player_id] is the session id.
signal hello_received(player_id: int)

## Somebody joined, left or changed sides. Client side; the HUD and a scoreboard read it.
signal roster_changed(player_id: int)

## A round began or ended. [param why] is the server's sentence about who won.
signal round_changed(number: int, began: bool, winner: int, why: String, killer: int)

## The round changed half. Client side.
signal phase_received(phase: int)

## Somebody died, and what did it.
signal death_received(player_id: int, by: int, why: StringName)

signal notice_received(text: String)

## Client side: the server moved this client's own camera. [param mode] is
## [enum DotSpectatorView.Mode]; the view has already been adopted by the world's mirror.
signal spectate_received(viewer: int, mode: int, target: int)

## Client side: the map was rebuilt from what the server sent. The HUD names it.
signal map_received(map_id: StringName)

## Client side: this client's own role arrived. [param side] is MmGame.BYSTANDERS or MURDERERS.
signal role_received(side: int, gun: bool, weapon_id: StringName)

## Client side: somebody fired. [param hit] is whether it struck anybody.
signal shot_received(player_id: int, from: Vector3, to: Vector3, hit: bool)

## Client side: a gun dropped ([param down]) or picked up.
signal gun_received(drop_id: int, down: bool, at: Vector3)

## Client side: a door set off, on the server's [param tick].
signal door_received(index: int, open: bool, tick: int)


## Somebody pressed Enter. Server side; who may say what and who hears it is DotChatRouter's, not the bridge's.
signal say_requested(peer_id: int, channel_id: StringName, text: String)

## A voice frame arrived. Server side; the payload is unparsed and must not be trusted —
## [method DotVoiceRouter.relay] is what stamps the speaker, from the peer id below.
signal voice_requested(peer_id: int, payload: PackedByteArray)

## Client side: one routed line, and one voice frame.
signal chat_received(wire: Dictionary)
signal voice_arrived(payload: PackedByteArray)

var game: MmGame = null
var net: DotNetManager = null
var link: MmNetLink = null

## Which session this process is. Zero on a server.
var local_player_id: int = 0

## Client side: this client's own side this round, from its ROLE. 0 until one arrives and again
## once the round ends; the wire's TEAM for this player is the public side and does not win.
var local_role: int = 0

## Where the clock learns the link's ping in milliseconds.
# dot-net cannot measure a transport; without a sample every command is stamped for a tick already simulated and discarded as late.
var rtt_source: Callable = Callable()

## Where a voice frame goes on the server. Assigned by [DotGameModule] to the services
## layer's `relay_voice`, because the bridge is the only thing that names both ends.
var voice_relay_fn: Callable = Callable()

## `func(session_id: int) -> DotAvatar`: what a player looks like, asked once as they are
## seated. Assigned by the module, which is what has the identity layer; unset, or answering
## null, is the stock person, which is what everybody was before there was one.
var avatar_fn: Callable = Callable()

var _entities: Node = null

## session id -> [MmPlayerNet].
var _behaviours: Dictionary = {}

## The next session id handed to somebody the world made itself.
# Above anything dot-server issues: a player called `bot` parses back to session 0, dot-net's broadcast address.
const FIRST_BOT_SESSION := 900000

var _next_bot_session: int = FIRST_BOT_SESSION

var _player_of_peer: Dictionary = {}
var _peer_of_player: Dictionary = {}
var _ready_peers: Dictionary = {}
## Carries the game's profile runtime over this manager; null when the types would not register.
var profile_link: DotNetProfileLink = null
## Server: peers whose READY came before their seat ([method add_player]).
# READY can overtake `loaded` over lossy ENet; a READY dropped here left the client waiting for a world.
var _ready_unseated: Dictionary = {}

var _tick: int = 0
var _game_ticked_for: int = -1

## Server only: whether [method DotNetManager.server_tick] is on the stack, and the net ids let go of
## while it was. An entity removed mid-tick would otherwise get a fresh lag-compensation track
## recorded after the registry forgot it, for ever; forgotten again once the manager lets go.
var _in_server_tick := false
var _unregistered_in_tick: Array[int] = []
var _client_ticked_for: int = -1

## The map the clients were last sent, so a late joiner is sent the same bytes.
var _map_body: PackedByteArray = PackedByteArray()

## The map's toys on the wire, one behaviour per toy in toy order, and the TOYS event that
## names their net ids (kept for a joiner, as [member _map_body] is).
var _toy_nets: Array = []
var _toys_body: PackedByteArray = PackedByteArray()

## Client: the map the last TOYS was for. Its mirrors are registered the moment it arrives and
## handed this end's toys when this end has built that map ([method _pair_pending_toys]).
var _toys_map: StringName = &""

## Client: where the mirrors live, which is not under the toys: they are registered before this
## end's map may exist, and stay registered through a map change.
var _toy_holder: Node3D = null

static func player_key(session_id: int) -> StringName:
	return StringName("u%d" % session_id)


## A stand-in by its id alone: a client's copy of a bot has `is_bot` false (only the server's
## bridge sets it), so the board tells one by the session range `add_bot` allocates from.
static func is_bot_key(id: StringName) -> bool:
	return session_of(id) >= FIRST_BOT_SESSION


static func session_of(id: StringName) -> int:
	return String(id).trim_prefix("u").to_int()


func peer_for_player(session_id: int) -> int:
	return int(_peer_of_player.get(session_id, 0))


func player_for_peer(peer_id: int) -> int:
	return int(_player_of_peer.get(peer_id, 0))


## How every dot-net message reaches a peer.
# Routed by delivery, not kind: snapshots unreliable, the rest reliable on the call that matches this end,
# else client requests are silently dropped.
func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return

	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	elif net.is_server:
		link.send_event(peer_id, payload)
	else:
		link.send_request(payload)


## One peer, and never zero.
# `net.send(msg, 0)` broadcasts in dot-net; a missing peer id passed through would leak a private message.
func _tell(peer_id: int, kind: int, body: PackedByteArray) -> void:
	if peer_id <= 0 or net == null or body.is_empty():
		return

	net.send(MmEvent.new(kind, body), peer_id)


## To every peer that has said it is ready, and to nobody else.
# An empty body is dropped: it decodes on the far end as a valid message about nothing.
func _broadcast(kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server or body.is_empty():
		return

	for peer_id in _ready_peers.keys():
		_tell(int(peer_id), kind, body)


## The side everybody else is told somebody is on: a bystander, whatever they are. 0 stays 0
## (not playing).
static func public_side(side: int) -> int:
	return MmGame.BYSTANDERS if side > 0 else 0


func _clock_body() -> PackedByteArray:
	return MmEvents.write_clock(
		game.round_number,
		game.phase_elapsed,
		game.play_elapsed,
		game.phase,
		game.alive_total(),
		game.alive_on(MmGame.MURDERERS),
		game.sides_are_playable()
	)
