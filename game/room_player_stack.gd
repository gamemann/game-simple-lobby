class_name RoomPlayerStack
extends Node

## The player-facing addons, stood up once and bound to the lobby.
##
## [b]A lobby is where this layer is most obviously the right idea and least obviously
## needed, which is worth stating plainly.[/b] There is no match, no combat, no round
## and nothing to spawn away from. What there is, is the thing a lobby is *for*: people
## arriving, picking a side, standing about, dropping out and coming back — and every
## one of those is a record that has to be right before anybody reaches a game.
##
## [codeblock]
## dot-physics  the top-down 2D layout, as names rather than as a retune
## dot-player   the roster, which is what a lobby's list of people should have been
## dot-team     the sides people pick HERE and take into a match
## dot-player-class  the class they pick here too, with the same enforcement
## dot-spawn    where in the room they appear
## [/codeblock]
##
## [b]The sides are the point.[/b] Picking a team in a lobby and having it mean something
## in the match you go on to is the whole reason a side outlives a match, and it is the
## case dot-team was written for.

const CHANNEL := "room.stack"

const SERVICE := &"room_player_stack"

@export var register_service: bool = true

@export var apply_physics: bool = true

var world: RoomWorld = null

var physics: DotPhysicsWorld = null
var roster: DotPlayerRoster = null
var teams: DotTeamRoster = null
var classes: DotPlayerClassManager = null
var characters: DotPlayerCharCatalogue = null
var spawns: DotSpawnDirector = null

var _registered: bool = false


func setup(p_world: RoomWorld) -> DotResult:
	if p_world == null:
		return DotResult.fail(DotError.CODE_INVALID, "No room to bind to.")

	if p_world.arena == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"RoomWorld is not set up yet.",
			"Call setup() on it first; this reads its arena bounds."
		)

	world = p_world

	var built := _build_physics()

	if not built.ok:
		return built

	_build_roster()
	_build_teams()
	_build_characters()
	_build_classes()
	_build_spawns()

	world.occupant_joined.connect(_on_joined)
	world.occupant_left.connect(_on_left)

	if register_service:
		DotRegistry.register(SERVICE, self)
		_registered = true

	DotLog.info(CHANNEL, "player stack up", {"tick_rate": world.tick_rate})
	return DotResult.success(null)


func _exit_tree() -> void:
	if _registered:
		DotRegistry.unregister_instance(SERVICE, self)


# --- Building ---------------------------------------------------------------

func _build_physics() -> DotResult:
	if not apply_physics:
		return DotResult.success(null)

	physics = DotPhysicsWorld.new()
	physics.name = "Physics"
	# The project's own numbers with one change. The lobby's movement is dot-2d's own
	# integration and consults none of Godot's solver settings, so a preset here would
	# be a set of decisions about something nothing in this game reads.
	physics.profile = DotPhysicsProfile.from_project()
	physics.profile.tick_rate = world.tick_rate
	physics.layout = DotPhysicsLayout.top_down_2d()
	physics.register_service = false
	physics.write_layer_names = false
	add_child(physics)

	return physics.setup().wrap("the lobby's physics profile")


func _build_roster() -> void:
	roster = DotPlayerRoster.new()
	roster.name = "Roster"
	roster.authoritative = world.is_authority
	roster.register_service = false

	var config := DotPlayerConfig.new()
	config.tick_rate = world.tick_rate
	config.max_players = 64
	# [b]Thirty seconds, which is short on purpose and is the one place in this family
	# where it should be.[/b] A held seat costs a stranger a slot, and in a lobby —
	# where somebody is queueing to get in and nobody is mid-round — that trade is the
	# wrong way round. dot-player's own documentation says a lobby wants this, and this
	# is the lobby.
	config.reconnect_window_sec = 30.0
	roster.config = config
	add_child(roster)


func _build_teams() -> void:
	teams = DotTeamRoster.new()
	teams.name = "Teams"
	teams.authoritative = world.is_authority
	teams.register_service = false
	teams.teams = DotTeamSet.standard_pair(&"blue", &"red")
	# Casual, not competitive: nothing is at stake in a lobby, switching should be free
	# and immediate, and a thirty-second cooldown on a side nobody is playing yet would
	# be a rule with no purpose that a player would report as a bug.
	teams.policy = DotTeamPolicy.casual()
	teams.policy.tick_rate = world.tick_rate
	teams.policy.auto_assign = false
	teams.policy.initial_team = DotTeamSet.UNASSIGNED
	teams.alive_fn = func(_key: String) -> bool: return false
	add_child(teams)

	var res := teams.setup()

	if not res.ok:
		DotLog.error(CHANNEL, "team roster", {"why": res.error.message})


func _build_characters() -> void:
	characters = DotPlayerCharCatalogue.sprite_2d(RoomContent.OCCUPANT_RADIUS * 2.0)
	var res := characters.build()

	if not res.ok:
		DotLog.error(CHANNEL, "character catalogue", {"why": res.error.message})


func _build_classes() -> void:
	classes = DotPlayerClassManager.new()
	classes.name = "Classes"
	classes.authoritative = world.is_authority
	classes.register_service = false
	classes.catalogue = DotPlayerClassCatalogue.team_shooter()
	# Instant: nobody is alive, so there is no fight to change class in the middle of,
	# and the whole point of picking here is seeing the choice take effect before you
	# leave for a match.
	classes.rules = DotPlayerClassRules.instant()
	classes.team_fn = func(key: String) -> StringName: return teams.team_of(key)
	classes.alive_fn = func(_key: String) -> bool: return false
	add_child(classes)

	var res := classes.setup()

	if not res.ok:
		DotLog.error(CHANNEL, "class manager", {"why": res.error.message})


func _build_spawns() -> void:
	spawns = DotSpawnDirector.new()
	spawns.name = "Spawns"
	spawns.tick_rate = world.tick_rate
	spawns.register_service = false
	spawns.rules = DotSpawnRules.deathmatch()
	spawns.rules.seed_value = 0x1088
	# Nobody is an enemy in a lobby, so the only thing worth scoring is how far a new
	# arrival is from everybody already standing about — which stops four people who
	# joined at once from being placed on top of each other.
	spawns.enemies_fn = _occupant_positions
	add_child(spawns)

	refresh_spawns()


## Lays a ring of sites inside the room's bounds.
##
## [b]A ring rather than a grid, because a lobby has furniture in the middle.[/b]
## `RoomWorld` pushes an arrival out of anything it lands inside, so a site that is
## occasionally inside a table is survivable — but a layout that puts most of them
## there makes the push the normal case, and the normal case is where a bug hides.
func refresh_spawns() -> void:
	if spawns == null or world == null or world.arena == null:
		return

	spawns.clear_sites()

	var bounds := world.arena.bounds
	var centre := bounds.get_center()
	var radius := minf(bounds.size.x, bounds.size.y) * 0.35
	var count := 8

	for i in range(count):
		var angle := TAU * float(i) / float(count)
		var at := centre + Vector2(cos(angle), sin(angle)) * radius
		var site := DotSpawnSite.point(
			StringName("seat_%d" % i), Vector3(at.x, at.y, 0.0), angle + PI
		)
		site.is_2d = true
		spawns.add_site(site)

	DotLog.debug(CHANNEL, "spawn sites", {"count": spawns.sites().size()})


# --- Keeping in step --------------------------------------------------------

func _on_joined(occupant: RoomOccupant) -> void:
	if not roster.authoritative:
		return

	var key := str(occupant.id)
	var res := roster.join(key, occupant.display_name, occupant.id, world.current_tick())

	if not res.ok:
		DotLog.warn(CHANNEL, "occupant not added to the roster", {
			"key": key, "why": res.error.message
		})
		return

	var _team := teams.add(key, world.current_tick())
	var _class := classes.add(key)
	# Standing in a room IS being in the world here. A lobby with nobody "alive" would
	# report an empty session to a browser query, which is the one thing a lobby is
	# asked for from outside.
	var _alive := roster.set_alive(key, true)


func _on_left(occupant: RoomOccupant) -> void:
	if not roster.authoritative:
		return

	var key := str(occupant.id)
	classes.remove(key)
	var _left := teams.remove(key)
	var _held := roster.note_disconnected(key, world.current_tick())


## One tick of what this node runs on its own.
func tick(current_tick: int) -> void:
	if not roster.authoritative:
		return

	var _dropped := roster.advance(current_tick)


# --- The lobby's own questions ----------------------------------------------

## Somebody picking a side. The refusal carries a sentence a client can show.
func choose_team(id: int, team_id: StringName) -> DotResult:
	return teams.request_switch(str(id), team_id, world.current_tick())


## Somebody picking a class.
func choose_class(id: int, class_id: StringName) -> DotResult:
	return classes.request(str(id), class_id, world.current_tick())


## What a class-select screen draws: every class, with a reason for each no.
func class_options(id: int) -> Array[Dictionary]:
	return classes.options_for(str(id))


## Where in the room somebody should be placed.
##
## Offered rather than imposed: `RoomWorld.add_occupant` uses `Dot2DArena.spawn_position`,
## which knows the room's rectangle and is right. This is the version that also knows
## where everybody else is standing.
func choose_seat(id: int) -> DotResult:
	var key := str(id)
	return spawns.choose(
		DotSpawnRequest.make(
			key, teams.team_of(key), classes.class_of(key), world.current_tick()
		)
	)


## What the two sides look like right now. For a lobby screen.
func sides() -> Dictionary:
	var out: Dictionary = {}

	for team_id in teams.teams.playing_ids():
		out[String(team_id)] = teams.members(team_id)

	return out


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("--- player stack")

	if physics != null:
		out.append_array(physics.describe_lines())

	out.append_array(roster.describe_lines())
	out.append_array(teams.describe_lines())
	out.append_array(classes.describe_lines())
	out.append_array(spawns.describe_lines())
	return out


func describe() -> Dictionary:
	return {
		"players": roster.count(),
		"connected": roster.connected_count(),
		"sides": sides(),
		"seats": spawns.sites().size(),
	}


func _occupant_positions(_team: StringName) -> Array:
	var out: Array = []

	for id: Variant in world.occupants.keys():
		var occupant: RoomOccupant = world.occupants[id]

		if occupant != null:
			var at := occupant.position()
			out.append(Vector3(at.x, at.y, 0.0))

	return out
