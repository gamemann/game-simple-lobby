class_name RoomWorld
extends Node

## The room: who is in it, where they are, and one deterministic tick.
##
## The authoritative half of game-simple-lobby, and the only file that decides anything.
## It knows nothing about dot-server, dot-net, rendering or chat — a world that reached
## for a socket could not be run twice in one process, which is exactly what
## `examples/sandbox.tscn` does.
##
## [b]Simulation is a pure function of (state, command, delta).[/b] Nothing in [method
## tick] reads a clock, a device or a node. That is the only shape [DotNetPredictor]
## converges for: a client predicting its own walk and a server re-running the same
## commands have to arrive at the same position, or every step is a correction.

const CHANNEL := "room.world"

## Registry name, so a module can find the world a game scene created without either of
## them naming a scene path.
const SERVICE := &"room_world"

## Somebody entered. Fired on the authority, and on a client when it is told.
signal occupant_joined(occupant: RoomOccupant)

## Somebody left. The occupant is still valid inside the handler and is gone after it.
signal occupant_left(occupant: RoomOccupant)

@export_group("Role")

## Whether this world decides, or mirrors one that does.
##
## A client's world runs the same motor over the same commands for the one occupant it
## predicts, and is told about everybody else. It must never resolve anything: a client
## that placed people itself would disagree with the server and be corrected forever.
@export var is_authority: bool = true

@export_group("Simulation")

@export_range(10, 240, 1) var tick_rate: int = RoomContent.TICK_RATE

## Call [method setup] as soon as this node enters the tree.
##
## [b]On, because the usual way this world comes into existence is that
## [DotGameManager] instantiated the scene it lives in[/b] — and nothing in dot-server
## knows a room needs setting up. Left to an explicit call, a server that loaded the game
## the documented way got a world that had no arena, registered no service, and failed the
## module load with "No RoomWorld is registered": the scene loaded perfectly and the game
## could not start.
##
## [method setup] is idempotent, so a host that prefers to call it itself still can.
@export var auto_setup: bool = true

@export_group("Service")

## Publish under [constant SERVICE] so a module can find this world.
@export var register_service: bool = true

## Suffix for the registry name, so two worlds can exist in one process.
##
## Not cosmetic: `examples/sandbox.tscn` runs a server and two clients in one tree, and
## three worlds registered under one name means two of them are invisible and the module
## binds to whichever registered last.
@export var service_scope: StringName = &""

## The space, its bounds and its spatial index.
var arena: Dot2DArena = null

## How a person moves. One instance, shared: it is read-only during a tick.
var tunables: Dot2DTunables = null

var motor: Dot2DMotor = null

## session id -> [RoomOccupant].
var occupants: Dictionary = {}

## What people have put in the room, or null on a world that has none.
##
## [b]Assigned rather than created here, and null is a legitimate value.[/b] The world is
## the thing a client replays and the props are the thing an operator can turn off; a
## world that built its own would make `sv_room_props 0` a world with a different
## simulation rather than a room with nothing in it. [RoomModule] creates it on the
## authority and [RoomClient] on a client, and both hand it here — which is also what
## makes `examples/headless_room.tscn` able to run the movement with no prop layer at all
## and get the same answer.
var props: RoomProps = null

var _tick: int = 0
var _registered_name: StringName = &""
var _ready_called: bool = false


func _ready() -> void:
	if auto_setup:
		setup()


func _exit_tree() -> void:
	if _registered_name != &"":
		DotRegistry.unregister(_registered_name)
		_registered_name = &""


# --- Lifecycle -------------------------------------------------------------

## Builds the arena and the motor. Call once, before anything else.
func setup() -> DotResult:
	if _ready_called:
		return DotResult.success(self)

	_ready_called = true
	tunables = RoomContent.tunables()

	var valid := tunables.validate()

	if not valid.ok:
		return valid.wrap("The room's movement tunables are not usable")

	arena = Dot2DArena.new()
	arena.name = "Arena"
	arena.bounds = RoomContent.bounds()
	arena.cell_size = 256.0
	arena.bounce_off_walls = false
	# The room's own arena is never looked up by name. Two worlds in one process would
	# otherwise fight over the registry entry, and dot-2d's is not the one anybody here
	# wants: [constant SERVICE] is.
	arena.register_service = false
	add_child(arena)

	var ready := arena.setup()

	if not ready.ok:
		return ready.wrap("The arena could not be set up")

	motor = Dot2DMotor.with_tunables(tunables)
	motor.body = arena.body

	if register_service:
		_registered_name = (
			DotRegistry.scoped_name(SERVICE, service_scope)
			if service_scope != &""
			else SERVICE
		)
		DotRegistry.register(_registered_name, self)

	DotLog.info(CHANNEL, "room ready", {
		"authority": is_authority,
		"bounds": arena.bounds,
		"tick_rate": tick_rate,
	})

	return DotResult.success(self)


func current_tick() -> int:
	return _tick


func tick_duration() -> float:
	return 1.0 / float(maxi(1, tick_rate))


# --- Membership ------------------------------------------------------------

## Puts somebody in the room.
##
## [param id] is a session id. Refused rather than replaced if it is already here: a
## duplicate join is a bug in whatever called this, and silently overwriting the
## occupant would move a player who is standing still and lose their chat bubble.
func add_occupant(id: int, display_name: String) -> DotResult:
	if id == 0:
		return DotResult.fail(DotError.CODE_INVALID, "An occupant needs a non-zero id.")

	if occupants.has(id):
		return DotResult.fail(
			DotError.CODE_STATE, "%d is already in the room." % id
		)

	if occupants.size() >= RoomContent.MAX_OCCUPANTS:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The room is full (%d)." % RoomContent.MAX_OCCUPANTS,
			"everybody in a lobby is relevant to everybody else, which is what caps it"
		)

	# The spawn is pushed out of the furniture before anybody is placed on it.
	#
	# [b]A lobby that puts somebody inside a pillar is broken, and quietly.[/b]
	# `Dot2DArena.spawn_position` knows the room's rectangle and nothing about what is
	# standing in it, so on a room with furniture a share of its answers are inside
	# something — and the first thing that happens is that the simulation shoves the new
	# arrival out. That is a correction on the tick they join, on both ends, from
	# slightly different starting states, and it showed up as a measurably worse
	# prediction rate under packet loss long before anybody would have noticed a person
	# standing in a bench.
	#
	# Resolved with the same static function the simulation uses, so the two cannot
	# drift apart.
	var placed := RoomContent.resolve_furniture(
		arena.spawn_position(id, RoomContent.OCCUPANT_RADIUS * 4.0),
		RoomContent.OCCUPANT_RADIUS,
		[]
	)

	var occupant := RoomOccupant.create(
		id,
		display_name.substr(0, RoomContent.NAME_BYTES),
		placed
	)

	occupants[id] = occupant
	arena.register(id, occupant.state)
	occupant_joined.emit(occupant)

	return DotResult.success(occupant)


## Takes somebody out of the room.
##
## The signal fires before the entry is erased, so a listener can still ask who left —
## which is the entire content of a leave notification.
func remove_occupant(id: int) -> bool:
	var occupant := occupant_for(id)

	if occupant == null:
		return false

	occupant_left.emit(occupant)
	arena.forget(id)
	occupants.erase(id)
	return true


func occupant_for(id: int) -> RoomOccupant:
	return occupants.get(id)


func occupant_count() -> int:
	return occupants.size()


## Everybody, oldest first.
##
## Sorted rather than in dictionary order because this is what the roster is drawn from,
## and a list that reordered itself whenever somebody left is a list nobody can read.
func roster() -> Array[RoomOccupant]:
	var out: Array[RoomOccupant] = []

	for key in occupants.keys():
		out.append(occupants[key])

	out.sort_custom(
		func(a: RoomOccupant, b: RoomOccupant) -> bool:
			if a.joined_at != b.joined_at:
				return a.joined_at < b.joined_at
			return a.id < b.id
	)

	return out


# --- The tick --------------------------------------------------------------

## Advances everybody by one tick under the commands they sent.
##
## [param commands] is `session id -> Dot2DCommand`. Somebody with no command this tick
## keeps the last one they sent — a person who stopped dead every time a packet was late
## would stutter continuously on any connection worth having.
func tick(commands: Dictionary) -> void:
	_tick += 1
	var delta := tick_duration()

	for key in occupants.keys():
		var occupant: RoomOccupant = occupants[key]
		var command: Variant = commands.get(occupant.id)

		if command is Dot2DCommand:
			occupant.last_command = command

		simulate_occupant(occupant, occupant.last_command, delta, _tick)

	arena.sync_grid()


## One person, one tick. The whole of the movement, and the only thing a client predicts.
##
## Separate from [method tick] because prediction runs it for exactly one occupant and
## must not run anything else: [DotNetPredictor] reconciles one entity at a time, so
## anything a replay does that couples two entities is computed against whatever the
## other one happened to be holding.
func simulate_occupant(
	occupant: RoomOccupant,
	command: Dot2DCommand,
	delta: float,
	tick_number: int
) -> void:
	if occupant == null or occupant.state == null:
		return

	motor.simulate(occupant.state, command, delta, tick_number)

	# The motor's body already keeps a walker inside the room while it is *moving*.
	# Clamping again is not redundant: somebody standing still at the edge whose radius
	# changed — or who was placed there by a correction — is not moving, so nothing else
	# would put them back. game-blob found the same hole from the other direction, where
	# a blob that grew against a wall ended up 2.8 units outside it.
	occupant.state.position = arena.clamp_position(
		occupant.state.position, occupant.state.radius
	)

	# The furniture, resolved AFTER the walls.
	#
	# The order matters and only in one place: somebody squeezed between a wall and a
	# bench. Resolving the wall last would push them back into the bench and leave them
	# inside it; resolving the furniture last leaves them slightly outside the wall,
	# which the next tick's clamp fixes and which nobody can see. There is no order that
	# satisfies both at once, and the visible failure of one of them is much worse.
	var normals: Array = []
	occupant.state.position = RoomContent.resolve_furniture(
		occupant.state.position, occupant.state.radius, normals
	)

	# And then whatever people have put in the room, which is the same problem with a
	# list that changes. [b]Both ends resolve it and both ends resolve it here[/b], inside
	# the one function a client replays — a prop the server collides against and the
	# client does not is a player corrected out of a space that looks empty, which is the
	# furniture's own argument with a list that somebody edits while you are standing in
	# it. The list is cached by [RoomProps] rather than rebuilt, because this runs on
	# every occupant on every tick on both ends and again on every replayed tick.
	if props != null:
		occupant.state.position = RoomContent.resolve_circles(
			occupant.state.position, occupant.state.radius, props.obstacles(), normals
		)

	# The velocity going INTO whatever pushed them, removed.
	#
	# Without this a player holding a direction against the island is pushed out by the
	# resolve and accelerated straight back in by the motor on the very next tick, sixty
	# times a second. The position ends up correct and the movement reads as lag —
	# which is the worst way for a level to be wrong, because it sends the next person
	# to the netcode.
	for entry in normals:
		var normal: Vector2 = entry
		var into := occupant.state.velocity.dot(normal)

		if into < 0.0:
			occupant.state.velocity -= normal * into


## Advances the client's own clock without simulating anybody.
##
## A client's world does not tick: everybody else arrives interpolated and the local
## occupant is predicted by dot-net. What it still needs is a tick number, because that
## is what a chat bubble's lifetime and the roster's ordering are measured against.
func client_tick(tick_number: int) -> void:
	_tick = tick_number


# --- Reporting -------------------------------------------------------------

func describe() -> Dictionary:
	return {
		"authority": is_authority,
		"tick": _tick,
		"occupants": occupants.size(),
		"bounds": arena.bounds if arena != null else Rect2(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("room     : %s, tick %d" % [
		"authority" if is_authority else "mirror", _tick
	])
	out.append("bounds   : %s" % (arena.bounds if arena != null else Rect2()))
	out.append("occupants: %d / %d" % [occupants.size(), RoomContent.MAX_OCCUPANTS])

	for occupant in roster():
		out.append("  %6d  %-20s  %6.0f,%6.0f" % [
			occupant.id,
			occupant.display_name,
			occupant.position().x,
			occupant.position().y,
		])

	return out
