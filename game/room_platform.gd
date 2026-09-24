extends Node

const RoomContent := preload("room_content.gd")

## The identity half, in one node: who somebody is, what they are called, what they wear.
##
## [b]Four addons that are useless apart and are one flow together.[/b] dot-auth says who
## a connection belongs to, dot-user turns that into a profile that follows them between
## servers, dot-user-avatar says what they may wear, and [DotPlatformHub] joins the three
## into a single admission. This node builds all of them with this lobby's settings, and
## then gets out of the way: the actual admission is [DotPlatformModule]'s, which
## `examples/dedicated.tscn` loads beside [RoomModule].
##
## [b]It is optional and the lobby must work without it.[/b] A LAN room somebody runs for
## an evening has no accounts, no profiles and no wardrobe, and that is the most common
## deployment there is. [RoomModule] therefore duck-types against the platform module
## rather than naming it — `server.modules.get_module("platform")` and a `has_method`
## check — so a server that never loaded one has players with names and no avatars, which
## is a lobby.
##
## [b]Guests get profiles.[/b] `allow_guest_profiles` is on, which is not the default,
## because the whole point of a lobby is that you can walk into one. A profile that
## required an account would make the name box on the launcher a lie.

const CHANNEL := "room.platform"

## Where profiles and avatars are written. Under one directory so an operator can move
## the whole identity half by moving one folder.
const DEFAULT_DIR := "user://room_identity"


var users: DotUserManager = null
var avatars: DotAvatarManager = null
var hub: DotPlatformHub = null

## Where everything is stored. Overridable so two servers in one process — which
## `examples/sandbox.tscn` is not, but a test harness could be — do not share a directory.
var directory: String = DEFAULT_DIR

## The pseudonym scope.
##
## [b]This is the field that decides whether operators can correlate their players.[/b]
## dot-user derives a per-scope id from the account and this string, so two servers with
## different scopes see two unrelated ids for one person. Left as a per-server value
## deliberately: a community that wants one identity across its servers sets them all to
## the same thing, and that is a decision rather than a default.
var scope: String = "server:simple-lobby"

## Registry suffix, for a process holding two of these.
var service_scope: StringName = &""


## Builds profiles, avatars and the hub, in that order.
##
## [b]Awaited, and it has to be:[/b] a store may be a directory that does not exist yet or
## an HTTP endpoint that has to answer. This is called from an application's own setup —
## `examples/dedicated.gd` — rather than from a module's `_module_load`, because
## dot-server's module host does not await that and a module whose load suspends returns
## null to it.
func setup() -> DotResult:
	var profiled: DotResult = await _build_users()

	if not profiled.ok:
		# ERROR, here rather than only in the caller, because only this file knows which
		# of the three stores it was — and "profiles" against "avatars" is the difference
		# between a directory to fix and a schema to fix.
		DotLog.result(CHANNEL, "profiles could not start", profiled)
		return profiled

	var dressed: DotResult = await _build_avatars()

	if not dressed.ok:
		DotLog.result(CHANNEL, "avatars could not start", dressed)
		return dressed

	var joined: DotResult = await _build_hub()

	if not joined.ok:
		DotLog.result(CHANNEL, "the platform hub could not start", joined)
		return joined

	# INFO: where a lobby keeps people's profiles is the first thing an admin asks when
	# one goes missing, and guests being allowed is this deployment's decision, not
	# dot-user's default.
	DotLog.info(CHANNEL, "profiles and avatars are up", {
		"directory": directory, "scope": String(scope), "guests": true,
	})
	return joined


func _build_users() -> DotResult:
	users = DotUserManager.new()
	users.name = "Users"
	users.register_service = true
	users.service_scope = service_scope
	users.load_layered_config = false
	users.config_file = ""
	users.server_id = scope

	var config := DotUserConfig.new()
	config.backend = "local"
	config.directory = "%s/profiles" % directory
	config.scope = scope
	config.scope_key_file = "%s/scope.key" % directory
	# A lobby you can walk into. See the note at the top of this file.
	config.allow_guest_profiles = true
	config.create_missing = true
	config.save_on_leave = true
	# [b]Name changes are allowed here and are off by default in dot-user.[/b] A lobby is
	# where somebody decides what to be called before they go and play something; a
	# competitive server is where a name has to stay put so a record means something. Two
	# deployments, two answers, and this is a lobby.
	config.allow_name_changes = true
	config.refuse_duplicate_names = true
	users.config = config

	add_child(users)

	return await users.setup()


func _build_avatars() -> DotResult:
	avatars = DotAvatarManager.new()
	avatars.name = "Avatars"
	avatars.register_service = true
	avatars.service_scope = service_scope
	avatars.load_layered_config = false
	avatars.config_file = ""
	# [b]The server holds the schema and no art at all.[/b] That is dot-user-avatar's one
	# idea: whether an avatar is legal is a question about a document and an entitlement
	# set, and a dedicated server answers it without ever loading a mesh — or, here,
	# without ever knowing that a hat is drawn as an arc.
	avatars.schema = RoomContent.avatar_schema()

	var config := DotAvatarConfig.new()
	config.backend = "local"
	config.directory = "%s/avatars" % directory
	avatars.config = config

	add_child(avatars)

	return await avatars.setup()


func _build_hub() -> DotResult:
	hub = DotPlatformHub.new()
	hub.name = "Platform"
	hub.register_service = true
	hub.service_scope = service_scope
	hub.load_layered_config = false
	hub.config_file = ""

	var config := DotPlatformConfig.new()
	# [b]Neither is required, and that is the decision this file exists to make.[/b]
	# dot-platform's own module documents that admission completes shortly *after*
	# dot-server has already admitted the player, because there is no cancellable stage
	# between authentication and content — so `require_profile` is a promise it cannot
	# keep yet. A lobby is also the last place to hold somebody at the door: a player you
	# cannot see is worse than a player with no hat, and a player who cannot get in at all
	# is worse than both.
	config.require_profile = false
	config.require_avatar = false
	config.apply_profile_name = true
	config.broadcast_avatar_changes = true
	config.onboarded_needs_avatar = false
	hub.config = config

	add_child(hub)

	return await hub.setup()


## The auth server a lobby runs when there is no backbone.
##
## [b]Guests, explicitly.[/b] `ANONYMOUS` with `allow_guests` is what makes a room
## somebody can walk into, and it is what every deployment of this game runs today: a real
## backbone means a device-code grant and a person clicking Approve in a browser, which is
## dot-auth's and which nothing in this family has ever done against a live site.
static func guest_auth_config() -> DotAuthConfig:
	var config := DotAuthConfig.new()
	config.strategy = DotAuthConfig.Strategy.ANONYMOUS
	config.allow_guests = true
	return config


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("identity     scope %s" % scope)

	if users != null:
		out.append("profiles     %s" % users.describe().get("store", "?"))

	if hub != null:
		out.append_array(hub.describe_lines())

	return out
