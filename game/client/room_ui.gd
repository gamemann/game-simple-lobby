extends Control

const RoomContent := preload("../room_content.gd")
const RoomOccupant := preload("../room_occupant.gd")
const RoomProps := preload("../room_props.gd")
const RoomServices := preload("../room_services.gd")

## The chat log, the entry, the roster and the join/leave feed.
##
## The three things the lobby is actually for, and the only part of this game a person
## looks at for longer than a second. Built out of dot-ui's widgets — [DotTableView] for
## the roster, [DotFeedView] for the notifications — because they already solve line
## expiry, fading, column widths and header colours, and a second implementation of any of
## those would drift.
##
## [b]Chat text arrives from dot-server, not from this game's netcode.[/b]
## [DotChatManager] has already sanitised it — control characters, zero-width characters
## and bidirectional overrides stripped, whitespace collapsed, length truncated — and
## filtered admin chat server-side. Nothing here re-implements any of that, and nothing
## here may: asking a client to hide messages it is not entitled to see is not a control.

const CHANNEL := "room.ui"

## Somebody pressed Enter with text in the box.
signal chat_submitted(text: String)

## Somebody clicked something in the prop palette and then somewhere in the room.
signal place_requested(prop_id: StringName, at: Vector2)

## Somebody asked for the last thing they placed back.
signal undo_requested()

## The entry took or lost the keyboard. [RoomInput] is disabled while it holds it.
signal typing_changed(typing: bool)

## Escape was pressed with nothing being typed and nothing held.
##
## The interface does not own the menu -- [RoomClient] does, because the stack draws over
## everything including this -- so this asks rather than opens. Same shape as
## [signal undo_requested].
signal pause_requested()

## Lines kept in the chat log.
##
## Bounded because every one of them is a [Label] in a container: a chat room left open
## overnight is otherwise a few hundred thousand nodes.
## The action that gives the entry the keyboard.
##
## [b]An action rather than a key, so the binding is the player's.[/b] It is stored in the
## lobby's settings document under `chat_open_key` and defaults to Y, which is what every
## other game in this family opens chat with. Enter still works and always will: this is a
## chat room, and a chat room that ignores Enter is broken.
const OPEN_CHAT_ACTION := &"room_chat"

const MAX_CHAT_LINES := 120

## Layout, in pixels. Named because three of them are used twice and a magic number used
## twice is two numbers that will eventually differ.
const MARGIN := 16.0
const ROSTER_WIDTH := 244.0
const CHAT_WIDTH := 460.0
const CHAT_HEIGHT := 212.0

## The chat client this reads channels and history from. Set by [RoomClient].
##
## [b]Read, never written.[/b] Everything that decides what a line is — the channel, the
## colour, the prefix, the order — is [DotChatClient]'s and the server's above it. This
## draws what it is given, which is the same division [RoomRenderer] has with the world.
var chat: DotChatClient = null

## The prop palette, in the order [method RoomProps.wire_ids] gives.
var _palette: HBoxContainer = null

## What is selected in the palette, or empty for "not placing anything".
var _held: StringName = &""

## The channel a typed line goes to. Cycled with Tab while typing.
var _channel: StringName = RoomServices.CHANNEL_ALL

var _channel_label: Label = null
var _talking: Label = null
var _voice_note: Label = null

var _log: VBoxContainer = null
var _scroll: ScrollContainer = null
var _entry: LineEdit = null
var _roster: DotTableView = null
var _roster_count: Label = null
var _feed: DotFeedView = null
var _status: Label = null

## Whether the log was scrolled to the bottom before the newest line was added.
##
## Read *before* appending and applied after: somebody reading back through the log must
## not be yanked to the bottom every time anybody speaks, and somebody who is at the
## bottom must not have to scroll for every line. There is no third behaviour that is
## right for both.
var _was_at_bottom: bool = true


func _ready() -> void:
	# [b]`_and_offsets_`, not `set_anchors_preset`.[/b] The anchors alone describe how a
	# rectangle should follow its parent and change nothing until something resizes it, so
	# a control built in code and never touched again keeps the zero size it was created
	# with. Every child then lays out inside nothing and the whole interface is invisible
	# while being, by every property, correctly configured.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()


func _build() -> void:
	_feed = DotFeedView.new()
	_feed.name = "Feed"
	_feed.max_lines = 6
	_feed.lifetime_sec = 7.0
	_feed.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feed.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_feed.position = Vector2(MARGIN, MARGIN)
	_feed.size = Vector2(420, 140)
	add_child(_feed)

	# --- the roster, top right ---
	var roster_box := VBoxContainer.new()
	roster_box.name = "Roster"
	# Pinned to the top-right corner by anchors *and* offsets, so it follows a resize
	# rather than sitting where the window happened to be when it was built. A browser tab
	# is resized constantly and a phone rotating is a resize.
	roster_box.anchor_left = 1.0
	roster_box.anchor_right = 1.0
	roster_box.offset_left = -(ROSTER_WIDTH + MARGIN)
	roster_box.offset_right = -MARGIN
	roster_box.offset_top = MARGIN
	roster_box.offset_bottom = MARGIN
	roster_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	roster_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(roster_box)

	_roster_count = Label.new()
	_roster_count.text = "In the room"
	_roster_count.add_theme_color_override("font_color", Color(0.72, 0.76, 0.82))
	roster_box.add_child(_roster_count)

	_roster = DotTableView.new()
	_roster.name = "Table"
	_roster.show_header = false
	_roster.max_rows = RoomContent.MAX_OCCUPANTS
	_roster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# `width` is a stretch ratio, not pixels — the name takes the slack and the duration
	# does not. Keys are [StringName]s because that is what [DotTableView] looks rows up
	# with, and a String key would find nothing and render a table of empty cells.
	var columns: Array[Dictionary] = [
		{"key": &"name", "width": 3.0},
		{"key": &"here", "align": HORIZONTAL_ALIGNMENT_RIGHT},
	]
	_roster.set_columns(columns)
	roster_box.add_child(_roster)

	# --- the chat log and entry, bottom left ---
	var chat_box := VBoxContainer.new()
	chat_box.name = "Chat"
	chat_box.anchor_top = 1.0
	chat_box.anchor_bottom = 1.0
	chat_box.offset_left = MARGIN
	chat_box.offset_right = MARGIN + CHAT_WIDTH
	chat_box.offset_top = -(CHAT_HEIGHT + MARGIN)
	chat_box.offset_bottom = -MARGIN
	chat_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(chat_box)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	chat_box.add_child(_scroll)

	_log = VBoxContainer.new()
	_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_log)

	_channel_label = Label.new()
	_channel_label.name = "Channel"
	# Above the entry rather than inside it: a player has to be able to see which channel
	# they are about to speak on BEFORE they press Enter, and a placeholder disappears the
	# moment they start typing — which is exactly when it matters.
	_channel_label.add_theme_color_override("font_color", Color(0.72, 0.76, 0.82))
	chat_box.add_child(_channel_label)

	_entry = LineEdit.new()
	_entry.placeholder_text = "Press Enter to talk"
	_entry.max_length = 240
	_entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Off until Enter is pressed. A text box that always had the keyboard would eat W, A,
	# S and D — which is the whole movement scheme — and the player would have no way of
	# telling why walking had stopped working.
	_entry.editable = false
	_entry.text_submitted.connect(_on_submitted)
	_entry.focus_entered.connect(func() -> void: typing_changed.emit(true))
	_entry.focus_exited.connect(_stop_typing)
	chat_box.add_child(_entry)

	# Created at Y only if the project does not already declare it — a player who has
	# rebound chat keeps what they chose, and the settings document is what carries it.
	DotInputBinding.ensure_action(OPEN_CHAT_ACTION, "Y")

	_build_palette()
	_set_channel(_channel)

	_talking = Label.new()
	_talking.name = "Talking"
	_talking.anchor_left = 0.0
	_talking.anchor_top = 1.0
	_talking.anchor_bottom = 1.0
	_talking.offset_left = MARGIN
	_talking.offset_top = -(CHAT_HEIGHT + MARGIN + 26.0)
	_talking.offset_bottom = -(CHAT_HEIGHT + MARGIN + 4.0)
	_talking.add_theme_color_override("font_color", Color(0.55, 0.90, 0.60))
	_talking.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_talking.visible = false
	_talking.text = "● talking"
	add_child(_talking)

	_status = Label.new()
	_status.name = "Status"
	# Centred across the whole width rather than a fixed box offset from the middle: a
	# fixed one clips its own text on a narrow window, which is every phone.
	_status.anchor_right = 1.0
	_status.offset_top = MARGIN
	_status.offset_bottom = MARGIN + 24.0
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_status)


## The palette: one button per thing that can be put in the room.
##
## [b]Built from [method RoomProps.wire_ids] rather than from the catalogue's own
## order.[/b] That is the sorted order the wire index is taken from, so the button at
## position three and the index at position three are the same thing by construction —
## and a palette built from `catalogue().props` would drift from it the first time
## somebody inserted a definition in the middle. dot-net shipped exactly that class of bug
## with message ids.
##
## [b]A [Button] each, not a container.[/b] A Button is focusable and a VBoxContainer is
## not, so Godot's own focus neighbours make the palette usable with a gamepad or the
## arrow keys for free — which is game-playground's finding about its spawn menu, and the
## failure dot-ui's `initial_focus` exists to prevent.
func _build_palette() -> void:
	_palette = HBoxContainer.new()
	_palette.name = "Palette"
	# [b]Beside the chat column, not centred on the window.[/b] Centred, it started at
	# half the window less half its own width — 387 px on this project's own 1280 × 720
	# window — and the chat entry runs to MARGIN + CHAT_WIDTH = 476, so the Bench and
	# Crate buttons sat on top of the line people type into, at 1920 as well. Nothing
	# measured it: every Control had a size and a position. A frame did.
	_palette.anchor_left = 0.0
	_palette.anchor_right = 0.0
	_palette.anchor_top = 1.0
	_palette.anchor_bottom = 1.0
	_palette.offset_left = MARGIN * 2.0 + CHAT_WIDTH
	_palette.offset_right = MARGIN * 2.0 + CHAT_WIDTH
	_palette.offset_top = -(MARGIN + 34.0)
	_palette.offset_bottom = -MARGIN
	_palette.grow_horizontal = Control.GROW_DIRECTION_END
	_palette.alignment = BoxContainer.ALIGNMENT_BEGIN
	add_child(_palette)

	var catalogue := RoomProps.shared_catalogue()

	for id in RoomProps.wire_ids():
		var def := catalogue.get_prop(StringName(id))

		if def == null:
			continue

		var button := Button.new()
		button.name = id
		button.text = def.name_or_id()
		button.toggle_mode = true
		button.tooltip_text = "Click, then click in the room. Backspace undoes."
		button.add_theme_color_override("font_color", RoomProps.colour_of(def))
		button.set_meta("prop_id", def.id)
		button.pressed.connect(_on_palette_pressed.bind(def.id))
		_palette.add_child(button)


func _on_palette_pressed(prop_id: StringName) -> void:
	# One at a time. A palette where two things are lit is a palette where the player does
	# not know what the next click will put down.
	_held = &"" if _held == prop_id else prop_id
	_sync_palette()


func _sync_palette() -> void:
	if _palette == null:
		return

	for child in _palette.get_children():
		var button := child as Button

		if button != null:
			button.button_pressed = button.get_meta("prop_id", &"") == _held


## What the player has selected, or empty.
func held_prop() -> StringName:
	return _held


## Whether anything is selected in the palette.
##
## Asked by the Escape ladder, which has to know whether there is something to put down
## before it decides that "nothing to stop" means "open the menu".
func has_held() -> bool:
	return _held != &""


## Puts the palette down. Called when a placement is made and when Escape is pressed.
func clear_held() -> void:
	_held = &""
	_sync_palette()


## Asks for something to be placed. Called by [RoomClient] with a world position.
func place_at(at: Vector2) -> bool:
	if _held == &"":
		return false

	place_requested.emit(_held, at)
	return true


## Draws the talking indicator.
func set_talking(talking: bool) -> void:
	if _talking != null:
		_talking.visible = talking


## Says why there is no microphone, once, in the log rather than in a dialog.
func note_voice(available: bool, reason: String) -> void:
	if available:
		add_notice("Hold V to talk.", Color(0.60, 0.78, 0.70))
		return

	add_notice(
		"No microphone: %s You can still hear everybody." % reason,
		Color(0.78, 0.72, 0.58)
	)


# --- Channels ---------------------------------------------------------------

## Which channel a typed line goes to.
func active_channel() -> StringName:
	return _channel


## Cycles to the next channel the player may speak on.
##
## [b]Admin-only channels are skipped rather than refused.[/b] A player who can tab onto a
## channel every line of which is rejected has a control that appears broken; one who
## cannot tab onto it has never heard of it, which is also the right answer.
func cycle_channel() -> void:
	var ids := _speakable_channels()

	if ids.is_empty():
		return

	var index := ids.find(String(_channel))
	_set_channel(StringName(ids[(index + 1) % ids.size()]))


func _speakable_channels() -> PackedStringArray:
	var out := PackedStringArray()

	for channel in RoomServices.chat_channels():
		# The whisper channel is DIRECT and needs a target, so it is not something Tab
		# can land on: a whisper with nobody addressed is a line that goes nowhere.
		if channel.admin_only or channel.scope == DotChatChannel.Scope.DIRECT:
			continue

		out.append(String(channel.id))

	return out


func _set_channel(id: StringName) -> void:
	_channel = id

	if _channel_label == null:
		return

	var chan: DotChatChannel = null

	for channel in RoomServices.chat_channels():
		if channel.id == id:
			chan = channel
			break

	if chan == null:
		_channel_label.text = "Talking to: %s" % String(id)
		return

	_channel_label.text = "Talking to: %s   (Tab to change)" % chan.display_name
	_channel_label.add_theme_color_override("font_color", chan.colour)


# --- Typing ----------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return

	var key := event as InputEventKey

	if (
		key.keycode == KEY_ENTER
		or key.keycode == KEY_KP_ENTER
		or (InputMap.has_action(OPEN_CHAT_ACTION) and event.is_action_pressed(OPEN_CHAT_ACTION))
	):
		start_typing()
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_TAB and is_typing():
		cycle_channel()
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_ESCAPE:
		# A ladder, innermost first: stop typing, then put the palette down, then open
		# the menu. One key for "stop what you are doing", and the menu is what is left
		# when there is nothing else to stop -- which is what every other client in this
		# family does and what this one did not do at all.
		if is_typing():
			_entry.text = ""
			_stop_typing()
		elif has_held():
			clear_held()
		else:
			pause_requested.emit()

		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_BACKSPACE and not is_typing():
		undo_requested.emit()
		get_viewport().set_input_as_handled()


## Gives the entry the keyboard.
func start_typing() -> void:
	if _entry == null or _entry.editable:
		return

	_entry.editable = true
	_entry.grab_focus()
	typing_changed.emit(true)


func _stop_typing() -> void:
	if _entry == null:
		return

	_entry.editable = false
	_entry.release_focus()
	typing_changed.emit(false)


func is_typing() -> bool:
	return _entry != null and _entry.editable


func _on_submitted(text: String) -> void:
	var trimmed := text.strip_edges()
	_entry.text = ""

	# The entry stays open after a line is sent, so a conversation is a conversation
	# rather than a sequence of Enter presses. Escape, or submitting nothing, closes it.
	if trimmed == "":
		_stop_typing()
		return

	chat_submitted.emit(trimmed)


# --- Content ---------------------------------------------------------------

## Adds a chat line, as [DotChatClient] filed it.
##
## [b]The channel decides how it is drawn, and the channel is a document rather than a
## flag.[/b] Its prefix and its colour come off the [DotChatChannel] both ends share, so
## adding a channel is adding a definition — there is no `if kind == "team"` here to
## forget to extend, which is what this function used to be.
func add_message(message: DotChatMessage, channel_id: StringName) -> void:
	if message == null or message.text == "":
		return

	var chan := chat.channel(channel_id) if chat != null else null

	var line := Label.new()
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var prefix := ""

	if chan != null and chan.prefix != "":
		prefix = chan.prefix + " "

	match message.kind:
		DotChatMessage.Kind.ACTION:
			# "* Ada waves" rather than "Ada: waves". The whole point of the form.
			line.text = "%s* %s %s" % [prefix, message.sender_name, message.text]
		DotChatMessage.Kind.WHISPER:
			line.text = "%s%s: %s" % [prefix, message.sender_name, message.text]
		DotChatMessage.Kind.SAY:
			line.text = "%s%s: %s" % [prefix, message.sender_name, message.text]
		_:
			# A system line, a join, a leave, an admin announcement. No speaker, and
			# attributing one would put the server's words in somebody's mouth.
			line.text = "%s%s" % [prefix, message.text]

	line.add_theme_color_override("font_color", _colour_for(message, chan))
	_append(line)


## What colour a line is drawn in.
##
## A player's own colour comes from the same derivation the circle over their head does,
## so the name in the log and the person in the room match — which is the only reason a
## derived colour beats an assigned one in a game with no profiles.
func _colour_for(message: DotChatMessage, chan: DotChatChannel) -> Color:
	if message.is_from_server():
		return chan.colour if chan != null else Color(0.65, 0.72, 0.80)

	var occupant_id := int(message.meta.get("o", 0))

	if occupant_id > 0:
		return RoomContent.colour_for(occupant_id).lightened(0.25)

	return chan.colour if chan != null else Color(0.85, 0.88, 0.92)


## Adds a line nobody said: joins, leaves, connection state.
func add_notice(text: String, colour: Color = Color(0.60, 0.68, 0.78)) -> void:
	var line := Label.new()
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.text = text
	line.add_theme_color_override("font_color", colour)
	_append(line)

	if _feed != null:
		_feed.add_text(text, colour)


func _append(line: Label) -> void:
	if _log == null:
		return

	_was_at_bottom = _at_bottom()
	_log.add_child(line)

	while _log.get_child_count() > MAX_CHAT_LINES:
		var oldest := _log.get_child(0)
		_log.remove_child(oldest)
		oldest.queue_free()

	if _was_at_bottom:
		# Deferred by two frames: the container has not laid the new label out yet, so
		# scrolling now scrolls to the old maximum and lands one line short. One frame is
		# enough for the label and not always for the wrap.
		_scroll_to_bottom.call_deferred()


func _scroll_to_bottom() -> void:
	await get_tree().process_frame

	if _scroll != null and is_instance_valid(_scroll):
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


func _at_bottom() -> bool:
	if _scroll == null:
		return true

	var bar := _scroll.get_v_scroll_bar()
	return _scroll.scroll_vertical >= int(bar.max_value - bar.page) - 4


## Redraws the roster from the world.
##
## Called on a change rather than every frame: the "here for" column only changes once a
## second and rebuilding a table of sixty-four labels at 144 Hz would be the most
## expensive thing in the game.
func set_roster(occupants: Array[RoomOccupant], local_id: int) -> void:
	if _roster == null:
		return

	var now := int(Time.get_unix_time_from_system())
	var rows: Array[Dictionary] = []

	for occupant in occupants:
		rows.append({
			&"name": occupant.display_name,
			&"here": _duration(maxi(0, now - occupant.joined_at)),
			"highlight": occupant.id == local_id,
			"colour": occupant.colour().lightened(0.2),
		})

	_roster.set_rows(rows)
	_roster_count.text = "In the room — %d" % occupants.size()


static func _duration(seconds: int) -> String:
	if seconds < 60:
		return "%ds" % seconds
	if seconds < 3600:
		return "%dm" % (seconds / 60)
	return "%dh" % (seconds / 3600)


## The banner across the top: connecting, downloading, a refusal.
##
## Empty hides it. A blank banner and a missing one look the same and behave differently
## the moment anything is laid out beside it.
func set_status(text: String, colour: Color = Color(0.85, 0.88, 0.92)) -> void:
	if _status == null:
		return

	_status.text = text
	_status.visible = text != ""
	_status.add_theme_color_override("font_color", colour)
