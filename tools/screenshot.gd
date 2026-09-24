extends SceneTree

const RoomContent := preload("../game/room_content.gd")
const RoomProps := preload("../game/room_props.gd")
const RoomWorld := preload("../game/room_world.gd")

## Renders the room to a PNG so a person can look at it.
##
## [b]A room is a drawn thing, and this family has shipped a 0 x 0 Control twice and a
## black screen once.[/b] Every check on the room is an assertion about numbers — a
## position, a count, a correction rate — and numbers pass just as happily when
## everything is drawn in the same place, or when the furniture the simulation collides
## against is not on screen at all.
##
##   xvfb-run -a godot --path . --script tools/screenshot.gd
##
## Needs a real rendering context, so it does NOT run under `--headless`; `xvfb-run` is
## how it runs on a machine with no display. It writes into `screenshots/`, which is
## gitignored — the frame is evidence for a review, not an asset.

const OUT_DIR := "screenshots"

const RENDERER := "res://game/client/room_renderer.gd"
const UI := "res://game/client/room_ui.gd"

var _wait := 0
var _done := false
var _renderer: Node2D = null
var _framed := false

## `-- --admin`: an administrator's beacon on two people, then the same room through a
## blinded person's interface. Two frames, `room_beacon.png` and `room_blind.png`, instead
## of `room.png`.
var _admin := false
var _world: RoomWorld = null
var _ui: Control = null

## Which frame is next: 0 the room (or the beacons), 1 the blind.
var _stage := 0


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	_admin = "--admin" in OS.get_cmdline_user_args()

	var world := RoomWorld.new()
	_world = world
	world.is_authority = true
	world.register_service = false
	root.add_child(world)

	# `setup()` explicitly, because `_ready` has not run yet.
	#
	# A node added from `SceneTree._initialize` gets its `_ready` on the first frame, and
	# everything below this line runs before that — so `world.arena` is still null and
	# `add_occupant` fails on it. The error is "Nonexistent function 'spawn_position' in
	# base 'Nil'", which reads like a missing method rather than like a node that has not
	# started yet.
	world.setup()

	# A few people, spread by the same spawn the server uses, so the picture shows what a
	# room with people in it looks like rather than an empty rectangle. Names of the
	# length a real one has, because a nameplate that fits at "a" and not at a real name
	# is the kind of thing only a picture shows.
	var names := [
		"gamemann", "christian", "a_very_long_display_name", "bo", "quiet_one",
		"someone_else", "lurker", "newcomer",
	]

	for i in names.size():
		world.add_occupant(i + 1, names[i])

	# One of them in the snug. A room nobody is drawn standing in cannot show whether a
	# person fits in it, and the snug is the smallest room here.
	var seat := RoomContent.snug_seat()
	world.occupant_for(5).state.position = Vector2(seat.x + 80.0, seat.y + 80.0)

	# And one in the alcove, stood against the bow out of the lane along the wall — the
	# spot the alcove's radius was sized to leave room for.
	world.occupant_for(6).state.position = Vector2(
		RoomContent.ALCOVE_X + 40.0,
		RoomContent.ROOM_EXTENT.y - RoomContent.DOORWAY_SPAN - RoomContent.OCCUPANT_RADIUS - 8.0
	)

	# Props, placed through the real spawner, because a placement drawn from a hand-built
	# dictionary is a picture of a dictionary. This is the one place anybody looks at what
	# a bench, a rug and a plant actually come out as — and the family's own record here
	# is four interface bugs found by a picture and none by an assertion.
	var props := RoomProps.new()
	root.add_child(props)
	props.setup(true, world)
	props.spawner.limits.spawn_interval = 0.0
	world.props = props

	props.place(1, &"bench", Vector2(-620.0, -60.0))
	props.place(1, &"table", Vector2(-500.0, 120.0))
	props.place(1, &"stool", Vector2(-420.0, 60.0))
	props.place(2, &"plant", Vector2(250.0, -330.0))
	props.place(2, &"lamp", Vector2(330.0, -330.0))
	props.place(2, &"crate", Vector2(-80.0, 250.0))
	# The two that are not obstacles. A rug drawn at an obstacle's weight would be a rug
	# people believe they have to walk around.
	props.place(3, &"rug", Vector2(120.0, 300.0))
	props.place(3, &"sign", Vector2(620.0, -420.0))

	var renderer := Node2D.new()
	renderer.set_script(load(RENDERER))
	renderer.set("world", world)
	renderer.set("props", props)

	# Avatars, on half the room. [b]Half on purpose[/b]: a picture where everybody is
	# wearing something cannot show whether somebody wearing nothing still reads as a
	# person, and a lobby full of guests is the ordinary case.
	var avatars := {
		1: [
			{"slot": "hat", "part": "hat_cap", "colour": Color(0.90, 0.35, 0.30)},
			{"slot": "face", "part": "face_wide", "colour": Color(0.08, 0.09, 0.11)},
		],
		2: [
			{"slot": "hat", "part": "hat_crown", "colour": Color(0.95, 0.80, 0.30)},
			{"slot": "badge", "part": "badge_dot", "colour": Color(0.35, 0.75, 0.95)},
		],
		3: [{"slot": "face", "part": "face_narrow", "colour": Color(0.08, 0.09, 0.11)}],
		4: [
			# A slot this build has no case for, drawn as a mark rather than as nothing.
			# A player wearing something from a newer catalogue has to be visibly wearing
			# something, and that branch is only ever looked at here.
			{"slot": "cape", "part": "cape_long", "colour": Color(0.60, 0.40, 0.85)},
		],
	}
	renderer.set("avatars", avatars)
	root.add_child(renderer)

	if _admin:
		_beacons()

	# The whole room in frame, with a margin. A camera that framed the bounds exactly
	# would cut the wall line the renderer draws on the boundary itself.
	_renderer = renderer

	# Three frames before grabbing. The viewport's texture is the last COMPLETED frame,
	# so grabbing on the frame the scene was built saves whatever was there before it —
	# and the framing above is applied on the first of the three, once the viewport's
	# visible rectangle is real.
	_wait = 3


func _process(_delta: float) -> bool:
	if _done:
		return true

	# The renderer is SCALED AND OFFSET, rather than framed with a Camera2D.
	#
	# [b]Two attempts at a camera produced two wrong pictures and no error either time.[/b]
	# `root.size` read in `_initialize` is whatever the window was made with before the
	# platform has finished sizing it — 121 units wide on this box — which fitted an
	# 1800-unit room into a postage stamp; and a `zoom` that fits by the documented
	# convention came out magnified instead, so the walls were off every edge. Both look
	# like a renderer that is not drawing the room.
	#
	# A transform on the node is arithmetic this file can check: `scale` multiplies and
	# `position` is where the world's origin lands. There is nothing to get the direction
	# of.
	if _renderer != null and not _framed:
		var view := root.get_visible_rect().size
		var bounds := RoomContent.bounds()
		var fit := minf(
			view.x / (bounds.size.x * 1.08), view.y / (bounds.size.y * 1.08)
		)

		_renderer.scale = Vector2.ONE * fit
		_renderer.position = view * 0.5 - bounds.get_center() * fit
		_framed = true

		# Reset the wait, so the three frames are counted from AFTER the framing rather
		# than from before it. Counting them first grabs a frame drawn at the old
		# transform, which is the whole hazard the wait exists for.
		_wait = 3
		return false

	if _wait > 0:
		_wait -= 1
		return false

	var image := root.get_texture().get_image()
	var file := "room.png"

	if _admin:
		file = "room_beacon.png" if _stage == 0 else "room_blind.png"

	var path := OUT_DIR.path_join(file)
	image.save_png(path)
	print("wrote %s (%d x %d)" % [path, image.get_width(), image.get_height()])

	if _admin and _stage == 0:
		_stage = 1
		_blind()
		_wait = 3
		return false

	_done = true
	return false


## Beacons on two people, placed before the first frame: one on open floor and one in the
## snug, because a ring that reads in the open and vanishes against the furniture is the
## one this picture exists to catch.
func _beacons() -> void:
	for id in [2, 5]:
		_world.occupant_for(id).beacon = true


## The same room through the interface of somebody blinded: the room gone, and the chat,
## the roster and the feed still there over it — which is the claim `RoomUi.blind_overlay`
## makes and only a picture can check.
func _blind() -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)

	_ui = Control.new()
	_ui.set_script(load(UI))
	layer.add_child(_ui)

	_ui.call("set_roster", _world.roster(), 1)
	_ui.call("add_notice", "A moderator has blinded you.", Color(1.0, 0.6, 0.5))
	_ui.call("set_status", "")
	# A whole fade in one step: the frame is of a blind that is on, not of one arriving.
	_ui.call("present_blind", 1.0, true)
