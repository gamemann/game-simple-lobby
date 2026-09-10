extends Node

## The launcher: connect to a server, or stand in an empty room offline.
##
## [codeblock]
## godot --path .                                   # the launcher
## godot --path . -- --offline                      # nobody else, no server
## godot --path . -- --connect 127.0.0.1:27085      # straight in
## godot --headless --path . -- --seconds 3         # exit on its own, for a sweep
## [/codeblock]
##
## [b]This is the standalone application, not the game.[/b] The game is
## `scenes/room_client.tscn`, and in the deployment this exists for a generic client shell
## downloads the pack and instantiates that scene itself — no launcher involved. What this
## is for is running the room on its own: to look at it, to develop it, and to be the main
## scene of a web export that has no shell in front of it.
##
## In a browser the server comes from the query string (`?server=wss://host:port`), because
## a tab cannot listen and a person who followed a link has already chosen which room they
## are joining.

const DEFAULT_PORT := 27085

var _link: DotClientLink = null
var _client: RoomClient = null
var _root: Node = null
var _status: Label = null
var _address_entry: LineEdit = null
var _name_entry: LineEdit = null
var _panel: Control = null

## The server list. Built on demand: a person who followed a link straight into a room
## never opens it, and a [DotBrowser] that exists is a [DotBrowser] sending UDP.
var _browser: RoomBrowser = null

## Who this person is, when there is a backbone to ask.
##
## [b]Signed in without a code on screen, or not at all.[/b] `sign_in()` tries the page
## handoff, then a stored session, and then falls through to a device-code login — two
## backbone requests for a flow with no code shown and nobody to read it. dot-server-setup-test
## shipped exactly that and it is what made a wrong default domain visible. So this asks
## for the quiet halves only, and a person who has never signed in stays a guest, which is
## what a lobby is for.
var _auth: DotAuthClient = null

## Content delivered at runtime, when a server names a pack.
##
## [b]Registered even when nothing is delivered.[/b] dot-cloud shipped a bug where
## [DotCloudClient] never published itself in [DotRegistry] and four call sites across
## dot-server and dot-user-avatar all found null — none of which errored, because every
## one treats an absent cloud as "this deployment ships its content in the build", which
## is a legitimate configuration and therefore indistinguishable from the bug.
var _cloud: DotCloudClient = null


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if _has_arg("--verbose") else DotLog.Level.INFO
	)

	_arm_exit_timer()

	_root = Node.new()
	_root.name = "Game"
	add_child(_root)

	# A bare statement call, not an await: this menu must be on screen whether or not a
	# content store answers, and nothing here needs the answer.
	_build_cloud()
	_build_menu()

	# Started before anything else so a stored session is already resolved by the time
	# somebody presses Join. Not awaited: a backbone that is slow or absent must not hold
	# up a menu, and the answer only changes what name a guest is given.
	_sign_in()

	if _has_arg("--offline"):
		_start_offline()
		return

	var address := _requested_address()

	if address != "":
		_connect_to(address)


## The content client, registered so anything that wants one can find it.
##
## A lobby that ships inside its own build never uses this; a lobby *delivered* as a pack
## is what this game exists to be, and in that deployment the shell mounts the pack before
## this scene exists at all. What this covers is the third case: a server that ships this
## room in the build and delivers something else — a map, a set of avatar parts — and
## needs somewhere to put it.
func _build_cloud() -> void:
	_cloud = DotCloudClient.new()
	_cloud.name = "Cloud"
	add_child(_cloud)

	var ready: DotResult = await _cloud.start()

	if not ready.ok:
		# Not fatal. Every consumer treats an absent cloud as "this deployment ships its
		# content in the build", which is true here — the failure to be loud about is the
		# one where a cloud is expected and is quietly not there.
		DotLog.warn(
			"room.play", "content delivery is unavailable", {"why": str(ready.error)}
		)


## Signs in if there is already a session, and stays a guest if there is not.
func _sign_in() -> void:
	_auth = DotAuthClient.new()
	_auth.name = "Auth"
	add_child(_auth)

	var started := _auth.start()

	if not started.ok:
		DotLog.info("room.play", "authentication is unavailable; joining as a guest", {
			"why": str(started.error),
		})
		return

	# [b]The page handoff and a stored session, and deliberately NOT `sign_in()`.[/b]
	# That one falls through to `start_device_login()` when neither works — two backbone
	# requests on every launch for a flow with no code on screen and nobody to read it.
	# dot-server-setup-test shipped exactly that, and those two requests are what made a
	# wrong default backbone domain visible in a network tab.
	if _auth.web_handoff and DotAuthWebHandoff.supported():
		var handed: DotResult = await _auth.try_web_handoff()

		if not handed.ok:
			DotLog.debug("room.play", "no usable handoff from the page")

	if not _auth.is_signed_in() and _auth.store != null \
			and _auth.store.has_credentials():
		var restored: DotResult = await _auth.restore_session()

		if not restored.ok:
			DotLog.info("room.play", "a stored session did not work; staying a guest", {
				"why": restored.code(),
			})

	var identity := _auth.identity()

	if identity == null:
		return

	var known := identity.display_name

	if known != "" and _name_entry != null:
		# [b]Only when the box still holds the generated name.[/b] Somebody who typed
		# something meant it, and a login landing a second later that overwrote it would
		# be the most annoying possible bug in this menu.
		if _name_entry.text.begins_with("Guest "):
			_name_entry.text = known

	if _status != null:
		_status.text = "Signed in as %s." % known


func _has_arg(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args()


func _arg_value(flag: String) -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find(flag)
	return args[index + 1] if index >= 0 and index + 1 < args.size() else ""


## Where to connect, from the command line or from the page's query string.
##
## [b]The query string is how a browser player arrives.[/b] They followed a link that
## already named a server; asking them to type an address they were never shown is asking
## them to leave.
func _requested_address() -> String:
	var from_cli := _arg_value("--connect")

	if from_cli != "":
		return from_cli

	if not DotPlatform.is_web():
		return ""

	return DotWeb.query_param("server")


# --- The menu --------------------------------------------------------------

func _build_menu() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Menu"
	add_child(layer)

	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_panel)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.position = Vector2(-180, -110)
	box.custom_minimum_size = Vector2(360, 0)
	_panel.add_child(box)

	var title := Label.new()
	title.text = "a room"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 34)
	box.add_child(title)

	var blurb := Label.new()
	blurb.text = "A place to stand about in while you decide where to go."
	blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.add_theme_color_override("font_color", Color(0.66, 0.71, 0.78))
	box.add_child(blurb)

	box.add_child(_spacer(18))

	_name_entry = LineEdit.new()
	_name_entry.placeholder_text = "Your name"
	_name_entry.text = "Guest %d" % (randi() % 900 + 100)
	_name_entry.max_length = RoomContent.NAME_BYTES
	box.add_child(_name_entry)

	_address_entry = LineEdit.new()
	_address_entry.placeholder_text = "host:port"
	_address_entry.text = "127.0.0.1:%d" % DEFAULT_PORT
	box.add_child(_address_entry)

	var join := Button.new()
	join.text = "Join"
	join.pressed.connect(func() -> void: _connect_to(_address_entry.text))
	box.add_child(join)

	var find := Button.new()
	find.text = "Find a room"
	find.pressed.connect(_open_browser)
	box.add_child(find)

	# [b]No Host button.[/b] A browser tab cannot listen, and offering a control that
	# fails on the platform this game exists for is worse than not offering it. Offline is
	# offered instead, and it says what it is.
	var offline := Button.new()
	offline.text = "Stand in an empty room"
	offline.pressed.connect(_start_offline)
	box.add_child(offline)

	if DotPlatform.is_web():
		var note := Label.new()
		note.text = "A browser tab cannot host. Follow a link to somebody's room."
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72))
		box.add_child(note)

	box.add_child(_spacer(10))

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)

	# The join button is what a keyboard lands on. Grabbed after the node is in the tree:
	# focusing one that is not yet there is a menu that opens with nothing focused —
	# unusable with a gamepad and invisible with a mouse. game-arena shipped that.
	join.grab_focus.call_deferred()


## Opens the server list, building it the first time.
##
## [b]Built on demand, and it is not laziness.[/b] A [DotBrowser] that exists is one that
## refreshes itself on a timer, which is a UDP packet to every server it knows about — and
## a person who followed a link straight into a room never opens this at all.
func _open_browser() -> void:
	if _browser == null:
		_browser = RoomBrowser.new()
		_browser.name = "Rooms"
		# Inside the same panel the menu is in, so hiding the menu hides both and there is
		# one thing that decides whether a person is looking at a menu or at a room.
		_panel.add_child(_browser)
		_browser.joined.connect(func(address: String) -> void:
			_browser.visible = false
			_connect_to(address)
		)
		return

	_browser.visible = not _browser.visible


func _spacer(height: int) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, height)
	return spacer


func _set_menu_visible(shown: bool) -> void:
	if _panel != null:
		_panel.visible = shown

	# The list stops refreshing with the menu. A browser polling six servers every eight
	# seconds while somebody is standing in a room is bandwidth spent on a screen nobody
	# is looking at — and it is `visible` that [method RoomBrowser._process] checks.
	if _browser != null and not shown:
		_browser.visible = false


# --- Starting --------------------------------------------------------------

func _start_offline() -> void:
	_set_menu_visible(false)
	_spawn_client(null)


func _connect_to(address: String) -> void:
	var target := address.strip_edges()

	if target == "":
		_status.text = "Type an address first."
		return

	if not target.contains(":") and not target.begins_with("ws"):
		target = "%s:%d" % [target, DEFAULT_PORT]

	_status.text = "Connecting to %s…" % target

	_link = DotClientLink.new()
	# "Server", because Godot routes an RPC by the receiver's node path relative to its
	# MultiplayerAPI root and the server's node is called that. The name is the routing.
	_link.name = "Server"
	_link.player_name = _name_entry.text.strip_edges()
	_root.add_child(_link)

	_link.spawned.connect(_on_spawned)
	_link.disconnected.connect(_on_disconnected)
	_link.phase_changed.connect(func(_phase: int, text: String) -> void:
		_status.text = text
	)

	var connecting: DotResult = await _link.connect_to_server(target)

	if not connecting.ok:
		_status.text = "Could not connect: %s" % str(connecting.error)
		_link.queue_free()
		_link = null


func _on_spawned() -> void:
	_set_menu_visible(false)
	_spawn_client(_link)


## Builds the game the way a client shell would.
##
## Through the scene rather than the class, and with the link assigned before it enters
## the tree, because that is exactly what a shell does with a downloaded pack — and a path
## only the launcher takes is a path the deployment never runs.
func _spawn_client(link: DotClientLink) -> void:
	if _client != null and is_instance_valid(_client):
		return

	var packed: Variant = load("res://scenes/room_client.tscn")
	_client = (packed as PackedScene).instantiate() as RoomClient
	_client.link = link
	_root.add_child(_client)


func _on_disconnected(reason: String) -> void:
	if _client != null and is_instance_valid(_client):
		_client.queue_free()
		_client = null

	_set_menu_visible(true)
	_status.text = "Disconnected: %s" % (reason if reason != "" else "no reason given")


## Runs for `--seconds N` and then exits 0. Zero, the default, means forever.
##
## This scene is interactive: it waits for a person, so a blanket "run every example"
## sweep stalls here and the scene is therefore opened by nothing. That is the state a
## load-time regression hides in — a renamed node or a moved resource breaks it and no
## suite in the repository notices. Bounding it is what makes it sweepable, the same
## way dot-auth's issuer example is.
##
## Not a self-test: reaching the timeout only proves the scene loaded and ran frames.
## It exits 0 for exactly that claim and no larger one.
func _arm_exit_timer() -> void:
	var argv := OS.get_cmdline_user_args()
	var at := argv.find("--seconds")
	if at < 0 or at + 1 >= argv.size():
		return

	var seconds := maxf(0.0, argv[at + 1].to_float())
	if seconds <= 0.0:
		return

	print("Exiting in %.1f seconds (--seconds)." % seconds)
	await get_tree().create_timer(seconds).timeout
	print("--seconds elapsed; exiting.")
	get_tree().quit(0)
