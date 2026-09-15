extends RefCounted

## The lobby's escape menu: dot-ui's pause screen, and dot-ui's settings screen behind it.
##
## [b]This game had a console and no menu at all, which is the wrong way round.[/b] Every
## other client in the family opens a pause screen on Escape; here Escape put the prop
## palette down and nothing else, so the only way to reach a setting was to know that a
## console existed and what to type into it. A player who has never opened a console had
## no way to change the volume of a game that makes noise at them.
##
## [b]Both screens are dot-ui's now, and one of them used to be a copy.[/b] The settings
## screen was moved when [DotSettingsScreen] was written; the pause screen was not, so this
## file went on carrying the forty lines that addon exists to hold once — a centred
## [PanelContainer], a heading, a column of [Button]s and a focus path — while the addon's
## own notes said four clients had stopped writing them. Three of the four had not. What is
## left here is the part that genuinely is this game's: which words are on the buttons, and
## what happens when one is pressed.

const CHANNEL := "room.menus"

## What is on the pause menu, top to bottom.
##
## A list of LABELS and no list of ids beside it: [DotPauseScreen] derives the id from the
## label, because two parallel lists are the shape this tree has paid for more than any
## other. `"Settings"` is `&"settings"`.
## (`const` rather than `static var`: a `PackedStringArray(...)` call is not a constant
## expression in GDScript, so the literal is an `Array[String]` and is converted at the
## one place it is handed over.)
const PAUSE_BUTTONS: Array[String] = ["Resume", "Settings", "Leave"]

## The id of the button the client acts on itself. See [method install].
const LEAVE := &"leave"


## Registers both screens with a stack and wires the buttons that navigate.
##
## Returns the pause screen. Resume and Settings are wired here, because both are about the
## stack and nothing else; **Leave is not**, because what leaving means is the client's —
## an embedded one cannot, and a single-process test must not. The caller connects
## [signal DotPauseScreen.chosen] and looks for [constant LEAVE].
static func install(
	stack: DotScreenStack, settings: DotSettingsManager
) -> DotPauseScreen:
	var pause := DotPauseScreen.new()
	pause.name = "Pause"
	pause.half_size = Vector2(150.0, 110.0)

	var built := pause.build(PackedStringArray(PAUSE_BUTTONS))

	if not built.ok:
		DotLog.result(CHANNEL, "the pause screen", built)
		pause.free()
		return null

	stack.register(pause)

	# dot-ui's screen rather than one of this game's own. Four games reached the same
	# shape independently -- a panel, a title, Apply / Revert / Back -- and two copies of
	# one thing is this tree's most expensive mistake. What is this game's own is which
	# document it hands over, and that is the line below.
	var has_settings := false

	if settings != null:
		var screen := DotSettingsScreen.new()
		screen.name = "Settings"

		var settings_built := screen.build(settings)

		if settings_built.ok:
			stack.register(screen)
			has_settings = true
		else:
			DotLog.result(CHANNEL, "the settings screen", settings_built)
			screen.free()

	if not has_settings:
		# Greyed out rather than removed. A button that is absent on one build and present
		# on another is a menu whose shape a player cannot learn; one that is there and
		# dimmed says the server did not give them settings, which is the truth.
		var button := pause.button(&"settings")

		if button != null:
			button.disabled = true

	pause.chosen.connect(func(id: StringName) -> void:
		match id:
			&"resume":
				stack.pop(&"pause")
			&"settings":
				if has_settings:
					stack.push(&"settings")
	)

	return pause
