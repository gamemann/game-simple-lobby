extends Control

## The server list: what a person sees before they are in a room.
##
## [b]dot-browser is the client half of dot-server's queries, and this is the screen over
## it.[/b] The addon does the asking — DQP over UDP on a desktop, DQP as JSON over a
## WebSocket in a browser, and A2S for the twenty years of tooling that speaks nothing
## else — behind a list model with sources, filters, sorting, favourites and history.
## Nothing here re-implements any of that; what this file decides is which sources a lobby
## has and what a row looks like.
##
## [b]Filtering is local and always will be.[/b] dot-browser is explicit that a filter is
## applied on the client rather than sent to the server, because a server that decided
## which of its own properties to report is a server that reports whatever gets it listed.
##
## [b]There is no master server yet, and this file is where that is visible.[/b] The
## family's own status notes say a tracker has to be told an address and nothing announces
## one — so the sources here are the two that need no such thing: the servers this person
## has actually visited, and whatever they type. `DotBrowserSourceBackbone` reads a
## listing website-city does not yet publish, and adding it here is one line the day it
## does.

const CHANNEL := "room.browser"

## Default port, matching the launcher's.
const DEFAULT_PORT := 27085

## How often the list refreshes itself while it is open, in seconds.
##
## [b]Not every frame and not never.[/b] A list that never refreshes shows a player count
## from when the window opened, which is the one number they are reading it for; a list
## that refreshes constantly is a UDP packet to every server on it several times a second,
## which is what a badly written server browser looks like from the other end.
const REFRESH_INTERVAL := 8.0


## Somebody picked a server. [param address] is what to connect to.
signal joined(address: String)


var browser: DotBrowser = null

var _table: DotTableView = null
var _status: Label = null
var _entry: LineEdit = null
var _rows: Array[DotBrowserEntry] = []
var _selected: int = -1
var _since_refresh: float = 0.0
var _last_online := -1
var _last_total := -1


func _ready() -> void:
	# `set_anchors_and_offsets_preset`, not `set_anchors_preset`. The anchors describe how
	# a rectangle follows its parent and change nothing until something resizes it, so a
	# Control built in code keeps the zero size it was created with — and every child then
	# lays out inside nothing while being, by every property, correctly configured. This
	# family has shipped that twice and dot-ui had five of them.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_start()


func _build() -> void:
	var box := VBoxContainer.new()
	box.name = "List"
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", 8)
	add_child(box)

	var title := Label.new()
	title.text = "Rooms"
	title.add_theme_font_size_override("font_size", 24)
	box.add_child(title)

	_table = DotTableView.new()
	_table.name = "Table"
	_table.show_header = true
	_table.max_rows = 64
	var columns: Array[Dictionary] = [
		{"key": &"name", "title": "Server", "width": 4.0},
		{"key": &"players", "title": "Players", "align": HORIZONTAL_ALIGNMENT_RIGHT},
		{"key": &"ping", "title": "Ping", "align": HORIZONTAL_ALIGNMENT_RIGHT},
	]
	_table.set_columns(columns)
	_table.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# [b]Clicking selects; the button joins.[/b] A list where a click joins is a list
	# where a mis-click leaves the menu, and a server browser is somewhere people click
	# about. `row_activated` carries the index into the rows as last given, which is the
	# filtered order — the same order [member _rows] is in, because both come out of one
	# call to [method _redraw].
	_table.row_activated.connect(func(index: int, _row: Dictionary) -> void:
		_selected = index
		_show_selection()
	)
	box.add_child(_table)

	var row := HBoxContainer.new()
	box.add_child(row)

	_entry = LineEdit.new()
	_entry.placeholder_text = "host:port"
	_entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_entry.text_submitted.connect(func(text: String) -> void: add_and_join(text))
	row.add_child(_entry)

	var add := Button.new()
	add.text = "Add"
	add.pressed.connect(func() -> void: add_address(_entry.text))
	row.add_child(add)

	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.pressed.connect(func() -> void: browser.refresh())
	row.add_child(refresh)

	var join := Button.new()
	join.text = "Join"
	join.pressed.connect(_join_selected)
	row.add_child(join)

	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(0.66, 0.71, 0.78))
	box.add_child(_status)


func _start() -> void:
	browser = DotBrowser.new()
	browser.name = "Browser"
	# One at a time is a slow list and thirty at a time is a burst that looks like a scan.
	browser.concurrency = 6
	browser.timeout_ms = 2000
	browser.retries = 1
	# `info` only. A player list per server is a second round trip to every one of them
	# for a column nobody reads until they have picked a row.
	browser.sections = PackedStringArray(["info"])
	browser.register_as = &""
	browser.favourites_path = "user://room_servers.json"
	add_child(browser)

	var started := browser.start()

	if not started.ok:
		# WARN: the list will stay empty and the player can still type an address in, so
		# the screen is degraded rather than broken — but nothing on it says why.
		DotLog.result(CHANNEL, "the server list could not start", started, DotLog.Level.WARN)

	# History and favourites, which is the only source that needs no tracker: a lobby you
	# have been in before is a lobby you can get back to.
	var remembered := browser.load_favourites()
	DotLog.debug(CHANNEL, "server list", {
		"remembered": remembered, "path": browser.favourites_path,
	})

	browser.entry_updated.connect(func(_entry: DotBrowserEntry) -> void: _redraw())
	browser.refresh_finished.connect(func(online: int, total: int) -> void:
		_status.text = "%d of %d answering." % [online, total]
		# On a change only. This refreshes every few seconds while the screen is up, and
		# a line per refresh saying the same two numbers is noise; the moment a known
		# server stops answering is the line worth having.
		if online != _last_online or total != _last_total:
			DotLog.debug(CHANNEL, "servers answering", {"online": online, "total": total})
			_last_online = online
			_last_total = total
		_redraw()
	)

	if browser.count() == 0:
		# A first run. The address the launcher defaults to, so somebody who has just
		# started a server on this machine sees it rather than an empty list they have to
		# work out how to fill.
		add_address("127.0.0.1:%d" % DEFAULT_PORT)

	browser.refresh()


func _process(delta: float) -> void:
	if browser == null or not visible:
		return

	_since_refresh += delta

	if _since_refresh >= REFRESH_INTERVAL and not browser.is_refreshing():
		_since_refresh = 0.0
		browser.refresh_known()


## Adds an address by hand. Returns false when it is not a plausible one.
func add_address(text: String) -> bool:
	var parsed := DotBrowserTarget.parse(text.strip_edges(), DEFAULT_PORT)

	if not parsed.ok:
		_status.text = "That is not an address: %s" % parsed.error.message
		DotLog.debug(CHANNEL, "address refused", {
			"text": text.strip_edges(), "why": parsed.error.message,
		})
		return false

	browser.add_target(parsed.value as DotBrowserTarget)
	browser.refresh()
	return true


func add_and_join(text: String) -> void:
	if add_address(text):
		joined.emit(text.strip_edges())


func _redraw() -> void:
	# [b]`filtered()`, not `entries()`.[/b] The filter and the sort are the model's, and a
	# screen that ordered rows itself would be a second ordering that disagrees with the
	# one favourites are pinned by.
	_rows = browser.filtered()

	# The selection is an index into a list that has just been rebuilt, and a refresh can
	# reorder it — the default sort is by ping. Dropping the selection is the honest
	# answer: keeping the index would silently move it onto a different server, and the
	# failure is somebody joining a room they did not choose.
	if _selected >= _rows.size():
		_selected = -1

	var rows: Array[Dictionary] = []

	for entry in _rows:
		rows.append({
			&"name": entry.name if entry.name != "" else entry.target.join_address(),
			&"players": "%d/%d" % [entry.players, entry.max_players],
			&"ping": "%d" % entry.ping_ms if entry.is_online() else "-",
			"colour": (
				Color(0.86, 0.89, 0.94) if entry.is_online()
				else Color(0.55, 0.55, 0.60)
			),
		})

	_table.set_rows(rows)


## Says which row is picked, and what is wrong with it if anything.
##
## A full server and an offline one are both rows you can select and neither is a row you
## can join, and saying so on selection is better than saying so after the button.
func _show_selection() -> void:
	if _selected < 0 or _selected >= _rows.size():
		return

	var entry := _rows[_selected]

	if not entry.is_online():
		_status.text = "%s is not answering." % entry.target.join_address()
	elif entry.is_full():
		_status.text = "%s is full (%d/%d)." % [
			entry.name, entry.players, entry.max_players
		]
	else:
		_status.text = "%s — %d of %d, %d ms." % [
			entry.name, entry.players, entry.max_players, entry.ping_ms
		]


func _join_selected() -> void:
	if _selected < 0 or _selected >= _rows.size():
		_status.text = "Pick a room first."
		return

	var entry := _rows[_selected]

	# [b]The join address, not the query address.[/b] A server's query port is frequently
	# not the port people connect to — A2S even carries the game port separately for
	# exactly that reason — and joining the one it answered on is the most confusing
	# possible failure: the list works, the server is right there, and the connection
	# times out.
	browser.note_connected(entry.key())
	# INFO: the one thing on this screen a person reporting "I joined the wrong room" or
	# "it never connected" needs in their log — which row, and the address it resolved to.
	DotLog.info(CHANNEL, "joining", {
		"name": entry.name, "address": entry.join_address(), "ping_ms": entry.ping_ms,
	})
	joined.emit(entry.join_address())
