class_name SpacesimPopulationRocks
extends RefCounted
## **The rocks of a population that are big enough to have a position.**
##
## Everything at or above `SpacesimPopulation.shown_floor` is made **once**, from the population's seed, and never
## respawned — so a rock you fly past is the same rock if you come back to it, and the number of them is the
## population's own count rather than a number of slots. Below the floor the population stays what it is: a density,
## which `SpacesimPopulationField` samples around the ship.
##
## **Why the split exists.** The belt holds 1.1e11 rocks of 10 m and up, and even 1e8 splats would be ten times
## sparser than it really is. Sizing the floor so the count is drawable is the only honest way to put rocks
## *somewhere*: above it they are objects, below it they are statistics.
##
## Positions are **relative to the parent body's centre** and fixed: a rock's orbit is known and not applied, which
## is the same arrangement the planets and moons have. The draw is uniform by volume — `r` is sampled against `r²`
## — because a population fills a volume, unlike a ring which fills a sheet.

## How many draws a position may take before giving up. A point drawn in the torus' bounding box lands in the band
## often enough that this is never reached in practice.
const PLACEMENT_TRIES := 64

var positions := PackedVector3Array()
## Each rock's radius in metres — half its diameter, as a body's is.
var radii := PackedFloat32Array()
## `A-0001` and up, in generation order. Derived from the seed, so it is the same list every load.
var designations := PackedStringArray()


static func of(population: SpacesimPopulation) -> SpacesimPopulationRocks:
	var rocks := SpacesimPopulationRocks.new()
	if population == null or population.shown_floor <= 0.0:
		return rocks
	var inner := population.semi_major_axis.x
	var outer := population.semi_major_axis.y
	if inner <= 0.0 or outer <= inner:
		return rocks
	var count := _count_above(population)
	if count <= 0:
		return rocks
	var rng := RandomNumberGenerator.new()
	rng.seed = population.seed_value
	var half := sin(deg_to_rad(clampf(population.inclination.y, 0.0, 90.0)))
	for index in count:
		var local := _place(rng, inner, outer, half)
		if local == Vector3.ZERO:
			continue
		rocks.positions.append(local)
		rocks.radii.append(0.5 * _diameter(rng, population))
		rocks.designations.append("A-%04d" % (rocks.positions.size()))
	return rocks


## How many rocks there are at or above the shown floor, on the population's own law: `N(>D) ∝ D^-index`
## anchored at `count` rocks of `reference_size`. The same arithmetic the field does for its floor, at a different
## size — `SpacesimPopulationField.addressable_count` is the 10 m version of this.
static func _count_above(population: SpacesimPopulation) -> float:
	if population.reference_size <= 0.0 or population.size_index <= 0.0:
		return 0.0
	return float(population.count) * pow(
		maxf(population.shown_floor, 1.0) / population.reference_size, -population.size_index
	)


## A point drawn uniformly by **volume** inside the band: `r` against `r²`, a bearing, and a `z` inside the
## inclination cone at that radius.
static func _place(rng: RandomNumberGenerator, inner: float, outer: float, half: float) -> Vector3:
	for _try in PLACEMENT_TRIES:
		var r := lerpf(pow(inner, 3.0), pow(outer, 3.0), rng.randf())
		r = pow(r, 1.0 / 3.0)
		var bearing := rng.randf() * TAU
		var z := rng.randf_range(-1.0, 1.0) * r * half
		var ring := sqrt(maxf(r * r - z * z, 0.0))
		return Vector3(cos(bearing) * ring, sin(bearing) * ring, z)
	return Vector3.ZERO


## A diameter at or above the shown floor, on the population's own power law: `N(>D) ∝ D^-index`.
static func _diameter(rng: RandomNumberGenerator, population: SpacesimPopulation) -> float:
	var p := maxf(population.size_index, 0.0)
	if p <= 0.0:
		return maxf(population.shown_floor, 1.0)
	var floor_size := maxf(population.shown_floor, 1.0)
	var ceiling := maxf(population.size_ceiling, floor_size)
	var drawn := floor_size * pow(maxf(rng.randf(), 1.0e-6), -1.0 / p)
	return clampf(drawn, floor_size, ceiling)


func size() -> int:
	return positions.size()


## The nearest rocks to `where`, by straight-line distance, in the frame the positions are in.
##
## **A linear scan, on purpose.** The belt's floor puts a few thousand rocks in here, and a few thousand distance
## tests is cheaper than an index built to avoid them — the rings need their buckets because they hold 300,000.
func nearest(where: Vector3, count := 1) -> Array[int]:
	var found: Array[int] = []
	if positions.is_empty() or count <= 0:
		return found
	var best: Array[float] = []
	for index in positions.size():
		var distance := positions[index].distance_squared_to(where)
		if best.size() < count:
			best.append(distance)
			found.append(index)
			var at := best.size() - 1
			while at > 0 and best[at] < best[at - 1]:
				best[at] = best[at - 1]
				best[at - 1] = distance
				var swap := found[at]
				found[at] = found[at - 1]
				found[at - 1] = swap
				at -= 1
		elif distance < best[count - 1]:
			best[count - 1] = distance
			found[count - 1] = index
			var at := count - 1
			while at > 0 and best[at] < best[at - 1]:
				best[at] = best[at - 1]
				best[at - 1] = distance
				var swap := found[at]
				found[at] = found[at - 1]
				found[at - 1] = swap
				at -= 1
	return found
