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

const CHECKS := 76

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

	var moved := occupant.position() - start
	_check(moved.x > 40.0, "half a second of walking moves you (%.0f units)" % moved.x)
	_check(absf(moved.y) < 0.5, "and only in the direction asked for")

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

	for _i in range(600):
		world.tick({1: _walk(Vector2.LEFT)})

	var through := occupant.position()
	_check(
		RoomContent.in_wing(through),
		"and the doorway leads into the wing (%.0f, %.0f)" % [through.x, through.y]
	)

	# Out again, so the wing is a room rather than a trap.
	for _i in range(600):
		world.tick({1: _walk(Vector2.RIGHT)})

	_check(
		not RoomContent.in_wing(occupant.position()),
		"and back out to the hall (%.0f, %.0f)"
			% [occupant.position().x, occupant.position().y]
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

	for _i in range(600):
		world.tick({1: _walk(Vector2.UP)})

	var north := walker.position()
	_check(
		RoomContent.in_wing(north) and north.y < -420.0,
		"the wing can be walked from its middle to its north end (%.0f, %.0f)"
			% [north.x, north.y],
		"one piece of furniture in a 280-wide strip closes it, and nothing else notices"
	)

	# And out the other end. The partition has two ways through it, so the wing is a
	# circuit rather than a pocket you have to back out of — which is what stops one
	# person standing in a doorway from being a locked door.
	for _i in range(400):
		world.tick({1: _walk(Vector2.RIGHT)})

	var out := walker.position()
	_check(
		not RoomContent.in_wing(out) and out.y < -420.0,
		"and left by the north gate rather than by the door it came in (%.0f, %.0f)"
			% [out.x, out.y]
	)

	# South, the whole way, from the same start. A lane that exists only north of the
	# doorway is half a room.
	walker.state.position = Vector2(-750.0, 0.0)
	walker.state.velocity = Vector2.ZERO

	for _i in range(600):
		world.tick({1: _walk(Vector2.DOWN)})

	var south := walker.position()
	_check(
		RoomContent.in_wing(south) and south.y > 420.0,
		"and from its middle to its south end (%.0f, %.0f)" % [south.x, south.y],
		"the south end is a dead end by design, but it has to be reachable"
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
	occupant.state.position = Vector2(-350.0, -180.0)
	occupant.state.velocity = Vector2.ZERO

	for _i in range(600):
		world.tick({1: _walk(Vector2.UP)})

	var mouth := occupant.position()
	_check(
		mouth.y < RoomContent.GALLERY_Y - RoomContent.GALLERY_POST_RADIUS,
		"a walker gets past the screen's west end into the strip (%.0f, %.0f)"
			% [mouth.x, mouth.y],
		"the pillars are the doorposts; a mouth narrower than a walker is a wall"
	)

	var went_in := false
	var shallowest := -INF

	for _i in range(900):
		world.tick({1: _walk(Vector2.RIGHT)})

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

	# --- It is empty, and that is the level rather than an omission ---------

	# [b]The opposite of the wing's check, deliberately.[/b] The wing needs something to
	# stand behind because it is a room you go to; the gallery IS the thing to stand
	# behind, and a strip this deep with furniture in it is the wing's own bug written
	# out a second time.
	# Anything whose centre is north of the screen's FACE is standing in the strip. The
	# screen's own posts are on the line and are the wall of it, not furniture in it.
	var standing := 0
	var face := RoomContent.GALLERY_Y - RoomContent.GALLERY_POST_RADIUS

	for piece in RoomContent.furniture():
		if piece.y < face and not RoomContent.in_wing(Vector2(piece.x, piece.y)):
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

	for _i in range(600):
		world.tick({1: _walk(Vector2.DOWN)})
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

	for _i in range(600):
		world.tick({1: _walk(Vector2.LEFT)})

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

	# --- And the other way round -------------------------------------------

	walker.state.position = Vector2(
		RoomContent.SNUG_X - 150.0, RoomContent.ROOM_EXTENT.y - 30.0
	)
	walker.state.velocity = Vector2.ZERO

	for _i in range(600):
		world.tick({1: _walk(Vector2.RIGHT)})

	var along := walker.position()
	_check(
		RoomContent.in_snug(along) and along.x > RoomContent.SNUG_GATE_X,
		"in by the south gate and along the wall to the corner (%.0f, %.0f)"
			% [along.x, along.y]
	)

	for _i in range(600):
		world.tick({1: _walk(Vector2.UP)})

	var up := walker.position()
	_check(
		not RoomContent.in_snug(up) and up.y < RoomContent.SNUG_Y,
		"and out by the east gate (%.0f, %.0f)" % [up.x, up.y]
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

		for _i in range(600):
			world.tick({1: _walk(way)})
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
	_check(reached_alcove, "and into the alcove")
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
