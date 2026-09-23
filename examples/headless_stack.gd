extends Node

const RoomContent := preload("../game/room_content.gd")
const RoomPlayerStack := preload("../game/room_player_stack.gd")
const RoomWorld := preload("../game/room_world.gd")

## The player stack, run against a real room rather than against a stub.
##
## [codeblock]
## godot --headless --path . res://examples/headless_stack.tscn
## [/codeblock]
##
## [b]The lobby is the staging area, and it had the same gap as the other three:[/b] a
## three-hundred-line player layer that no suite named. game-arena got one; this did not.
##
## Two of the sections are about things only this game gets to say:
##
## - **It is the one game here with real SIDES.** The other four are free-for-alls, so a
##   hardcoded `team_fn` returning 1 was harmless there and wrong here: blue and red both
##   read as team 1, which dot-spectate takes as "team-mates".
## - **Nothing applies a class, deliberately.** A lobby has no health and one shared
##   `Dot2DTunables` that every occupant's motor reads, so a per-player speed scale
##   written there would be everybody's. The class is a choice to carry into the match
##   that will use it, which is what a lobby is for.

const CHECKS := 24
const SECTIONS := 4

var _passed := 0
var _failed := 0
var _section_count := 0

var _world: RoomWorld = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	print("lobby player stack")
	print("")

	if not _build():
		get_tree().quit(1)
		return

	_test_physics_layout()
	_test_two_sides()
	_test_classes_are_a_choice()
	_test_seats()

	print("")
	print("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		print("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _build() -> bool:
	_world = RoomWorld.new()
	_world.name = "World"
	_world.is_authority = true
	_world.register_service = false
	add_child(_world)

	var res := _world.setup()

	if not res.ok:
		print("  FAIL  the room did not set up: %s" % res.error.message)
		return false

	if _world.player_stack == null:
		print("  FAIL  the room set up without a player stack")
		return false

	return true


func _stack() -> RoomPlayerStack:
	return _world.player_stack


# --- 1 ----------------------------------------------------------------------

func _test_physics_layout() -> void:
	_section("the collision layout is worn, not just named")

	var physics := _stack().physics
	_check(physics != null, "the stack built a physics world")

	if physics == null:
		return

	_check(physics.layout != null, "with a layout on it")
	_check(
		physics.layout.has_layer(&"prop"),
		"that has the one layer this room has bodies for"
	)
	_check(
		physics.layout.layer_mask(&"prop") != physics.layout.layer_mask(&"world"),
		"and a prop is not on the same layer as the room, which is where it started"
	)
	_check(
		physics.layout.collision_mask(&"prop") & physics.layout.layer_mask(&"player") != 0,
		"and a prop is solid against a player, which is what furniture is for"
	)
	# [b]`top_down_2d` leaves prop-vs-prop OFF and `shooter_3d` turns it on, and the
	# difference is deliberate rather than an oversight.[/b] A top-down arena is
	# described as "many bodies": props that collide with each other is an O(n²) the
	# preset is declining. A lobby with eight benches would rather have it, and the way
	# to get it is a `DotPhysicsLayout.custom` — which is what that constructor is for —
	# not an edit to a preset four games share.
	_check(
		physics.layout.collision_mask(&"prop") & physics.layout.layer_mask(&"prop") == 0,
		"while two props pass through each other, which this preset chooses on purpose"
	)


# --- 2 ----------------------------------------------------------------------

func _test_two_sides() -> void:
	_section("two sides, and the number dot-spectate is given")

	var _a := _world.add_occupant(1, "Ada")
	var _b := _world.add_occupant(2, "Bob")

	var teams := _stack().teams
	_check(teams.has_player("1") and teams.has_player("2"), "both occupants are held")

	# The lobby starts everybody unassigned, which is what a side-picking screen wants.
	_check(
		_stack().team_index_of("1") == 0,
		"an unassigned occupant is team 0, because they have not chosen yet"
	)

	var blue := _stack().choose_team(1, &"blue")
	var red := _stack().choose_team(2, &"red")
	_check(blue.ok and red.ok, "they pick opposite sides")

	var one := _stack().team_index_of("1")
	var two := _stack().team_index_of("2")

	_check(one > 0 and two > 0, "both now have a playing side")
	_check(
		one != two,
		"and DIFFERENT numbers — this is the one game in the family with real sides, "
		+ "and a hardcoded team_fn returning 1 made blue and red team-mates"
	)
	_check(
		teams.are_enemies("1", "2"),
		"which dot-team agrees with"
	)


# --- 3 ----------------------------------------------------------------------

func _test_classes_are_a_choice() -> void:
	_section("a class is a choice to carry, not a set of numbers to apply")

	var options := _stack().class_options(1)
	_check(options.size() > 0, "an occupant is offered classes")

	var wanted := StringName(str(options[0].get("id", "")))
	var picked := _stack().choose_class(1, wanted)
	_check(picked.ok, "and can pick one", )

	_check(
		_stack().classes.class_of("1") == wanted,
		"which the manager holds"
	)

	var def := _stack().classes.def_of("1")
	_check(def != null, "with a document behind it")

	if def != null:
		_check(
			def.max_health > 0.0,
			"carrying numbers for the game that will use them — the lobby applies none "
			+ "of them, because it has no health and one shared tunables object"
		)

	# The detector, turned on this file's own decision: an applier here would have no
	# caller, and an uncalled public method is exactly what this family greps for.
	_check(
		not _stack().has_method("apply_class_numbers"),
		"and there is deliberately no applier on this stack to be left uncalled"
	)


# --- 4 ----------------------------------------------------------------------

func _test_seats() -> void:
	_section("the director picks where somebody stands")

	var spawns := _stack().spawns
	_check(spawns.sites().size() > 0, "a ring of seats is laid inside the room")

	var res := _stack().choose_seat(1)
	_check(res.ok, "the director answers")

	if not res.ok:
		return

	var choice := res.value as DotSpawnChoice
	var at := Vector2(choice.transform.origin.x, choice.transform.origin.y)
	_check(
		_world.arena.bounds.has_point(at),
		"inside the room's own bounds"
	)

	# The thing the ring exists for: two arrivals in the same second must not be put on
	# top of each other, which `Dot2DArena.spawn_position` cannot avoid because it knows
	# the rectangle and nothing that is standing in it.
	var first := _world.occupant_for(1)
	var second := _world.occupant_for(2)
	_check(first != null and second != null, "two occupants are in the room")

	if first != null and second != null:
		_check(
			first.state.position.distance_to(second.state.position) > 0.5,
			"and they are not standing in the same place"
		)

	# And a room's worth of them, which is where the preset's RANDOM mode gave itself
	# away: it never reads `enemies_fn`, so the sixth and eighth arrivals in an empty room
	# landed exactly on the first. Two arrivals cannot show that — seven of eight seats
	# are free for the second one whatever the mode.
	for id in range(100, 116):
		var _in := _world.add_occupant(id, "p%d" % id)

	var everybody := _world.roster()
	var closest := INF

	for i in everybody.size():
		for j in range(i + 1, everybody.size()):
			closest = minf(
				closest, everybody[i].position().distance_to(everybody[j].position())
			)

	_check(
		closest >= RoomContent.OCCUPANT_RADIUS * 2.0,
		"and %d arrivals in a row stand clear of each other (closest %.1f apart)"
			% [everybody.size(), closest]
	)

	_world.queue_free()


# --- Harness ---------------------------------------------------------------

func _section(title: String) -> void:
	_section_count += 1
	print("")
	print("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		print("   ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)
