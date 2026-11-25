class_name StoichonPopulation
extends Resource
## A population of small bodies in a solar system — the asteroid belt, a ring — as **content**.
##
## A population is a **distribution**, not a list: nothing here describes a fragment. The fragments
## are made up around the observer from these numbers, kept while they are in range, and dropped when
## they leave. Evert, 2026-11-14: *"you calculate the chances of an asteroid being in a position, make
## up a few that are in range, and forget about them when they go out of range again."*
##
## That is why there is no address, no lattice and no stored position anywhere: a fragment is a
## short-lived thing the field invents, and coming back to the same place gives different rocks.
## Evert's own rule from the design's first sitting, 2026-11-04: *"If you fly away from it, it gets
## lost in the noise again."*
##
## **A population is not a body and is not in [member StoichonSolarSystem.bodies].** It has no radius,
## no mass, no layers, and nothing orbits it. See the vault: "Asteroids and Rings", and the plan
## "Asteroids and Rings Plan".

@export var id: String = "" ## stable id, `population:main_belt`
@export var display_name: String = ""
## What it orbits. Empty means the primary star, exactly as for a body. A ring is the same type with
## its parent set to the planet.
@export var parent_id: String = ""
## Fragments are drawn with this. Two fields in one session do not look alike.
@export var seed_value: int = 0

## Mass fractions per species, summing to 1 — the same shape a layer's composition has, so a fragment
## is made of something the material table knows, and what it is worth follows from what it is.
@export var composition: Dictionary[String, float] = {}

## The radial extent, metres, as semi-major axes. Sol's main belt is 2.1 to 3.3 AU.
@export var semi_major_axis: Vector2 = Vector2.ZERO
## Degrees, to the reference plane. **This is the belt's thickness**, not a per-fragment tilt that
## has to be inverted: a fragment is placed inside |z| <= r sin(i), and its own orbit is then given
## its tilt from the band.
@export var inclination: Vector2 = Vector2.ZERO

## The anchor every count is derived from: how many fragments are at or above
## [member reference_size]. Sol's published figure is 1.1 million above 1 km.
@export var reference_size: float = 1000.0
@export var count: int = 0
## Cumulative size distribution, N(>D) proportional to D^-size_index. Dohnanyi's collisional cascade
## gives 2.5, which is what the belt follows below 100 km.
@export var size_index: float = 2.5
## **How many particles are drawn, and queried**, for a band that is a sheet rather than a swarm.
##
## **A ring needs this and the belt does not.** A belt's fragments are made up around the observer a couple
## of dozen at a time, so its count is the field's business; a ring is a whole object seen from every angle,
## so it is generated entire. It is not [member count]: `count` is the physical population, and this is the
## sample drawn in its place.
@export var particle_count: int = 0

## **How thick the sheet is**, in metres, full thickness — each particle is placed inside that slab.
##
## Saturn's main rings are 10 to 100 m thick. It is 10^-8 of a pixel at every distance the band reads as a ring, and
## it is the whole of what you see when you fly through one. Evert, 2026-11-18: *"surely not all the rocks and dust
## are on a perfect plane?"*
@export var thickness: float = 0.0

## **How much light the band reflects, as optical depth `tau`** — and the only brightness number a band has.
##
## The band's own apparent reflectance is `tau/(1 + tau)` of a bright surface before any geometry is
## applied (`StoichonRingModel.reflectance`), which puts Saturn's three bands where the measurements put
## them: C 0.1 gives 9 %, A 0.7 gives 41 %, B 1.2 gives 55 %.
@export var optical_depth: float = 0.0

## **The ring plane's normal, in the frame of the body it orbits.** A ring lies in its planet's equatorial
## plane, and which way that faces is a planet's axial tilt and its season.
##
## Authored rather than derived, because the engine has no obliquity (a body's node is only ever
## translated). It matters for one thing above all: **the star's elevation above the plane decides the
## planet's shadow**, which is a cylinder of the planet's radius along the star's direction and so reaches
## ring radius `R_planet / sin(elevation)` — 84,000 km at 45 degrees, crossing the C ring and nothing else,
## against 433,000 km at 8 degrees, crossing the whole system. Real Saturn never exceeds 26.7 degrees and
## shows the long shadow near equinox, which is the picture an author should choose.
@export var ring_axis: Vector3 = Vector3(0.0, 0.0, 1.0)

## The smallest fragment that exists at all. Below it the material is dust: it is part of the
## distribution's mass and none of its objects.
@export var size_floor: float = 10.0
## The largest, where the power law is clamped — it is only valid below ~100 km, and Ceres is 940.
@export var size_ceiling: float = 5.0e5


## **The volume the population occupies**: a shell between the two semi-major axes, as thick as the
## inclination band makes it. `z` of an object at radius r on an orbit inclined by i never exceeds
## `r·sin i`, so the shell's half-thickness is `r·sin(i_max)` — the same band [method contains]
## tests, and the number every count is divided by.
func volume() -> float:
	var inner := semi_major_axis.x
	var outer := semi_major_axis.y
	if inner <= 0.0 or outer <= inner:
		return 0.0
	var half := sin(deg_to_rad(clampf(inclination.y, 0.0, 90.0)))
	return 4.0 / 3.0 * PI * half * (pow(outer, 3.0) - pow(inner, 3.0))


## Whether a point, **relative to the parent body's centre**, is inside the band.
##
## **The band's vertical axis is `z`.** A builder that puts the height in `y` produces objects that
## fail this test and look like a placement fault elsewhere.
func contains(local: Vector3) -> bool:
	var radius := local.length()
	if radius < semi_major_axis.x or radius > semi_major_axis.y:
		return false
	var half := sin(deg_to_rad(clampf(inclination.y, 0.0, 90.0)))
	return absf(local.z) <= radius * half


## How many objects are at or above `size`. `N(>D)` falls as `D^-size_index`, anchored at
## [member count] at [member reference_size] — so the floor a population is drawn at IS its count,
## and raising the floor is how you get fewer.
func count_at_or_above(size: float) -> float:
	if reference_size <= 0.0 or size <= 0.0 or count <= 0:
		return 0.0
	return float(count) * pow(size / reference_size, -size_index)


## Objects per cubic metre at or above [member size_floor] — the density the geometry is placed at,
## rather than the density of the material.
func density() -> float:
	var space := volume()
	if space <= 0.0:
		return 0.0
	return count_at_or_above(size_floor) / space
