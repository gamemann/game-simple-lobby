extends Node

const RoomMenus := preload("../game/client/room_menus.gd")
const RoomParty := preload("../game/room_party.gd")
const RoomPresentation := preload("../game/client/room_presentation.gd")
const RoomRenderer := preload("../game/client/room_renderer.gd")
const RoomServices := preload("../game/room_services.gd")
const RoomUi := preload("../game/client/room_ui.gd")
const RoomWorld := preload("../game/room_world.gd")

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

const RoomVoice := preload("../game/client/room_voice.gd")

const CHECKS := 105

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
	await _test_party()
	await _test_party_over_http()
	_test_chat_key()
	await _test_escape_menu()

	_test_every_sound_has_a_voice()
	await _test_blind_and_beacon()

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
	# There used to be exactly one, `near_range`, and it was read by nothing: how far a voice
	# carries is the server's radius (RoomServices.NEAR_RANGE), which decides who hears, so
	# a player's value could never have mattered. Nothing here is a server's to cap now, and
	# a setting that turns up in this scope should come with something that reads it.
	_check(
		s.keys_in_scope(DotSettingsDef.Scope.SERVER_CLAMPED).is_empty()
			and not s.has(&"near_range"),
		"and none a server may cap, because the server's own radius decides who hears"
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

	# Voice: a real RoomVoice, listening only (no microphone in a headless run), bound the
	# way the client binds it. `push_to_talk` was on the settings screen and read by nothing.
	p.settings.set_value(&"voice_nearby", true)
	var voice := RoomVoice.new()
	add_child(voice)
	var _listening := voice.setup(false)
	p.bind_voice(voice)
	_check(
		voice.is_nearby(),
		"a voice_nearby saved before the voice existed reaches it when it is bound"
	)
	p.settings.set_value(&"voice_nearby", false)
	_check(not voice.is_nearby(), "and turning it off sends to the whole room again")
	p.settings.set_value(&"push_to_talk", false)
	_check(
		voice.manager != null and not voice.manager.config.push_to_talk
			and (voice.manager.gate == null or not voice.manager.gate.push_to_talk),
		"and push to talk off reaches the voice gate"
	)
	voice.queue_free()

	# A server may cap nothing here: not the volume, and not a near_range that is gone.
	var applied := p.on_server_clamps({"near_range": 200.0, "master_volume": 0.1})
	_check(applied.is_empty(), "a server caps nothing, because nothing is its to cap")
	_check(
		is_equal_approx(p.settings.get_float(&"master_volume"), 0.25),
		"and the volume it asked for is untouched"
	)

	# A save from before near_range was removed still loads, and keeps the key: the
	# manager treats it as a setting this build does not declare and writes it back.
	var old_save := DotSettingsStoreMemory.new()
	old_save.save_document(p.settings.app_namespace, p.settings.profile, {
		"version": 1, "values": {"master_volume": 0.4, "near_range": 300.0},
	})
	p.settings.local_store = old_save
	var loaded := p.settings.load_now()
	_check(
		loaded.ok and is_equal_approx(p.settings.get_float(&"master_volume"), 0.4)
			and p.settings.to_document().get("near_range") == 300.0,
		"an old save carrying near_range loads, and keeps it for the build that knew it"
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

	# [b]Drawn, not only decided.[/b] Until 2026-09-27 the ripple's scene did not exist,
	# dot-fx refused it at DEBUG, and every check above passed: a tint needs no scene.
	var missing := RoomPresentation.fx_catalogue().missing_scenes()
	_check(
		missing.is_empty(),
		"every scene the effect catalogue names is present (missing: %s)" % ", ".join(missing)
	)
	var drawn := {}
	p.fx.spawned.connect(func(id: StringName, node: Node, why: StringName) -> void:
		drawn[id] = node if node != null else why
	)
	p.on_prop_placed(Vector2(-140, 60))
	var ripple: Variant = drawn.get(&"prop_placed")
	_check(
		ripple is Node2D and (ripple as Node2D).global_position.is_equal_approx(Vector2(-140, 60)),
		"putting something down draws a ripple where it went (%s)" % str(ripple)
	)
	_check(
		ripple is Node and not (ripple as Node).find_children("*", "CPUParticles2D").is_empty(),
		"and it is particles, not an empty node"
	)
	# The client builds this layer before the renderer, so at an equal z the floor is
	# drawn over the ripple.
	_check(
		ripple is CanvasItem and (ripple as CanvasItem).z_index > 0,
		"over the room, which is drawn after it at z 0"
	)

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
		var refused: DotResult = await host.host("Ada")
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


# --- 6b ---------------------------------------------------------------------

## A stand-in rendezvous: the four routes `DotP2PSignallerHttp` speaks, on a real socket,
## answering each request [member delay] frames after it arrives.
##
## [b]The delay is the point.[/b] `_test_party` uses the loopback signaller, which answers
## inside the call, and a coroutine that never suspends is indistinguishable from a
## function, so a caller that forgot `await` passes against it. A rendezvous that answers
## frames later is the shape the real one has. Ported from game-playground d4ff040, on its
## own port range (39000-39060) so the two suites can run at the same time.
class RendezvousStub:
	extends Node

	var port := 0
	var delay := 4
	## An HTTP status to answer everything with instead of 200, to see a refusal arrive.
	var refuse := 0
	## What arrived, in order: `{route, body}`.
	var seen: Array[Dictionary] = []
	## The ids that announced themselves, so a join answers with who is here.
	var present: Array[String] = []

	var _server := TCPServer.new()
	var _open: Array[Dictionary] = []

	func start() -> bool:
		for candidate in range(39000, 39060):
			if _server.listen(candidate, "127.0.0.1") == OK:
				port = candidate
				return true
		return false

	func _exit_tree() -> void:
		_server.stop()

	func _process(_delta: float) -> void:
		while _server.is_connection_available():
			_open.append({"peer": _server.take_connection(), "bytes": PackedByteArray(), "wait": -1})

		for c in _open.duplicate():
			var peer: StreamPeerTCP = c["peer"]
			peer.poll()
			var available := peer.get_available_bytes()
			if available > 0:
				var got := peer.get_data(available)
				if int(got[0]) == OK:
					# Written back: a packed array is a value, so appending to the one read
					# out of the dictionary appends to a copy and the bytes are lost.
					var buffer: PackedByteArray = c["bytes"]
					buffer.append_array(got[1] as PackedByteArray)
					c["bytes"] = buffer

			if int(c["wait"]) < 0:
				var text := (c["bytes"] as PackedByteArray).get_string_from_utf8()
				var split := text.find("\r\n\r\n")
				if split < 0:
					continue
				var length := 0
				for line in text.substr(0, split).split("\r\n"):
					if line.to_lower().begins_with("content-length:"):
						length = line.get_slice(":", 1).strip_edges().to_int()
				if (c["bytes"] as PackedByteArray).size() < split + 4 + length:
					continue
				var first := text.get_slice("\r\n", 0)
				var target := first.get_slice(" ", 1)
				var route := target.get_slice("?", 0).get_file()
				var body: Variant = JSON.parse_string(text.substr(split + 4)) if length > 0 else {}
				c["route"] = route
				c["body"] = body if body is Dictionary else {}
				seen.append({"route": route, "body": c["body"]})
				c["wait"] = delay
				continue

			if int(c["wait"]) > 0:
				c["wait"] = int(c["wait"]) - 1
				continue

			var answer := _answer(str(c["route"]), c["body"] as Dictionary)
			var status := "200 OK" if refuse == 0 else "%d Refused" % refuse
			var payload := JSON.stringify(answer).to_utf8_buffer()
			var head := "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status, payload.size()]
			peer.put_data(head.to_utf8_buffer())
			peer.put_data(payload)
			peer.disconnect_from_host()
			_open.erase(c)

	func _answer(route: String, body: Dictionary) -> Dictionary:
		match route:
			"host":
				present.append(str(body.get("id", "")))
				return {}
			"join":
				var here := present.duplicate()
				present.append(str(body.get("id", "")))
				return {"peers": here}
			"poll":
				return {"messages": [], "cursor": 0}
		return {}


## `[p2p-await-games]`: a party over the HTTP rendezvous, host and join, each awaited end
## to end — through `RoomParty`, `DotP2PSession` and `DotP2PSignallerHttp` to a socket and
## back.
##
## [b]What "awaited" is asserted as.[/b] The answer the caller gets back is the one the
## stub sent, and it arrives at least [member RendezvousStub.delay] frames after the call:
## a link that dropped its `await` hands its caller null or returns before the stub has
## answered, and either fails here.
##
## [b]Trust and migration.[/b] Every playground assertion applies here unchanged: none of
## them is about who may decide, only about who is there and who hosts. The lobby's
## `migrate_host` does touch "the joiner does not elect itself", since `_settle_host` runs
## the same election migration uses — so that check is the one that would catch a joiner
## that saw nobody and elected itself because the answer had not arrived yet.
## `RoomParty` has no `active()` (playground's `PlaygroundParty` does), so "open" is read
## as the session's state not being idle.
func _test_party_over_http() -> void:
	_section("A party that meets over HTTP waits for the answer")

	var stub := RendezvousStub.new()
	stub.name = "Rendezvous"
	add_child(stub)
	var listening := stub.start()
	_check(listening, "a stand-in rendezvous listens on a local port", str(stub.port))

	if not listening:
		stub.queue_free()
		_done()
		return

	var url := "http://127.0.0.1:%d/p2p" % stub.port
	var ada := RoomParty.new()
	ada.name = "PartyAda"
	ada.signalling_url = url
	add_child(ada)
	var bob := RoomParty.new()
	bob.name = "PartyBob"
	bob.signalling_url = url
	add_child(bob)

	_check(
		ada.setup().ok and bob.setup().ok
			and ada.session.signaller is DotP2PSignallerHttp
			and bob.session.signaller is DotP2PSignallerHttp,
		"two parties set up with a URL, and both meet over HTTP rather than the loopback"
	)

	var opened: Array[String] = []
	ada.open.connect(func(c: String) -> void: opened.append(c))

	var before := Engine.get_process_frames()
	var hosted: DotResult = await ada.host("Ada")
	var took := Engine.get_process_frames() - before
	var code := str(hosted.value) if hosted != null and hosted.ok else ""

	_check(
		hosted != null and hosted.ok and DotP2PLobby.is_code_shaped(code, ada.session.config.code_length),
		"host() hands back a join code",
		str(hosted.error.message) if hosted != null and not hosted.ok else "null"
	)
	_check(took >= stub.delay,
		"only once the rendezvous has answered: %d frames, the stub waits %d" % [took, stub.delay])
	_check(
		stub.seen.size() >= 1 and stub.seen[0]["route"] == "host"
			and str((stub.seen[0]["body"] as Dictionary).get("code", "")) == code
			and str(((stub.seen[0]["body"] as Dictionary).get("info", {}) as Dictionary).get("name", "")) == "Ada",
		"and it is the code the rendezvous was told, under the host's name",
		str(stub.seen)
	)
	_check(ada.session.state() != &"idle" and ada.is_host() and opened == [code],
		"the room is open, hosted, and says so once",
		"state %s, opened %s" % [ada.session.state(), str(opened)])

	before = Engine.get_process_frames()
	var joined: DotResult = await bob.join(code.to_lower(), "Bob")
	took = Engine.get_process_frames() - before

	_check(joined != null and joined.ok and took >= stub.delay,
		"join() waits for the rendezvous too (%d frames) and succeeds" % took,
		str(joined.error.message) if joined != null and not joined.ok else "null")
	_check(
		stub.seen.size() >= 2 and stub.seen[1]["route"] == "join"
			and str((stub.seen[1]["body"] as Dictionary).get("code", "")) == code,
		"under the code as the host has it, not as it was typed",
		str(stub.seen)
	)
	_check(
		bob.session.lobby.has(ada.session.local_id) and not bob.is_host(),
		"and the joiner learns who is already there from the answer, and does not elect itself",
		str(bob.members())
	)

	# A refusal arrives as a failure the caller can read, not as null and not as success.
	bob.leave()
	var carol := RoomParty.new()
	carol.name = "PartyCarol"
	carol.signalling_url = url
	add_child(carol)
	var _set := carol.setup()
	stub.refuse = 403
	var refused: DotResult = await carol.host("Carol")
	_check(refused != null and not refused.ok and carol.session.state() == &"idle",
		"and a rendezvous that refuses leaves the party closed with a reason",
		"null" if refused == null else ("ok" if refused.ok else refused.error.message))

	ada.leave()
	for node: Node in [ada, bob, carol, stub]:
		node.queue_free()
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

	# [b]dot-ui's screen, not a copy of it.[/b] This game carried its own forty lines of
	# pause menu for as long as `DotPauseScreen` has existed -- the settings screen was
	# moved when that addon grew one and the pause screen was not, so the file that says
	# four clients stopped writing these was wrong about three of them.
	_check(pause is DotPauseScreen, "the pause screen is the shared one")
	# Ids derived from labels rather than paired with them, which is what stops the two
	# lists disagreeing. The client matches on LEAVE and nothing restates the string.
	_check(
		pause.ids() == ([&"resume", &"settings", RoomMenus.LEAVE] as Array[StringName]),
		"and its ids come from its labels (%s)" % [pause.ids()]
	)
	_check(
		pause.button(RoomMenus.LEAVE) != null and not pause.button(RoomMenus.LEAVE).disabled,
		"Leave is there and live"
	)

	var chosen: Array[StringName] = []
	pause.chosen.connect(func(id: StringName) -> void: chosen.append(id))
	pause.button(RoomMenus.LEAVE).pressed.emit()
	_check(
		chosen == ([RoomMenus.LEAVE] as Array[StringName]),
		"and pressing it says which button it was, rather than a signal per button"
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


func _test_every_sound_has_a_voice() -> void:
	# This game shipped a complete catalogue pointing at files nobody has produced, and
	# was therefore silent while every check about its audio passed. The two directions
	# below are the ones that go wrong without erroring: an id with no recipe is one sound
	# that stays silent for ever, and a recipe naming an id the catalogue does not have is
	# a decision that reaches nothing. Neither is visible from any assertion about the
	# catalogue on its own -- and a headless run cannot hear the result, so this is as
	# close as an assertion gets. game-arena/tools/audio_probe.sh is the other half.
	_section("Every sound this game declares has a noise to make")

	var cat := RoomPresentation.sound_catalogue()
	var recipes := RoomPresentation.sound_recipes()

	var uncovered: Array[String] = []
	for id in cat.ids():
		if not recipes.has(id):
			uncovered.append(String(id))
	_check(
		uncovered.is_empty(),
		"every id in the catalogue has a stand-in voice",
		"silent for ever: %s" % str(uncovered)
	)

	var stray: Array[String] = []
	for id in recipes.keys():
		if cat.find(StringName(id)) == null:
			stray.append(String(id))
	_check(stray.is_empty(), "and no recipe names an id that is not there", str(stray))

	var bank := DotAudioSynth.bank(cat, recipes)
	_check(
		bank.has(&"chat_message") and bank.has("res://audio/message.ogg"),
		"the bank answers under both the id and the path the def names"
	)
	_check(
		(
			(bank[&"chat_message"] as AudioStreamWAV).data
			!= (bank[&"chat_whisper"] as AudioStreamWAV).data
		),
		"and chat_message does not sound like chat_whisper",
		"a line addressed to you arriving in the same blip as the room's traffic is a line you will miss"
	)

	_done()


## An administrator's blind and beacon, as the client draws them.
##
## Who is TOLD is `headless_net`'s — the owner alone for a blind, everybody for a beacon —
## and whether the server sets them is `dedicated`'s. This is what a client does with the
## two flags once it has them: the ping happens once a period rather than once a frame, the
## ring goes when the flag or the person does, and the blind covers the viewport while
## staying under the chat. What it LOOKS like is `tools/screenshot.sh --admin`'s.
func _test_blind_and_beacon() -> void:
	_section("An admin's blind and beacon, drawn")

	var world := RoomWorld.new()
	world.name = "BeaconWorld"
	world.is_authority = true
	world.register_service = false
	world.service_scope = &"beacon"
	add_child(world)
	world.setup()
	var _a := world.add_occupant(701, "Ada")
	var _b := world.add_occupant(702, "Bo")
	var ada := world.occupant_for(701)

	var p := RoomPresentation.new()
	p.name = "BeaconP"
	add_child(p)
	p.setup()
	var sink := p.audio.sink as DotAudioSinkNull
	p.audio.listener_position = Vector3.ZERO

	var renderer := RoomRenderer.new()
	renderer.name = "BeaconRenderer"
	# Stepped by hand below. Its own `_process` would advance the ripple on every frame
	# this section awaits, and a count of pings would then depend on the frame rate.
	renderer.set_process(false)
	renderer.world = world
	add_child(renderer)
	var pings: Array[Vector2] = []
	renderer.beacon_pulsed.connect(func(at: Vector2) -> void:
		pings.append(at)
		var _voice := p.on_beacon(at)
	)

	_check(
		renderer.advance_beacons(0.1) == 0 and renderer.beaconed().is_empty(),
		"nobody beaconed, nothing drawn and nothing heard"
	)

	ada.beacon = true
	_check(
		renderer.advance_beacons(0.0) == 1,
		"a beacon pings the frame it is first seen, not a period later"
	)
	_check(
		pings.size() == 1 and pings[0].is_equal_approx(ada.position()),
		"from where the beaconed person is", str(pings)
	)

	# Sixty frames of a second: one ping, not sixty. A ping per frame is the easy bug and
	# a fire alarm in a room somebody sits in for twenty minutes.
	var per_second := 0
	for _frame in range(60):
		per_second += renderer.advance_beacons(1.0 / 60.0)
	_check(per_second == 1, "and then once a second, not once a frame (%d)" % per_second)
	_check(
		renderer.beaconed() == ([701] as Array[int]),
		"on Ada alone", str(renderer.beaconed())
	)

	sink.forget()
	var _far := renderer.advance_beacons(RoomRenderer.BEACON_PERIOD_SEC)
	_check(
		sink.count_of(RoomPresentation.BEACON_SOUND) == 1,
		"each ripple is a ping the audio layer plays"
	)
	var def := RoomPresentation.sound_catalogue().find(RoomPresentation.BEACON_SOUND)
	_check(
		def != null and def.kind == DotAudioDef.Kind.POSITIONAL_2D
			and def.max_distance > world.arena.bounds.size.length(),
		"positional, and heard from anywhere in the room",
		"a ping that cut out across the room fails in the one place a beacon is for"
	)

	ada.beacon = false
	var _off := renderer.advance_beacons(0.1)
	_check(renderer.beaconed().is_empty(), "the ring goes the frame the flag does")

	ada.beacon = true
	var _on := renderer.advance_beacons(0.0)
	var _gone := world.remove_occupant(701)
	var _after := renderer.advance_beacons(0.1)
	_check(renderer.beaconed().is_empty(), "and the frame the person leaves")

	# --- the blind ---
	var ui := RoomUi.new()
	ui.name = "BlindUi"
	add_child(ui)
	await get_tree().process_frame

	_check(
		ui.blind_overlay != null and ui.get_child(0) == ui.blind_overlay,
		"the blind is the interface's first child, so the chat and the roster draw over it"
	)
	_check(
		ui.blind_overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"and lets the mouse through, so a blinded person can still click into the chat"
	)

	ui.present_blind(RoomUi.BLIND_FADE_SEC * 0.5, true)
	var halfway := ui.blind_overlay.modulate.a
	ui.present_blind(RoomUi.BLIND_FADE_SEC, true)
	_check(
		halfway > 0.0 and halfway < 1.0 and is_equal_approx(ui.blind_overlay.modulate.a, 1.0),
		"a blind fades in rather than cutting (%.2f halfway)" % halfway
	)
	# The whole viewport, measured in the viewport's own coordinates. A headless viewport
	# is 64 x 64 (docs/testing.md), which is still a size this can be equal to or not.
	var covered := ui.blind_overlay.get_global_rect()
	var viewport := get_viewport().get_visible_rect()
	_check(
		covered.position.is_equal_approx(viewport.position)
			and covered.size.is_equal_approx(viewport.size),
		"and covers the whole viewport", "%s against %s" % [covered, viewport]
	)

	ui.present_blind(1.0, false)
	_check(
		not ui.blind_overlay.visible,
		"and lifting it hides the overlay rather than leaving a transparent rect on top"
	)

	ui.queue_free()
	renderer.queue_free()
	p.queue_free()
	world.queue_free()
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
