extends RefCounted

const MmMaterials := preload("mm_materials.gd")

## What a map IS: a JSON document, checked here before anything is built, which the server
## sends to each client so the two cannot disagree. Lengths are metres, angles degrees; a box's
## `at` is its CENTRE, a prop's the middle of its footprint ON the floor. Normalised into plain
## arrays rounded to the millimetre, so the digest does not move. See `maps/README.md`.


## The format this build reads. A document written for a later one is refused rather than
## half-built.
const FORMAT := 1

const KIND := "murder_map"

## The other games' kinds this game reads, converted by [method import]: their rooms, furniture,
## doors, toys and lights as they are, every spawn group pooled into one.
const FOREIGN_KINDS := ["hideseek_map", "prophunt_map", "playground_map"]

## Playground's materials that are not ours, as the nearest of ours and a tint.
const PLAYGROUND_MATS := {
	"rock": ["stone", [0.62, 0.6, 0.58]],
	"foliage": ["hedge", [1.0, 1.0, 1.0]],
	"ice": ["tile", [0.8, 0.92, 1.0]],
	"thin_ice": ["glass", [0.85, 0.95, 1.0]],
	"snow": ["plaster", [1.0, 1.0, 1.0]],
	"mud": ["dirt", [0.7, 0.6, 0.5]],
	"lava": ["rubber", [1.6, 0.8, 0.3]],
	"slime": ["rubber", [0.5, 1.4, 0.4]],
}

## Playground's liquids, which are volumes to fall into rather than floors.
const PLAYGROUND_LIQUIDS := ["water", "lava", "slime"]

## The largest a document may be on the wire, compressed. A WebSocket's outbound buffer is
## sixty-four kilobytes and a message past it is never sent (mg-look-at-me's finding), so a map
## must fit with room for the header.
const WIRE_LIMIT := 60000

const MAX_BOXES := 6000
const MAX_PROPS := 2000
const MAX_LIGHTS := 128
const MAX_SPAWNS := 64
const MAX_DOORS := 256
const MAX_TOYS := 48

## How a door moves: about a hinge at one edge, sideways into the wall, or up like a shutter.
const DOOR_MOTIONS := ["swing", "slide", "lift"]

## The ambience beds dot-audio ships (CC0, its stock/CREDITS.md), which a map may name.
const AMBIENCE_BEDS := ["amb_wind", "amb_outdoor", "amb_night", "amb_city", "amb_indoor", "amb_eerie", "amb_industrial", "amb_cave", "amb_rain"]

## Every top-level field, and what a missing one becomes.
const DEFAULT_ENV := {
	"sky_top": [0.32, 0.52, 0.82],
	"sky_horizon": [0.72, 0.82, 0.92],
	"ground": [0.35, 0.33, 0.30],
	"sun_pitch": -55.0,
	"sun_yaw": 30.0,
	"sun_energy": 1.1,
	"sun_colour": [1.0, 0.96, 0.88],
	"ambient": [0.62, 0.66, 0.72],
	"ambient_energy": 0.55,
	"fog": 0.0,
}


## Reads a document from JSON text, and checks it.
static func parse_json(text: String, origin: String = "") -> DotResult:
	var json := JSON.new()

	if json.parse(text) != OK:
		return DotResult.fail(
			DotError.CODE_PARSE, "The map is not JSON.",
			"%s line %d: %s" % [origin, json.get_error_line(), json.get_error_message()]
		)

	if typeof(json.data) != TYPE_DICTIONARY:
		return DotResult.fail(DotError.CODE_PARSE, "The map is not a JSON object.", origin)

	return validate(import(json.data as Dictionary))


## [param source] as this game's kind: itself if it is one already, converted if it is one of
## [constant FOREIGN_KINDS], and untouched otherwise (which [method validate] then refuses).
##
## [b]What converts.[/b] Hide & Seek and Prop Hunt documents are this format's parents: the
## same boxes, props, doors, toys and lights, so only the spawns change (hiders and seekers, or
## props and hunters, pooled into players). A Playground document's boxes say `material`,
## `colour` and `turn` where ours say `mat`, `tint` and a rotation, and it has one spawn point,
## which [method MmMap.spawn] rings people round. Its props are physics objects this game does
## not simulate, so they are left out; its toys are dot-props' and stay.
static func import(source: Dictionary) -> Dictionary:
	var kind := str(source.get("kind", ""))

	if kind == KIND or not FOREIGN_KINDS.has(kind):
		return source

	var doc := source.duplicate(true)
	doc["kind"] = KIND
	doc["imported_from"] = kind
	var spawns: Array = []

	if kind == "playground_map":
		var boxes: Array = []
		for raw: Variant in source.get("boxes", []):
			if raw is Dictionary:
				boxes.append(_playground_box(raw as Dictionary))
		doc["boxes"] = boxes
		doc["props"] = []
		var at: Variant = _playground_spawn_on_floor(source.get("spawn", [0.0, 1.0, 0.0]), boxes)
		var yaw := float(source.get("spawn_yaw", 0.0))
		for i in range(8):
			spawns.append({"at": at, "yaw": yaw + 45.0 * i})
		doc.erase("spawn")
		doc.erase("spawn_yaw")
		doc.erase("declared")
		doc.erase("wires")
	else:
		var groups: Variant = source.get("spawns", {})
		if groups is Dictionary:
			var names: Array = (groups as Dictionary).keys()
			names.sort()
			for group: Variant in names:
				var list: Variant = (groups as Dictionary)[group]
				if list is Array:
					spawns.append_array(list)

	doc["spawns"] = {"players": spawns.slice(0, MAX_SPAWNS)}
	return doc


## A Playground spawn hangs a metre above its floor (a person is dropped in), where ours is the feet.
## Left as it is, eight people start in the air and a spawn audit finds nothing under them, so the
## point is lowered to the highest unturned solid box top under it, within 1.5 m. No box found, no change.
static func _playground_spawn_on_floor(spawn: Variant, boxes: Array) -> Variant:
	if not (spawn is Array) or (spawn as Array).size() != 3:
		return spawn

	var p := v3(spawn)
	var best := -INF

	for box: Variant in boxes:
		var b: Dictionary = box
		var turn: Variant = b.get("turn")
		# A turn of no degrees (the editor writes one on every box) is still a level top.
		if turn is Array and (turn as Array).size() == 4 and absf(float(turn[3])) > 0.01:
			continue
		if b.get("solid", true) == false:
			continue
		var centre := v3(b["at"])
		var half := v3(b["size"]) * 0.5
		var top := centre.y + half.y
		if absf(p.x - centre.x) <= half.x and absf(p.z - centre.z) <= half.z and top <= p.y + 0.1 and top >= p.y - 1.5:
			best = maxf(best, top)

	if best == -INF:
		return spawn

	return [p.x, best + 0.02, p.z]


static func _playground_box(b: Dictionary) -> Dictionary:
	var out := {"at": b.get("at", [0, 0, 0]), "size": b.get("size", [1, 1, 1])}
	var material := str(b.get("material", "flat")) if b.get("material") != null else "flat"
	var tint: Array = _colour_list(b.get("colour", [1.0, 1.0, 1.0]))

	if PLAYGROUND_MATS.has(material):
		var pair: Array = PLAYGROUND_MATS[material]
		var over: Array = pair[1]
		tint = [tint[0] * over[0], tint[1] * over[1], tint[2] * over[2]]
		material = pair[0]

	out["mat"] = material
	out["tint"] = tint

	if PLAYGROUND_LIQUIDS.has(str(b.get("material", ""))):
		out["solid"] = false

	var turn: Variant = b.get("turn")
	if turn is Array and (turn as Array).size() == 4:
		out["turn"] = turn

	return out




## Checks a document and returns a normalised copy of it: every optional field present, every
## position three numbers.
static func validate(source: Dictionary) -> DotResult:
	if int(source.get("format", 0)) != FORMAT:
		return _refuse("format is %s; this build reads %d" % [str(source.get("format")), FORMAT], source)

	if str(source.get("kind", "")) != KIND:
		return _refuse("kind is '%s', not '%s'" % [str(source.get("kind", "")), KIND], source)

	var id := str(source.get("id", ""))

	if not _is_id(id):
		return _refuse("id '%s' is not lower-case letters, digits and underscores" % id, source)

	var doc := {
		"format": FORMAT,
		"kind": KIND,
		"id": id,
		"name": str(source.get("name", id)),
		"author": str(source.get("author", "")),
		"blurb": str(source.get("blurb", "")),
		"round_seconds": maxf(float(source.get("round_seconds", 0.0)), 0.0),
		"grace_seconds": maxf(float(source.get("grace_seconds", 0.0)), 0.0),
		"kill_y": float(source.get("kill_y", -30.0)),
	}

	var env := DEFAULT_ENV.duplicate(true)
	var given: Variant = source.get("environment", {})

	if given is Dictionary:
		for key: String in DEFAULT_ENV:
			if (given as Dictionary).has(key):
				var value: Variant = (given as Dictionary)[key]
				env[key] = _floats(value, 3) if DEFAULT_ENV[key] is Array else float(value)

	# The map's own fog, in metres, when it has one: absent, the map gets the horizon haze every map has.
	if given is Dictionary and (given as Dictionary).has("fog_end"):
		var g := given as Dictionary
		env["fog_colour"] = _floats(g.get("fog_colour", env["sky_horizon"]), 3)
		env["fog_start"] = maxf(float(g.get("fog_start", 0.0)), 0.0)
		env["fog_end"] = maxf(float(g["fog_end"]), env["fog_start"] + 1.0)
		env["fog_max"] = clampf(float(g.get("fog_max", 1.0)), 0.0, 1.0)

	doc["environment"] = env

	# Weather: a dot-weather document, parsed by its own rules so a server and a client refuse the same maps.
	if source.has("weather"):
		var weather: Variant = source["weather"]
		if not (weather is Dictionary):
			return _refuse("weather is not an object", source)
		var parsed := DotWeatherDoc.parse(weather as Dictionary)
		if not parsed.ok:
			return _refuse("weather: %s" % parsed.error.message, source)
		doc["weather"] = (parsed.value as DotWeatherDoc).to_dict()

	# The beds under the map: outdoors, and indoors under any ceiling. Only dot-audio's stock ones.
	for key: String in ["ambience", "ambience_indoor"]:
		if source.has(key):
			var bed := str(source[key])
			if not (bed in AMBIENCE_BEDS):
				return _refuse("%s '%s' is not one of %s" % [key, bed, ", ".join(AMBIENCE_BEDS)], source)
			doc[key] = bed

	var boxes: Array = []
	for raw: Variant in source.get("boxes", []):
		var box := _box(raw)
		if box.is_empty():
			return _refuse("box %d is not {at, size, mat}" % boxes.size(), source)
		boxes.append(box)

	if boxes.size() > MAX_BOXES:
		return _refuse("%d boxes; the most is %d" % [boxes.size(), MAX_BOXES], source)

	doc["boxes"] = boxes

	# A converted map's displacement ground (dot-map's heightfield), which the boxes cannot be: a
	# stepped field stops a walker at the first hill. `tint` is the colour it is drawn in.
	if source.has("terrain"):
		if not (source["terrain"] is Dictionary):
			return _refuse("terrain is not a dictionary", source)
		var ground := DotMapTerrain.from_dict(source["terrain"])
		if not ground.ok:
			return _refuse("terrain: %s" % str(ground), source)
		var raw_ground: Dictionary = (source["terrain"] as Dictionary).duplicate()
		raw_ground["tint"] = _floats(raw_ground.get("tint", [1.0, 1.0, 1.0]), 3)
		doc["terrain"] = raw_ground

	var props: Array = []
	for raw: Variant in source.get("props", []):
		var prop := _prop(raw)
		if prop.is_empty():
			return _refuse("prop %d is not {id, at}" % props.size(), source)
		props.append(prop)

	if props.size() > MAX_PROPS:
		return _refuse("%d props; the most is %d" % [props.size(), MAX_PROPS], source)

	doc["props"] = props

	var lights: Array = []
	for raw: Variant in source.get("lights", []):
		if not (raw is Dictionary) or not (raw as Dictionary).has("at"):
			return _refuse("light %d has no 'at'" % lights.size(), source)
		var light := raw as Dictionary
		lights.append({
			"at": _floats(light["at"], 3),
			"range": clampf(float(light.get("range", 8.0)), 0.5, 80.0),
			"energy": clampf(float(light.get("energy", 1.0)), 0.0, 16.0),
			"colour": _floats(light.get("colour", [1.0, 0.95, 0.85]), 3),
		})

	if lights.size() > MAX_LIGHTS:
		return _refuse("%d lights; the most is %d" % [lights.size(), MAX_LIGHTS], source)

	doc["lights"] = lights

	var doors: Array = []
	for raw: Variant in source.get("doors", []):
		var door := _door(raw)
		if door.is_empty():
			return _refuse("door %d is not {at, size} with a known motion" % doors.size(), source)
		doors.append(door)

	if doors.size() > MAX_DOORS:
		return _refuse("%d doors; the most is %d" % [doors.size(), MAX_DOORS], source)

	doc["doors"] = doors

	# Toys: dot-props' DotPropToyBox placements, `{toy, at, yaw, links?, on?}`. Which ids exist
	# is the catalogue's to say when the map is built (an unknown one is left out and listed),
	# so a map with a toy a newer dot-props has still plays on an older server.
	var toys: Array = []
	for raw: Variant in source.get("toys", []):
		var toy := DotPropToyBox.normal_placement(raw)
		if toy.is_empty():
			return _refuse("toy %d is not {toy, at}" % toys.size(), source)
		toys.append(toy)

	if toys.size() > MAX_TOYS:
		return _refuse("%d toys; the most is %d" % [toys.size(), MAX_TOYS], source)

	for toy: Dictionary in toys:
		for link: int in toy.get("links", []):
			if link < 0 or link >= toys.size():
				return _refuse("a %s links to toy %d, and there are %d" % [toy["toy"], link, toys.size()], source)

	doc["toys"] = toys

	if source.has("imported_from"):
		doc["imported_from"] = str(source["imported_from"])

	var spawns: Variant = source.get("spawns", {})
	if not (spawns is Dictionary):
		return _refuse("'spawns' is not {players}", source)

	var out_spawns := {}
	for side in ["players"]:
		var list: Array = []
		for raw: Variant in (spawns as Dictionary).get(side, []):
			if not (raw is Dictionary) or not (raw as Dictionary).has("at"):
				return _refuse("a %s spawn has no 'at'" % side, source)
			list.append({"at": _floats((raw as Dictionary)["at"], 3), "yaw": _r(float((raw as Dictionary).get("yaw", 0.0)))})
		if list.is_empty():
			return _refuse("no spawns for the %s" % side, source)
		if list.size() > MAX_SPAWNS:
			return _refuse("%d %s spawns; the most is %d" % [list.size(), side, MAX_SPAWNS], source)
		out_spawns[side] = list

	doc["spawns"] = out_spawns
	return DotResult.success(doc)


static func _box(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {}

	var b := raw as Dictionary

	if not b.has("at") or not b.has("size"):
		return {}

	var size := _floats(b["size"], 3)

	if size[0] <= 0.0 or size[1] <= 0.0 or size[2] <= 0.0:
		return {}

	var mat := str(b.get("mat", "flat"))

	if not MmMaterials.has(mat):
		mat = "flat"

	var out := {"at": _floats(b["at"], 3), "size": size, "mat": mat}

	if float(b.get("yaw", 0.0)) != 0.0:
		out["yaw"] = _r(float(b["yaw"]))

	# A rotation about any axis, `[ax, ay, az, degrees]`: a Playground ramp.
	var turn: Variant = b.get("turn")
	if turn is Array and (turn as Array).size() == 4 and float(turn[3]) != 0.0:
		var axis := Vector3(float(turn[0]), float(turn[1]), float(turn[2]))
		if axis.length() > 0.0001:
			out["turn"] = _floats([axis.x, axis.y, axis.z], 3) + [_r(float(turn[3]))]

	if b.has("tint"):
		out["tint"] = _floats(_colour_list(b["tint"]), 3)

	# Solid unless the map says not: water, a light's glow, a line painted on a floor.
	if b.has("solid") and not bool(b["solid"]):
		out["solid"] = false

	# Drawn unless the map says not: an invisible wall that keeps people in the map.
	if b.has("visible") and not bool(b["visible"]):
		out["visible"] = false

	return out


static func _prop(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {}

	var p := raw as Dictionary

	if not p.has("id") or not p.has("at"):
		return {}

	var out := {"id": str(p["id"]), "at": _floats(p["at"], 3)}

	for angle in ["yaw", "pitch", "roll"]:
		if float(p.get(angle, 0.0)) != 0.0:
			out[angle] = _r(float(p[angle]))

	return out


## A door: a panel that a player opens and shuts with the use key. `at` is the middle of the
## panel SHUT and `size` is its width, height and thickness, turned by `yaw` like a box; it
## swings about its `hinge` edge (left is the panel's own -x) by `angle` degrees (the sign is
## the side it opens to), slides that way by its width, or lifts by its height. Every field but
## `at` and `size` has a default, so a hand-written door is two lines.
static func _door(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {}

	var d := raw as Dictionary

	if not d.has("at") or not d.has("size"):
		return {}

	var size := _floats(d["size"], 3)

	if size[0] <= 0.0 or size[1] <= 0.0 or size[2] <= 0.0:
		return {}

	var motion := str(d.get("motion", "swing"))

	if not DOOR_MOTIONS.has(motion):
		return {}

	var hinge := str(d.get("hinge", "left"))
	var mat := str(d.get("mat", "wood"))

	if not MmMaterials.has(mat):
		mat = "wood"

	var out := {
		"at": _floats(d["at"], 3),
		"size": size,
		"yaw": _r(float(d.get("yaw", 0.0))),
		"motion": motion,
		"hinge": "right" if hinge == "right" else "left",
		"angle": _r(clampf(float(d.get("angle", 100.0)), -170.0, 170.0)),
		"seconds": _r(clampf(float(d.get("seconds", 0.6)), 0.1, 5.0)),
		# How far a slide or a lift goes, in metres; 0 is all the way (its width, its height).
		"travel": _r(clampf(float(d.get("travel", 0.0)), 0.0, 50.0)),
		"open": bool(d.get("open", false)),
		# A swinging door opens away from whoever opens it, unless the map pins its way.
		"away": bool(d.get("away", true)),
		"mat": mat,
		"tint": _floats(_colour_list(d.get("tint", [1.0, 1.0, 1.0])), 3),
		"name": str(d.get("name", "")),
		# A secret door has no handle and is drawn in the wall's own material, so it reads as
		# wall until somebody tries it.
		"secret": bool(d.get("secret", false)),
	}

	return out


## A normalised document as bytes: JSON, deflated, behind both its lengths.
static func encode(doc: Dictionary) -> PackedByteArray:
	var raw := JSON.stringify(doc, "", false).to_utf8_buffer()
	var packed := raw.compress(FileAccess.COMPRESSION_DEFLATE)

	var out := PackedByteArray()
	out.resize(8)
	out.encode_u32(0, raw.size())
	out.encode_u32(4, packed.size())
	out.append_array(packed)
	return out


static func decode(bytes: PackedByteArray) -> DotResult:
	if bytes.size() < 9:
		return DotResult.fail(DotError.CODE_PARSE, "A map on the wire was empty.")

	var size := bytes.decode_u32(0)

	if bytes.decode_u32(4) != bytes.size() - 8:
		return DotResult.fail(DotError.CODE_PARSE, "A map on the wire is not the length it says.")

	# A size this large is a corrupt header; decompressing it would allocate whatever it says.
	if size <= 0 or size > WIRE_LIMIT * 40:
		return DotResult.fail(DotError.CODE_PARSE, "A map on the wire says it is %d bytes." % size)

	var raw := bytes.slice(8).decompress(size, FileAccess.COMPRESSION_DEFLATE)

	if raw.size() != size:
		return DotResult.fail(DotError.CODE_PARSE, "A map on the wire would not decompress.")

	return parse_json(raw.get_string_from_utf8(), "wire")


## A short fingerprint of a document, for a log line and for two ends to compare.
static func digest(doc: Dictionary) -> String:
	return JSON.stringify(doc, "", true).sha256_text().substr(0, 12)


# --- Small readers ----------------------------------------------------------

static func v3(value: Variant) -> Vector3:
	if value is Vector3:
		return value

	if typeof(value) == TYPE_ARRAY and (value as Array).size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))

	return Vector3.ZERO


static func colour(value: Variant, fallback: Color = Color.WHITE) -> Color:
	if typeof(value) == TYPE_ARRAY and (value as Array).size() >= 3:
		return Color(float(value[0]), float(value[1]), float(value[2]))

	return fallback


static func _floats(value: Variant, count: int) -> Array:
	var out: Array = []

	if value is Vector3:
		value = [value.x, value.y, value.z]

	if typeof(value) == TYPE_ARRAY:
		for i in range(count):
			out.append(_r(float((value as Array)[i]) if i < (value as Array).size() else 0.0))
	else:
		for i in range(count):
			out.append(0.0)

	return out


static func _colour_list(value: Variant) -> Array:
	if typeof(value) == TYPE_STRING and Color.html_is_valid(str(value)):
		var c := Color.html(str(value))
		return [c.r, c.g, c.b]

	return value if typeof(value) == TYPE_ARRAY else [1.0, 1.0, 1.0]


## Millimetres, as a double JSON prints short.
static func _r(value: float) -> float:
	return snappedf(value, 0.001)


static func _is_id(id: String) -> bool:
	if id.is_empty() or id.length() > 48:
		return false

	for character in id:
		if not (character >= "a" and character <= "z") and not (character >= "0" and character <= "9") \
				and character != "_":
			return false

	return true


static func _refuse(why: String, doc: Dictionary) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INVALID, "The map is refused: %s." % why, str(doc.get("id", "?"))
	)
