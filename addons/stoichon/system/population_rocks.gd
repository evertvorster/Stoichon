class_name StoichonPopulationRocks
extends RefCounted
## **The rocks a population has** — built once, at fixed positions, and never changed again.
##
## This replaces the belt's invented fragments: a couple of dozen rocks made up around the observer and
## dropped when they left, so a rock had no identity, coming back gave different rocks, and a long crawl
## through the band arrived at thousands of names in succession.
## Evert, 2026-11-23: *"The asteroid belt is real, but invisible in the game unless you are in it, and
## being slowed down by asteroids ... maybe we can select a floor size so we end up with around 300,000 to
## 1,000,000 objects. We can then just instantiate them, and track the closest one to the player ... The
## mechanism of spawning in stuff seems broken."*
##
## So a population is **a set of rocks that is there**. The count comes from the content — Sol's belt is
## 1.1 million at or above 1 km — and every one of them is placed once, by a seeded draw over the band's
## own volume, with an id from its index. Nothing moves (S8) and nothing is ever removed, so a rock that
## is nearest is nearest until the ship flies past it.
##
## **The count is the floor.** `N(>D)` falls as `D^-2.5`, so the authored `count` at `reference_size` is
## what a floor buys: 1 km gives 1.1 million rocks 4.9 million km apart, 3 km gives 70 thousand 12
## million km apart. There is no second, invented population below the floor.
##
## **The query is a voxel grid, deliberately not [StoichonParticleCloud]'s index.** A ring is a flat sheet
## with a bearing structure, indexed by radius and then bearing; a belt is a thick shell, and a third
## dimension would make that two orderings into three. A grid answers the same question in a few dozen
## lines, and both stops are exact — see [method nearest_n].
##
## Positions are in the **parent body's frame**, so a caller adds the parent's position rather than the
## set carrying it.

## Rocks wanted per grid cell. The cell is then derived from the density, so the first 27 cells answer
## the query almost every time: twelve rocks each is a few hundred distance tests, against a million for
## a linear scan.
const NOMINAL_PER_CELL := 12.0

var population: StoichonPopulation

## One entry per rock, indexed the same way: `_positions` are parent-frame and `_diameters` are metres.
## Diameters are `float32` on purpose — the smallest is 1 km and the largest 500 km, which is seven
## significant digits, so memory is the only thing the precision costs.
var _positions := PackedVector3Array()
var _diameters := PackedFloat32Array()
## Occupied cells only: `Vector3i -> Array` of rock indices. The values are untyped `Array`s, which are
## **reference** types — appending to `_cells[key]` writes through, where a `PackedInt32Array` would be
## copied back and forth a million times.
var _cells: Dictionary = {}
var _cell := 0.0
## The band's own bounds, for the box test that stops a walk before it starts.
var _inner := 0.0
var _outer := 0.0
## `sin(i_max)`, so a rock's height above the plane never exceeds `r · _half`.
var _half := 0.0
var _max_shells := 0


## Build the set. `null`, an empty band or a count of zero gives an empty set rather than an error:
## content is validated by [method StoichonSolarSystem.validate], not here.
static func of(p_population: StoichonPopulation) -> StoichonPopulationRocks:
	var rocks := StoichonPopulationRocks.new()
	rocks.population = p_population
	rocks._build()
	return rocks


func count() -> int:
	return _positions.size()


## Where a rock is, in the parent body's frame.
func position_of(rock: int) -> Vector3:
	return _positions[rock]


func diameter_of(rock: int) -> float:
	return _diameters[rock]


## `A-000001` — from the index, so the same build gives the same rock the same name, and
## [StoichonFragmentBodies] can seed its shape from it.
func designation_of(rock: int) -> String:
	return "A-%06d" % (rock + 1)


## The rocks as pieces — an id, where it is in the system frame, and how big it is. The shape
## [StoichonFragmentBodies] takes, so a belt and a ring hand rocks to one manager.
func pieces(parent_position: Vector3, which: Array[int]) -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	for rock in which:
		list.append({
			"id": designation_of(rock),
			"position": parent_position + _positions[rock],
			"diameter": _diameters[rock],
		})
	return list


## The nearest rock to `local`, or `-1` when there is none within `reach` metres.
func nearest(local: Vector3, reach: float = INF) -> int:
	var found := nearest_n(local, 1, reach)
	return found[0] if not found.is_empty() else -1


## The nearest `n` rocks to `local`, nearest first — the travel unit reads the first and the HUD the rest.
##
## **Both stops are exact.** Every rock in a cell at Chebyshev distance `k` from the query's own cell is
## at least `(k - 1)` cells from the query point, so a shell whose lower bound is already worse than the
## worst rock kept cannot improve the answer, and the walk can stop there. Nothing is approximate and no
## rock is missed by stopping early.
##
## `reach` bounds the search as well as the answer: a caller that only cares about what is within the
## band's own scale does not pay for a walk to the far side of the solar system.
func nearest_n(local: Vector3, n: int, reach: float = INF) -> Array[int]:
	if n <= 0 or _positions.is_empty():
		return []
	# **A box test before the walk.** From outside the band a shell walk pays for every empty shell
	# inside `reach` — nine of them, three times a frame, for nothing: measured at 1 AU, where the belt
	# starts at 2.1 AU, `_scan_shell` alone was **13.3 ms of a 44.6 ms frame**. No rock can be within
	# `reach` unless the ship is within `reach` of the band's own bounding box, and the box is three
	# comparisons. Conservative in both directions: `_half · _outer` is the greatest height any rock of
	# the band can have, because the allowed height grows with the radius.
	if is_finite(reach):
		var radius := local.length()
		if radius < _inner - reach or radius > _outer + reach \
				or absf(local.z) > _half * _outer + reach:
			return []
	var best := Best.new()
	best.wanted = n
	best.limit_squared = reach * reach
	var centre := _cell_of(local)
	for shell in _shell_limit(local, reach) + 1:
		if shell > 0 and best.found() == best.wanted:
			var lower := float(shell - 1) * _cell
			if lower * lower > best.cutoff():
				break
		_scan_shell(centre, shell, local, best)
	return best.indexes


## The `n` best so far, kept in order. An inner class because GDScript has no out-parameters and a
## lambda captures by value — this is the shape that lets the shell walk write into one accumulator.
class Best:
	var indexes: Array[int] = []
	var distances := PackedFloat64Array()
	var wanted := 1
	## Squared distance of the worst rock kept, or `INF` while there is room for one more.
	var worst_squared := INF
	## Squared `reach`: a rock further than this is not an answer, however near it is to the ship.
	var limit_squared := INF


	func found() -> int:
		return indexes.size()


	## The distance beyond which nothing can improve the answer — the worst kept, or the caller's reach.
	func cutoff() -> float:
		return minf(worst_squared, limit_squared)


	func offer(rock: int, squared: float) -> void:
		if squared > limit_squared:
			return
		if found() >= wanted and squared >= worst_squared:
			return
		var at := found()
		while at > 0 and distances[at - 1] > squared:
			at -= 1
		indexes.insert(at, rock)
		distances.insert(at, squared)
		if found() > wanted:
			indexes.resize(wanted)
			distances.resize(wanted)
		worst_squared = distances[wanted - 1] if found() >= wanted else INF


func _build() -> void:
	var pop := population
	if pop == null or pop.count <= 0:
		return
	var inner := pop.semi_major_axis.x
	var outer := pop.semi_major_axis.y
	if inner <= 0.0 or outer <= inner:
		return
	var volume := pop.volume()
	if volume <= 0.0:
		return

	var total := pop.count
	_positions.resize(total)
	_diameters.resize(total)

	# The cell: as many as hold `NOMINAL_PER_CELL` rocks at the population's own density, so a sparse
	# belt gets bigger cells rather than empty ones.
	_cell = pow(NOMINAL_PER_CELL / (float(total) / volume), 1.0 / 3.0)
	_inner = inner
	_outer = outer
	_max_shells = ceili(2.0 * outer / _cell) + 2

	var half := sin(deg_to_rad(clampf(pop.inclination.y, 0.0, 90.0)))
	_half = half
	var rng := RandomNumberGenerator.new()
	rng.seed = pop.seed_value
	# **Drawn a hair inside the band's own bounds**, because [method StoichonPopulation.contains]
	# is an exact comparison: a rock placed exactly on the boundary reconstructs to a length a part in
	# 10^16 either side of the radius it was drawn at, and then fails the test that defines the band.
	var lo := inner * (1.0 + 1.0e-9)
	var hi := outer * (1.0 - 1.0e-9)
	var inner_cubed := pow(lo, 3.0)
	var span := pow(hi, 3.0) - inner_cubed

	for index in total:
		# **Uniform by volume**, in the shell the inclination makes: `r` drawn against `r^3`, the height
		# within `±r sin(i)` at that radius, bearing uniform. That is the same band
		# [method StoichonPopulation.contains] tests, sampled rather than rejected — and the band's
		# `z` is the vertical axis, which is why the height is the **third** component here and not the
		# second.
		var radius := pow(inner_cubed + rng.randf() * span, 1.0 / 3.0)
		var azimuth := rng.randf() * TAU
		var height := rng.randf_range(-half * radius, half * radius) * (1.0 - 1.0e-9)
		var across := sqrt(maxf(0.0, radius * radius - height * height))
		var where := Vector3(across * cos(azimuth), across * sin(azimuth), height)
		_positions[index] = where
		_diameters[index] = _draw_diameter(rng)
		var cell := _cell_of(where)
		if not _cells.has(cell):
			_cells[cell] = []
		_cells[cell].append(index)


## `N(>D) ∝ D^-index`, inverted: a uniform draw becomes a diameter with the right distribution, and
## nothing is ever smaller than the reference size — the set *is* the population at or above the floor.
func _draw_diameter(rng: RandomNumberGenerator) -> float:
	var pop := population
	var floor_size := maxf(pop.reference_size, pop.size_floor)
	if pop.size_index <= 0.0:
		return floor_size
	var uniform := maxf(rng.randf(), 1.0e-9)
	var diameter := floor_size * pow(uniform, -1.0 / pop.size_index)
	return minf(diameter, maxf(pop.size_ceiling, floor_size))


func _cell_of(local: Vector3) -> Vector3i:
	return Vector3i(floori(local.x / _cell), floori(local.y / _cell), floori(local.z / _cell))


## How many shells are worth walking: `reach` if it is finite, and never more than the band can span.
## The second bound is what keeps a query far outside the belt from walking the whole grid.
func _shell_limit(local: Vector3, reach: float) -> int:
	var limit := _max_shells
	if is_finite(reach):
		limit = mini(limit, maxi(0, ceili(reach / _cell) + 1))
	return mini(limit, maxi(0, ceili((local.length() + _outer) / _cell) + 2))


## Every rock in one shell of cells — the cube surface at Chebyshev distance `shell` from `centre`.
func _scan_shell(centre: Vector3i, shell: int, local: Vector3, best: Best) -> void:
	for x in range(centre.x - shell, centre.x + shell + 1):
		for y in range(centre.y - shell, centre.y + shell + 1):
			for z in range(centre.z - shell, centre.z + shell + 1):
				if shell > 0 and absi(x - centre.x) != shell and absi(y - centre.y) != shell \
						and absi(z - centre.z) != shell:
					continue
				var key := Vector3i(x, y, z)
				if not _cells.has(key):
					continue
				for rock: int in _cells[key]:
					best.offer(rock, local.distance_squared_to(_positions[rock]))
