class_name SpacesimDeepSky
extends RefCounted
## The catalogued extended objects and the galactic frame: the data half of the celestial background, with no
## rendering in it.
##
## ## Why these are typed objects and not numbers in a shader
##
## An object is a direction, a size, a rotation and a brightness — facts about the sky, not about the renderer.
## Keeping them as small typed records means the layer that draws them never decides any of it, and a different
## sky (another system's, or a generated one) can be handed to the same layer without touching the drawing code.
##
## ## The frame
##
## J2000 equatorial, the same frame SpaceSim's star catalogue is stored in: `X` at RA 0h Dec 0, `Z` at the north
## celestial pole. [method direction_from_ra_dec] is the only place RA and Declination become a vector, and
## [method galactic_basis] is the only place the galaxy's tilt is decided — from the published pole and centre
## rather than from a matrix of unexplained constants.

## North galactic pole and galactic centre, J2000 (IAU).
const NGP_RA_DEG := 192.85948
const NGP_DEC_DEG := 27.12825
const GC_RA_DEG := 266.40499
const GC_DEC_DEG := -28.93617

## Flux at the observer for a V = 0 star, in lux (Schlyter). Every luminance in this file is in lux.
const LUX_PER_MAG0 := 2.54e-6

## RA and Declination in degrees to a unit vector in the J2000 equatorial frame.
static func direction_from_ra_dec(ra_deg: float, dec_deg: float) -> Vector3:
	var ra := deg_to_rad(ra_deg)
	var dec := deg_to_rad(dec_deg)
	return Vector3(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec))


## The rotation that takes a J2000 direction into the galactic frame, built from the pole and the centre.
##
## `z` is the north galactic pole, `x` points at the galactic centre, and the third axis is what the other two
## leave. Those two directions are published; the Euler angles that would do the same thing are not, which is
## why this is built from them.
static func galactic_basis() -> Basis:
	var z := direction_from_ra_dec(NGP_RA_DEG, NGP_DEC_DEG).normalized()
	var x := direction_from_ra_dec(GC_RA_DEG, GC_DEC_DEG).normalized()
	var y := z.cross(x).normalized()
	x = y.cross(z).normalized()
	return Basis(x, y, z)


## Illuminance at the observer for an apparent magnitude, in lux.
static func lux_from_magnitude(magnitude: float) -> float:
	return LUX_PER_MAG0 * pow(10.0, -0.4 * magnitude)


## The objects bright enough to be worth drawing, as direction, published angular size, roll, profile and
## integrated visual magnitude.
##
## **The numbers are the published ones** — M31 is 3.17 degrees and magnitude 3.4, the Large Magellanic Cloud
## 10.75 degrees and 0.4 — so an object's light is its measured light and the layer decides only how it is drawn.
static func objects() -> Array[SpacesimDeepSkyEntry]:
	var list: Array[SpacesimDeepSkyEntry] = []
	# Large and Small Magellanic Clouds — irregular, dominated by young blue associations and pink H II regions.
	list.append(_entry(80.894, -69.756, 10.75, 9.17, 0.0, SpacesimDeepSkyEntry.PROFILE_IRREGULAR, 0.4, Color(0.92, 0.94, 1.0)))
	list.append(_entry(13.187, -72.829, 5.33, 3.57, 15.0, SpacesimDeepSkyEntry.PROFILE_IRREGULAR, 2.7, Color(0.94, 0.95, 1.0)))
	# Andromeda, inclined; Triangulum, nearly face-on.
	list.append(_entry(10.685, 41.269, 3.17, 1.00, 35.0, SpacesimDeepSkyEntry.PROFILE_SPIRAL, 3.4, Color(1.0, 1.0, 1.0)))
	list.append(_entry(23.462, 30.660, 1.17, 0.70, 51.5, SpacesimDeepSkyEntry.PROFILE_SPIRAL, 5.7, Color(1.0, 1.0, 1.0)))
	# The Orion Nebula: green core, red outskirts, a dust lane, and the Trapezium at its centre.
	list.append(_entry(83.822, -5.391, 1.10, 0.90, 0.0, SpacesimDeepSkyEntry.PROFILE_EMISSION, 4.0, Color(1.0, 1.0, 1.0)))
	# The Pleiades: an open cluster whose light is scattered, so blue.
	list.append(_entry(56.750, 24.117, 1.80, 1.40, 17.0, SpacesimDeepSkyEntry.PROFILE_REFLECTION, 1.6, Color(0.80, 0.88, 1.0)))
	# M13: an old globular, warm and dense.
	list.append(_entry(250.423, 36.460, 0.33, 0.33, 0.0, SpacesimDeepSkyEntry.PROFILE_GLOBULAR, 5.8, Color(1.0, 0.94, 0.84)))
	return list


static func _entry(
	ra_deg: float, dec_deg: float, major_deg: float, minor_deg: float, roll_deg: float,
	profile: float, magnitude: float, tint: Color
) -> SpacesimDeepSkyEntry:
	var entry := SpacesimDeepSkyEntry.new()
	entry.direction = direction_from_ra_dec(ra_deg, dec_deg)
	entry.major_deg = major_deg
	entry.minor_deg = minor_deg
	entry.roll_deg = roll_deg
	entry.profile = profile
	entry.magnitude = magnitude
	entry.tint = tint
	return entry
