extends Node2D

const RoomBridge := preload("res://game/room_bridge.gd")
const RoomContent := preload("res://game/room_content.gd")
const RoomInput := preload("res://game/client/room_input.gd")
const RoomMenus := preload("res://game/client/room_menus.gd")
const RoomOffline := preload("res://game/room_offline.gd")
const RoomPresentation := preload("res://game/client/room_presentation.gd")
const RoomProps := preload("res://game/room_props.gd")
const RoomRenderer := preload("res://game/client/room_renderer.gd")
const RoomServices := preload("res://game/room_services.gd")
const RoomUi := preload("res://game/client/room_ui.gd")
const RoomVoice := preload("res://game/client/room_voice.gd")
const RoomWorld := preload("res://game/room_world.gd")

## Everything a person sees, in one scene.
##
## [b]This is what a host application instantiates.[/b] It is
## [member DotGameDescriptor.client_scene], so a generic client shell that downloaded and
## mounted this pack adds it under [DotClientLink] and gets a playable lobby — no code in
## the shell knows anything about a room.
##
## It owns a mirroring [RoomWorld], a client-side [DotNetManager] and a [RoomBridge], and
## it drives them from [code]_physics_process[/code]. Two of those it also builds for
## itself when there is nothing to connect to, which is what `--offline` is: the same
## scene with a server in the same tree.
##
## [b]The camera does not follow anybody.[/b] The room is smaller than a screen at a
## sensible zoom, and a lobby where you cannot see who is standing behind you is a lobby
## whose roster is the only thing anybody reads. So the whole room is framed, always, and
## re-framed when the window changes.

const CHANNEL := "room.client"

## What a person is called when nothing has told us otherwise.
const DEFAULT_NAME := "Guest"

## Margin around the room when the camera frames it, as a fraction of the room.
const CAMERA_MARGIN := 0.06

## The link this client talks to a server through.
##
## Set by whoever built this scene, before it enters the tree. A generic client shell that
## mounted this pack does not know what a room is, so when it is left null the link is
## looked up in [DotRegistry] instead — which is right for the one-client case and wrong
## for any process holding two, where only one of them can hold the name. Anything running
## two clients sets this explicitly; `examples/sandbox.tscn` does.
##
## Null with nothing registered means offline: there is no server, and
## [method _build_offline] stands one up in this tree instead.
## The player asked to leave from the pause menu.
##
## [b]Announced rather than acted on, and that is the same rule game-arena's browser
## follows.[/b] What "leave" means belongs to whatever loaded this client: a shell that
## downloaded a pack goes back to its own menu, an embedded page closes the frame, a
## development scene quits. A client that called `get_tree().quit()` itself would be one
## that cannot be embedded in anything.
##
## Nothing connected to it is a pause menu whose Leave button closes the menu, which is
## the honest behaviour for a host that has nowhere to go.
signal leave_requested()

var link: DotClientLink = null

var world: RoomWorld = null
var net: DotNetManager = null
var bridge: RoomBridge = null

var input: RoomInput = null
var renderer: RoomRenderer = null
var ui: RoomUi = null

## The client half of chat: the channels, the history, the unread counts and the gap
## detection. [b]It decides nothing[/b] — every rule is the server's — and it exists so
## the interface has somewhere to read a channel's last fifty lines from without keeping
## its own copy of them.
var chat: DotChatClient = null

## The client half of voice. Null on a build with no audio at all; every call on it is
## guarded, because "there is no microphone" is a legitimate machine rather than an error.
var voice: RoomVoice = null

## What people have put in the room, mirrored. Both ends collide against it.
var props: RoomProps = null

## Settings, audio, effects and the console. Everything that belongs to the person at the
## keyboard rather than to the room.
var presentation: RoomPresentation = null

## The escape menu. See [RoomMenus].
var menus: DotScreenStack = null

## occupant id -> the avatar rows the server sent. Drawn by [RoomRenderer].
var _avatars: Dictionary = {}

var _camera: Camera2D = null
var _tick: int = 0
var _roster_dirty: bool = true
var _roster_drawn_at: int = 0

## Whether the initial roster has finished arriving.
##
## Joins are announced only after it has. Otherwise every connect opens with a wall of
## "X joined" for people who were already standing there — wrong, and the loudest thing
## on the screen at the moment somebody is trying to read the room.
var _roster_ready: bool = false

## An offline session's own server half, when there is one. Null in every real deployment.
var _offline: RoomOffline = null


func _ready() -> void:
	# [b]First, and before the interface.[/b] The settings document decides how many chat
	# lines the interface draws and whether it timestamps them, so a presentation layer
	# built afterwards would be read by a screen that had already laid itself out.
	_build_presentation()
	_build_chat()
	_build_view()

	# The link is found rather than required. A client scene instantiated by a shell has
	# one; the same scene run from `examples/play.tscn --offline` does not, and the
	# difference must not be two scenes.
	if link == null:
		link = DotRegistry.get_node_service(DotClientLink.SERVICE) as DotClientLink

	if link != null:
		_build_online()
	else:
		_build_offline()

	# After the bridge exists either way, because both of them need somewhere to send.
	_build_voice()

	get_viewport().size_changed.connect(_frame_room)
	_frame_room()


func _exit_tree() -> void:
	if link != null and is_instance_valid(link):
		if link.disconnected.is_connected(_on_disconnected):
			link.disconnected.disconnect(_on_disconnected)


# --- Building --------------------------------------------------------------

## Settings, audio, effects and the console.
func _build_presentation() -> void:
	presentation = RoomPresentation.new()
	presentation.name = "Presentation"
	presentation.client = self
	add_child(presentation)
	DotLog.result("room.client", "the presentation layer", presentation.setup())

## The chat client, before the interface, because the interface reads its channels.
func _build_chat() -> void:
	chat = DotChatClient.new()
	chat.name = "Chat"
	# The same channel definitions the server routes with. [b]Shared rather than sent[/b],
	# for the room-size reason: a client holding a different set would show a line on a
	# channel it has no colour or prefix for, and the failure is a message that is
	# silently unattributed rather than one that is missing.
	chat.channels = RoomServices.chat_channels()
	chat.rules = RoomServices.chat_rules()
	chat.history_limit = 400
	# Two clients in one process — `examples/sandbox.tscn` — would otherwise collide on
	# the registry name and one of them would be invisible to whatever asked for it.
	chat.register_as = &""
	add_child(chat)

	chat.start()
	chat.message_received.connect(_on_chat_message)


## Voice, once there is a bridge to send through.
##
## [b]Capture is off in a headless run and that is not a special case[/b] — it is what
## [method DotVoiceSourceMicrophone.is_supported] answers, and it answers it by asking
## `AudioServer.get_driver_name()` rather than any of the three properties that report a
## working sound card on a machine with none.
func _build_voice() -> void:
	if bridge == null:
		return

	voice = RoomVoice.new()
	voice.name = "Voice"
	voice.send_fn = func(bytes: PackedByteArray) -> void:
		if bridge != null and bridge.link != null:
			# The peer is ignored on a client — every frame goes to the authority — and
			# it is passed as 1 rather than 0 because in this family zero has meant
			# "everybody" often enough to be worth never writing by accident.
			bridge.link.send_voice(1, bytes)
	add_child(voice)

	voice.setup(not DotPlatform.is_headless())

	bridge.voice_arrived.connect(voice.receive)
	voice.talking_changed.connect(func(talking: bool) -> void:
		ui.set_talking(talking)
	)

	# Said once, in the log, rather than swallowed. A player whose microphone was refused
	# and who is told nothing spends the evening believing voice is broken for everybody.
	ui.note_voice(voice.available, voice.unavailable_reason)


func _build_view() -> void:
	_camera = Camera2D.new()
	_camera.name = "Camera"
	_camera.enabled = true
	add_child(_camera)

	renderer = RoomRenderer.new()
	renderer.name = "Renderer"
	add_child(renderer)

	input = RoomInput.new()
	input.name = "Input"
	add_child(input)

	var layer := CanvasLayer.new()
	layer.name = "Ui"
	add_child(layer)

	ui = RoomUi.new()
	ui.name = "Room"
	layer.add_child(ui)

	ui.chat = chat
	ui.chat_submitted.connect(_on_chat_submitted)
	ui.place_requested.connect(_on_place_requested)
	ui.pause_requested.connect(_toggle_pause)
	ui.undo_requested.connect(func() -> void:
		if bridge != null:
			bridge.ask_to_undo()
	)

	_build_menus(layer)
	# The one wiring that matters: while a text field has the keyboard, WASD is text.
	ui.typing_changed.connect(func(typing: bool) -> void:
		input.enabled = not typing
		if typing:
			input.release()
			# The microphone closes with the keyboard. Otherwise the key-up for the talk
			# key lands in the text field, the gate is never closed, and the player is
			# broadcasting whatever they say while typing — which is the one voice bug
			# people report as "everyone could hear me" rather than as a bug.
			if voice != null:
				voice.release()
	)


## The normal case: a mirroring world behind a real connection.
func _build_online() -> void:
	world = _make_world()
	world.props = _make_props()
	renderer.world = world

	var config := RoomContent.net_config()
	config.tick_rate = world.tick_rate

	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	# Replaced by the hello. Until then nothing is sent, because nothing has been spawned.
	net.local_peer_id = 0
	net.config = config
	net.config_file = ""
	net.auto_tick = false
	add_child(net)

	var ready := net.setup()

	if not ready.ok:
		DotLog.error(CHANNEL, "the netcode would not start", {"error": str(ready.error)})
		ui.set_status("This room could not start.", Color(1.0, 0.5, 0.5))
		return

	bridge = RoomBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(world, net, link)

	if not attached.ok:
		DotLog.error(CHANNEL, "the bridge would not attach", {"error": str(attached.error)})
		ui.set_status("This room could not start.", Color(1.0, 0.5, 0.5))
		return

	net.start()
	_connect_bridge()

	# Where the clock learns how long the link is. dot-net never touches a transport and
	# cannot measure this itself; dot-server already does, through its heartbeat. Fed
	# nothing, the clock assumes an instant connection and stamps every command for a tick
	# the server has already simulated — see [member RoomBridge.rtt_source].
	bridge.rtt_source = func() -> float:
		return float(maxi(0, link.ping_ms()))

	# [b]dot-server's own chat signal is deliberately NOT connected.[/b] The server
	# cancels that path — see [method RoomModule._on_player_chat] — and routes every line
	# through [DotChatRouter] onto this game's own wire instead. Connecting both would
	# draw a line twice on a server running the old path and once on a server running the
	# new one, which is the sort of difference that survives every test.
	link.disconnected.connect(_on_disconnected)

	ui.set_status("Joining the room…")

	# [b]Nothing may be sent to us before we say we exist.[/b] dot-server's signon
	# finished and *then* this scene was built; anything the server sent in between landed
	# on a node that did not exist. This is the first thing that goes the other way, and
	# it is what makes the roster arrive at all.
	bridge.ask_for_room()


## The client's mirror of what is in the room.
##
## Not authoritative: [method RoomProps.setup] with `false` builds no [DotPropSpawner] at
## all, because dot-props is explicit that a client holding one that could spawn would be
## a modified client filling the world. What this holds is placements the server announced.
func _make_props() -> RoomProps:
	props = RoomProps.new()
	props.name = "Props"
	add_child(props)
	props.setup(false, self)
	return props


func _connect_bridge() -> void:
	bridge.chat_received.connect(func(wire: Dictionary) -> void:
		chat.receive(wire)
	)
	bridge.avatar_received.connect(_on_avatar)

	# The renderer reads the same object the simulation collides against, once, rather
	# than being handed a copy on every placement. There is nothing to keep in step
	# because there is only one list.
	renderer.props = props
	renderer.avatars = _avatars

	if props != null:
		# One line in the feed when something appears, because a bench materialising with
		# no explanation reads as a glitch and a sentence does not.
		props.placed.connect(func(_place_id: int, def: DotPropDef, at: Vector2) -> void:
			if _roster_ready:
				ui.add_notice("A %s was put down." % def.name_or_id().to_lower())
			if presentation != null:
				# Positional, on the XZ plane, which is the convention every addon in this
				# family uses for a 2D world -- dot-npc maps one onto it so its senses and
				# navigation run unchanged, and dot-audio and dot-fx take the same shape so
				# one call serves both dimensions.
				presentation.on_prop_placed(at)
		)

	bridge.hello_received.connect(func(occupant_id: int) -> void:
		renderer.local_occupant_id = occupant_id
		_roster_dirty = true
	)
	bridge.roster_changed.connect(_on_roster_changed)
	bridge.roster_complete.connect(func() -> void:
		ui.set_status("")
		_roster_dirty = true
		_roster_ready = true
	)


## `--offline`: a server and a client in one tree, with a loopback between them.
##
## Not a mode the deployed game has. It exists so the room can be looked at, and drawn,
## without a socket — and because a scene that can only be run by connecting to something
## is a scene nobody checks.
func _build_offline() -> void:
	_offline = RoomOffline.new()
	_offline.name = "Offline"
	add_child(_offline)

	var built := _offline.start(DEFAULT_NAME)

	if not built.ok:
		DotLog.error(CHANNEL, "offline room failed", {"error": str(built.error)})
		ui.set_status("This room could not start.", Color(1.0, 0.5, 0.5))
		return

	world = _offline.client_world
	net = _offline.client_net
	bridge = _offline.client_bridge
	props = _offline.client_props
	renderer.world = world

	_connect_bridge()
	ui.set_status("Offline — nobody else can see this room.", Color(0.8, 0.75, 0.5))
	bridge.ask_for_room()


## A mirroring world for this client.
##
## [b]Not published in [DotRegistry].[/b] Nothing on a client looks a room up by name —
## only a server-side module does, to find the world a game scene created — and two
## clients in one process would collide on the entry, leaving one of them invisible to
## whatever asked. `examples/sandbox.tscn` runs exactly that, and dot-platform's sandbox
## proved two clients in one tree is a shape this family has to support.
func _make_world() -> RoomWorld:
	var made := RoomWorld.new()
	made.name = "World"
	made.is_authority = false
	made.tick_rate = RoomContent.TICK_RATE
	made.register_service = false
	add_child(made)
	return made


# --- The frame -------------------------------------------------------------

## One or more simulation ticks, driven by the netcode's clock.
##
## [b]The clock is what puts the input ahead of the server.[/b] A command for tick N has
## to be in the server's hands *before* it simulates N, so a client running level with the
## server has every input arrive one tick late — for ever, with no error, and the only
## symptom is a player who cannot move while moving perfectly on their own screen. A
## private frame counter is exactly that mistake, and it is what this used to be.
func _physics_process(delta: float) -> void:
	if bridge == null or net == null or world == null:
		return

	var me := bridge.local_occupant()

	if me != null:
		input.centre = me.position()

	var command := input.sample(get_viewport(), _camera)

	for _step in range(net.clock.advance(delta)):
		if _offline != null:
			# Offline the client *is* the authority's neighbour and there is nothing to
			# be ahead of, so both halves run on the same number. The lead exists to
			# cover a network that is not there.
			_tick += 1
			bridge.client_tick(_tick, command)
			_offline.server_tick(_tick)
		elif net.clock.is_synced():
			bridge.client_tick(net.clock.input_tick(), command)


func _process(delta: float) -> void:
	if presentation != null:
		# Once a frame, with the camera's position. dot-audio culls by distance from the
		# listener and dot-fx ages its instances, and neither of them ticks itself -- for
		# the reason everything tickable in this family is explicit: `_process` does not
		# run while a tree is paused, and a pause menu is exactly when nothing finishes.
		presentation.present(delta, _camera.global_position if _camera != null else Vector2.ZERO)

	if net != null:
		# Every frame, not every tick: this is what turns fifteen snapshots a second into
		# smooth motion, and it is sampled at the render tick rather than the simulation
		# one. Skipping it on a frame is a frame everybody else stands still for.
		net.interpolate_frame()

	# The roster's "here for" column changes once a second, so it is rebuilt at most that
	# often — and immediately when somebody arrives or leaves. Rebuilding sixty-four
	# labels at 144 Hz would be the most expensive thing in this game by an order of
	# magnitude.
	var now := Time.get_ticks_msec()

	if _roster_dirty or now - _roster_drawn_at > 1000:
		_roster_dirty = false
		_roster_drawn_at = now

		if world != null and ui != null:
			ui.set_roster(world.roster(), bridge.local_occupant_id if bridge != null else 0)


func _unhandled_input(event: InputEvent) -> void:
	# [b]The console before anything else that reads a key.[/b] This game turns letters
	# into shortcuts -- Tab cycles a channel, Enter starts typing -- so without this,
	# typing `settings` into the console would cycle the channel four times and open the
	# chat box. It is the line every game that ships a console forgets.
	if presentation != null and presentation.swallows_input():
		return

	# [b]Voice first, and it is the one thing that must be seen while typing.[/b] The
	# talk key is not a movement key and the interface only takes the keyboard for text;
	# a release swallowed because a text field had focus is a microphone left open, which
	# is exactly the failure [method RoomVoice.release] exists for and is why the typing
	# handler closes it as well.
	if voice != null and voice.handle_event(event):
		get_viewport().set_input_as_handled()
		return

	# A click with something selected in the palette puts it down instead of walking.
	# Checked before the input sampler sees it, because on a touchscreen the same press is
	# a drag: a player who selected a bench and then dragged across the room would
	# otherwise walk there and place nothing.
	if _place_click(event):
		get_viewport().set_input_as_handled()
		return

	if input != null:
		input.handle_event(event)


## The escape menu, on the same layer the interface is drawn on.
##
## [b]`manage_mouse` is off.[/b] The stack forces CAPTURED whenever nothing is open, which
## is right for a first-person game and wrong for this one: the lobby is played with a
## visible cursor -- a click places a prop -- so a stack that recaptured the mouse every
## time a menu closed would take the pointer away from the one control scheme this game
## has. dot-ui's own notes say two owners fighting over the mouse is a cursor that
## flickers; here there is one owner and it is the game.
func _build_menus(layer: CanvasLayer) -> void:
	menus = DotScreenStack.new()
	menus.name = "Menus"
	menus.register_service = false
	menus.manage_mouse = false
	layer.add_child(menus)

	var settings: DotSettingsManager = (
		presentation.settings if presentation != null else null
	)
	var pause := RoomMenus.install(menus, settings)

	pause.leave_pressed.connect(func() -> void:
		# Closing the menu first, so a client that cannot actually leave -- an embedded
		# one, a single-process test -- is not left staring at a pause screen over a game
		# that carried on running behind it.
		menus.pop(&"pause")
		leave_requested.emit()
	)


## Opens or closes the pause menu.
##
## Nothing else may be open when it opens: a player pressing Escape in a settings screen
## means "go back", which the stack's own back key already does, and a pause screen pushed
## on top of settings would be two menus deep for one press.
func _toggle_pause() -> void:
	if menus == null:
		return

	if menus.top() != null and not menus.is_open(&"pause"):
		menus.pop()
		return

	menus.toggle(&"pause")


## A click that is a placement rather than a step. False when it is not one.
func _place_click(event: InputEvent) -> bool:
	if ui == null or ui.held_prop() == &"":
		return false

	var at := Vector2.ZERO

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton

		if button.button_index != MOUSE_BUTTON_LEFT or not button.pressed:
			return false

		at = button.position
	elif event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch

		if not touch.pressed:
			return false

		at = touch.position
	else:
		return false

	return ui.place_at(input.to_world(get_viewport(), _camera, at))


## Fits the whole room in the window.
##
## Recomputed on every resize because a browser tab is resized constantly — and because a
## phone rotating is a resize, and a camera that kept its zoom would show a quarter of the
## room in portrait with no indication that there was any more of it.
func _frame_room() -> void:
	if _camera == null or world == null or world.arena == null:
		return

	var room := world.arena.bounds.size * (1.0 + CAMERA_MARGIN * 2.0)
	var view := Vector2(get_viewport_rect().size)

	if room.x <= 0.0 or room.y <= 0.0 or view.x <= 0.0 or view.y <= 0.0:
		return

	# The *smaller* ratio, so the whole room fits rather than filling the window. Taking
	# the larger one crops, and a person standing in a cropped corner is a person nobody
	# can see talking.
	var scale := minf(view.x / room.x, view.y / room.y)
	_camera.zoom = Vector2(scale, scale)
	_camera.position = world.arena.bounds.get_center()


# --- Chat ------------------------------------------------------------------

## Somebody pressed Enter.
##
## [b]One path, online and offline.[/b] Both send a `SAY` request over the bridge — the
## offline one over a loopback — and both get the answer back as a routed `CHAT` event.
## This function used to fork, and the offline half restated the shape of a chat payload
## by hand, so the code a person running `--offline` exercised was the one path nothing
## else used.
func _on_chat_submitted(text: String) -> void:
	if bridge != null:
		bridge.say(ui.active_channel(), text)


## A line [DotChatClient] accepted: in sequence, not a duplicate, on a known channel.
func _on_chat_message(message: DotChatMessage, channel_id: StringName) -> void:
	ui.add_message(message, channel_id)

	# The bubble over somebody's head is drawn from the same message the log is, rather
	# than from a second event. One path, so a bubble can never say something the log does
	# not — which is what a second path eventually produces.
	#
	# [b]Only what a player said.[/b] A join notice or a server announcement has no
	# speaker, and drawing one over somebody's head would put the server's words in their
	# mouth. `sender_key` is what says which it is, and it is the pseudonymous key rather
	# than a name for the reason dot-user exists.
	if message.is_from_server() or message.sender_key == "":
		return

	# The occupant the server named, out of the one meta field this game's wire carries.
	# Zero means the server could not resolve one — a line from somebody who has already
	# left, which is a real sequence rather than an error — and there is simply no bubble.
	var occupant := world.occupant_for(int(message.meta.get("o", 0)))

	if occupant != null:
		occupant.say(message.text, Time.get_ticks_msec())

	if presentation != null:
		# A whisper and a mention are worth a noise and a tint; an ordinary line is worth
		# a quieter noise with a cooldown on it, because a room of twenty people typing is
		# twenty notifications a second and that is a fire alarm rather than a busy room.
		var me := bridge.local_occupant_id if bridge != null else 0
		var mine := world.occupant_for(me)
		var mentioned := mine != null and message.text.to_lower().contains(
			mine.display_name.to_lower()
		)
		presentation.on_message(channel_id, mentioned)


# --- Props -----------------------------------------------------------------

func _on_place_requested(prop_id: StringName, at: Vector2) -> void:
	if bridge != null:
		bridge.ask_to_place(prop_id, at)


# --- Avatars ---------------------------------------------------------------

## Somebody's avatar document arrived. Ids and colours; no scene, no mesh, no download.
func _on_avatar(occupant_id: int, parts: Array) -> void:
	# Written into the dictionary the renderer already holds, rather than reassigning it:
	# a Dictionary is a reference in GDScript, so both ends are looking at one object and
	# there is nothing to forget to hand over.
	_avatars[occupant_id] = parts


func _on_roster_changed(occupant_id: int, present: bool) -> void:
	_roster_dirty = true

	var occupant := world.occupant_for(occupant_id)
	var who := occupant.display_name if occupant != null else "Somebody"

	if not _roster_ready:
		return

	ui.add_notice(
		"%s joined." % who if present else "%s left." % who,
		Color(0.55, 0.85, 0.60) if present else Color(0.85, 0.60, 0.55)
	)

	if presentation != null:
		if present:
			presentation.on_join(occupant_id)
		else:
			presentation.on_leave(occupant_id)


func _on_disconnected(reason: String) -> void:
	input.enabled = false
	ui.set_status(
		"Disconnected: %s" % reason if reason != "" else "Disconnected.",
		Color(1.0, 0.55, 0.55)
	)
