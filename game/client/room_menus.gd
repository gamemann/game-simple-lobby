class_name RoomMenus
extends RefCounted

## The lobby's escape menu: a pause screen, and dot-ui's settings screen behind it.
##
## [b]This game had a console and no menu at all, which is the wrong way round.[/b] Every
## other client in the family opens a pause screen on Escape; here Escape put the prop
## palette down and nothing else, so the only way to reach a setting was to know that a
## console existed and what to type into it. A player who has never opened a console had
## no way to change the volume of a game that makes noise at them.
##
## [b]Two screens and about a hundred lines, because dot-ui does the hard part.[/b] The
## stack owns z-order, input blocking, mouse mode and the back key; the settings panel
## builds itself from a [DotConfig]. What is left is deciding which screens exist and what
## is on them, which is the part that is a game's own.

const CHANNEL := "room.menus"


## The pause menu. Opaque, so the room goes away behind it.
class PauseScreen extends DotScreen:
	signal resume_pressed()
	signal settings_pressed()
	signal leave_pressed()

	func _screen_id() -> StringName:
		return &"pause"

	func build() -> void:
		hides_below = true
		blocks_input = true
		mouse_mode = DotScreen.Mouse.VISIBLE

		var panel := PanelContainer.new()
		panel.name = "Panel"
		panel.set_anchors_preset(Control.PRESET_CENTER)
		panel.offset_left = -150.0
		panel.offset_right = 150.0
		panel.offset_top = -110.0
		panel.offset_bottom = 110.0
		add_child(panel)

		var column := VBoxContainer.new()
		column.name = "Column"
		panel.add_child(column)

		var title := Label.new()
		title.text = "Paused"
		title.theme_type_variation = &"DotHeading"
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(title)

		_add_button(column, "Resume", func() -> void: resume_pressed.emit())
		_add_button(column, "Settings", func() -> void: settings_pressed.emit())
		_add_button(column, "Leave", func() -> void: leave_pressed.emit())

		# Without this the menu opens with nothing focused and cannot be used with a
		# gamepad at all -- invisible to anybody testing with a mouse.
		#
		# A path by NAME, not `button.get_path()`: this runs before the screen is
		# registered with a stack, so the node is not in the tree and `get_path()` pushes
		# an error and returns nothing. game-arena shipped exactly that.
		initial_focus = NodePath("Panel/Column/Resume")

	func _add_button(into: Control, text: String, action: Callable) -> Button:
		var button := Button.new()
		button.name = text
		button.text = text
		button.pressed.connect(action)
		into.add_child(button)
		return button


## Registers both screens with a stack and wires the buttons that navigate.
##
## Returns the pause screen, because that is the one the client opens.
static func install(
	stack: DotScreenStack, settings: DotSettingsManager
) -> PauseScreen:
	var pause := PauseScreen.new()
	pause.name = "Pause"
	pause.build()
	stack.register(pause)

	# dot-ui's screen rather than one of this game's own. Four games reached the same
	# shape independently -- a panel, a title, Apply / Revert / Back -- and two copies of
	# one thing is this tree's most expensive mistake. What is this game's own is which
	# document it hands over, and that is the line below.
	if settings != null:
		var screen := DotSettingsScreen.new()
		screen.name = "Settings"

		var built := screen.build(settings)

		if built.ok:
			stack.register(screen)
			pause.settings_pressed.connect(func() -> void: stack.push(&"settings"))
		else:
			DotLog.result(CHANNEL, "the settings screen", built)
			screen.free()

	pause.resume_pressed.connect(func() -> void: stack.pop(&"pause"))

	return pause
