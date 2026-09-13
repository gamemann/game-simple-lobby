extends SceneTree

const RoomMenus := preload("../game/client/room_menus.gd")
const RoomPresentation := preload("../game/client/room_presentation.gd")

## Renders this game's own screens to `screenshots/` so a person can look at them.
##
## Separate from `screenshot.gd`, which renders the ROOM. A room wants a camera framing a
## world and a menu wants a viewport-sized stack with nothing behind it.
##
## The pause screen is this game's own; the settings screen is dot-ui's and is rendered
## there too, and is included here because what matters is that THIS game's stack opens it
## — a screen registered under a name nothing pushes is the bug that made dot-ui's pause
## menu a grey rectangle, and it is invisible to every assertion about the screen itself.
##
## [b]Not `--headless`[/b]: that gives a null renderer, a 64 x 64 viewport, and frames that
## are empty for a reason that has nothing to do with the code.

const OUT_DIR := "res://screenshots"
const SETTLE := 3

var _stack: DotScreenStack = null
var _presentation: RoomPresentation = null
var _shots: Array[Dictionary] = []
var _at := 0
var _wait := SETTLE
var _done := false


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	_presentation = RoomPresentation.new()
	_presentation.name = "Presentation"
	root.add_child(_presentation)
	_presentation.setup()

	_stack = DotScreenStack.new()
	_stack.name = "Stack"
	_stack.register_service = false
	_stack.manage_mouse = false
	_stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(_stack)
	_stack.setup()

	RoomMenus.install(_stack, _presentation.settings)

	_shots = [
		{"id": &"pause", "file": "menu_pause.png"},
		{"id": &"settings", "file": "menu_settings.png"},
	]


func _process(_delta: float) -> bool:
	if _done:
		return true

	if _at >= _shots.size():
		_done = true
		return false

	var shot: Dictionary = _shots[_at]

	if _wait == SETTLE:
		_stack.clear()

		var opened := _stack.push(StringName(shot["id"]))

		if not opened.ok:
			# Said out loud rather than saved as a grey rectangle. A picture of an empty
			# viewport is indistinguishable from a renderer that is not working, which is
			# exactly how dot-ui's unopened pause menu looked.
			push_error("could not open '%s': %s" % [shot["id"], opened.error.message])
			_at += 1
			return false

	if _wait > 0:
		_wait -= 1
		return false

	var image := root.get_texture().get_image()
	var path := OUT_DIR.path_join(str(shot["file"]))
	image.save_png(path)
	print("wrote %s (%d x %d)" % [path, image.get_width(), image.get_height()])

	_at += 1
	_wait = SETTLE
	return false
