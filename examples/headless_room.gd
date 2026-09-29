extends Node

const RoomContent := preload("../game/room_content.gd")
const RoomOccupant := preload("../game/room_occupant.gd")
const RoomWorld := preload("../game/room_world.gd")

## The room's own suite: membership, movement, bounds and determinism.
##
## [codeblock]
## godot --headless --path . res://examples/headless_room.tscn
## [/codeblock]
##
## Exits non-zero on any failure. No netcode, no server, no rendering — this is
## [RoomWorld] alone, which is the only part of the game that decides anything.

const CHECKS := 137

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

## Sections entered, and sections that ran to their last line.
##
## [b]A check count is not coverage.[/b] A runtime error inside a section aborts that
## function and nothing says so: the checks that already ran still print ok, the ones after
## it never happen, and the total at the bottom cannot reveal a check that never ran.
## dot-2d-hungry lost eight checks that way and the reported total went *up*.
var _entered := 0
var _completed := 0

## Where the walker of the leg being driven has been, a point a tick from where it started.
##
## [b]A route check here reads a position, and a position cannot say how the walker got
## there.[/b] Every leg below holds a direction for up to ten seconds, which at the room's
## speed is 2,600 units in a room 1,800 across, so a walker at a third of its speed
## arrives at every one of them and passes: with the stick at 30%, all 90 of the checks
## this file had before the trail still passed. The trail is what turns "arrived" into "arrived at walking pace":
## [method _leg] reads the distance covered and the time taken to the first tick the
## arrival held, and prints both beside the room's own [code]max_speed[/code] whether the
## check passes or not — a detail line shows only on failure, and a number that is only
## asserted is a number nobody reads again once it passes. The family learned that from
## `[bot-drive-1]`: game-playground's bots crossed its maps at 1 m/s of a 7 for as long
## as its checks existed, and every check passed.
var _trail := PackedVector2Array()
var _trail_world: RoomWorld = null

## The fraction of [code]max_speed[/code] a leg's average has to reach to count as
## walked at pace. [b]Averaged over the whole leg, run-up included[/b]: the room reaches
## full speed in five ticks (260 at 3200 u/s²), which costs a leg of 300 units about 4%.
## A walker sliding along a post rather than walking its lane is well under it.
const AT_PACE := 0.9


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("game-simple-lobby: the room")

	_test_setup()
	_test_membership()
	_test_capacity()
	_test_walking()
	_test_bounds()
	_test_wing()
	_test_gallery()
	_test_snug()
	_test_alcove()
	_test_booth()
	_test_bay()
	_test_landing()
	_test_earshot()
	_test_reach()
	_test_determinism()
	_test_bubbles()
	_test_spectating()

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


## A world of its own, unregistered, so several can exist in one run.
func _world(scope: StringName) -> RoomWorld:
	var world := RoomWorld.new()
	world.name = "World_%s" % scope
	world.is_authority = true
	world.register_service = false
	world.service_scope = scope
	add_child(world)
	world.setup()
	return world


func _walk(direction: Vector2) -> Dot2DCommand:
	var command := Dot2DCommand.new()
	command.move = direction.normalized()
	return command


## Starts a leg from where occupant 1 of [param world] stands now.
func _begin_leg(world: RoomWorld) -> void:
	_trail_world = world
	_trail = PackedVector2Array([world.occupant_for(1).position()])


## One tick of occupant 1 holding [param direction], recorded on the leg's trail.
func _stride(world: RoomWorld, direction: Vector2) -> void:
	world.tick({1: _walk(direction)})
	if world == _trail_world:
		_trail.append(world.occupant_for(1).position())


## How the leg went, up to the first tick [param arrived] held for the walker's position:
## the distance walked, the time it took, the straight line from the start, and the
## average speed against the room's [code]max_speed[/code]. [b]Printed, always.[/b]
## Returns that average as a fraction of [code]max_speed[/code], or 0.0 if the walker
## never arrived.
func _leg(what: String, arrived: Callable) -> float:
	var top := _trail_world.tunables.max_speed
	var tick := _trail_world.tick_duration()
	var walked := 0.0

	for i in range(1, _trail.size()):
		walked += _trail[i - 1].distance_to(_trail[i])

		if arrived.call(_trail[i]):
			var seconds := float(i) * tick
			var speed := walked / seconds
			print("  ..    %s: %.0f units walked in %.2f s (%.0f as the crow flies), %.0f u/s of a max_speed of %.0f (%.0f%%)"
				% [what, walked, seconds, _trail[0].distance_to(_trail[i]), speed, top,
					speed / top * 100.0])
			return speed / top

	print("  ..    %s: never arrived; %.0f units walked in %.2f s"
		% [what, walked, float(_trail.size() - 1) * tick])
	return 0.0


## The check every leg gets: arrived, at pace, with the numbers in the line.
func _at_pace(fraction: float, what: String) -> void:
	_check(
		fraction >= AT_PACE,
		"%s, at walking pace (%.0f%% of max_speed)" % [what, fraction * 100.0],
		"a walker that arrives slowly still arrives; only its speed tells a lane from a slide along a post"
	)


# --- Sections --------------------------------------------------------------

func _test_setup() -> void:
	_section("setting up")

	var world := _world(&"setup")

	_check(world.arena != null, "the world builds an arena")
	_check(
		world.arena.bounds.size.is_equal_approx(RoomContent.ROOM_EXTENT * 2.0),
		"the size RoomContent says (%s)" % world.arena.bounds.size
	)
	_check(world.motor != null, "and a motor")
	_check(
		world.motor.body == world.arena.body,
		"whose body is the arena's, so a walker is stopped by the same walls it is "
		+ "clamped to"
	)
	_check(world.occupant_count() == 0, "with nobody in it")
	_done()


## Watching somebody else, which is what you do in a lobby while you wait.
func _test_spectating() -> void:
	_section("spectating")

	var world := _world(&"spectate")

	if not _check(world.spectate != null, "the world builds a spectate layer"):
		_done()
		return

	var rules := world.spectate.manager.rules
	_check(
		rules.allow_while_alive,
		"a living occupant may watch, because everybody here is alive and the rule "
		+ "from a deathmatch would mean nobody could watch anything"
	)
	_check(
		rules.allow_roaming,
		"and may roam, because a free camera over a twenty-metre room is not an "
		+ "advantage, it is how you look at the furniture"
	)
	_check(
		rules.death_cam_ticks == 0 and rules.freeze_cam_ticks == 0,
		"with no death cameras at all: nobody dies here, and a timer that can never "
		+ "fire is a thing somebody eventually spends an afternoon on"
	)

	var a := world.add_occupant(1, "Ada")
	var b := world.add_occupant(2, "Bob")
	_check(a.ok and b.ok, "two people are in the room")

	var occupant_b := world.occupant_for(2)
	occupant_b.state.position = Vector2(120.0, -80.0)

	var watched := world.spectate.watch(1, 2)
	_check(watched.ok, "one can watch the other", str(watched.error))
	_check(world.spectate.watching(1) == 2, "and is watching them")

	world.tick({})

	var where: Variant = world.spectate.camera_position(1)
	_check(where != null, "the camera has a position")

	if where is Vector2:
		_check(
			(where as Vector2).distance_to(occupant_b.position()) < 1.0,
			"which is where that occupant actually is, on the XZ plane the whole "
			+ "family maps 2D onto",
			"%v against %v" % [where as Vector2, occupant_b.position()]
		)

	# The one thing a lobby camera really has to survive.
	world.remove_occupant(2)
	world.tick({})
	_check(
		world.spectate.watching(1) != 2,
		"and a target who leaves is not still being watched",
		str(world.spectate.watching(1))
	)

	_done()


func _test_membership() -> void:
	_section("membership")

	var world := _world(&"membership")
	var joins: Array[int] = []
	var leaves: Array[int] = []

	# Captured through an Array, not an int. GDScript lambdas capture locals by value, so
	# a counter incremented inside a handler stays zero outside it — and the test reports
	# a failure for a signal that fired perfectly.
	world.occupant_joined.connect(func(o: RoomOccupant) -> void: joins.append(o.id))
	world.occupant_left.connect(func(o: RoomOccupant) -> void: leaves.append(o.id))

	var first := world.add_occupant(11, "Ada")
	_check(first.ok, "somebody can enter")
	_check(joins == [11], "and the join is announced (%s)" % [joins])

	var again := world.add_occupant(11, "Ada")
	_check(
		not again.ok,
		"the same id cannot enter twice",
		"replacing them would move somebody standing still and lose their bubble"
	)

	world.add_occupant(12, "Grace")
	_check(world.occupant_count() == 2, "two people are in the room")

	var roster := world.roster()
	_check(roster.size() == 2, "the roster lists both")
	_check(
		roster[0].id == 11 and roster[1].id == 12,
		"oldest first, so a list somebody is reading does not reorder itself"
	)

	_check(world.remove_occupant(11), "somebody can leave")
	_check(leaves == [11], "and the leave is announced")
	_check(
		not world.remove_occupant(11), "leaving twice is refused rather than announced"
	)
	_check(world.occupant_count() == 1, "one person is left")
	_done()


func _test_capacity() -> void:
	_section("capacity")

	var world := _world(&"capacity")

	for index in range(RoomContent.MAX_OCCUPANTS):
		world.add_occupant(1000 + index, "P%d" % index)

	_check(
		world.occupant_count() == RoomContent.MAX_OCCUPANTS,
		"the room fills to %d" % RoomContent.MAX_OCCUPANTS
	)

	var overflow := world.add_occupant(9999, "One too many")
	_check(
		not overflow.ok,
		"and refuses the next one",
		"everybody in a lobby is relevant to everybody else, which is what caps it"
	)
	_done()


func _test_walking() -> void:
	_section("walking")

	var world := _world(&"walking")
	world.add_occupant(1, "Walker")

	var occupant := world.occupant_for(1)
	var start := occupant.position()

	for _i in range(30):
		world.tick({1: _walk(Vector2.RIGHT)})

	# [b]How far, against how far the room's own numbers say.[/b] This asked for "more than
	# 40 units" in half a second, which a walker at 35% of its speed passes. Half a
	# second at max_speed, less what the run-up costs (v² / 2a), is the distance: 119.4
	# units at 260 and 3200. Printed as well as asserted, because once it passes nobody
	# reads the detail line again.
	var top := world.tunables.max_speed
	var seconds := 30.0 * world.tick_duration()
	var owed := top * seconds - top * top / (2.0 * world.tunables.acceleration)
	var moved := occupant.position() - start
	print("  ..    holding a direction: %.2f u/s of a max_speed of %.2f; %.1f units in %.2f s, %.1f owed"
		% [occupant.state.speed(), top, moved.x, seconds, owed])
	_check(
		absf(occupant.state.speed() - top) < 0.01,
		"a walker holding a direction travels at the room's max_speed (%.2f of %.2f u/s)"
			% [occupant.state.speed(), top]
	)
	_check(
		moved.x >= owed * 0.98,
		"half a second of walking covers what max_speed owes, run-up and all (%.1f of %.1f units)"
			% [moved.x, owed]
	)
	_check(absf(moved.y) < 0.5, "and only in the direction asked for")

	# And diagonally, which is two keys and the same speed: a command that summed its
	# axes would walk corners at 1.41 times the room's speed, and one that clamped each
	# axis would walk them at 0.71 of it on a pad.
	occupant.state.velocity = Vector2.ZERO
	for _i in range(30):
		world.tick({1: _walk(Vector2(1.0, 1.0))})
	print("  ..    holding two keys: %.2f u/s of a max_speed of %.2f" % [occupant.state.speed(), top])
	_check(
		absf(occupant.state.speed() - top) < 0.01,
		"and holding two keys travels at the same speed, not 1.41 or 0.71 of it (%.2f u/s)"
			% occupant.state.speed()
	)

	# The command is kept rather than cleared. Somebody who stopped dead on every tick a
	# packet was late would stutter continuously on any connection worth having.
	var before := occupant.position()
	world.tick({})
	_check(
		occupant.position().x > before.x,
		"a tick with no command keeps walking, because the last one is still in force"
	)

	for _i in range(60):
		world.tick({1: Dot2DCommand.new()})

	_check(
		occupant.state.speed() < 1.0,
		"and releasing everything stops you (%.2f u/s)" % occupant.state.speed()
	)
	_done()


func _test_bounds() -> void:
	_section("the walls")

	var world := _world(&"bounds")
	world.add_occupant(1, "Wanderer")

	var occupant := world.occupant_for(1)

	# Long enough to cross the room several times over from anywhere in it.
	for _i in range(600):
		world.tick({1: _walk(Vector2(1.0, 1.0))})

	var at := occupant.position()
	var room := world.arena.bounds
	var radius := occupant.state.radius

	_check(
		at.x <= room.end.x - radius + 0.001 and at.y <= room.end.y - radius + 0.001,
		"walking into the corner does not leave the room (%.1f, %.1f)" % [at.x, at.y]
	)

	# Placed outside by hand and ticked with nothing held. The motor only clamps something
	# that is *moving*; game-blob measured a cell 2.8 units past the wall because of
	# exactly this, and [method RoomWorld.simulate_occupant] clamps unconditionally for
	# that reason.
	occupant.state.position = room.end + Vector2(500.0, 500.0)
	occupant.state.velocity = Vector2.ZERO
	world.tick({1: Dot2DCommand.new()})

	at = occupant.position()
	_check(
		at.x <= room.end.x - radius + 0.001 and at.y <= room.end.y - radius + 0.001,
		"and somebody standing still outside it is put back (%.1f, %.1f)" % [at.x, at.y]
	)
	_done()


## The partition and the room behind it.
##
## [b]A level here is a list of circles, so the only thing that proves it is a level is
## walking it.[/b] Everything else about this room — the renderer, the roster, the
## resolve — is happy with a wall that has a hole in it, or with one that has no way
## through at all, and both of those are the same list with different numbers in it.
func _test_wing() -> void:
	_section("the wing behind the partition")

	var world := _world(&"wing")
	world.add_occupant(1, "Wanderer")

	var occupant := world.occupant_for(1)

	# Straight at a post, from the middle of the hall. Long enough to cross the whole
	# room twice, so arriving at the wall is not a matter of how far they got.
	occupant.state.position = Vector2(-200.0, 300.0)
	occupant.state.velocity = Vector2.ZERO

	for _i in range(600):
		world.tick({1: _walk(Vector2.LEFT)})

	_check(
		not RoomContent.in_wing(occupant.position()),
		"walking into the partition does not go through it (%.0f, %.0f)"
			% [occupant.position().x, occupant.position().y]
	)

	# And the same walker, lined up with the doorway. Nothing steers here: the command
	# is due west for the whole run, which is the point — a door that has to be aimed at
	# is a door nobody uses.
	occupant.state.position = Vector2(-200.0, 0.0)
	occupant.state.velocity = Vector2.ZERO
	_begin_leg(world)

	for _i in range(600):
		_stride(world, Vector2.LEFT)

	var through := occupant.position()
	_check(
		RoomContent.in_wing(through),
		"and the doorway leads into the wing (%.0f, %.0f)" % [through.x, through.y]
	)
	_at_pace(
		_leg("hall to wing through the doorway", func(at: Vector2) -> bool:
			return RoomContent.in_wing(at)),
		"and is walked through rather than squeezed through"
	)

	# Out again, so the wing is a room rather than a trap.
	_begin_leg(world)
	for _i in range(600):
		_stride(world, Vector2.RIGHT)

	_check(
		not RoomContent.in_wing(occupant.position()),
		"and back out to the hall (%.0f, %.0f)"
			% [occupant.position().x, occupant.position().y]
	)
	_at_pace(
		_leg("wing to hall", func(at: Vector2) -> bool:
			return not RoomContent.in_wing(at)),
		"and back out"
	)

	# The wing has something in it. A second room with nothing to stand behind is a
	# corridor with a wide end.
	var standing := 0

	for piece in RoomContent.furniture():
		if RoomContent.in_wing(Vector2(piece.x, piece.y)):
			standing += 1

	_check(standing >= 3, "and something to stand behind when you get there (%d)" % standing)

	# --- The wing's LENGTH, which is a different question from its door ------
	#
	# [b]Every check above walks ACROSS the wing and none of them walks ALONG it.[/b]
	# The wing is a strip 280 units wide with a walker's usable band narrower still —
	# the partition's posts eat 90 of it and the west wall another 22 — so a single
	# piece of furniture in the middle of it closes the whole room off, and the
	# renderer, the roster and the resolve are all perfectly happy with that. Walking
	# the door proves the door.
	var walker := world.occupant_for(1)
	walker.state.position = Vector2(-750.0, 0.0)
	walker.state.velocity = Vector2.ZERO
	_begin_leg(world)

	for _i in range(600):
		_stride(world, Vector2.UP)

	var north := walker.position()
	_check(
		RoomContent.in_wing(north) and north.y < -420.0,
		"the wing can be walked from its middle to its north end (%.0f, %.0f)"
			% [north.x, north.y],
		"one piece of furniture in a 280-wide strip closes it, and nothing else notices"
	)
	_at_pace(
		_leg("the wing, middle to north end", func(at: Vector2) -> bool:
			return RoomContent.in_wing(at) and at.y < -420.0),
		"and walked, not scraped along a post"
	)

	# And out the other end. The partition has two ways through it, so the wing is a
	# circuit rather than a pocket you have to back out of — which is what stops one
	# person standing in a doorway from being a locked door.
	_begin_leg(world)
	for _i in range(400):
		_stride(world, Vector2.RIGHT)

	var out := walker.position()
	_check(
		not RoomContent.in_wing(out) and out.y < -420.0,
		"and left by the north gate rather than by the door it came in (%.0f, %.0f)"
			% [out.x, out.y]
	)
	_at_pace(
		_leg("the wing's north gate, out to the hall", func(at: Vector2) -> bool:
			return not RoomContent.in_wing(at)),
		"and out through the gate"
	)

	# South, the whole way, from the same start. A lane that exists only north of the
	# doorway is half a room.
	walker.state.position = Vector2(-750.0, 0.0)
	walker.state.velocity = Vector2.ZERO
	_begin_leg(world)

	for _i in range(600):
		_stride(world, Vector2.DOWN)

	var south := walker.position()
	_check(
		RoomContent.in_wing(south) and south.y > 420.0,
		"and from its middle to its south end (%.0f, %.0f)" % [south.x, south.y],
		"the south end is a dead end by design, but it has to be reachable"
	)
	_at_pace(
		_leg("the wing, middle to south end", func(at: Vector2) -> bool:
			return RoomContent.in_wing(at) and at.y > 420.0),
		"and walked"
	)
	_done()


## The gallery along the north wall: walked end to end, and out the far mouth.
##
## [b]The wing taught this project that a room is only a room if something has walked
## its length[/b], and it taught it the expensive way: the wing was impassable from the
## day it was built, and the renderer, the roster, the resolve and every check over it
## were perfectly happy. So the gallery is checked the way the wing is checked now
## rather than the way the wing was checked then — a walker goes in one mouth, along it,
## and out the other, with nothing steering.
func _test_gallery() -> void:
	_section("the gallery along the north wall")

	var world := _world(&"gallery")
	world.add_occupant(1, "Stroller")

	var occupant := world.occupant_for(1)

	# The screen is solid. Due north from the middle of the room, through the gap
	# between the two middle posts — which is not a gap: they overlap by
	# GALLERY_OVERLAP precisely so that a walker cannot be squeezed between them.
	occupant.state.position = Vector2(0.0, -200.0)
	occupant.state.velocity = Vector2.ZERO

	for _i in range(600):
		world.tick({1: _walk(Vector2.UP)})

	_check(
		not RoomContent.in_gallery(occupant.position()),
		"walking north at the middle of the screen does not go through it (%.0f, %.0f)"
			% [occupant.position().x, occupant.position().y]
	)

	# --- In by the west mouth, along, and out by the east -------------------

	# [b]Nothing steers.[/b] Due north to the wall, then due east until the far side —
	# two held directions, which is what makes this a statement about the room rather
	# than about the path somebody found through it.
	# Through the landing's door since 2026-09-29: the west mouth is its door now.
	occupant.state.position = Vector2(RoomContent.landing_door().x, -180.0)
	occupant.state.velocity = Vector2.ZERO
	_begin_leg(world)

	for _i in range(600):
		_stride(world, Vector2.UP)

	var mouth := occupant.position()
	_check(
		mouth.y < RoomContent.GALLERY_Y - RoomContent.GALLERY_POST_RADIUS,
		"a walker gets past the screen's west end into the strip (%.0f, %.0f)"
			% [mouth.x, mouth.y],
		"the pillars are the doorposts; a mouth narrower than a walker is a wall"
	)
	_at_pace(
		_leg("hall to the gallery's west mouth", func(at: Vector2) -> bool:
			return at.y < RoomContent.GALLERY_Y - RoomContent.GALLERY_POST_RADIUS),
		"and walks into it"
	)

	var went_in := false
	var shallowest := -INF
	_begin_leg(world)

	for _i in range(900):
		_stride(world, Vector2.RIGHT)

		if RoomContent.in_gallery(occupant.position()):
			went_in = true
			shallowest = maxf(shallowest, occupant.position().y)

	var out := occupant.position()

	_check(went_in, "and walks the length of the gallery rather than round it")
	_check(
		shallowest < RoomContent.GALLERY_Y,
		"staying behind the screen the whole way (nearest the hall %.0f, screen at %.0f)"
			% [shallowest, RoomContent.GALLERY_Y]
	)
	_check(
		not RoomContent.in_gallery(out) and out.x > 0.0
			and out.y < RoomContent.GALLERY_Y,
		"and leaves by the east mouth rather than backing out of the west (%.0f, %.0f)"
			% [out.x, out.y],
		"a nook with one way in is a pocket, and one person standing in it is a locked door"
	)
	_at_pace(
		_leg("the gallery, west mouth to east", func(at: Vector2) -> bool:
			return (not RoomContent.in_gallery(at) and at.x > 0.0
				and at.y < RoomContent.GALLERY_Y)),
		"and walks its length"
	)

	# --- It is empty, and that is the level rather than an omission ---------

	# [b]The opposite of the wing's check, deliberately.[/b] The wing needs something to
	# stand behind because it is a room you go to; the gallery IS the thing to stand
	# behind, and a strip this deep with furniture in it is the wing's own bug written
	# out a second time.
	# Anything whose centre is north of the screen's FACE, and within the screen's own
	# width, is standing in the strip. The screen's own posts are on the line and are the
	# wall of it, not furniture in it. [b]Within its width since 2026-09-26[/b]: the booth's
	# west arm runs to the north wall at x 640, north of the face and 390 east of the
	# strip's end, and the check counted five of its posts as furniture in the gallery.
	var standing := 0
	var face := RoomContent.GALLERY_Y - RoomContent.GALLERY_POST_RADIUS

	for piece in RoomContent.furniture():
		var at := Vector2(piece.x, piece.y)
		if piece.y < face and RoomContent.in_gallery(at) and not RoomContent.in_wing(at):
			standing += 1

	_check(
		standing == 0,
		"and nothing stands inside it (%d)" % standing,
		"four occupant diameters deep is two people talking and two getting past"
	)

	# --- Both mouths are wider than the front door --------------------------

	# [b]Measured against the furniture that exists, not against the constants.[/b] The
	# mouths are gaps between two different things placed by two different rules — a
	# screen post and a pillar — so the only honest way to ask how wide they are is to
	# measure every pair. A slot eight units wide is the family's own recurring bug and
	# it looks like a way through in every picture of it.
	var screen := RoomContent.gallery_screen()
	var narrowest := INF

	if not _check(screen.size() == RoomContent.GALLERY_POSTS, "the screen is six posts"):
		_done()
		return

	for post in screen:
		for other in RoomContent.furniture():
			var at := Vector2(other.x, other.y)

			# Itself, its neighbours in the screen, and the wing across the room.
			if absf(at.y - post.y) < 1.0 or RoomContent.in_wing(at):
				continue

			narrowest = minf(
				narrowest,
				Vector2(post.x, post.y).distance_to(at) - post.z - other.z
			)

	_check(
		is_finite(narrowest) and narrowest > RoomContent.DOORWAY_SPAN,
		"and the narrowest way past it anywhere is wider than the front door (%.0f against %.0f)"
			% [narrowest, RoomContent.DOORWAY_SPAN],
		"this measures the hall's north lane as well as the two mouths, and the lane is what moving the screen south would close"
	)

	_done()


## The snug in the south-east corner: in one gate, round the seat, and out the other.
##
## [b]Driven, both ways round, because a corner room has two ways to be a pocket.[/b] The
## wing was a corridor with a cork in each end and the gallery's first check measured an
## empty set; both were lists of circles every other check was happy with. So this
## walks it — two held directions each way, nothing steering — and then measures every
## gap the snug makes against the furniture that exists, walls included.
func _test_snug() -> void:
	_section("the snug in the south-east corner")

	var world := _world(&"snug")
	world.add_occupant(1, "Lounger")

	var walker := world.occupant_for(1)
	var seat := RoomContent.snug_seat()
	var seat_at := Vector2(seat.x, seat.y)

	# The corner holds. Due south-east from the hall, straight at the post the two arms
	# share — which is where a join between two separately built arms would have left a
	# diagonal slot.
	var corner := Vector2(RoomContent.SNUG_X, RoomContent.SNUG_Y)
	walker.state.position = corner - Vector2(140.0, 140.0)
	walker.state.velocity = Vector2.ZERO

	for _i in range(600):
		world.tick({1: _walk(Vector2(1.0, 1.0))})

	_check(
		not RoomContent.in_snug(walker.position()),
		"walking into the corner of the L does not go through it (%.0f, %.0f)"
			% [walker.position().x, walker.position().y]
	)

	# --- In by the east gate, out by the south ------------------------------

	# Down the east wall from the benches. The gate is DOORWAY_SPAN against the wall and
	# the seat stops on the gate's inner edge, so this lane should never touch it.
	# Down the middle of the gate, which is where somebody walking in without aiming is.
	var gate_post := Vector2(RoomContent.SNUG_GATE_X, RoomContent.SNUG_Y)
	walker.state.position = Vector2(
		RoomContent.ROOM_EXTENT.x - RoomContent.DOORWAY_SPAN * 0.5, 0.0
	)
	walker.state.velocity = Vector2.ZERO
	var nearest_seat := INF
	var nearest_post := INF
	_begin_leg(world)

	for _i in range(600):
		_stride(world, Vector2.DOWN)
		nearest_seat = minf(
			nearest_seat, walker.position().distance_to(seat_at) - seat.z - walker.state.radius
		)
		nearest_post = minf(
			nearest_post,
			walker.position().distance_to(gate_post)
				- RoomContent.SNUG_POST_RADIUS - walker.state.radius
		)

	var down := walker.position()
	_check(
		RoomContent.in_snug(down) and down.y > RoomContent.SNUG_GATE_Y,
		"a walker holding south comes in by the east gate to the far wall (%.0f, %.0f)"
			% [down.x, down.y],
		"the gate is a door against the wall; a post or a seat in the lane is a cork"
	)
	_at_pace(
		_leg("the benches down through the snug's east gate", func(at: Vector2) -> bool:
			return RoomContent.in_snug(at) and at.y > RoomContent.SNUG_GATE_Y),
		"and walks in"
	)
	# [b]No nearer than the gate's own post, rather than merely not touching.[/b] A seat
	# whose face stood on the gate's inner edge would be passed exactly as close as the
	# post beside it is; any closer and it is standing in the lane. The first version of
	# this asked only "did not touch", and passed with the seat twelve units into it.
	_check(
		nearest_seat >= nearest_post - 0.5,
		"with the seat standing no further into the lane than the gate's own post (%.1f against %.1f)"
			% [nearest_seat, nearest_post],
		"a doorway that opens onto a table is the wing's bug"
	)

	var inside := false
	var went_back := false
	_begin_leg(world)

	for _i in range(600):
		_stride(world, Vector2.LEFT)

		if RoomContent.in_snug(walker.position()):
			inside = true

		if walker.position().y < RoomContent.SNUG_Y:
			went_back = true

	var out := walker.position()
	_check(
		inside and not went_back,
		"and crosses it under the seat rather than going back the way it came"
	)
	_check(
		not RoomContent.in_snug(out) and out.x < RoomContent.SNUG_X
			and out.y > RoomContent.SNUG_GATE_Y,
		"and leaves by the south gate (%.0f, %.0f)" % [out.x, out.y],
		"a corner room with one way out is a pocket, and one person in it is a locked door"
	)
	_at_pace(
		_leg("across the snug and out of its south gate", func(at: Vector2) -> bool:
			return (not RoomContent.in_snug(at) and at.x < RoomContent.SNUG_X
				and at.y > RoomContent.SNUG_GATE_Y)),
		"and walks across"
	)

	# --- And the other way round -------------------------------------------

	walker.state.position = Vector2(
		RoomContent.SNUG_X - 150.0, RoomContent.ROOM_EXTENT.y - 30.0
	)
	walker.state.velocity = Vector2.ZERO
	_begin_leg(world)

	for _i in range(600):
		_stride(world, Vector2.RIGHT)

	var along := walker.position()
	_check(
		RoomContent.in_snug(along) and along.x > RoomContent.SNUG_GATE_X,
		"in by the south gate and along the wall to the corner (%.0f, %.0f)"
			% [along.x, along.y]
	)
	_at_pace(
		_leg("in by the snug's south gate", func(at: Vector2) -> bool:
			return RoomContent.in_snug(at) and at.x > RoomContent.SNUG_GATE_X),
		"walked, both ways round"
	)

	_begin_leg(world)
	for _i in range(600):
		_stride(world, Vector2.UP)

	var up := walker.position()
	_check(
		not RoomContent.in_snug(up) and up.y < RoomContent.SNUG_Y,
		"and out by the east gate (%.0f, %.0f)" % [up.x, up.y]
	)
	_at_pace(
		_leg("out by the snug's east gate", func(at: Vector2) -> bool:
			return not RoomContent.in_snug(at) and at.y < RoomContent.SNUG_Y),
		"and out"
	)

	# --- Every gap it makes, against what is actually there ----------------

	# [b]Walls included, because both gates are against one.[/b] The gallery's check
	# measured circle against circle and that was right for a screen standing free; a
	# gate derived against a wall is a gap no circle-pair ever sees. The seat against its
	# own screen is skipped: those gaps seal the crook behind it, which nobody can reach
	# and nobody is meant to.
	var screen := RoomContent.snug_screen()

	if not _check(
		screen.size() == 1 + RoomContent.SNUG_ARM_POSTS * 2,
		"the L is a shared corner and two arms (%d posts)" % screen.size()
	):
		_done()
		return

	var mine := PackedVector3Array(screen)
	mine.append(seat)
	var narrowest := INF
	var where := ""
	var room := RoomContent.bounds()

	for piece in mine:
		var at := Vector2(piece.x, piece.y)

		for gap in [
			room.end.x - at.x - piece.z, room.end.y - at.y - piece.z,
		]:
			if gap < narrowest:
				narrowest = gap
				where = "(%.0f, %.0f) to a wall" % [at.x, at.y]

		for other in RoomContent.furniture():
			if other in mine:
				continue

			var gap := at.distance_to(Vector2(other.x, other.y)) - piece.z - other.z

			if gap < narrowest:
				narrowest = gap
				where = "(%.0f, %.0f) to (%.0f, %.0f)" % [at.x, at.y, other.x, other.y]

	_check(
		is_finite(narrowest) and narrowest >= RoomContent.DOORWAY_SPAN - 0.01,
		"and nothing about it is narrower than the front door (%.0f against %.0f, %s)"
			% [narrowest, RoomContent.DOORWAY_SPAN, where],
		"its two gates are the door's width by derivation; anything narrower is a slot"
	)
	_done()


func _test_alcove() -> void:
	_section("the alcove off the south wall")

	var world := _world(&"alcove")
	world.add_occupant(1, "Stroller")

	var walker := world.occupant_for(1)
	var bow := RoomContent.alcove_screen()
	var lane_y := RoomContent.ROOM_EXTENT.y - RoomContent.DOORWAY_SPAN * 0.5

	# The bow is a wall. Straight down at its middle from the hall, which is the one
	# direction a hole between two posts would show up as a way in.
	walker.state.position = Vector2(RoomContent.ALCOVE_X, 200.0)
	walker.state.velocity = Vector2.ZERO

	for _i in range(600):
		world.tick({1: _walk(Vector2.DOWN)})

	_check(
		not RoomContent.in_alcove(walker.position()),
		"walking into the middle of the bow does not go through it (%.0f, %.0f)"
			% [walker.position().x, walker.position().y]
	)

	# --- Along the wall, through both gates, on one held direction each way -----

	# Down the middle of the lane along the wall, which is where somebody walking in
	# without aiming is. [b]Untouched, not merely through:[/b] the lane is the door's
	# width by derivation, so anything that pushes a walker off their line in it is a
	# post standing in a doorway.
	for way in [Vector2.RIGHT, Vector2.LEFT]:
		var from := -1.0 if way == Vector2.RIGHT else 1.0
		walker.state.position = Vector2(
			RoomContent.ALCOVE_X + from * (RoomContent.ALCOVE_RADIUS + 60.0), lane_y
		)
		walker.state.velocity = Vector2.ZERO
		var inside := false
		var drift := 0.0
		_begin_leg(world)

		for _i in range(600):
			_stride(world, way)
			drift = maxf(drift, absf(walker.position().y - lane_y))

			if RoomContent.in_alcove(walker.position()):
				inside = true

			if (walker.position().x - RoomContent.ALCOVE_X) * -from \
					> RoomContent.ALCOVE_RADIUS + 40.0:
				break

		var out := walker.position()
		var heading := "east" if way == Vector2.RIGHT else "west"
		var entry := "west" if way == Vector2.RIGHT else "east"
		_check(
			inside and drift < 0.5,
			"holding %s along the wall goes in at the %s gate touching nothing (%.1f off the line)"
				% [heading, entry, drift],
			"the gate is the door's width against the wall; a push here is a post in the lane"
		)
		_check(
			not RoomContent.in_alcove(out)
				and (out.x - RoomContent.ALCOVE_X) * -from > RoomContent.ALCOVE_RADIUS,
			"and comes out of the %s gate into the hall (%.0f, %.0f)" % [heading, out.x, out.y],
			"an alcove with one way out is a pocket, and one person in it is a locked door"
		)
		_at_pace(
			_leg("along the wall through the alcove, %s" % heading, func(at: Vector2) -> bool:
				return (at.x - RoomContent.ALCOVE_X) * -from > RoomContent.ALCOVE_RADIUS + 40.0),
			"and walks it"
		)

	# --- The bow has no hole in it, and makes no slot ---------------------------

	var widest := 0.0

	for index in range(1, bow.size()):
		widest = maxf(
			widest,
			Vector2(bow[index].x, bow[index].y).distance_to(
				Vector2(bow[index - 1].x, bow[index - 1].y)
			)
		)

	_check(
		bow.size() >= 3 and widest <= RoomContent.ALCOVE_POST_RADIUS * 2.0
			- RoomContent.GALLERY_OVERLAP + 0.01,
		"its %d posts overlap by at least the partition's %.0f (%.1f apart at most)"
			% [bow.size(), RoomContent.GALLERY_OVERLAP, widest],
		"two circles that merely touch leave a point the resolve pushes a walker through"
	)

	# Walls included, for the snug's reason: both gates are against one.
	var narrowest := INF
	var where := ""
	var room := RoomContent.bounds()

	for piece in bow:
		var at := Vector2(piece.x, piece.y)

		for gap in [
			room.end.y - at.y - piece.z, at.x - piece.z - room.position.x,
			room.end.x - at.x - piece.z,
		]:
			if gap < narrowest:
				narrowest = gap
				where = "(%.0f, %.0f) to a wall" % [at.x, at.y]

		for other in RoomContent.furniture():
			if other in bow:
				continue

			var gap := at.distance_to(Vector2(other.x, other.y)) - piece.z - other.z

			if gap < narrowest:
				narrowest = gap
				where = "(%.0f, %.0f) to (%.0f, %.0f)" % [at.x, at.y, other.x, other.y]

	_check(
		is_finite(narrowest) and narrowest >= RoomContent.DOORWAY_SPAN - 0.01,
		"and nothing about it is narrower than the front door (%.1f against %.0f, %s)"
			% [narrowest, RoomContent.DOORWAY_SPAN, where],
		"its gates are the door's width by derivation; anything narrower is a slot"
	)
	_done()


func _test_booth() -> void:
	_section("the booth in the north-east corner")

	var world := _world(&"booth")
	world.add_occupant(1, "Stroller")
	var walker := world.occupant_for(1)
	var door := RoomContent.booth_door()

	# In through the doorway on one held direction, touching nothing, and out again.
	for way in [Vector2.UP, Vector2.DOWN]:
		var from := door + Vector2(0.0, 200.0 if way == Vector2.UP else -150.0)
		walker.state.position = from
		walker.state.velocity = Vector2.ZERO
		var drift := 0.0
		_begin_leg(world)

		for _i in range(600):
			_stride(world, way)
			drift = maxf(drift, absf(walker.position().x - door.x))
			var past := walker.position().y < door.y - 120.0 if way == Vector2.UP \
				else walker.position().y > door.y + 120.0
			if past:
				break

		var inside := RoomContent.in_booth(walker.position())
		_check(
			(inside if way == Vector2.UP else not inside) and drift < 0.5,
			"holding %s through the booth's doorway goes %s touching nothing (%.1f off the line)"
				% ["north" if way == Vector2.UP else "south",
					"in" if way == Vector2.UP else "out", drift]
		)
		# To the break condition above, which is 120 past the door on the far side.
		_at_pace(
			_leg("through the booth's doorway, %s" % ("in" if way == Vector2.UP else "out"),
				func(at: Vector2) -> bool:
					return at.y < door.y - 120.0 if way == Vector2.UP else at.y > door.y + 120.0),
			"and walks it"
		)

	# Its walls are walls: straight at the south arm beside the doorway, and at the west arm.
	for probe in [
		# At a post's centre, head on: aimed between two it slides along the arm into
		# the doorway, which is the doorway working.
		[Vector2(RoomContent.BOOTH_X + RoomContent.BOOTH_SPACING, -230.0), Vector2.UP, "south arm"],
		[Vector2(RoomContent.BOOTH_X - 150.0, -450.0), Vector2.RIGHT, "west arm"],
	]:
		walker.state.position = probe[0]
		walker.state.velocity = Vector2.ZERO

		for _i in range(600):
			world.tick({1: _walk(probe[1])})

		_check(
			not RoomContent.in_booth(walker.position()),
			"walking into its %s does not go through (%.0f, %.0f)"
				% [probe[2], walker.position().x, walker.position().y]
		)

	# No hole, and nothing about it narrower than the front door, walls included.
	var screen := RoomContent.booth_screen()
	var narrowest := INF
	var where := ""
	var room := RoomContent.bounds()

	for piece in screen:
		var at := Vector2(piece.x, piece.y)

		for other in RoomContent.furniture():
			if other in screen:
				continue
			var gap := at.distance_to(Vector2(other.x, other.y)) - piece.z - other.z
			if gap < narrowest:
				narrowest = gap
				where = "(%.0f, %.0f) to (%.0f, %.0f)" % [at.x, at.y, other.x, other.y]

	var south: Array[float] = []
	for piece in screen:
		if is_equal_approx(piece.y, RoomContent.BOOTH_Y):
			south.append(piece.x)
	south.sort()
	var widest := 0.0
	for index in range(1, south.size()):
		widest = maxf(widest, south[index] - south[index - 1] - RoomContent.BOOTH_POST_RADIUS * 2.0)

	_check(
		absf(widest - RoomContent.DOORWAY_SPAN) < 0.01 and south[south.size() - 1]
			+ RoomContent.BOOTH_POST_RADIUS >= room.end.x,
		"its one doorway is the front door's width, and the south arm runs into the east wall (%.1f)"
			% widest
	)
	_check(
		narrowest >= RoomContent.DOORWAY_SPAN - 0.01,
		"and it leaves nothing in the hall narrower than the front door (%.1f, %s)"
			% [narrowest, where]
	)
	_done()


## The bay: a room off the south wall between the alcove and the snug, its front joined to
## the south-east pillar. See [constant RoomContent.BAY_Y].
##
## [b]Driven as a circuit, and then as the walk it makes.[/b] From the hall down the
## passage west of it, east along the wall through both its gates, and up the passage east
## of it back to the hall: three held directions, nothing steering. Then the south wall end
## to end on one held direction, from west of the alcove into the snug — the route the
## alcove, the bay and the snug make together, which nothing had walked whole.
func _test_bay() -> void:
	_section("the bay off the south wall")

	var world := _world(&"bay")
	world.add_occupant(1, "Stroller")
	var walker := world.occupant_for(1)
	var screen := RoomContent.bay_screen()
	var west := RoomContent.bay_west_x()
	var east := RoomContent.BAY_EAST_X
	var extent := RoomContent.ROOM_EXTENT
	var r := RoomContent.BAY_POST_RADIUS
	var lane_y := extent.y - RoomContent.DOORWAY_SPAN * 0.5
	# The middles of the two passages, which is where somebody walking without aiming is.
	var west_passage := west - r - RoomContent.DOORWAY_SPAN * 0.5
	var east_passage := east + r + RoomContent.DOORWAY_SPAN * 0.5
	# Everything the circuit passes, so "touching nothing" is measured against what is there.
	var near := PackedVector3Array(screen)
	near.append_array(RoomContent.alcove_screen())
	near.append_array(RoomContent.snug_screen())
	near.append(Vector3(RoomContent.PILLAR_AT.x, RoomContent.PILLAR_AT.y, RoomContent.PILLAR_RADIUS))

	var clearance := func() -> float:
		var least := INF
		for piece in near:
			least = minf(least, walker.position().distance_to(Vector2(piece.x, piece.y))
				- piece.z - walker.state.radius)
		return least

	# --- Its walls are walls ------------------------------------------------------

	# At the front's middle from the hall, at the west arm from the passage beside it, and
	# at the east arm from the other side: the three directions a hole would be a way in.
	var held := 0
	for probe in [
		[Vector2((west + RoomContent.PILLAR_AT.x) * 0.5, 200.0), Vector2.DOWN],
		[Vector2(west_passage, 400.0), Vector2.RIGHT],
		[Vector2(east_passage, 400.0), Vector2.LEFT],
	]:
		walker.state.position = probe[0]
		walker.state.velocity = Vector2.ZERO
		for _i in range(600):
			world.tick({1: _walk(probe[1])})
		if not RoomContent.in_bay(walker.position()):
			held += 1

	_check(held == 3, "walking into its front or either arm does not go through (%d of 3 held)" % held)

	# --- The circuit: down the west passage, along the wall, up the east passage ----

	walker.state.position = Vector2(west_passage, 200.0)
	walker.state.velocity = Vector2.ZERO
	var least := INF
	_begin_leg(world)

	for _i in range(600):
		_stride(world, Vector2.DOWN)
		least = minf(least, clearance.call())
		if walker.position().y >= lane_y - 10.0:
			break

	_check(
		walker.position().y >= lane_y - 10.0 and least > 0.5,
		"holding south from the hall goes down the passage beside the alcove to the wall, touching nothing (%.1f clear)"
			% least
	)
	_at_pace(
		_leg("down the passage west of the bay", func(at: Vector2) -> bool:
			return at.y >= lane_y - 10.0),
		"and walks it"
	)

	least = INF
	var inside := false
	_begin_leg(world)

	for _i in range(600):
		_stride(world, Vector2.RIGHT)
		least = minf(least, clearance.call())
		inside = inside or RoomContent.in_bay(walker.position())
		if walker.position().x >= east_passage - 10.0:
			break

	_check(
		inside and walker.position().x >= east_passage - 10.0 and least > 0.5,
		"holding east along the wall goes in at the west gate and out of the east one, touching nothing (%.1f clear)"
			% least,
		"both gates are the door's width against the wall; a push here is a post in the lane"
	)
	_at_pace(
		_leg("along the wall through the bay", func(at: Vector2) -> bool:
			return at.x >= east_passage - 10.0),
		"and walks it"
	)

	least = INF
	_begin_leg(world)

	for _i in range(600):
		_stride(world, Vector2.UP)
		least = minf(least, clearance.call())
		if walker.position().y <= 200.0:
			break

	_check(
		walker.position().y <= 200.0 and least > 0.5,
		"and holding north goes up the passage beside the snug into the hall, touching nothing (%.1f clear)"
			% least
	)
	_at_pace(
		_leg("up the passage east of the bay", func(at: Vector2) -> bool:
			return at.y <= 200.0),
		"and walks it"
	)

	# --- The south wall, end to end ---------------------------------------------

	# From west of the alcove to the east wall inside the snug, down the middle of the lane
	# the alcove's, the bay's and the snug's gates all leave against the wall.
	walker.state.position = Vector2(RoomContent.ALCOVE_X - RoomContent.ALCOVE_RADIUS - 60.0, lane_y)
	walker.state.velocity = Vector2.ZERO
	var drift := 0.0
	var passed := {}
	_begin_leg(world)

	for _i in range(900):
		_stride(world, Vector2.RIGHT)
		drift = maxf(drift, absf(walker.position().y - lane_y))
		if RoomContent.in_alcove(walker.position()):
			passed["alcove"] = true
		if RoomContent.in_bay(walker.position()):
			passed["bay"] = true
		if RoomContent.in_snug(walker.position()):
			passed["snug"] = true
		if walker.position().x >= RoomContent.SNUG_GATE_X:
			break

	_check(
		passed.size() == 3 and drift < 0.5 and walker.position().x >= RoomContent.SNUG_GATE_X,
		"one held direction walks the south wall through the alcove, the bay and into the snug (%s; %.1f off the line)"
			% [", ".join(passed.keys()), drift]
	)
	_at_pace(
		_leg("the south wall, the alcove to the snug", func(at: Vector2) -> bool:
			return at.x >= RoomContent.SNUG_GATE_X),
		"and walks it"
	)

	# --- Derived, and joined -----------------------------------------------------

	# The two gates against the wall, and the two passages either side, each the door.
	var alcove_end := RoomContent.alcove_screen()[0]
	var widths := [
		extent.y - RoomContent.BAY_GATE_Y - r,
		west - r - alcove_end.x - alcove_end.z,
		RoomContent.SNUG_X - RoomContent.SNUG_POST_RADIUS - east - r,
	]
	var gates := true
	for width in widths:
		gates = gates and absf(width - RoomContent.DOORWAY_SPAN) < 0.01
	_check(
		gates and is_equal_approx(alcove_end.y, RoomContent.BAY_GATE_Y),
		"its gates and the passages either side are each the front door's width (%.1f, %.1f, %.1f), level with the alcove's end"
			% widths
	)

	# The pillar is part of the front. The post under it overlaps it by the partition's
	# twenty, and no other post of the bay leaves a gap to it that a walker could mistake
	# for a way through: whatever does not overlap it is at least the door away.
	var pillar := Vector2(RoomContent.PILLAR_AT.x, RoomContent.PILLAR_AT.y)
	var under := RoomContent.bay_pillar_post()
	var joined := r + RoomContent.PILLAR_RADIUS - under.distance_to(pillar)
	_check(
		absf(joined - RoomContent.GALLERY_OVERLAP) < 0.01,
		"its front is joined to the south-east pillar, overlapping it by %.1f" % joined,
		"stood clear of the pillar by the door, the bay could be 182 wide"
	)

	# Every neighbouring pair overlapping, so no hairline gap in any run.
	var widest := 0.0
	for index in range(1, screen.size()):
		var a := Vector2(screen[index - 1].x, screen[index - 1].y)
		var b := Vector2(screen[index].x, screen[index].y)
		# Runs restart at a corner; a pair that is not neighbours is skipped.
		if a.distance_to(b) < r * 2.0:
			widest = maxf(widest, a.distance_to(b))

	# And against everything else: nothing narrower than the front door, walls included.
	# The pillar is left out, because it is joined; the check above is its.
	var narrowest := INF
	var where := ""
	for piece in screen:
		var at := Vector2(piece.x, piece.y)
		for gap in [extent.y - at.y - piece.z]:
			if gap < narrowest:
				narrowest = gap
				where = "(%.0f, %.0f) to the south wall" % [at.x, at.y]
		for other in RoomContent.furniture():
			if other in screen or Vector2(other.x, other.y) == pillar:
				continue
			var gap := at.distance_to(Vector2(other.x, other.y)) - piece.z - other.z
			if gap < narrowest:
				narrowest = gap
				where = "(%.0f, %.0f) to (%.0f, %.0f)" % [at.x, at.y, other.x, other.y]

	_check(
		widest <= r * 2.0 - RoomContent.GALLERY_OVERLAP + 0.01
			and narrowest >= RoomContent.DOORWAY_SPAN - 0.01,
		"its posts overlap by at least %.0f (%.1f apart at most), and nothing about it is narrower than the front door (%.1f, %s)"
			% [RoomContent.GALLERY_OVERLAP, widest, narrowest, where]
	)

	# Somewhere to stand out of the lane: the floor above it holds two people.
	var above := extent.y - RoomContent.BAY_Y - r - RoomContent.DOORWAY_SPAN
	_check(
		above >= RoomContent.OCCUPANT_RADIUS * 4.0,
		"above the lane along the wall it has %.0f of floor, two people's %.0f"
			% [above, RoomContent.OCCUPANT_RADIUS * 4.0],
		"a room that is only its lane is a corridor with a name"
	)
	_done()


## The landing: the north-west corner of the hall, closed off by a front joined to the
## partition's north post and the north-west pillar, with its door against the gallery's
## west end. See [constant RoomContent.LANDING_POST_RADIUS].
##
## [b]Driven as the north wall's walk it makes[/b]: in from the hall by its door, west along
## the wall and out through the wing's north gate, back east across it into the gallery,
## and out of the door again. Four held directions, nothing steering, every leg timed. Then
## the slot it closed, walked into from the side that used to lead through it.
func _test_landing() -> void:
	_section("the landing in the north-west corner")

	var world := _world(&"landing")
	world.add_occupant(1, "Stroller")
	var walker := world.occupant_for(1)
	var screen := RoomContent.landing_screen()
	var door := RoomContent.landing_door()
	var r := RoomContent.LANDING_POST_RADIUS
	var extent := RoomContent.ROOM_EXTENT
	var wall_lane := -extent.y + RoomContent.OCCUPANT_RADIUS + 1.0

	# --- In by the door, north, touching nothing --------------------------------------

	walker.state.position = Vector2(door.x, -180.0)
	walker.state.velocity = Vector2.ZERO
	var drift := 0.0
	_begin_leg(world)

	for _i in range(600):
		_stride(world, Vector2.UP)
		drift = maxf(drift, absf(walker.position().x - door.x))
		if walker.position().y <= wall_lane:
			break

	_check(
		RoomContent.in_landing(walker.position()) and drift < 0.5,
		"holding north through the landing's door reaches the north wall touching nothing (%.1f off the line)"
			% drift
	)
	_at_pace(
		_leg("hall to the north wall through the landing's door", func(at: Vector2) -> bool:
			return at.y <= wall_lane),
		"and walks it"
	)

	# --- West along the wall, out through the wing's north gate -------------------------

	var along := walker.position().y
	drift = 0.0
	_begin_leg(world)

	for _i in range(600):
		_stride(world, Vector2.LEFT)
		drift = maxf(drift, absf(walker.position().y - along))
		if walker.position().x < RoomContent.WALL_X - 100.0:
			break

	_check(
		RoomContent.in_wing(walker.position()) and drift < 0.5,
		"holding west along the north wall leaves the landing by the wing's north gate (%.1f off the line)"
			% drift,
		"the gate is the partition's second way through, and the landing is what it opens onto"
	)
	_at_pace(
		_leg("the landing, west into the wing", func(at: Vector2) -> bool:
			return at.x < RoomContent.WALL_X - 100.0),
		"and walks it"
	)

	# --- And back east, across it and into the gallery ----------------------------------

	drift = 0.0
	var crossed := false
	_begin_leg(world)

	for _i in range(600):
		_stride(world, Vector2.RIGHT)
		drift = maxf(drift, absf(walker.position().y - along))
		crossed = crossed or RoomContent.in_landing(walker.position())
		if RoomContent.in_gallery(walker.position()):
			break

	_check(
		crossed and RoomContent.in_gallery(walker.position()) and drift < 0.5,
		"holding east from the wing crosses the landing into the gallery behind its screen (%.1f off the line)"
			% drift,
		"the north wall is one walk: the wing's gate, the landing, the gallery"
	)
	_at_pace(
		_leg("the wing, across the landing into the gallery", func(at: Vector2) -> bool:
			return RoomContent.in_gallery(at)),
		"and walks it"
	)

	# --- Out of the door, south -------------------------------------------------------

	walker.state.position = Vector2(door.x, -480.0)
	walker.state.velocity = Vector2.ZERO
	drift = 0.0
	_begin_leg(world)

	for _i in range(600):
		_stride(world, Vector2.DOWN)
		drift = maxf(drift, absf(walker.position().x - door.x))
		if walker.position().y > RoomContent.GALLERY_Y + 150.0:
			break

	_check(
		walker.position().y > RoomContent.GALLERY_Y + 150.0 and drift < 0.5,
		"holding south from the landing goes out of its door into the hall (%.1f off the line)" % drift
	)
	_at_pace(
		_leg("the landing, out of its door", func(at: Vector2) -> bool:
			return at.y > RoomContent.GALLERY_Y + 150.0),
		"and walks it"
	)

	# --- Its front is a wall, and the slot is shut --------------------------------------

	# From the hall at a front post, head on; from inside at the joint on the partition;
	# and into the slot that stood between the partition's north post and the pillar,
	# along its own axis from the landing's side, which is the one line that used to go
	# through it with 3.6 to spare.
	var north := Vector2(RoomContent.WALL_X, RoomContent.NORTH_GATE_Y)
	var pillar := Vector2(-RoomContent.PILLAR_AT.x, -RoomContent.PILLAR_AT.y)
	var across := (pillar - north).normalized()
	var saddle := north + across * (
		RoomContent.POST_RADIUS
		+ (north.distance_to(pillar) - RoomContent.POST_RADIUS - RoomContent.PILLAR_RADIUS) * 0.5
	)
	var into := Vector2(-across.y, across.x)
	var joint := RoomContent.landing_joint_post()
	var over := RoomContent.landing_pillar_post()
	var held := 0

	for probe in [
		[Vector2((over.x + RoomContent.landing_door_post().x) * 0.5, -200.0), Vector2.UP, false],
		[Vector2((joint.x + over.x) * 0.5, -480.0), Vector2.DOWN, true],
		[saddle - into * 120.0, into, true],
	]:
		walker.state.position = probe[0]
		walker.state.velocity = Vector2.ZERO
		for _i in range(600):
			world.tick({1: _walk(probe[1])})
		if RoomContent.in_landing(walker.position()) == probe[2]:
			held += 1

	_check(
		held == 3,
		"walking into its front from the hall, or into its joint or the old slot from inside, does not go through (%d of 3 held)"
			% held,
		"47.6 between the partition's north post and the pillar was a walker and 3.6"
	)

	# --- Measured -----------------------------------------------------------------------

	var gallery_west := RoomContent.gallery_screen()[0]
	var doorpost := RoomContent.landing_door_post()
	var width := doorpost.distance_to(Vector2(gallery_west.x, gallery_west.y)) - r - gallery_west.z
	# Measured off the posts that are standing, not off the functions that place them: the
	# post nearest each thing it is joined to has to overlap it by the partition's twenty.
	var on_partition := -INF
	var on_pillar := -INF
	for piece in screen:
		var at := Vector2(piece.x, piece.y)
		on_partition = maxf(on_partition, RoomContent.POST_RADIUS + piece.z - at.distance_to(north))
		on_pillar = maxf(on_pillar, RoomContent.PILLAR_RADIUS + piece.z - at.distance_to(pillar))
	_check(
		absf(width - RoomContent.DOORWAY_SPAN) < 0.01
			and absf(on_partition - RoomContent.GALLERY_OVERLAP) < 0.01
			and absf(on_pillar - RoomContent.GALLERY_OVERLAP) < 0.01,
		"its door is the front door's width (%.1f), and it is joined to the partition (%.1f) and the pillar (%.1f)"
			% [width, on_partition, on_pillar]
	)

	var widest := 0.0
	var shallowest := INF
	for index in range(screen.size()):
		var at := Vector2(screen[index].x, screen[index].y)
		shallowest = minf(shallowest, at.y - r + extent.y)
		if index > 0:
			widest = maxf(widest, at.distance_to(Vector2(screen[index - 1].x, screen[index - 1].y)))

	# Everything it is not joined to: nothing narrower than the front door. The partition and
	# the pillar are left out, because it is joined to both; the check above is theirs.
	var narrowest := INF
	var where := ""
	for piece in screen:
		var at := Vector2(piece.x, piece.y)
		for other in RoomContent.furniture():
			var there := Vector2(other.x, other.y)
			if other in screen or other in RoomContent.partition() or there == pillar:
				continue
			var gap := at.distance_to(there) - piece.z - other.z
			if gap < narrowest:
				narrowest = gap
				where = "(%.0f, %.0f) to (%.0f, %.0f)" % [at.x, at.y, there.x, there.y]

	_check(
		widest <= r * 2.0 - RoomContent.GALLERY_OVERLAP + 0.01
			and narrowest >= RoomContent.DOORWAY_SPAN - 0.01
			and shallowest >= RoomContent.GALLERY_DEPTH,
		"its posts overlap by at least %.0f (%.1f apart at most), nothing about it is narrower than the front door (%.1f, %s), and it is as deep as the gallery everywhere (%.0f of %.0f)"
			% [RoomContent.GALLERY_OVERLAP, widest, narrowest, where, shallowest, RoomContent.GALLERY_DEPTH]
	)
	_done()


## Who can hear whom, as the room decides it. See [method RoomContent.within_earshot].
##
## [b]Pure geometry, and the sandbox is where it meets the routers.[/b] This is the rule on
## its own — every wall, both doorways and the furniture that is not a wall — so a failure
## here names a wall rather than a socket.
func _test_earshot() -> void:
	_section("who can hear whom through the walls")

	var hears := func(a: Vector2, b: Vector2) -> bool:
		return RoomContent.within_earshot(a, b) and RoomContent.within_earshot(b, a)
	var deaf := func(a: Vector2, b: Vector2) -> bool:
		return not RoomContent.within_earshot(a, b) and not RoomContent.within_earshot(b, a)
	var clear := RoomContent.POST_RADIUS + RoomContent.OCCUPANT_RADIUS

	# The bug: both pressed against the partition, level with a post, well inside "near".
	var wing_side := Vector2(RoomContent.WALL_X - clear, -220.0)
	var hall_side := Vector2(RoomContent.WALL_X + clear, -220.0)
	_check(
		deaf.call(wing_side, hall_side),
		"two people either side of the partition, %.0f apart, cannot hear each other"
			% wing_side.distance_to(hall_side),
		"the near radius is 420 and the partition is 180 thick"
	)
	_check(
		hears.call(Vector2(-770.0, 0.0), Vector2(-470.0, 0.0)),
		"through the front door they can, either way"
	)
	_check(
		hears.call(Vector2(RoomContent.WALL_X, 0.0), Vector2(-770.0, 150.0))
			and hears.call(Vector2(RoomContent.WALL_X, 0.0), Vector2(-470.0, 100.0)),
		"somebody standing in the doorway hears both rooms",
		"that is what a doorway is for, and a room predicate would split it down the middle"
	)
	_check(
		hears.call(Vector2(-770.0, -200.0), Vector2(-770.0, 200.0))
			and hears.call(Vector2(-200.0, 0.0), Vector2(200.0, 0.0)),
		"furniture is not a wall: along the wing past its counter, and across the island"
	)
	_check(
		deaf.call(Vector2(0.0, -450.0), Vector2(0.0, -200.0)),
		"behind the gallery's screen is out of earshot of the hall in front of it"
	)
	_check(
		deaf.call(Vector2(760.0, 450.0), Vector2(760.0, 200.0)),
		"inside the snug is out of earshot of the hall across its screen"
	)

	var in_alcove := Vector2(RoomContent.ALCOVE_X, 440.0)
	_check(
		RoomContent.in_alcove(in_alcove)
			and deaf.call(in_alcove, Vector2(RoomContent.ALCOVE_X, 250.0)),
		"inside the alcove is out of earshot of the hall across its bow"
	)
	_check(
		hears.call(
			Vector2(RoomContent.ALCOVE_X - 60.0, 470.0), Vector2(RoomContent.ALCOVE_X + 60.0, 470.0)
		),
		"and two people inside it hear each other"
	)

	# Straight through a post of the south arm, and then across the booth's floor.
	var in_booth := Vector2(RoomContent.BOOTH_X + RoomContent.BOOTH_SPACING, -450.0)
	_check(
		RoomContent.in_booth(in_booth)
			and deaf.call(in_booth, Vector2(in_booth.x, -220.0))
			and hears.call(in_booth, Vector2(860.0, -500.0)),
		"inside the booth is out of earshot of the hall, and two people in it hear each other"
	)

	# Across the bay's front, and across its floor.
	var in_bay := Vector2(300.0, RoomContent.ROOM_EXTENT.y - RoomContent.DOORWAY_SPAN - 40.0)
	_check(
		RoomContent.in_bay(in_bay)
			and deaf.call(in_bay, Vector2(in_bay.x, 200.0))
			and hears.call(in_bay, Vector2(RoomContent.bay_west_x() + 60.0, 520.0)),
		"inside the bay is out of earshot of the hall, and two people in it hear each other"
	)

	# [b]The south wall is one line of sight.[/b] The alcove's, the bay's and the snug's
	# gates all leave the same lane against the wall, so somebody in that lane in the bay
	# hears somebody in it in the alcove and in the snug — which is the rule, not a leak:
	# you hear whoever you could see. Stood out of the lane, above it, the bay is deaf to
	# the alcove's floor above its lane: the end posts are in the way.
	var lane := RoomContent.ROOM_EXTENT.y - RoomContent.DOORWAY_SPAN * 0.5
	_check(
		hears.call(Vector2(300.0, lane), Vector2(RoomContent.ALCOVE_X, lane))
			and hears.call(Vector2(300.0, lane), Vector2(820.0, lane))
			and deaf.call(in_bay, Vector2(RoomContent.ALCOVE_X, 420.0)),
		"along the wall the bay hears the alcove and the snug through their gates, and out of the lane it does not"
	)

	# Across the landing's front, through where the slot was, across its floor, and along
	# the north wall into the wing through the gate it opens onto.
	var in_landing := Vector2(-450.0, -470.0)
	_check(
		RoomContent.in_landing(in_landing)
			and deaf.call(in_landing, Vector2(-420.0, -200.0))
			and deaf.call(Vector2(-500.0, -420.0), Vector2(-470.0, -180.0))
			and hears.call(in_landing, Vector2(-330.0, -520.0))
			and hears.call(Vector2(-450.0, -520.0), Vector2(-770.0, -520.0)),
		"inside the landing is out of earshot of the hall, through its front and the old slot, and hears its own floor and the wing's gate"
	)
	_done()


## Anywhere a walker can stand, a walker can get to.
##
## [b]The other half of the question every level here has asked.[/b] The wing, the gate,
## the gallery and the snug each ask "can a walker get through this gap"; none asks "is
## there anywhere in the room a walker fits and cannot reach", which is the one that
## produces a room with a sealed pocket in it that every picture shows as floor. A grid
## over the room, every point a walker's centre fits at, and a flood from the hall.
func _test_reach() -> void:
	_section("anywhere a walker fits, a walker can reach")

	const STEP := 8.0
	var radius := RoomContent.OCCUPANT_RADIUS
	var inner := RoomContent.bounds().grow(-radius)
	var columns := int(floor(inner.size.x / STEP)) + 1
	var rows := int(floor(inner.size.y / STEP)) + 1
	var fits := PackedByteArray()
	fits.resize(columns * rows)
	var total := 0

	for row in range(rows):
		for column in range(columns):
			var at := inner.position + Vector2(column, row) * STEP
			var normals: Array = []

			if RoomContent.resolve_furniture(at, radius, normals) == at:
				fits[row * columns + column] = 1
				total += 1

	# From the middle of the hall's south side, which is nowhere near any level.
	var start := -1
	var best := INF

	for index in range(fits.size()):
		if fits[index] == 0:
			continue

		var at := inner.position + Vector2(index % columns, index / columns) * STEP
		var distance := at.distance_to(Vector2(0.0, 300.0))

		if distance < best:
			best = distance
			start = index

	var seen := PackedByteArray()
	seen.resize(fits.size())
	var queue := PackedInt32Array([start])
	seen[start] = 1
	var reached := 0
	var reached_snug := false
	var reached_alcove := false
	var reached_booth := false
	var reached_bay := false
	var reached_landing := false
	var head := 0

	while head < queue.size():
		var index := queue[head]
		head += 1
		reached += 1
		var column := index % columns
		var row := index / columns

		if RoomContent.in_snug(inner.position + Vector2(column, row) * STEP):
			reached_snug = true

		if RoomContent.in_alcove(inner.position + Vector2(column, row) * STEP):
			reached_alcove = true

		if RoomContent.in_booth(inner.position + Vector2(column, row) * STEP):
			reached_booth = true

		if RoomContent.in_bay(inner.position + Vector2(column, row) * STEP):
			reached_bay = true

		if RoomContent.in_landing(inner.position + Vector2(column, row) * STEP):
			reached_landing = true

		for step in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var c: int = column + step.x
			var r: int = row + step.y

			if c < 0 or r < 0 or c >= columns or r >= rows:
				continue

			var next := r * columns + c

			if fits[next] == 1 and seen[next] == 0:
				seen[next] = 1
				queue.append(next)

	# The first unreached point, so a failure says where to look.
	var stranded := ""

	for index in range(fits.size()):
		if fits[index] == 1 and seen[index] == 0:
			var at := inner.position + Vector2(index % columns, index / columns) * STEP
			stranded = " — first at (%.0f, %.0f)" % [at.x, at.y]
			break

	_check(
		total > columns * rows / 2,
		"most of the room is floor (%d of %d points)" % [total, columns * rows],
		"a sweep over a room that is all furniture proves nothing about pockets"
	)
	_check(
		reached_snug,
		"the flood from the hall gets into the snug"
	)
	_check(reached_alcove and reached_booth, "and into the alcove and the booth")
	_check(reached_bay, "and into the bay")
	_check(reached_landing, "and onto the landing")
	_check(
		reached == total,
		"and every point a walker fits at is one it can get to (%d of %d%s)"
			% [reached, total, stranded],
		"a sealed pocket draws as floor in every picture of it"
	)
	_done()


func _test_determinism() -> void:
	_section("determinism")

	# The property everything else rests on: a client predicting a walk and a server
	# re-running the same commands must reach the same position, or every tick is a
	# correction. Two worlds, the same ids, the same commands, no shared state.
	var a := _world(&"det_a")
	var b := _world(&"det_b")

	for world in [a, b]:
		world.add_occupant(7, "Twin")
		world.add_occupant(8, "Other")

	var rng := RandomNumberGenerator.new()
	rng.seed = 20260829
	var script: Array[Dictionary] = []

	for _i in range(240):
		script.append({
			7: _walk(Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1))),
			8: _walk(Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1))),
		})

	for frame in script:
		a.tick(frame)
		b.tick(frame)

	var drift := 0.0

	for id in [7, 8]:
		drift = maxf(
			drift, a.occupant_for(id).position().distance_to(b.occupant_for(id).position())
		)

	_check(
		drift == 0.0,
		"two worlds replaying the same commands are bit-identical (drift %.9f)" % drift,
		"anything above zero here is a prediction that will never converge"
	)

	_check(
		a.current_tick() == b.current_tick() and a.current_tick() == script.size(),
		"and both counted the same ticks (%d)" % a.current_tick()
	)
	_done()


func _test_bubbles() -> void:
	_section("chat bubbles")

	var world := _world(&"bubbles")
	world.add_occupant(1, "Talker")

	var occupant := world.occupant_for(1)
	var now := 100000

	_check(not occupant.has_bubble(now), "nobody starts out saying anything")

	occupant.say("hello", now)
	_check(occupant.has_bubble(now), "saying something shows one")
	_check(
		not occupant.has_bubble(now + 20000),
		"and it goes away (%d ms)" % (occupant.bubble_until_ms - now)
	)

	occupant.say("a", now)
	var short_life := occupant.bubble_until_ms - now
	occupant.say("a".repeat(200), now)
	var long_life := occupant.bubble_until_ms - now

	_check(
		long_life > short_life,
		"a longer line stays up longer (%d ms against %d)" % [long_life, short_life]
	)
	_check(
		long_life <= 7000,
		"but not indefinitely — the text comes from another player (%d ms)" % long_life
	)
	_done()
