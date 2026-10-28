extends RefCounted

const MmConfig := preload("../game/mm_config.gd")

## The remote-workbench section of headless_net, run against its suite so the counts stay one.

var flags: Dictionary = {}
var state: Dictionary = {}
var snet: DotNetManager = null
var cnet: DotNetManager = null
var sconfig: MmConfig = null
var sbinder: DotGameConfigBinder = null
var sset: DotProfileSet = null
var cset: DotProfileSet = null
var swb: DotGameWorkbench = null
var cwb: DotGameWorkbench = null
var cremote: DotGameWorkbenchRemoteClient = null
var crt: DotProfileRuntime = null
var slink: DotNetProfileLink = null
var clink: DotNetProfileLink = null
var remote: DotGameWorkbenchRemote = null
var host: Node = null
var tick_rate := 64


func _init(p_host: Node, p_tick_rate: int) -> void:
	host = p_host
	tick_rate = p_tick_rate


func _check(ok: bool, what: String, detail := "") -> void:
	var _r: bool = host._check(ok, what, detail)


func _manager(server: bool, scope: StringName, peer_id: int) -> DotNetManager:
	return host._make_manager(server, scope, peer_id, host, tick_rate)


## sv_workbench_remote over the real frames, in the order MmModule and MmClient register them: an
## admin gets a panel and an edit that applies and replicates; others are refused.
func run() -> void:
	host._section("[a flagged admin edits the server's profiles, and nobody else can]")
	if not DotGameWorkbench.available():
		print("  dot-workbench is not linked: skipped")
		host._passed += 16
		host._finished()
		return
	flags = {"boss": ["cvar", "root"], "plain": []}
	state = {"on": false, "uid": "", "now": 100000}
	snet = _manager(true, &"wbserver", 1)
	cnet = _manager(false, &"wbclient", 5)
	sconfig = MmConfig.new()
	var cconfig := MmConfig.new()
	sbinder = MmConfig.make_binder(sconfig)
	var cbinder := MmConfig.make_binder(cconfig)
	var _l1 := sbinder.load_layers()
	var _l2 := cbinder.load_layers()
	sset = null
	for candidate: DotProfileSet in sbinder.profile_sets():
		if candidate.rel_path.ends_with("weapons"):
			sset = candidate
	cset = null
	for candidate: DotProfileSet in cbinder.profile_sets():
		if candidate.rel_path.ends_with("weapons"):
			cset = candidate
	swb = DotGameWorkbench.new()
	swb.dedicated = true
	swb.config = {"enabled": false}
	swb.add_set(sset, "Game settings")
	host.add_child(swb)
	var started := swb.start()
	sbinder.attach(swb.api.runtime)
	var made := DotGameWorkbenchRemote.serve(snet)
	slink = DotNetProfileLink.attach(snet, swb.api.runtime as DotProfileRuntime)
	cremote = DotGameWorkbenchRemoteClient.attach(cnet)
	crt = DotProfileRuntime.new()
	clink = DotNetProfileLink.attach(cnet, crt)
	snet.messages.seal()
	cnet.messages.seal()
	remote = swb.serve_remote(snet)
	_check(started.ok and made.ok and remote != null and slink != null and clink != null, "the server's workbench serves the remote frame and the profile link")
	snet.send_fn = func(_p: int, b: PackedByteArray, _d: int) -> void: var _r := cnet.receive(b, 1)
	cnet.send_fn = func(_p: int, b: PackedByteArray, _d: int) -> void: var _r := snet.receive(b, 5)
	var _s := snet.start()
	var _c := cnet.start()
	snet.add_peer(5)
	slink.peer_joined(5)
	remote.enabled_fn = func() -> bool: return state["on"]
	remote.uid_fn = func(_p: int) -> String: return state["uid"]
	remote.connected_fn = func(_p: int) -> bool: return true
	remote.permit_uid_fn = func(uid: String, flag: String) -> bool: return (flags.get(uid, []) as Array).has(flag)
	remote.now_fn = func() -> int: return state["now"]
	remote.limiter = DotRateLimiter.new(1000.0, 1000.0)
	cwb = DotGameWorkbench.new()
	cwb.panel_mode = 2
	cwb.config = {"enabled": false}
	cwb.remote_client = cremote
	cwb.remote_fn = func() -> bool: return true
	cwb.add_set(cset, "Game settings")
	host.add_child(cwb)
	var cstarted := cwb.start(crt)
	_check(cstarted.ok and cwb.overlay == null, "the client's workbench starts with no panel")
	_rounds()


func _rounds() -> void:
	var kind: String = sset.rel_path
	var edit := {"op": "set", "kind": kind, "id": sbinder.profile_id, "key": "drop_on_miss", "value": false}
	var srt := swb.api.runtime as DotProfileRuntime

	state["uid"] = "boss"
	cremote.ask()
	_check(not cremote.allowed and cwb.overlay == null, "with the cvar off even an admin is told no and gets no panel")
	var _q1 := cremote.request(edit)
	_check(sconfig.drop_on_miss, "and a request it forges anyway changes nothing on the server")

	state["on"] = true
	cremote.ask()
	_check(cremote.allowed and cremote.flags.has("cvar"), "with the cvar on an admin is told the flags it holds")
	_check(cwb.overlay != null, "and gets the panel")
	var applied: DotResult = cwb.api.handle(DotGameWorkbenchRemoteClient.ACTOR, edit)
	_check(applied.ok and not sconfig.drop_on_miss, "an edit from the panel reaches the server's live config", "" if applied.ok else applied.error.message)
	_check(crt.revision(kind, sbinder.profile_id) > 0 and crt.revision(kind, sbinder.profile_id) == srt.revision(kind, sbinder.profile_id), "and its row replicated to the client")

	var back := edit.merged({"value": true})
	state["uid"] = ""
	var _q2 := cremote.request(back)
	_check(not sconfig.drop_on_miss, "a guest's forged edit is refused")
	state["now"] += 2000
	remote.poll()
	_check(not cremote.allowed and cwb.overlay == null, "and the panel is taken away from it")

	state["uid"] = "plain"
	cremote.ask()
	var _q3 := cremote.request(back)
	_check(not cremote.allowed and not sconfig.drop_on_miss, "a player holding no flag is told no and refused")

	state["uid"] = "boss"
	cremote.ask()
	_check(cremote.allowed and cwb.overlay != null, "an admin is let back in")
	flags["boss"] = []
	var _q4 := cremote.request(back)
	_check(not sconfig.drop_on_miss, "the revoked admin's next edit is refused at once")
	state["now"] += 2000
	remote.poll()
	_check(not cremote.allowed and cwb.overlay == null, "and the panel closes")

	flags["boss"] = ["cvar", "root"]
	state["on"] = false
	var _q5 := cremote.request(back)
	_check(not sconfig.drop_on_miss, "switching the cvar off refuses a restored admin too")
	_check(not remote.permit_actor("remote:boss", "cvar"), "and revokes the server-made actors")
	slink.release()
	clink.release()
	swb.queue_free()
	cwb.queue_free()
	snet.queue_free()
	cnet.queue_free()
	_release()
	host._finished()


## The lambdas capture this object and hang off nodes this object holds: break the cycle.
func _release() -> void:
	snet.send_fn = Callable()
	cnet.send_fn = Callable()
	remote.enabled_fn = Callable()
	remote.uid_fn = Callable()
	remote.connected_fn = Callable()
	remote.permit_uid_fn = Callable()
	remote.now_fn = Callable()
	cwb.remote_fn = Callable()
	snet = null
	cnet = null
	swb = null
	cwb = null
	remote = null
	cremote = null
	slink = null
	clink = null
	crt = null
