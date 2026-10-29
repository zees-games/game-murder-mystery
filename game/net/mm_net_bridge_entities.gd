extends "mm_net_bridge_state.gd"

## The entities and toy mirrors of [code]mm_net_bridge.gd[/code]: one behaviour per player, one per toy.
## Path-based base, no class_name.

func _build_entity(player: MmPlayer, peer_id: int) -> DotNetIdentity:
	# The behaviour is added BEFORE the identity: [DotNetIdentity] collects behaviours in
	# `_ready` by walking the subtree, and one added afterwards would never be found.
	var behaviour := MmPlayerNet.new()
	behaviour.name = "Net"
	behaviour.player = player
	behaviour.bridge = self
	player.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = peer_id
	# SHARED: the server corrects, the owner predicts. SERVER would put a player's own
	# movement a round trip behind their keys, and somebody running from a knife would arrive
	# a round trip after the murderer turned the corner.
	identity.authority = DotNetIdentity.Authority.SHARED
	# Relevant to everybody: a map is a few rooms, and nobody here is hidden from anybody on the
	# wire. What is secret is a role, which no snapshot carries at all.
	identity.always_relevant = true
	player.add_child(identity)

	var session_id := session_of(player.player_id)
	_behaviours[session_id] = behaviour

	return identity


## Server side. See [member _in_server_tick] for why an id let go of mid-tick is remembered.
func _unregister(net_id: int) -> void:
	net.registry.unregister(net_id)

	if _in_server_tick:
		_unregistered_in_tick.append(net_id)


func _release_entity(session_id: int) -> void:
	var behaviour: MmPlayerNet = _behaviours.get(session_id)
	_behaviours.erase(session_id)

	if behaviour == null or behaviour.identity == null or net == null:
		return

	_unregister(behaviour.identity.net_id)


## Server: an entity for each of the map's toys, and TOYS naming them, after MAP.
func _register_toys() -> void:
	_release_toys()
	var box := game.map.toys if game != null and game.map != null else null
	var ids := PackedInt64Array()
	if box != null:
		for toy in box.toys:
			var behaviour := _toy_entity(toy, toy, 0)
			if behaviour == null:
				break
			ids.append(behaviour.identity.net_id)
	_toys_body = MmEvents.write_toys(game.map.id() if game != null and game.map != null else &"", ids)
	_broadcast(MmEvents.Kind.TOYS, _toys_body)


## A toy's behaviour and identity under [param parent], registered under [param net_id] (0 allocates one). Null when refused.
# The behaviour goes before the identity, which collects behaviours in its `_ready`.
func _toy_entity(toy: DotPropToy, parent: Node, net_id: int) -> MmToyNet:
	var behaviour := MmToyNet.new()
	behaviour.name = "Net"
	behaviour.toy = toy
	var holder := Node3D.new() if parent != toy else null
	if holder != null:
		holder.name = "Toy%d" % _toy_nets.size()
		parent.add_child(holder)
	var at: Node = holder if holder != null else toy
	at.add_child(behaviour)
	if net.is_server:
		behaviour.pull()

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	identity.always_relevant = true
	at.add_child(identity)

	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)
	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a toy", {"toy": _toy_nets.size(), "error": str(registered.error)})
		for node: Node in [behaviour, identity]:
			at.remove_child(node)
			node.queue_free()
		if holder != null:
			parent.remove_child(holder)
			holder.queue_free()
		return null
	_toy_nets.append(behaviour)
	return behaviour


## Every toy entity out of the registry [b]and out of the tree at once[/b]: a new identity on
## the same toy collects every behaviour under it in its `_ready`, and a freed one still found
## there broke the next snapshot (game-playground found it). A map change, or a new TOYS.
func _release_toys() -> void:
	for behaviour: MmToyNet in _toy_nets:
		if not is_instance_valid(behaviour):
			continue
		if behaviour.identity != null and net != null and net.registry.has(behaviour.identity.net_id):
			if net.is_server:
				_unregister(behaviour.identity.net_id)
			else:
				net.registry.unregister(behaviour.identity.net_id)
		var at := behaviour.get_parent()
		for node: Node in [behaviour.identity, behaviour]:
			if node != null and is_instance_valid(node) and node.get_parent() != null:
				node.get_parent().remove_child(node)
				node.queue_free()
		if at != null and _toy_holder != null and at.get_parent() == _toy_holder:
			_toy_holder.remove_child(at)
			at.queue_free()
	_toy_nets.clear()


## Client: TOYS. A mirror for every id at once, whether this end has built that map or not.
# dot-net stops reading a snapshot at the first entity it does not know, so a client without the map would freeze every player listed after the toys.
func _apply_toys(reader: DotNetReader) -> void:
	var told := MmEvents.read_toys(reader)
	if not bool(told["ok"]) or net == null or net.is_server:
		return
	_release_toys()
	if _toy_holder == null:
		_toy_holder = Node3D.new()
		_toy_holder.name = "ToyMirrors"
		add_child(_toy_holder)
	_toys_map = told["map_id"]
	for id in (told["ids"] as PackedInt64Array):
		var _mirror := _toy_entity(null, _toy_holder, int(id))
	_pair_pending_toys()


## Client: each mirror handed this end's toy at its index, once this end's map is the one TOYS
## named; none while it is not (a map on the way, or one that never came).
func _pair_pending_toys() -> void:
	if net == null or net.is_server or game == null:
		return
	# No id is a server from before TOYS carried one: the map it means is the last MAP.
	var same_map := game.map != null and (_toys_map == &"" or game.map.id() == _toys_map)
	var box := game.map.toys if same_map and game.map.toys != null else null
	if box != null and box.count() != _toy_nets.size():
		DotLog.warn(CHANNEL, "the server's map has a different number of toys", {"server": _toy_nets.size(), "here": box.count()})
	for i in range(_toy_nets.size()):
		var behaviour: MmToyNet = _toy_nets[i]
		if is_instance_valid(behaviour):
			behaviour.toy = box.toy(i) if box != null else null


## Client: the old map's toys are about to go; the mirrors stay registered, without them.
func _unpair_toys() -> void:
	for behaviour: MmToyNet in _toy_nets:
		if is_instance_valid(behaviour):
			behaviour.toy = null


## How many toy entities this end has registered (a client's paired or not). For a check.
func toy_entities() -> int:
	return _toy_nets.size()


## How many toys this end replicates: a client's, mirrors paired with a toy. For a check.
func toy_count() -> int:
	var n := 0
	for behaviour: MmToyNet in _toy_nets:
		if is_instance_valid(behaviour) and (net.is_server or behaviour.toy != null):
			n += 1
	return n
