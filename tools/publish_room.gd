extends Node

## Packages this room into a signed dot-cloud pack a server can deliver.
##
## [codeblock]
## godot --headless --path . res://tools/publish_room.tscn
## godot --headless --path . res://tools/publish_room.tscn -- \
##     --out user://published --version 1.1.0 --key user://keys/content.key \
##     --mirror https://cdn.example/simple-lobby/
## [/codeblock]
##
## [b]This is the deployment this game exists for.[/b] game-arena, game-hungario and
## game-g2gfast all ship inside their own build, so `changelevel` has never sent a client
## to fetch anything and dot-server's content sync has never run end to end. A lobby is
## small enough to be a pack — no art, no audio, no fonts — and what a generic client
## shell mounts and instantiates is `scenes/room_client.tscn` out of this directory.
##
## [b]What goes in is scenes, and the scripts go with them.[/b] game-hungario's avatar
## pack excludes `.gd` deliberately, because it is a bag of parts whose code ships in the
## build. This is the opposite case: a shell that has never heard of a room has none of
## this game's code, so the pack has to carry it. That is also why the pack is signed and
## why signing is not optional — **a Godot pack can contain scripts and this one does**,
## so the manifest's signature is the only thing between a content host and code execution
## on every player's machine.
##
## [b]The mounted pack cannot use `class_name`.[/b] Measured, and written down in the
## family's own CLAUDE.md: a mounted pack's `class_name` globals are not registered in the
## host, so every cross-file type reference inside it fails to compile — `preload` and
## `extends` by path both work. **This game does not satisfy that yet**, and the tool says
## so rather than producing a pack that mounts and is entirely dead. See the warning it
## prints, and the note in this project's CLAUDE.md.
##
## A build step, not a runtime path: it hashes every file synchronously, which is right in
## a CLI and wrong in a frame.

const CHANNEL := "room.publish"

const DEFAULT_OUT := "user://room_published"
const DEFAULT_KEY := "user://room_keys/content.key"
const DEFAULT_PUB := "user://room_keys/content.pub"

## What the pack is called, and what a manifest URL is built from.
##
## [b]Not the game id.[/b] `simple_lobby` is what an operator types at a console;
## `simple-lobby` is what a version-namespaced directory is called. dot-cloud mounts at
## `res://dot_cloud/<id>/<version>/`, and a mounted pack can never be unmounted on any
## platform — which is the constraint that shaped dot-cloud more than any other and the
## reason the version is in the path rather than in a field.
const PACK_ID := &"simple-lobby"

## The directories that make up the room, relative to the project.
const SOURCE_DIRS := ["game", "scenes"]


func _ready() -> void:
	DotLog.set_level(DotLog.Level.INFO)
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out_dir := _arg(args, "--out", DEFAULT_OUT)
	var version := _arg(args, "--version", "1.0.0")
	var key_path := _arg(args, "--key", DEFAULT_KEY)
	var public_path := _arg(args, "--public", DEFAULT_PUB)
	var mirror := _arg(args, "--mirror", "")

	print("game-simple-lobby: publishing the room")
	print("")

	var key := _key(key_path, public_path)

	if key == "":
		get_tree().quit(1)
		return

	var staged := _stage(out_dir)

	if staged == "":
		get_tree().quit(1)
		return

	var mirrors := PackedStringArray()

	if mirror != "":
		mirrors.append(mirror)

	var publisher := DotCloudPublisher.new()
	publisher.content_id = PACK_ID
	publisher.version = version
	publisher.display_name = "the room"
	publisher.signing_key_pem = key
	publisher.mirrors = mirrors
	# The scene a shell instantiates. Relative, and it has to be:
	# [method DotClientLink._resolve_scene] refuses every absolute path outside dot-cloud's
	# mount — correctly, because a server that could name one could ask any client to load
	# any scene in their build.
	publisher.entry_scene = "scenes/room_client.tscn"
	publisher.metadata = {
		"kind": "lobby",
		"game_id": RoomModule.GAME_ID,
		"capacity": RoomContent.MAX_OCCUPANTS,
	}
	publisher.exclude_suffixes = PackedStringArray([
		".gd.uid", ".import", ".tmp", ".DS_Store", "Thumbs.db",
	])

	var published := publisher.publish(staged, out_dir.path_join(String(PACK_ID)))

	if not published.ok:
		print("  FAILED  %s" % str(published.error))
		get_tree().quit(1)
		return

	var result: Dictionary = published.value

	print("  content id       %s" % PACK_ID)
	print("  version          %s" % version)
	print("  files            %d" % int(result.get("files", 0)))
	print("  objects          %d (%d deduplicated)" % [
		int(result.get("objects", 0)), int(result.get("deduped", 0))
	])
	print("  signed           %s" % ("yes" if bool(result.get("signed", false)) else "NO"))
	print("  manifest         %s" % str(result.get("manifest_path", "")))
	print("")
	print("  mounts at        res://dot_cloud/%s/%s/" % [PACK_ID, version])
	print("")
	print("  Serve this directory, then run the server with the manifest URL:")
	print("    RoomModule.game_descriptor(\"https://host/%s/%s/manifest.json\")"
		% [PACK_ID, version])
	print("  A client needs the public key in DotCloudConfig.trusted_keys under 'default'.")
	print("  The public key is at %s" % public_path)
	print("")
	print("  WARNING: every script in this game uses `class_name`, and a mounted pack's")
	print("  class_name globals are NOT registered in the host. This pack will mount and")
	print("  its scripts will not compile. Converting the game to `preload` and")
	print("  `extends \"res://...\"` by path is what makes it deliverable; the pack is")
	print("  produced anyway so the publishing half can be checked before that work.")

	get_tree().quit(0)


## Copies the room into a staging directory dot-cloud can hash.
##
## [b]Staged rather than published straight out of `res://`.[/b] The publisher walks a
## directory and hashes what it finds; `res://` in an editor build contains `.godot`,
## `addons`, the examples and the tools, none of which belong in a pack a player
## downloads. Naming the two directories that ARE the game is the only version of this
## that cannot quietly ship the signing key.
func _stage(out_dir: String) -> String:
	var staged := out_dir.path_join("staged")

	DotPaths.remove_tree(staged)

	var made := DotPaths.ensure_dir(staged)

	if not made.ok:
		print("  FAILED  could not prepare %s: %s" % [staged, str(made.error)])
		return ""

	for dir in SOURCE_DIRS:
		var copied := _copy_tree("res://%s" % dir, staged.path_join(dir))

		if not copied.ok:
			print("  FAILED  could not stage %s: %s" % [dir, str(copied.error)])
			return ""

	print("  staged           %s" % staged)
	return staged


func _copy_tree(from: String, to: String) -> DotResult:
	var made := DotPaths.ensure_dir(to)

	if not made.ok:
		return made

	var dir := DirAccess.open(from)

	if dir == null:
		return DotResult.fail(DotError.CODE_IO, "Could not read a directory.", from)

	dir.list_dir_begin()
	var name := dir.get_next()

	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue

		var source := from.path_join(name)
		var target := to.path_join(name)

		if dir.current_is_dir():
			var nested := _copy_tree(source, target)

			if not nested.ok:
				dir.list_dir_end()
				return nested
		else:
			var bytes := FileAccess.get_file_as_bytes(source)

			if FileAccess.get_open_error() != OK:
				dir.list_dir_end()
				return DotResult.fail(DotError.CODE_IO, "Could not read a file.", source)

			var out := FileAccess.open(target, FileAccess.WRITE)

			if out == null:
				dir.list_dir_end()
				return DotResult.fail(DotError.CODE_IO, "Could not write a file.", target)

			out.store_buffer(bytes)
			out.close()

		name = dir.get_next()

	dir.list_dir_end()
	return DotResult.success(null)


## Loads the signing key, generating one the first time.
##
## Refuses to publish unsigned rather than falling back to it. A default-configured client
## refuses unsigned content, so an unsigned pack is one nobody can mount — quietly
## producing one would be a build that succeeds and content that never loads.
##
## Generating a key here is a convenience for getting started. **The private half lands on
## disk with whatever permissions the platform gives it**, and it is the key that
## authorises code execution on every player's machine. Move it into a secrets store and
## delete the file.
func _key(key_path: String, public_path: String) -> String:
	if FileAccess.file_exists(key_path):
		var existing := DotPaths.read_text(key_path)

		if existing.ok:
			print("  signing key      %s" % key_path)
			return str(existing.value)

		print("  FAILED  could not read %s: %s" % [key_path, str(existing.error)])
		return ""

	print("  signing key      generating a new one")
	var made := DotCloudPublisher.generate_keys(key_path, public_path)

	if not made.ok:
		print("  FAILED  %s" % str(made.error))
		return ""

	var pair: Dictionary = made.value
	return str(pair["private"])


static func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var index := args.find(name)

	if index >= 0 and index + 1 < args.size():
		return args[index + 1]

	return fallback
