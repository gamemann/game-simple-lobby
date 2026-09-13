extends RigidBody2D

const RoomProps := preload("room_props.gd")

## One placed thing in the room, built from its [DotPropDef].
##
## [b]One scene for every prop, and nothing in it.[/b] `game/room_prop.tscn` has no shape, no
## colour and no radius; what makes a plant a plant is three fields of the definition's
## `meta` — `radius`, `colour` and `solid` — which [method configure] turns into a
## collision shape and a size the renderer draws from. A server with real content points
## `scene_path` at its own scene and never loads this file, which is the seam
## [DotPropDef] was designed around: the definition is checkable without loading anything
## and the scene is fetched only when something is actually placed.
##
## [b]The body is built by [method configure], not by [code]_ready[/code].[/b]
## [DotPropSpawner] instantiates the scene, places it, adds it to the world and [i]then[/i]
## emits `spawned` — so the definition is not available until after the node is in the
## tree, and a `_ready` that built a default would build one that is thrown away. A prop
## nobody configured has no shape and no size: it is invisible and nothing collides with
## it, which is two symptoms pointing somewhere else. So `_ready` schedules a deferred
## check that says so, loudly, once. game-playground's `PlaygroundProp` exists for the
## same reason and says the same thing.
##
## [b]Frozen the moment it lands, and that is the whole reason a lobby can have props at
## all.[/b] Rigid-body simulation is not reproducible across machines — dot-props says so
## and every game in this family that networks props repeats it — so a prop that fell over
## would be in a different place on every client with nothing erroring. A frozen body is a
## static obstacle: both ends derive its collision from the same replicated position and
## the same catalogue radius, and there is nothing left to disagree about. The freeze goes
## through [method DotPhysGun.set_frozen] rather than by assigning `freeze` here, because
## that is the one place in dot-props that also zeroes the velocities.

const CHANNEL := "room.prop"

## The definition this was built from. Null until [method configure] runs.
var def: DotPropDef = null

## Collision radius in world units, or zero for something you walk over.
var radius: float = 0.0

## What the renderer fills it with.
var colour: Color = Color(0.5, 0.5, 0.55)

## Whether anybody collides with it. A rug is a prop and is not an obstacle.
var solid: bool = true

var _configured: bool = false


func _ready() -> void:
	# Deferred rather than immediate: `configure` is called by the spawner's `spawned`
	# handler, which runs after `add_child` and therefore after this. A check that ran
	# now would fire on every correctly built prop in the game.
	call_deferred("_complain_if_bare")


func _complain_if_bare() -> void:
	if _configured or not is_inside_tree():
		return

	DotLog.error(CHANNEL, "a prop was put in the room and never configured", {
		"node": name,
		"hint": "RoomProps.configure() runs off DotPropSpawner.spawned; something "
			+ "instantiated this scene directly",
	})


## Turns a definition into a body. Called by [RoomProps] off `spawned`.
func configure(p_def: DotPropDef) -> void:
	def = p_def
	radius = RoomProps.radius_of(p_def)
	colour = RoomProps.colour_of(p_def)
	solid = RoomProps.solid_of(p_def)
	_configured = true

	freeze_mode = RigidBody2D.FREEZE_MODE_STATIC

	if radius <= 0.0:
		return

	var shape := CircleShape2D.new()
	shape.radius = radius

	var collider := CollisionShape2D.new()
	collider.shape = shape
	add_child(collider)


func describe() -> Dictionary:
	return {
		"prop": String(def.id) if def != null else "?",
		"at": position,
		"radius": radius,
		"solid": solid,
	}
