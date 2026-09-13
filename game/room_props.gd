extends Node

const RoomContent := preload("res://game/room_content.gd")
const RoomProp := preload("res://game/room_prop.gd")

## What people have put in the room, on both ends.
##
## The same script runs on the server and on a client and branches on
## [member authoritative] — the shape [RoomBridge] already uses, and for the same reason:
## every decision here is a pair, and a pair split across two files drifts.
##
## [b]dot-props is the server half and nothing else.[/b] Its own CLAUDE.md says props are
## server-authoritative and are not predicted, because rigid-body simulation is not
## reproducible across machines. So [DotPropSpawner] exists only on the authority, and a
## client keeps a dictionary of what it has been told. That is not a second
## implementation: what the client holds is a **placement** — an id, a definition and a
## position — and every property that makes a prop what it is comes out of
## [method catalogue], which both ends build from this file. Nothing about a bench travels
## except that it is a bench and where it was put.
##
## [b]Everything is frozen the moment it lands.[/b] A prop that fell over would be
## somewhere different on every machine with nothing erroring; a frozen body is a static
## obstacle, and both ends derive its collision from the same replicated position and the
## same catalogue radius. That is the whole reason a lobby can have props at all, and it
## is why there is no physics gun here — a lobby is a place you decorate, not a sandbox.
##
## [b]Collision is a circle, always, even for something drawn as a rectangle.[/b] Same
## argument as [method RoomContent.resolve_furniture]: pushing a walker out of a circle is
## one normalise and one multiply, is exact, and has no corner case. Because both ends use
## the same circle they cannot disagree, which is the property that actually matters — a
## shape a client draws and does not collide with is a client being corrected out of a
## space that looks empty.

const CHANNEL := "room.props"

## Nobody may hold more than this. Small, because a lobby is not a build server and the
## room is 1800 units across: sixteen benches is already a room you cannot walk through.
const PER_PLAYER := 8

## Everything anybody has placed, together. What stops eight people each behaving from
## making the room impassable.
const WORLD_BUDGET := 48

## How often one person may place something, in seconds.
##
## A budget alone does not stop a held key — reach the cap, undo one, place another is a
## place and a free every frame, which costs the server more than the props do. dot-props
## says this and it is the reason [member DotPropLimits.spawn_interval] exists.
const PLACE_INTERVAL := 0.35

## The scene every prop is, and the only one this game ships.
## The scene every prop is, and the only one this game ships.
##
## [b]`room_`-prefixed, and that is a deployment constraint rather than a style.[/b]
## dot-server-deploy flattens every built-in game into one `game/` directory — a
## `.tscn` names its scripts by absolute `res://` path and there is no relative form — so
## two games with a `game/prop.tscn` between them means one silently overwrites the other.
## This was called `prop.tscn` and collided with game-playground's on the first vendored
## build; that project's own collision check is what said so.
const PROP_SCENE := "res://game/room_prop.tscn"


## Somebody placed something. Both ends, and what the renderer redraws from.
signal placed(place_id: int, def: DotPropDef, at: Vector2)

## Something is gone. Both ends.
signal cleared(place_id: int)


## Whether this end may actually place anything.
var authoritative: bool = false

## The spawner. Authority only; null on a client.
var spawner: DotPropSpawner = null

## place id -> {"def": DotPropDef, "at": Vector2, "rotation": float, "owner": int}
##
## [b]The one thing both ends have.[/b] On the authority it is written beside the
## spawner's own book-keeping rather than instead of it: the spawner owns the budget, the
## interval and the undo stack, and this owns the wire identity. Keying the wire on
## `Object.get_instance_id()` — which is what a [DotPropInstance] is keyed by — would send
## a number that means nothing on the receiving machine.
var _placements: Dictionary = {}

## place id -> the spawner's instance id, and back. Authority only.
var _instance_of_place: Dictionary = {}
var _place_of_instance: Dictionary = {}

## The next wire id. Monotonic and never reused, for [Dot2DScatter]'s reason: an id that
## came round again would let a client draw a prop that had been removed as one that had
## just arrived.
var _next_place_id: int = 1

## The room this belongs to. Kept for reporting; the bodies are not parented to it.
var _world: Node = null

## Cached obstacle list, rebuilt when something is placed or cleared.
##
## [b]Cached because it is read on every occupant on every tick on both ends[/b], and
## rebuilt rather than mutated because the alternative is a second copy of "what is in the
## room" that can disagree with the first. Sixty-four people against forty-eight props is
## three thousand distance tests a tick; allocating the list as well would not be.
var _obstacles: PackedVector3Array = PackedVector3Array()


# --- The catalogue ---------------------------------------------------------

## Everything anybody may put in this room.
##
## [b]Built in code rather than loaded from JSON, and that is this game's answer rather
## than dot-props'.[/b] The addon's catalogue is a document an operator edits, which is
## right for a sandbox server with content; this lobby ships no art, has eight things in
## it, and — like [RoomContent] — needs both ends to agree exactly. A file one end could
## have a different version of is the same silent mismatch as a different room size.
##
## Three fields of `meta` are the whole of what a prop is here: `radius` (what people
## collide with, and zero for something you walk over), `colour` (what the renderer
## fills), and `tall` (whether it is drawn as standing up, which is only a shadow).
static func catalogue() -> DotPropCatalogue:
	var out := DotPropCatalogue.new()

	_add(out, &"stool", "Stool", &"seating", 18.0, Color(0.72, 0.52, 0.33), 8.0, 1)
	_add(out, &"bench", "Bench", &"seating", 46.0, Color(0.66, 0.47, 0.30), 30.0, 2)
	_add(out, &"table", "Table", &"seating", 58.0, Color(0.58, 0.41, 0.26), 45.0, 3)
	_add(out, &"plant", "Potted plant", &"decor", 24.0, Color(0.30, 0.62, 0.34), 14.0, 1)
	_add(out, &"lamp", "Floor lamp", &"decor", 16.0, Color(0.95, 0.83, 0.45), 9.0, 1)
	_add(out, &"crate", "Crate", &"decor", 34.0, Color(0.52, 0.53, 0.58), 40.0, 2)

	# The two that are not obstacles, and they are here to prove the field is read. A rug
	# you could not stand on is not a rug, and a sign you have to walk round is a bollard.
	_add(out, &"rug", "Rug", &"decor", 0.0, Color(0.44, 0.24, 0.31), 6.0, 1, 78.0)
	_add(out, &"sign", "Sign", &"decor", 0.0, Color(0.86, 0.86, 0.90), 5.0, 1, 20.0)

	return out


static func _add(
	into: DotPropCatalogue,
	id: StringName,
	display: String,
	category: StringName,
	radius: float,
	colour: Color,
	mass: float,
	cost: int,
	flat: float = 0.0
) -> void:
	var def := DotPropDef.make(id, PROP_SCENE)
	def.display_name = display
	def.category = category
	def.mass = mass
	def.cost = cost
	# Nothing in a lobby is grabbed or frozen by a player: everything is frozen already.
	# Said explicitly rather than left at the default, because a lobby that shipped a
	# physics gun later would want to change these and not to discover them.
	def.can_grab = false
	def.can_freeze = false
	# `flat` is how big something nobody collides with is DRAWN. Without it every rug and
	# every sign came out the same size — a picture showed a bollard-sized sign and a rug
	# you would swear you had to walk round, which is the whole reason a footprint is a
	# field rather than a constant in the renderer.
	def.meta = {
		"radius": radius, "colour": colour.to_html(false), "flat": flat,
	}
	into.add(def)


## The catalogue, built once. Both ends call this rather than [method catalogue].
##
## Building eight definitions is cheap and building them on every menu keystroke is not,
## and — the part that matters — two copies of a catalogue are two things that can be
## edited apart. Everything reads this one.
static var _catalogue: DotPropCatalogue = null

static func shared_catalogue() -> DotPropCatalogue:
	if _catalogue == null:
		_catalogue = catalogue()

	return _catalogue


## What people collide with. Zero for a rug.
static func radius_of(def: DotPropDef) -> float:
	return float(def.meta.get("radius", 0.0)) if def != null else 0.0


static func colour_of(def: DotPropDef) -> Color:
	if def == null:
		return Color(0.5, 0.5, 0.55)

	return Color.from_string(String(def.meta.get("colour", "808080")), Color(0.5, 0.5, 0.55))


static func solid_of(def: DotPropDef) -> bool:
	return radius_of(def) > 0.0


## How big something is drawn.
##
## The collision radius for anything solid — so what a player walks round is what they can
## see, which is this game's own rule about the furniture — and `meta.flat` for anything
## they walk over.
static func footprint_of(def: DotPropDef) -> float:
	var radius := radius_of(def)

	if radius > 0.0:
		return radius

	return float(def.meta.get("flat", 40.0)) if def != null else 40.0


## The catalogue's ids, in a fixed order, so an index can travel instead of a name.
##
## [b]Sorted, and sorted as Strings.[/b] `Array.sort()` on a [StringName] compares interned
## pointers rather than characters — dot-net shipped exactly that bug and two peers gave
## the same message two different ids — so this converts before sorting. A wire index that
## meant a stool on one machine and a table on another would be silent on both.
static func wire_ids() -> PackedStringArray:
	var out := PackedStringArray()

	for def in shared_catalogue().props:
		out.append(String(def.id))

	out.sort()
	return out


static func index_of(id: StringName) -> int:
	return wire_ids().find(String(id))


static func id_at(index: int) -> StringName:
	var ids := wire_ids()

	if index < 0 or index >= ids.size():
		return &""

	return StringName(ids[index])


# --- Lifecycle -------------------------------------------------------------

## Builds the spawner on the authority, and nothing at all on a client.
##
## [param world] is the room this belongs to. It is [b]not[/b] where the bodies go — see
## below — and on a client there are no bodies at all: what it draws comes out of
## [method placements], which is the mirror the events fill.
func setup(p_authoritative: bool, world: Node) -> DotResult:
	authoritative = p_authoritative

	if not authoritative:
		return DotResult.success(null)

	var limits := DotPropLimits.new()
	limits.per_player_budget = PER_PLAYER
	limits.world_budget = WORLD_BUDGET
	limits.spawn_interval = PLACE_INTERVAL
	# Everything anybody placed goes when they leave. A lobby is not a build server and a
	# room that accumulated the furniture of everybody who has ever visited would be
	# impassable inside a day — which is dot-props' own `clean_up_on_leave` argument.
	limits.clean_up_on_leave = true
	limits.undo_depth = PER_PLAYER

	var problem := limits.validate()

	if not problem.ok:
		return problem.wrap("The room's prop limits are not usable")

	spawner = DotPropSpawner.new()
	spawner.name = "Spawner"
	spawner.catalogue = shared_catalogue()
	spawner.limits = limits
	spawner.authoritative = true
	# [b]`world_ref` is deliberately left unset, so the bodies are parented to the
	# spawner.[/b] Two reasons, and the second one is a bug a screenshot found.
	#
	# The design reason: a prop somebody placed outlives a `changegame`, and the world is
	# a scene [DotGameManager] frees and replaces. Bodies under the world would be freed
	# with it while the placements survived — a book-keeping half that says there is a
	# bench and a physics half where there is not.
	#
	# The practical one: `DotNodeRef.of_path(world.get_path())` needs the world to be in a
	# tree, and `tools/screenshot.gd` builds one from `SceneTree._initialize`, where it is
	# not yet. That failed with "Cannot get path of node as it is not in a scene tree",
	# the spawner then refused every placement, and the picture came out with no props in
	# it — which is exactly the class of bug a picture exists to find, since every
	# assertion in every suite was passing at the time.
	_world = world
	add_child(spawner)

	spawner.removed.connect(_on_spawner_removed)

	return DotResult.success(null)


func _physics_process(delta: float) -> void:
	# The spawner's cooldown runs on simulated seconds the host advances, never on a wall
	# clock — dot-props is explicit that a wall clock lets a player who lags the server
	# place faster than one who does not.
	if authoritative and spawner != null:
		spawner.advance(delta)


# --- The authority --------------------------------------------------------

## Puts something in the room. Returns the place id, or zero with the reason logged.
##
## [param owner_id] is the **session id**, exactly as everywhere else in this game. A peer
## id is reassigned the moment somebody reconnects, so a budget keyed by one is charged to
## whoever joins next.
func place(owner_id: int, prop_id: StringName, at: Vector2, rotation: float = 0.0) -> DotResult:
	if not authoritative:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server places props.")

	var def := shared_catalogue().get_prop(prop_id)

	if def == null:
		return DotResult.fail(DotError.CODE_INVALID, "There is no such thing to place.")

	# Inside the room, and not inside the furniture. Resolved rather than refused: a
	# player aiming at a pillar meant "next to the pillar", and refusing gives them a
	# button that silently does nothing near half the landmarks in the room.
	var bounded := _resolve_placement(at, radius_of(def))

	var instance := spawner.spawn_2d(prop_id, StringName(str(owner_id)), bounded, rotation)

	if instance == null:
		# The spawner has already said why through `refused`, which is where the budget,
		# the interval and the world cap are distinguished from each other. Repeating the
		# reason here would be a second copy of it that could disagree.
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"That could not be placed.",
			"budget, cooldown or world cap; see the props channel"
		)

	if instance.node is RoomProp:
		(instance.node as RoomProp).configure(def)

	# [b]On the layout's `prop` layer.[/b] A placed prop arrives on Godot's default layer
	# 1 masking layer 1 — the bit `top_down_2d` calls `world` — so two props placed in the
	# same spot were transparent to each other while both were solid against the room. The
	# lobby is mostly analytic (`Dot2DArena`), which makes these the only bodies here
	# whose layers mean anything, and is why setting them is two lines.
	if _world != null and _world.has_method("classify_prop") and instance.node != null:
		_world.call("classify_prop", instance.node)

	# Frozen through the physics gun's own call rather than by assigning `freeze`, because
	# that is the one place in dot-props that also zeroes the velocities — and a body
	# frozen with a velocity applies it the instant anything thaws it.
	DotPhysGun.set_frozen(instance, true)

	var place_id := _next_place_id
	_next_place_id += 1

	_placements[place_id] = {
		"def": def, "at": bounded, "rotation": rotation, "owner": owner_id,
	}
	_instance_of_place[place_id] = instance.instance_id
	_place_of_instance[instance.instance_id] = place_id
	_rebuild_obstacles()

	placed.emit(place_id, def, bounded)

	return DotResult.success(place_id)


## Takes back the newest thing somebody placed. False when they have nothing.
func undo(owner_id: int) -> bool:
	if not authoritative or spawner == null:
		return false

	return spawner.undo(StringName(str(owner_id)))


## Everything one person placed, gone. What a disconnect does.
func clear_owner(owner_id: int) -> int:
	if not authoritative or spawner == null:
		return 0

	return spawner.clear_player(StringName(str(owner_id)))


## Everything, gone. What an admin does.
func clear_all() -> int:
	if not authoritative or spawner == null:
		return 0

	return spawner.clear_all()


## How many one person is holding against their budget.
func count_for(owner_id: int) -> int:
	if not authoritative or spawner == null:
		return 0

	return spawner.player_count(StringName(str(owner_id)))


## The spawner removed something, for any of its five reasons.
##
## [b]This is the only place a placement is forgotten, and that is deliberate.[/b] An undo,
## a disconnect, an admin clear and a world-budget eviction all end here, so there is one
## path that tells the clients rather than four that must remember to.
func _on_spawner_removed(instance: DotPropInstance, _reason: StringName) -> void:
	var place_id := int(_place_of_instance.get(instance.instance_id, 0))

	if place_id == 0:
		return

	_place_of_instance.erase(instance.instance_id)
	_instance_of_place.erase(place_id)
	_placements.erase(place_id)
	_rebuild_obstacles()

	cleared.emit(place_id)


## Keeps a placement inside the room and out of the built-in furniture.
func _resolve_placement(at: Vector2, radius: float) -> Vector2:
	var extent := RoomContent.ROOM_EXTENT - Vector2(radius, radius) - Vector2(8.0, 8.0)
	var bounded := Vector2(
		clampf(at.x, -extent.x, extent.x), clampf(at.y, -extent.y, extent.y)
	)

	var normals: Array = []
	return RoomContent.resolve_furniture(bounded, radius, normals)


# --- A client's mirror -----------------------------------------------------

## Takes a placement the authority announced. Client side.
##
## [b]The id is adopted, never allocated.[/b] dot-2d's `Dot2DScatter` had to gain `adopt`
## for exactly this: a receiving peer that numbered things itself gives the same object
## two names on two machines, and the failure is invisible because every count matches.
func adopt(place_id: int, prop_id: StringName, at: Vector2, rotation: float, owner_id: int) -> void:
	var def := shared_catalogue().get_prop(prop_id)

	if def == null:
		# A server offering something this build has never heard of. Not fatal and not
		# silent: the room is still usable and the player is simply missing one bench.
		DotLog.warn(CHANNEL, "the server placed something this build does not know", {
			"prop": String(prop_id), "place": place_id,
		})
		return

	_placements[place_id] = {
		"def": def, "at": at, "rotation": rotation, "owner": owner_id,
	}
	_rebuild_obstacles()
	placed.emit(place_id, def, at)


## Drops a placement the authority removed. Client side.
func drop(place_id: int) -> void:
	if not _placements.has(place_id):
		return

	_placements.erase(place_id)
	_rebuild_obstacles()
	cleared.emit(place_id)


## Everything this end knows about, for a client that has just reconnected.
func forget_all() -> void:
	_placements.clear()
	_rebuild_obstacles()


# --- Reading ---------------------------------------------------------------

## place id -> the placement. A copy, so a caller iterating cannot be surprised by a
## removal landing inside its own loop.
func placements() -> Dictionary:
	return _placements.duplicate()


func has(place_id: int) -> bool:
	return _placements.has(place_id)


func count() -> int:
	return _placements.size()


## Everything solid, as `(x, y, radius)` — the same shape
## [method RoomContent.furniture] uses, so [method RoomWorld.simulate_occupant] resolves
## both with one function.
func obstacles() -> PackedVector3Array:
	return _obstacles


func _rebuild_obstacles() -> void:
	var out := PackedVector3Array()

	for value in _placements.values():
		var entry: Dictionary = value
		var def: DotPropDef = entry["def"]
		var radius := radius_of(def)

		if radius <= 0.0:
			continue

		var at: Vector2 = entry["at"]
		out.append(Vector3(at.x, at.y, radius))

	_obstacles = out


func describe() -> Dictionary:
	return {
		"authoritative": authoritative,
		"placed": _placements.size(),
		"solid": _obstacles.size(),
		"budget": "%d each, %d total" % [PER_PLAYER, WORLD_BUDGET],
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("props        %d placed, %d solid" % [_placements.size(), _obstacles.size()])
	out.append("budget       %d each, %d in the room" % [PER_PLAYER, WORLD_BUDGET])

	if authoritative and spawner != null:
		out.append_array(spawner.describe_lines())

	return out
