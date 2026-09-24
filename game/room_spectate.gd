extends Node

const RoomOccupant := preload("room_occupant.gd")
const RoomWorld := preload("room_world.gd")

## Watching somebody else in the room.
##
## [b]A lobby is the smallest possible use of dot-spectate, and that is why it is here.[/b]
## This project exists to be the staging area — the smallest thing that still exercises
## admission, membership, replication, prediction and chat — and a spectator camera is
## the same shape as all of those: a rule the server owns, a state a client mirrors, and
## a camera that has to point somewhere sensible when the thing it was following is gone.
##
## Nobody dies in a lobby, so there is no death camera and no hand-over chain. What is
## left is the part a lobby actually wants: `follow somebody`, which is what you do while
## you wait for the map to change, and a camera that copes when they leave.
##
## Two settings say so:
##
## - **A living occupant may watch**, because everybody here is alive and the rule from a
##   deathmatch would mean nobody could ever watch anything.
## - **Roaming is on.** A room is twenty metres across; a free camera over it is not an
##   advantage, it is how you look at the furniture.

const CHANNEL := "room.spectate"

var world: RoomWorld = null

var manager: DotSpectatorManager = null


func setup(p_world: RoomWorld) -> DotResult:
	world = p_world

	manager = DotSpectatorManager.new()
	manager.name = "SpectatorManager"
	manager.authoritative = world.is_authority
	manager.rules = _rules()
	manager.participants_fn = _participants
	# The side they are actually on, not a constant.
	#
	# dot-spectate keys teams by [code]int[/code] and treats 0 as "no team". A hardcoded
	# 1 made everybody — including somebody on the spectator side — a team-mate of
	# everybody, which is what `force_camera` reads as permission to watch. The stack is
	# built before anything can spectate, and 0 is the honest answer while it is not.
	manager.team_fn = func(key: String) -> int:
		return world.player_stack.team_index_of(key) if world.player_stack != null else 0
	# Everybody in a lobby is alive. Answering anything else here would make every
	# occupant unwatchable, which is the whole feature.
	manager.alive_fn = func(key: String) -> bool:
		return world.occupant_for(key.to_int()) != null
	manager.pose_fn = _pose_of
	add_child(manager)

	var res := manager.setup()
	if not res.ok:
		return res.wrap("room spectate")

	if not world.occupant_left.is_connected(_on_left):
		world.occupant_left.connect(_on_left)

	return DotResult.success(null)


func _rules() -> DotSpectatorRules:
	var rules := DotSpectatorRules.new()
	rules.force_camera = 0
	rules.allow_while_alive = true
	rules.allow_roaming = true
	rules.cycle_includes_dead = true
	# Nobody dies here, so both cameras that exist for dying are off. Leaving them on
	# would be leaving two timers that can never fire, and a timer that can never fire
	# is a thing somebody eventually spends an afternoon on.
	rules.death_cam_ticks = 0
	rules.freeze_cam_ticks = 0
	rules.chase_distance = 3.0
	rules.chase_height = 0.0
	rules.history_ticks = 4 * world.tick_rate
	return rules


func _participants() -> PackedStringArray:
	var out := PackedStringArray()
	var ids: Array = []
	for key: Variant in world.occupants.keys():
		ids.append(int(key))
	ids.sort()
	for id: Variant in ids:
		out.append(str(id))
	return out


## An occupant's position, on the XZ plane the whole family maps 2D onto.
func _pose_of(key: String) -> Transform3D:
	var occupant := world.occupant_for(key.to_int())
	if occupant == null:
		return Transform3D.IDENTITY
	var at := occupant.position()
	return Transform3D(Basis.IDENTITY, Vector3(at.x, 0.0, at.y))


func tick(_delta: float) -> void:
	if manager != null:
		manager.advance(world.current_tick())


func watch(viewer: int, target: int) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Spectating is not set up.")
	var watched := manager.watch(str(viewer), str(target))
	# DEBUG either way: a decision, and the one a player reports as "the camera did
	# nothing" when it was refused.
	if watched.ok:
		DotLog.debug(CHANNEL, "watching", {"viewer": viewer, "target": target})
	else:
		DotLog.debug(CHANNEL, "watch refused", {
			"viewer": viewer, "target": target, "why": watched.error.message,
		})
	return watched


func next_target(viewer: int) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Spectating is not set up.")
	return manager.next_target(str(viewer))


func stop(viewer: int) -> void:
	if manager != null and manager.is_spectating(str(viewer)):
		manager.stop(str(viewer))
		DotLog.debug(CHANNEL, "stopped watching", {"viewer": viewer})


func is_spectating(viewer: int) -> bool:
	return manager != null and manager.is_spectating(str(viewer))


func watching(viewer: int) -> int:
	if manager == null:
		return 0
	var target := manager.view(str(viewer)).target
	return target.to_int() if target != "" else 0


## Where a viewer's camera should be, in room units, or null.
func camera_position(viewer: int) -> Variant:
	if manager == null or not manager.is_spectating(str(viewer)):
		return null
	var flat := manager.camera_2d_of(str(viewer))
	return flat[0] as Vector2


func _on_left(occupant: RoomOccupant) -> void:
	if manager == null:
		return
	# After the roster has dropped them, which is what dot-spectate's own note asks for:
	# the replacement target is chosen from the participants list, so reporting the
	# departure first picks the occupant who just left.
	var watchers: Array[int] = []
	for key: Variant in world.occupants.keys():
		if watching(int(key)) == occupant.id:
			watchers.append(int(key))

	manager.on_leave(str(occupant.id))

	# Only when somebody was watching: a camera that moved on its own is what a viewer
	# asks about, and a leave nobody was watching is the roster's news, not this.
	for viewer in watchers:
		DotLog.debug(CHANNEL, "the person being watched left", {
			"viewer": viewer, "left": occupant.id, "now": watching(viewer),
		})


func describe() -> Dictionary:
	return manager.describe() if manager != null else {}


func describe_lines() -> PackedStringArray:
	if manager == null:
		return PackedStringArray(["spectate: not set up"])
	return manager.describe_lines()
