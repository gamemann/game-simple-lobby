extends SceneTree

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

var _wait := 0
var _done := false
var _renderer: Node2D = null
var _framed := false


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	var world := RoomWorld.new()
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

	var renderer := Node2D.new()
	renderer.set_script(load(RENDERER))
	renderer.set("world", world)
	root.add_child(renderer)

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
	var path := OUT_DIR.path_join("room.png")
	image.save_png(path)
	print("wrote %s (%d x %d)" % [path, image.get_width(), image.get_height()])

	_done = true
	return false
