extends Node

const RoomPaths := preload("../room_paths.gd")

const RoomServices := preload("../room_services.gd")
const RoomUi := preload("room_ui.gd")

## The four things that belong to the person sitting in front of the screen.
##
## dot-settings, dot-audio, dot-fx and dot-console, in one node, on the client only.
##
## [b]They are here together for the same reason [RoomServices] exists[/b]: the joins
## between them are the whole point. The settings document is where the volume lives, the
## mixer is what reads it, the console is what changes it from a keyboard, and none of
## those three addons knows the other two exist — they meet through this file and through
## two duck-typed calls.
##
## [b]None of it runs on the dedicated server.[/b] A settings document belongs to a person,
## a sound belongs to a machine with a sound card, an effect belongs to a machine with a
## renderer, and a console belongs to somebody with a keyboard. The server has
## dot-server's own console, which this one bridges to when the two are in one process.

const CHANNEL := "room.presentation"

## What a lobby lets a player change.
##
## Small on purpose. This is the smallest game in the family and its settings screen
## should look like it — a list of six is a list somebody reads, and a list of forty is a
## list with a search box in it.
const SCHEMA_VERSION := 1

## Sounds. Ids only: the catalogue names files and loads none, and this game ships no
## audio at all, so every one of these resolves to nothing and is refused at the sink.
##
## [b]That is a deployment, not a gap.[/b] Four of the five games in this family ship no
## audio; what they were missing was not the files but the decision about what is
## audible, how many at once and how loud — which is a document, and is this one. Dropping
## a file in later changes nothing else.
const SOUND_DIR := "res://audio"

## The ping an administrator's beacon makes. See [method sound_catalogue].
const BEACON_SOUND := &"beacon"

var settings: DotSettingsManager = null
var audio: DotAudioManager = null
var fx: DotFxManager = null
var console: DotConsoleController = null
var console_panel: DotConsolePanel = null

## Where the console's surface goes. A [CanvasLayer] above everything the game draws.
var _layer: CanvasLayer = null

## The client this belongs to, for the commands that ask it questions.
var client: Node = null


func setup() -> DotResult:
	var settled := _build_settings()
	if not settled.ok:
		return settled

	# Audio before the console, because the console binds `volume` straight through to the
	# settings document and wants the mixer to already be reading it. Same ordering rule as
	# RoomServices' "moderation first": the thing that publishes goes before the thing that
	# subscribes, or the subscriber warns once about a source that turns up a line later.
	var heard := _build_audio()
	if not heard.ok:
		return heard

	var drawn := _build_fx()
	if not drawn.ok:
		return drawn

	var consoled := _build_console()
	if not consoled.ok:
		return consoled

	# Every value pushed once, after everything exists. The builders above read the
	# settings they need, which is enough today and is the arrangement that rots: the
	# next thing added reacts to `changed` only, a value loaded from disk has not changed,
	# and a player's saved setting silently does nothing until they touch it. game-hungario
	# shipped exactly that -- a saved volume that never reached the sound bank.
	apply_all()
	return DotResult.success(null)


## Pushes every current setting at whatever reads it.
func apply_all() -> void:
	for key in settings.schema.keys():
		_on_setting_changed(key, settings.get_value(key), &"applied")


# --- Settings ---------------------------------------------------------------

## The schema, as a static function so a suite can check it without a node.
static func schema() -> DotSettingsSchema:
	var s := DotSettingsSchema.new()
	s.version = SCHEMA_VERSION

	s.add(DotSettingsDef.number(&"master_volume", 0.8, 0.0, 1.0, &"audio"))
	s.add(DotSettingsDef.number(&"voice_volume", 1.0, 0.0, 1.0, &"audio"))
	s.add(DotSettingsDef.boolean(&"push_to_talk", true, &"audio").with_description(
		"Off uses voice activation, which a noisy room should not."
	))

	# ACCOUNT scope: a lobby is where somebody configures themselves before going
	# somewhere else, so the settings that are about *them* follow them.
	s.add(DotSettingsDef.boolean(&"show_timestamps", false, &"chat").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.integer(&"chat_lines", 14, 4, 40, &"chat").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))

	# The key that gives the entry the keyboard. Y, which is what every other game in this
	# family opens chat with, and this one also answers Enter because it is a chat room and
	# a chat room that ignores Enter is broken.
	#
	# [b]There is deliberately no `chat_window` setting here, and this is the one game
	# where that is right.[/b] Everywhere else the box is something drawn over a game and a
	# player can sensibly say "I chat somewhere else"; here the chat log, the roster and
	# the entry ARE the game, and turning them off leaves a person standing in an empty
	# room with no way to say so.
	s.add(DotSettingsDef.binding(&"chat_open_key", "Y", &"chat").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))

	# The only one a server may touch here, and it is the only one worth touching: a room
	# that wants everybody to hear everybody caps the proximity range at its own width.
	s.add(DotSettingsDef.number(&"near_range", 420.0, 60.0, 2000.0, &"chat").with_scope(
		DotSettingsDef.Scope.SERVER_CLAMPED
	))

	s.add(DotSettingsDef.number(&"shake_scale", 1.0, 0.0, 2.0, &"accessibility")
		.with_description("Zero turns camera shake off entirely."))
	s.add(DotSettingsDef.boolean(&"allow_flashes", true, &"accessibility")
		.with_description("Off draws no full-screen flashes at all."))
	return s


func _build_settings() -> DotResult:
	settings = DotSettingsManager.new()
	settings.name = "Settings"
	settings.schema = schema()
	settings.local_store = DotSettingsStoreFile.new("user://lobby_settings")
	settings.app_namespace = &"game_simple_lobby"
	# The shared namespace is the point of ACCOUNT scope: a player who sets their chat
	# preferences in the lobby has set them for every game in this family that opts in.
	settings.shared_namespace = &"tmc_account"
	add_child(settings)

	var res := settings.setup()
	if not res.ok:
		return res.wrap("the lobby's settings")

	settings.changed.connect(_on_setting_changed)
	return DotResult.success(null)


func _on_setting_changed(key: StringName, value: Variant, _why: StringName) -> void:
	match key:
		&"master_volume":
			if audio != null:
				audio.mixer.master = float(value)
				audio.mixer.apply_to_buses()
		&"voice_volume":
			if audio != null:
				audio.mixer.voice = float(value)
				audio.mixer.apply_to_buses()
		&"shake_scale":
			if fx != null:
				# Not applied here beyond the config: DotFxManager reads it every frame in
				# advance(), which is what makes turning shake off take effect immediately
				# rather than at the next map.
				fx.config.shake_scale = float(value)
		&"allow_flashes":
			if fx != null:
				fx.config.allow_flashes = bool(value)
		&"chat_open_key":
			# Empty is left alone rather than applied: a settings file somebody cleared
			# the field in would otherwise leave a chat room with no way into its own
			# chat box but Enter.
			if str(value).strip_edges() != "":
				var bound := DotInputBinding.apply(RoomUi.OPEN_CHAT_ACTION, str(value))
				if bound == "":
					DotLog.warn(CHANNEL, "a chat key was not understood", {
						"binding": str(value)
					})
		_:
			pass


# --- Audio ------------------------------------------------------------------

## What a lobby makes a noise about.
##
## Six sounds, and the interesting one is `chat_message`: it has a cooldown because a
## room of twenty people typing is twenty notification sounds a second, which is not a
## busy room, it is a fire alarm.
static func sound_catalogue() -> DotAudioCatalogue:
	var c := DotAudioCatalogue.new()

	var join := DotAudioDef.new()
	join.id = &"join"
	join.path = "%s/join.ogg" % SOUND_DIR
	join.bus = &"UI"
	join.cooldown_ms = 150
	join.max_concurrent = 2
	join.priority = 40
	c.add(join)

	var leave := DotAudioDef.new()
	leave.id = &"leave"
	leave.path = "%s/leave.ogg" % SOUND_DIR
	leave.bus = &"UI"
	leave.cooldown_ms = 150
	leave.max_concurrent = 2
	leave.priority = 40
	c.add(leave)

	var message := DotAudioDef.new()
	message.id = &"chat_message"
	message.path = "%s/message.ogg" % SOUND_DIR
	message.bus = &"UI"
	# Twenty people typing is twenty notifications a second without this.
	message.cooldown_ms = 400
	message.max_concurrent = 1
	message.priority = 20
	c.add(message)

	var whisper := DotAudioDef.new()
	whisper.id = &"chat_whisper"
	whisper.path = "%s/whisper.ogg" % SOUND_DIR
	whisper.bus = &"UI"
	whisper.cooldown_ms = 200
	# Louder than an ordinary message and with a higher priority, because a whisper is
	# addressed to you and the whole point is that you notice it.
	whisper.priority = 70
	c.add(whisper)

	var place := DotAudioDef.new()
	place.id = &"prop_placed"
	place.path = "%s/place.ogg" % SOUND_DIR
	place.kind = DotAudioDef.Kind.POSITIONAL_2D
	place.bus = &"SFX"
	# The room is 1800 x 1120, so this is about a third of it -- far enough to hear
	# somebody moving furniture near you and not across the room.
	place.max_distance = 600.0
	place.pitch_min = 0.92
	place.pitch_max = 1.08
	place.max_concurrent = 3
	c.add(place)

	# An administrator's beacon: a ping once a period from the beaconed person, heard by
	# everybody. The one sound here about somebody a moderator wants the room to find, so
	# it is the one allowed to be insistent — and it stops the moment the beacon does.
	# Positional, so it says WHERE as well as that; reaching past the room's diagonal, so
	# nobody in it is out of earshot. Pitched an octave under `chat_message`, which shares
	# its voice, so a ping is never heard as somebody talking.
	var ping := DotAudioDef.new()
	ping.id = BEACON_SOUND
	ping.path = "%s/beacon.ogg" % SOUND_DIR
	ping.kind = DotAudioDef.Kind.POSITIONAL_2D
	ping.bus = &"SFX"
	ping.max_distance = 2400.0
	ping.max_concurrent = 4
	ping.priority = 45
	ping.pitch_min = 0.5
	ping.pitch_max = 0.5
	c.add(ping)

	return c


## Which synthesised voice stands in for each id until real audio is dropped into
## [constant SOUND_DIR].
##
## [b]Everything a lobby makes a noise about is somebody else doing something.[/b] Nothing
## here is a consequence of your own input, so every one of these is short and quiet by
## design — a room you sit in for twenty minutes is the one place in this family where an
## over-eager sound becomes something people mute the tab for.
##
## `chat_message` and `chat_whisper` are deliberately different: a line addressed to you
## arriving in the same blip as the room's traffic is a line you will miss.
static func sound_recipes() -> Dictionary:
	return {
		&"join": DotAudioSynth.Voice.SPAWN,
		&"leave": DotAudioSynth.Voice.DENY,
		&"chat_message": DotAudioSynth.Voice.BLIP,
		&"chat_whisper": DotAudioSynth.Voice.CLICK,
		&"prop_placed": DotAudioSynth.Voice.IMPACT,
		BEACON_SOUND: DotAudioSynth.Voice.BLIP,
	}


func _build_audio() -> DotResult:
	audio = DotAudioManager.new()
	audio.name = "Audio"
	audio.catalogue = sound_catalogue()
	audio.mixer = DotAudioMixer.new()
	audio.mixer.master = settings.get_float(&"master_volume", 0.8)
	audio.mixer.voice = settings.get_float(&"voice_volume", 1.0)
	audio.voices = 16
	add_child(audio)

	var res := audio.setup()
	if not res.ok:
		return res.wrap("the lobby's audio")

	# Only on a real sink, and only after setup: the manager decides whether there is a
	# device, and on a headless server there is nothing to bake for. Building the bank
	# anyway would be arithmetic per dedicated-server startup for streams no process on
	# that machine can play.
	var godot_sink := audio.sink as DotAudioSinkGodot
	if godot_sink != null:
		godot_sink.bank = DotAudioSynth.bank(audio.catalogue, sound_recipes())
		DotLog.info(
			CHANNEL,
			"no audio files; synthesised stand-ins are in use",
			{"ids": sound_recipes().size(), "dir": SOUND_DIR}
		)

	return DotResult.success(null)


# --- Effects ----------------------------------------------------------------

## What a lobby draws. Two things, and both are about the conversation.
static func fx_catalogue() -> DotFxCatalogue:
	var c := DotFxCatalogue.new()

	var ripple := DotFxDef.new()
	ripple.id = &"prop_placed"
	ripple.scene_path = RoomPaths.rebase("res://scenes/fx/place_ripple.tscn")
	ripple.kind = DotFxDef.Kind.SPAWNED
	ripple.lifetime_ms = 700
	ripple.cost = 1
	ripple.priority = 30
	ripple.max_distance = 0.0
	c.add(ripple)

	var mention := DotFxDef.new()
	mention.id = &"mentioned"
	mention.kind = DotFxDef.Kind.SCREEN
	# Deliberately gentle, and it still goes through the rate limit and the player's own
	# off switch. A notification flash is exactly the kind of effect somebody adds at
	# full strength because it is "only a tint".
	mention.flash_peak = 0.12
	mention.flash_colour = Color(0.55, 0.78, 1.0)
	mention.flash_decay_ms = 350
	c.add(mention)

	return c


func _build_fx() -> DotResult:
	fx = DotFxManager.new()
	fx.name = "Fx"
	fx.catalogue = fx_catalogue()
	fx.config = DotFxConfig.new()
	fx.config.shake_scale = settings.get_float(&"shake_scale", 1.0)
	fx.config.allow_flashes = settings.get_bool(&"allow_flashes", true)
	fx.config.max_decals = 0
	add_child(fx)

	var res := fx.setup()
	if not res.ok:
		return res.wrap("the lobby's effects")
	return DotResult.success(null)


# --- Console ----------------------------------------------------------------

func _build_console() -> DotResult:
	console = DotConsoleController.new()
	console.name = "Console"
	console.config = DotConsoleConfig.new()
	console.config.mirror_log = true
	# INFO and above. A lobby is quiet enough that INFO is readable, which is not true of
	# a dedicated server -- and a console that is a wall of noise is one nobody opens.
	console.config.mirror_from = DotLog.Level.INFO
	add_child(console)

	var res := console.setup()
	if not res.ok:
		return res.wrap("the lobby's console")

	console.add_source(_local_commands())

	# And dot-server's console, when there is one in this process -- a listen server, or
	# `examples/dedicated.tscn`. Duck-typed through DotConsoleBridge, so this file names
	# no dot-server type and the client still works with no server at all.
	var server: Object = DotRegistry.get_service(&"dot_server")
	if server != null and server.get("console") != null:
		console.add_source(DotConsoleBridge.wrap(server.get("console"), "server"))

	_layer = CanvasLayer.new()
	_layer.name = "ConsoleLayer"
	# Above everything. The console is the thing you open when the interface is wrong, so
	# it must not be underneath it.
	_layer.layer = 128
	add_child(_layer)

	console_panel = DotConsolePanel.new()
	console_panel.name = "ConsolePanel"
	console_panel.controller = console
	_layer.add_child(console_panel)

	console.print_line("game-simple-lobby. `help` lists what this client can do.")
	return DotResult.success(null)


func _local_commands() -> DotConsoleLocal:
	var local := DotConsoleLocal.new()

	local.add_command(&"help", "List what this client can do", func(_a: PackedStringArray) -> Variant:
		var lines := PackedStringArray(["Client commands:"])
		for n in console.all_names():
			var help := console.help_for(n)
			lines.append("  %-18s %s" % [n, help])
		return lines
	)

	local.add_command(&"quit", "Leave the room", func(_a: PackedStringArray) -> Variant:
		# Local, and first in the source order, so it quits the client rather than the
		# dedicated server bridged in below it. An unprefixed remote console has shut
		# down more than one server with a `quit` somebody meant for their own client.
		get_tree().quit()
		return null
	)

	local.add_command(&"settings", "Show every setting", func(_a: PackedStringArray) -> Variant:
		return settings.describe_lines()
	)

	local.add_command(&"audio", "Show the audio system", func(_a: PackedStringArray) -> Variant:
		return audio.describe_lines()
	)

	local.add_command(&"fx", "Show the effects system", func(_a: PackedStringArray) -> Variant:
		return fx.describe_lines()
	)

	local.add_command(&"clear", "Empty the scrollback", func(_a: PackedStringArray) -> Variant:
		console.buffer.clear()
		return null
	)

	# Every declared setting becomes a variable, by reflection over the schema.
	#
	# [b]This is the reason a schema is the only list.[/b] A setting added to `schema()`
	# appears in the console, in a generated settings screen and in the saved document at
	# once, with nobody editing three files -- which is the tree's most repeated bug
	# ("two copies of one list") not happening.
	for key in settings.schema.keys():
		var def := settings.schema.find(key)
		local.bind_setting(key, settings, def.description if def != null else "")

	return local


# --- What the game asks for -------------------------------------------------

## Called once a frame by the client, with the camera's position.
func present(delta: float, listener: Vector2) -> void:
	audio.listener_position = Vector3(listener.x, 0.0, listener.y)
	fx.viewer_position = Vector3(listener.x, 0.0, listener.y)
	fx.advance(delta)


## Whether the console currently wants the keyboard.
##
## [b]The line every game with a console forgets.[/b] Without it, opening the console and
## typing turns into movement and chat: this game reads letters for its own shortcuts, so
## typing "say hello" would cycle the channel and start typing at the same time.
func swallows_input() -> bool:
	return console_panel != null and console_panel.has_keyboard_focus()


func on_message(channel_id: StringName, mentions_me: bool) -> void:
	if channel_id == RoomServices.CHANNEL_WHISPER or mentions_me:
		audio.play(&"chat_whisper")
		fx.flash(&"mentioned")
		return
	audio.play(&"chat_message")


func on_join(_occupant_id: int) -> void:
	audio.play(&"join")


func on_leave(_occupant_id: int) -> void:
	audio.play(&"leave")


func on_prop_placed(at: Vector2) -> void:
	audio.play_at_2d(&"prop_placed", at)
	fx.spawn_2d(&"prop_placed", at)


## A beacon's ripple went out from [param at]: `RoomRenderer.beacon_pulsed`, on every
## client, for every beaconed person — the beaconed one included, who hears their own.
## Returns the voice, or 0 when nothing played.
func on_beacon(at: Vector2) -> int:
	if audio == null:
		return 0

	return audio.play_at_2d(BEACON_SOUND, at)


## A server asked to cap something. Applied through the player's own policy.
func on_server_clamps(request: Dictionary) -> PackedStringArray:
	return settings.apply_server_clamps(request)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("the lobby's presentation layer")
	out.append_array(settings.describe_lines())
	out.append_array(audio.describe_lines())
	out.append_array(fx.describe_lines())
	out.append_array(console.describe_lines())
	return out
