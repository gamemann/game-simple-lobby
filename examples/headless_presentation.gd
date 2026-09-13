extends Node

const RoomMenus := preload("res://game/client/room_menus.gd")
const RoomParty := preload("res://game/room_party.gd")
const RoomPresentation := preload("res://game/client/room_presentation.gd")
const RoomServices := preload("res://game/room_services.gd")
const RoomUi := preload("res://game/client/room_ui.gd")

## The client half that has nothing to do with the room: settings, audio, effects, the
## console, and hosting for friends.
##
## [codeblock]
## godot --headless --path . res://examples/headless_presentation.tscn
## [/codeblock]
##
## [b]None of this is reachable from `headless_room`[/b], which is [RoomWorld] alone and
## deliberately has no client in it — and this family's own repeated lesson is that a code
## path only one deployment shape reaches is a code path nothing has run. game-arena
## shipped a module that nobody could ever join because its only suite never connected a
## client; this is the shape that catches that.
##
## Exits non-zero on any failure.

const CHECKS := 66

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("game-simple-lobby: the presentation layer")

	_test_schema()
	_test_settings_reach_the_mixer()
	_test_sounds_are_bounded()
	_test_effects_respect_the_player()
	_test_console()
	_test_party()
	_test_chat_key()
	await _test_escape_menu()

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for f in _failures:
		print("  %s" % f)
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


# --- 1 ----------------------------------------------------------------------

func _test_schema() -> void:
	_section("The schema is the only list")

	var s := RoomPresentation.schema()
	_check(s.validate().ok, "the lobby's settings schema validates")
	_check(s.keys().size() >= 6, "and declares what a lobby lets a player change")
	_check(
		s.keys_in_scope(DotSettingsDef.Scope.ACCOUNT).size() >= 2,
		"with the ones about the person scoped to follow them between games"
	)
	_check(
		s.keys_in_scope(DotSettingsDef.Scope.SERVER_CLAMPED).has(&"near_range"),
		"and exactly one a server may cap, which is the one about how far a voice carries"
	)
	_check(
		not s.keys_in_scope(DotSettingsDef.Scope.SERVER_CLAMPED).has(&"master_volume"),
		"a server may not touch the volume, because that is nobody else's business"
	)

	var audio := RoomPresentation.sound_catalogue()
	_check(audio.validate().ok, "the sound catalogue validates with no files present")
	var fx := RoomPresentation.fx_catalogue()
	_check(fx.validate().ok, "and so does the effect catalogue")
	_done()


# --- 2 ----------------------------------------------------------------------

func _test_settings_reach_the_mixer() -> void:
	_section("A setting that nothing reads is a setting that does not exist")

	var p := RoomPresentation.new()
	p.name = "P"
	add_child(p)
	var res := p.setup()
	_check(res.ok, "the presentation layer sets up")
	if not res.ok:
		_done()
		return

	# This family's most repeated bug is a value produced correctly and consumed by
	# nothing, and a settings document is the easiest place in any game to write one.
	p.settings.set_value(&"master_volume", 0.25)
	_check(
		is_equal_approx(p.audio.mixer.master, 0.25),
		"the volume reaches the mixer, rather than being stored and read by nobody"
	)
	p.settings.set_value(&"shake_scale", 0.0)
	_check(
		is_equal_approx(p.fx.config.shake_scale, 0.0),
		"and the shake scale reaches the effects config"
	)
	p.settings.set_value(&"allow_flashes", false)
	_check(not p.fx.config.allow_flashes, "and the flash switch does too")

	# A server may cap how far a voice carries, and may not have the volume.
	var applied := p.on_server_clamps({"near_range": 200.0, "master_volume": 0.1})
	_check(applied.size() == 1 and applied[0] == "near_range", "a server caps only what it may")
	_check(
		is_equal_approx(p.settings.get_float(&"master_volume"), 0.25),
		"and the volume it asked for is untouched"
	)
	p.settings.set_value(&"near_range", 120.0)
	_check(
		is_equal_approx(p.settings.get_float(&"near_range"), 120.0),
		"a player below the cap keeps their own value, because a clamp is a bound"
	)

	p.queue_free()
	_done()


# --- 3 ----------------------------------------------------------------------

func _test_sounds_are_bounded() -> void:
	_section("Twenty people typing is not twenty notifications")

	var p := RoomPresentation.new()
	p.name = "P2"
	add_child(p)
	p.setup()

	var sink := p.audio.sink as DotAudioSinkNull
	_check(sink != null, "a headless run gets the sink that cannot make a noise")
	if sink == null:
		p.queue_free()
		_done()
		return

	sink.forget()
	for _i in range(20):
		p.on_message(RoomServices.CHANNEL_ALL, false)
	_check(
		sink.count_of(&"chat_message") == 1,
		"twenty messages in one tick make one sound, not twenty (%d)"
		% sink.count_of(&"chat_message")
	)

	sink.forget()
	p.on_message(RoomServices.CHANNEL_WHISPER, false)
	_check(sink.count_of(&"chat_whisper") == 1, "a whisper is its own sound")
	sink.forget()
	p.on_message(RoomServices.CHANNEL_ALL, true)
	_check(
		sink.count_of(&"chat_whisper") == 0,
		"and a mention immediately afterwards is silent, because the attention sound has "
		+ "a cooldown and two of it a millisecond apart is one noise anyway"
	)

	# The mention takes the whisper's path, which the cooldown above hides -- so it is
	# checked on a manager that has not just played one. A check that passes only because
	# something else was refused is a check that would pass with the path deleted.
	var fresh := RoomPresentation.new()
	fresh.name = "P2b"
	add_child(fresh)
	fresh.setup()
	var fresh_sink := fresh.audio.sink as DotAudioSinkNull
	fresh.on_message(RoomServices.CHANNEL_ALL, true)
	_check(
		fresh_sink.count_of(&"chat_whisper") == 1,
		"a line with your name in it uses the whisper sound, because both are addressed to you"
	)
	fresh.queue_free()

	sink.forget()
	p.audio.listener_position = Vector3.ZERO
	p.on_prop_placed(Vector2(10, 10))
	_check(sink.count_of(&"prop_placed") == 1, "something put down nearby is heard")
	sink.forget()
	p.on_prop_placed(Vector2(9000, 9000))
	_check(
		sink.count_of(&"prop_placed") == 0,
		"and one across the room is culled before it costs a voice"
	)

	p.queue_free()
	_done()


# --- 4 ----------------------------------------------------------------------

func _test_effects_respect_the_player() -> void:
	_section("A flash a player asked not to see is not drawn")

	var p := RoomPresentation.new()
	p.name = "P3"
	add_child(p)
	p.setup()

	p.fx.flash_colour.a = 0.0
	p.on_message(RoomServices.CHANNEL_WHISPER, false)
	_check(p.fx.flash_colour.a > 0.0, "a whisper tints the screen")
	_check(
		p.fx.flash_colour.a <= 0.2,
		"gently -- a notification is exactly the effect somebody sets to full strength "
		+ "because it is 'only a tint'"
	)

	p.settings.set_value(&"allow_flashes", false)
	p.fx.flash_colour.a = 0.0
	p.on_message(RoomServices.CHANNEL_WHISPER, false)
	_check(
		is_equal_approx(p.fx.flash_colour.a, 0.0),
		"and a player who has asked for no flashes gets none at all"
	)

	p.settings.set_value(&"allow_flashes", true)
	p.fx.flash_colour.a = 0.0
	var applied := 0
	for _i in range(10):
		if p.fx.flash(&"mentioned"):
			applied += 1
	_check(
		applied <= 3,
		"and the rate limit holds at the published three a second (%d of 10)" % applied
	)

	p.present(0.016, Vector2.ZERO)
	_check(p.fx.live_count() >= 0, "a frame advances without a renderer")

	p.queue_free()
	_done()


# --- 5 ----------------------------------------------------------------------

func _test_console() -> void:
	_section("The console, and the settings it reaches")

	var p := RoomPresentation.new()
	p.name = "P4"
	add_child(p)
	p.setup()

	_check(p.console != null, "there is a console")
	_check(p.console_panel != null, "and a panel drawing it")
	_check(
		p.console.all_names().has("settings"),
		"with the client's own commands in it"
	)

	# Every declared setting is a console variable, by reflection over the schema. A
	# setting added to schema() appears here, in a generated settings screen and in the
	# saved document at once -- which is "two copies of one list" not happening.
	for key in RoomPresentation.schema().keys():
		if not p.console.all_names().has(String(key)):
			_check(false, "the setting '%s' is missing from the console" % key)
			break
	_check(
		p.console.all_names().has("master_volume"),
		"and every setting is reachable from a keyboard, by reflection rather than by a list"
	)

	p.console.submit("master_volume 0.4")
	_check(
		is_equal_approx(p.settings.get_float(&"master_volume"), 0.4),
		"setting one from the console writes the document, not a second copy of the value"
	)
	_check(
		is_equal_approx(p.audio.mixer.master, 0.4),
		"and still reaches the mixer, because there is one path"
	)

	p.console.submit("rcon_password hunter2")
	_check(
		not p.console.buffer.to_text().contains("hunter2"),
		"a credential typed into the console never reaches the scrollback"
	)
	_check(
		not "\n".join(Array(p.console.buffer.history())).contains("hunter2"),
		"nor the history, where the next Up arrow would put it back on screen"
	)

	var unknown := p.console.submit("mastervolume 1")
	_check(not unknown.ok, "an unknown command is refused")
	_check(
		unknown.error.detail.contains("master_volume"),
		"with a suggestion, because a typo is the commonest thing that happens in a console"
	)

	p.queue_free()
	_done()


# --- 6 ----------------------------------------------------------------------

func _test_party() -> void:
	_section("Hosting for friends, which is the one game this suits")

	DotP2PSignallerLoopback.reset_all()

	var host := RoomParty.new()
	host.name = "HostParty"
	add_child(host)
	_check(host.setup().ok, "a party sets up")
	_check(
		host.session.config.trust == DotP2PConfig.Trust.HOST_AUTHORITATIVE,
		"host-authoritative, because a lobby has no score, no records and nothing to cheat for"
	)
	_check(host.session.config.migrate_host, "and it migrates, because a host leaving is somebody's evening")
	_check(host.session.config.max_peers == 8, "sized for what this room and a domestic uplink hold")

	if not DotP2PSession.available():
		# The honest half on a machine with no WebRTC extension, which is this one.
		var refused := host.host("Ada")
		_check(not refused.ok, "a build with no WebRTC refuses to host")
		_check(
			refused.error.detail != "",
			"naming which of the two reasons it is, because they have different answers"
		)

	# The lobby half works regardless, which is the point of the split: everything that
	# actually goes wrong with peer-to-peer is here and none of it involves a socket.
	host.session.lobby.add_member(&"ada", "Ada", 100)
	host.session.lobby.host_id = &"ada"
	host.session.lobby.add_member(&"bob", "Bob", 200)
	_check(host.members().size() == 2, "two people are in the party")
	_check(host.is_host() == false, "and this peer is not the one hosting")

	var elected := host.session.lobby.migrate_from(&"ada")
	_check(elected == &"bob", "a host leaving hands over to the elected successor")
	_check(
		host.session.lobby.elect_host() == &"bob",
		"which every peer computes for itself, with no round of messages"
	)

	host.queue_free()
	_done()


# --- Harness ---------------------------------------------------------------

func _test_escape_menu() -> void:
	_section("Escape opens a menu, which this game did not have at all")

	var p := RoomPresentation.new()
	p.name = "MenuP"
	add_child(p)
	if not _check(p.setup().ok, "a presentation layer to read the settings from"):
		_done()
		return

	var stack := DotScreenStack.new()
	stack.name = "Stack"
	stack.register_service = false
	stack.manage_mouse = false
	add_child(stack)
	stack.setup()

	var pause := RoomMenus.install(stack, p.settings)
	await get_tree().process_frame

	_check(stack.screen(&"pause") != null, "the pause screen registers")
	_check(stack.screen(&"settings") != null, "and the settings screen beside it")

	# The one thing an assertion can reach about a Control, and this family has shipped a
	# 0 x 0 one twice: `set_anchors_preset` does not set offsets, so a Control built in
	# code keeps the zero size it was created with -- laying out inside nothing while
	# being, by every property, correctly configured.
	stack.push(&"pause")
	await get_tree().process_frame
	await get_tree().process_frame
	_check(pause.size.x > 0.0 and pause.size.y > 0.0, "an open screen has a size")
	var panel := pause.get_node_or_null("Panel") as Control
	_check(
		panel != null and panel.size.x > 0.0 and panel.size.y > 0.0,
		"and so does the panel inside it"
	)
	_check(
		pause.initial_focus != NodePath(),
		"with something focused, or the menu cannot be used with a gamepad at all"
	)
	_check(
		pause.get_node_or_null(pause.initial_focus) != null,
		"and the focus path resolves, which `button.get_path()` before the tree does not"
	)

	# Settings replaces nothing: a player who opens it and presses Back is back at the
	# pause menu, not in the game.
	stack.push(&"settings")
	await get_tree().process_frame
	_check(stack.top_id() == &"settings", "settings opens over the pause menu")
	stack.pop()
	_check(stack.top_id() == &"pause", "and closing it comes back to the pause menu")

	# THE CHECK THIS SECTION EXISTS FOR.
	#
	# `to_config()` hands out a snapshot and `absorb_config()` is the way back, and until
	# this screen the round trip had no caller anywhere in the family. A panel bound to a
	# snapshot whose second half nobody calls is an Apply button that reports success and
	# changes nothing -- and every check above passes exactly as happily either way.
	var screen := stack.screen(&"settings") as DotSettingsScreen
	p.settings.set_value(&"master_volume", 0.9)
	stack.push(&"settings")
	await get_tree().process_frame

	var editor := screen.panel.editor_for("master_volume")
	if _check(editor != null, "the panel built an editor for a real setting"):
		screen.panel._edited("master_volume", 0.2)
		screen.apply()
		_check(
			is_equal_approx(p.settings.get_float(&"master_volume"), 0.2),
			"Apply reaches the settings manager, not just the snapshot it was bound to"
		)
		_check(
			is_equal_approx(p.audio.mixer.master, 0.2),
			"and carries on to the mixer, which is what a player actually hears"
		)

	stack.clear()
	stack.queue_free()
	p.queue_free()
	_done()


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("   ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
	return condition


func _test_chat_key() -> void:
	_section("The key that opens a chat room's own chat")

	var s := RoomPresentation.schema()
	var def := s.find(&"chat_open_key")

	_check(def != null, "the open key is a declared setting")

	if def == null:
		_done()
		return

	_check(def.kind == DotSettingsDef.Kind.BINDING, "declared as a binding, not as text")
	_check(str(def.default_value) == "Y", "defaulting to Y, like every other game here")
	_check(
		def.scope == DotSettingsDef.Scope.ACCOUNT,
		"and following the person between games rather than sitting on one machine"
	)

	# [b]No on/off switch, and this is the one game where that is right.[/b] Everywhere
	# else the box is drawn over a game and "I chat somewhere else" is a sensible thing for
	# a player to say; here the log, the roster and the entry ARE the game.
	_check(
		s.find(&"chat_window") == null,
		"and there is no setting that turns a lobby's chat off",
		"a lobby with its chat hidden is a person standing in an empty room"
	)

	# The action the entry actually listens on, and what a rebind does to it.
	DotInputBinding.ensure_action(RoomUi.OPEN_CHAT_ACTION, "Y")
	_check(
		DotInputBinding.describe_action(RoomUi.OPEN_CHAT_ACTION) == "Y",
		"the action exists at the default binding"
	)

	var p := RoomPresentation.new()
	p.name = "PChat"
	add_child(p)
	p.setup()
	# A memory store: a suite that writes to `user://` is a suite whose result depends on
	# what the last run left there.
	p.settings.local_store = DotSettingsStoreMemory.new()
	p.settings.load_now()

	p.settings.set_value(&"chat_open_key", "T")
	_check(
		DotInputBinding.describe_action(RoomUi.OPEN_CHAT_ACTION) == "T",
		"rebinding through the settings document moves it"
	)
	_check(
		InputMap.action_get_events(RoomUi.OPEN_CHAT_ACTION).size() == 1,
		"and leaves ONE binding, not the old one as well"
	)

	p.settings.set_value(&"chat_open_key", "")
	_check(
		DotInputBinding.describe_action(RoomUi.OPEN_CHAT_ACTION) == "T",
		"an empty binding is ignored rather than leaving the room with no way in"
	)

	InputMap.erase_action(RoomUi.OPEN_CHAT_ACTION)
	_done()
