class_name StoichonDeepSkyEntry
extends Resource
## One extended object: a direction, an angular size, a roll and a brightness — facts about the sky, not about the
## renderer.
##
## Sizes and the roll are authored in **degrees**, which is how a catalogue states them; the accessors hand the
## renderer radians, so no caller has to remember which unit it is holding.
##
## ## The two profiles
##
## [constant PROFILE_GALAXY] is a smooth ellipse with a bright core; [constant PROFILE_NEBULA] is the same ellipse
## with a ragged edge. They are the shader's vocabulary, and they live here because an object's kind is a fact
## about the object.

## An inclined or face-on spiral: an old warm bulge, a disc, logarithmic arms with dust on their inner edges.
const PROFILE_SPIRAL := 0.0
## An irregular galaxy: a bar of old stars and the rest clumped into blue associations.
const PROFILE_IRREGULAR := 1.0
## An emission nebula: **green inside** (doubly ionised oxygen at 501 nm) and **red outside** (H-alpha, 656 nm).
const PROFILE_EMISSION := 2.0
## A reflection nebula: blue, because it scatters starlight rather than emitting, and scattering goes as 1/lambda^4.
const PROFILE_REFLECTION := 3.0
## A globular cluster: old, round, dense, warm.
const PROFILE_GLOBULAR := 4.0
## Kept for the older name: a galaxy is drawn as a spiral.
const PROFILE_GALAXY := PROFILE_SPIRAL
## Kept for the older name: a nebula is drawn as an emission region.
const PROFILE_NEBULA := PROFILE_EMISSION

## Unit vector in the J2000 equatorial frame.
@export var direction := Vector3(0.0, 0.0, 1.0)
## Full angular size along the major axis, in degrees.
@export var major_deg := 1.0
## Full angular size along the minor axis, in degrees.
@export var minor_deg := 1.0
## Rotation of the object's own axes about its direction, in degrees.
@export var roll_deg := 0.0
## Which profile the shader draws — one of the five above.
@export var profile := PROFILE_GALAXY
## Integrated visual magnitude — the object's whole light, not a surface brightness.
@export var magnitude := 6.0
## Linear tint, multiplied over the object's profile.
@export var tint := Color(1.0, 1.0, 1.0)


func major_rad() -> float:
	return deg_to_rad(major_deg)


func minor_rad() -> float:
	return deg_to_rad(minor_deg)


func roll_rad() -> float:
	return deg_to_rad(roll_deg)


## The object's whole light at the observer, in lux, from its integrated magnitude.
func luminance() -> float:
	return StoichonDeepSky.lux_from_magnitude(magnitude)
