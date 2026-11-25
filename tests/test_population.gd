extends RefCounted
## A population is a distribution, and the field makes fragments up out of it.
##
## The numbers here are Sol's own belt: 2.1 to 3.3 AU, 1.1 million fragments above 1 km, a 10 m
## floor. What the arithmetic should give is in `Asteroids and Rings Plan` — a density of about
## 8.6e-25 fragments per cubic metre, a mean spacing of about 105,000 km, and a field ball of about
## 188,000 km for two dozen fragments.

const AU := 1.495978707e11
## Sol itself, loaded once: `load` caches by path anyway, so the three calls below already shared
## one instance, and this says so.
const SOL := preload("res://systems/sol.tres")
## Sol's gravitational parameter, G(M_sun + m): a fragment's own mass is not worth adding.
const SUN_MU := 1.3271244e20


func run(h, root: Node) -> void:
	print("  populations")
	_test_the_arithmetic(h)
	_test_the_band(h)
	_test_validation(h)
	_test_sol_authors_the_belt(h)
	_test_a_fragment_is_significant(h)
	_test_a_fragment_is_an_irregular_body(h)
	_test_the_belt_reaches_the_marker_pool(h, root)
	_test_a_fragment_becomes_a_body(h, root)
	_test_the_rocks_are_the_population(h)
	_test_the_belt_slows_the_ship_by_its_own_sparseness(h)
	_test_two_builds_give_the_same_rocks(h)
	_test_the_index_answers_like_a_linear_scan(h)
	_test_far_outside_the_band_there_is_nothing(h)


func _belt() -> StoichonPopulation:
	var population := StoichonPopulation.new()
	population.id = "population:main_belt"
	population.parent_id = "star:sol"
	population.seed_value = 108
	population.semi_major_axis = Vector2(2.1 * AU, 3.3 * AU)
	population.inclination = Vector2(0.0, 20.0)
	population.reference_size = 1000.0
	population.count = 1100000
	population.size_index = 2.5
	population.size_floor = 10.0
	population.size_ceiling = 5.0e5
	return population


## The published figure is 1.1 million above 1 km; the number of *objects* is that scaled down to
## the size floor by the power law, and the density is that divided by the belt's own volume.
func _test_the_arithmetic(h) -> void:
	var belt := _belt()
	var addressable := belt.count_at_or_above(belt.size_floor)
	h.check_near(addressable, 1.1e11, "1.1 million above 1 km becomes 1.1e11 above 10 m", 1.0e8)

	var volume := belt.volume()
	# 4/3 pi sin(20 deg) (a_hi^3 - a_lo^3): a shell as thick as the inclination makes it.
	h.check_near(volume, 1.28e35, "the belt's volume", 1.0e33)

	var density := belt.density()
	h.check_near(density, 8.6e-25, "fragments per cubic metre", 1.0e-26)

	var spacing := pow(1.0 / density, 1.0 / 3.0)
	h.check(spacing > 9.0e7 and spacing < 1.3e8, "the mean spacing is about 105,000 km")

	# **The count at the floor IS the count at the reference**, because the author set them equal: this
	# is the floor-as-count rule, and it is what makes raising the floor give fewer rocks.
	h.check_near(belt.count_at_or_above(belt.reference_size), 1.1e6,
		"the count at the reference size is the authored figure", 1.0)
	h.check(belt.count_at_or_above(2000.0) < belt.count_at_or_above(1000.0) / 5.0,
		"and doubling the floor leaves a fifth of the objects")


func _test_the_band(h) -> void:
	var belt := _belt()
	h.check(belt.contains( Vector3(2.5 * AU, 0.0, 0.0)), "2.5 AU on the plane is in the belt")
	h.check(not belt.contains( Vector3(1.0 * AU, 0.0, 0.0)), "1 AU is inside the inner edge")
	h.check(not belt.contains( Vector3(3.8 * AU, 0.0, 0.0)), "3.8 AU is outside the outer edge")
	# sin(20 deg) is 0.342, so a fragment at 2.5 AU reaches z = 1.28e11 m and no further. The radius
	# is measured to the fragment, so the point inside the band has to be placed at that radius.
	var band_radius := 2.5 * AU
	var high := band_radius * sin(deg_to_rad(20.0))
	var across := sqrt(band_radius * band_radius - high * high)
	h.check(belt.contains( Vector3(across, 0.0, high * 0.99)),
		"just inside the top of the band")
	h.check(not belt.contains( Vector3(across, 0.0, high * 1.01)),
		"just outside it")


func _test_validation(h) -> void:
	var system := _system_with(_belt())
	h.check(system.validate().is_empty(), "a sound population validates clean")

	_breaks(h, "a band that runs backwards",
		func(population: StoichonPopulation) -> void:
			population.semi_major_axis = Vector2(3.3 * AU, 2.1 * AU))
	_breaks(h, "a band that starts inside the star",
		func(population: StoichonPopulation) -> void:
			population.semi_major_axis = Vector2(1.0e8, 3.3 * AU))
	_breaks(h, "an inclination that runs backwards",
		func(population: StoichonPopulation) -> void:
			population.inclination = Vector2(20.0, 5.0))
	_breaks(h, "no fragments at all",
		func(population: StoichonPopulation) -> void:
			population.count = 0)
	_breaks(h, "a size floor above the ceiling",
		func(population: StoichonPopulation) -> void:
			population.size_floor = 1.0e6)
	_breaks(h, "a composition that does not sum to 1",
		func(population: StoichonPopulation) -> void:
			population.composition = {"carbonaceous": 0.5})


## Rebuild the system with one wrong field, and require that it is reported. **The report is the
## test**: a validator that silently repairs is the thing this suite exists to prevent.
func _breaks(h, what: String, spoil: Callable) -> void:
	var population := _belt()
	population.composition = {"carbonaceous": 1.0}
	spoil.call(population)
	h.check(not _system_with(population).validate().is_empty(), "rejected: %s" % what)


func _system_with(population: StoichonPopulation) -> StoichonSolarSystem:
	var system := StoichonSolarSystem.new()
	var star := StoichonSystemBody.new()
	star.id = "star:sol"
	star.display_name = "Sol"
	star.kind = StoichonSystemBody.Kind.STAR
	star.primary = true
	star.radius = 6.957e8
	star.mass = 1.989e30
	system.bodies.append(star)
	system.populations.append(population)
	return system


func _test_sol_authors_the_belt(h) -> void:
	var sol: StoichonSolarSystem = SOL
	h.check(sol != null, "the Sol system loads")
	if sol == null:
		return
	var belt := sol.population_by_id("population:main_belt")
	h.check(belt != null, "Sol authors the main belt")
	if belt == null:
		return
	h.check(belt.parent_id == "star:sol", "and it orbits the star")
	h.check_near(belt.semi_major_axis.x, 2.1 * AU, "its inner edge is 2.1 AU", 1.0e6)
	h.check_near(belt.semi_major_axis.y, 3.3 * AU, "its outer edge is 3.3 AU", 1.0e6)
	h.check(belt.density() > 0.0, "and it has a density")


## **A fragment is significant from the moment it exists** — it sets the local travel unit, so it has to
## be a scale body the ship's own proximity scan can see. It has no node at all, which is the half of
## `StoichonScaleBody` this adds.
func _test_a_fragment_is_significant(h) -> void:
	var rock := StoichonScaleBody.new(null, 5.0)
	rock.position = Vector3(1000.0, 0.0, 0.0)
	rock.name = "A-0007"
	h.check_near(rock.surface_distance_to(Vector3.ZERO), 995.0,
		"a scale body with no node answers its distance", 1.0e-6)
	h.check_near(rock.surface_distance_mesh(Vector3.ZERO), 995.0,
		"and its altitude, without a mesh to ask", 1.0e-6)

	# **A rock is solid**, so "dockable" means what it says: flying into one stops the ship at its surface.
	var heading := StoichonScaleBody.new(null, 14.0)
	heading.position = Vector3(100.0, 0.0, 0.0)
	var probe: Array[StoichonScaleBody] = [heading]
	h.check_near(StoichonProximity.nearest_surface_distance(Vector3(90.0, 0.0, 0.0), probe), 0.0,
		"inside a rock, the nearest surface is behind you", 1.0e-9)
	h.check_near(StoichonProximity.nearest_surface_distance(Vector3(120.0, 0.0, 0.0), probe), 6.0,
		"and outside it, the distance to its surface", 1.0e-9)

	var planet := StoichonScaleBody.new(null, 6.371e6)
	planet.position = Vector3(1.0e11, 0.0, 0.0)
	var bodies: Array[StoichonScaleBody] = [planet, rock]
	h.check(StoichonProximity.nearest_body(Vector3.ZERO, bodies) == rock,
		"the rock is nearest even though the planet is a place")
	h.check_near(StoichonProximity.nearest_surface_distance(Vector3.ZERO, bodies), 995.0,
		"and the nearest surface is the rock's", 1.0e-6)

	# **The unit is the rock's, not the planet's**, which is what makes full throttle drop as the belt is
	# entered rather than only once the ship is on top of something. 1e11 m to 995 m is eight orders.
	var band := Vector2(1.0, 1.0e11)
	var near_unit := StoichonTravelScale.local_length(995.0, band.x, band.y)
	var far_unit := StoichonTravelScale.local_length(1.0e11 - 6.371e6, band.x, band.y)
	h.check(near_unit < far_unit / 1.0e6,
		"the rock's unit is orders below the planet's (%s against %s)"
			% [String.num(near_unit), String.num(far_unit)])


func _belt_with_composition() -> StoichonPopulation:
	var belt := _belt()
	belt.composition = {"carbonaceous": 0.75, "iron": 0.08, "silicate": 0.17}
	return belt


## **A fragment is built by the builder the moons use, and it is a real body.** Evert, 2026-11-14: *"I was
## under the impression that asteroids would be created in the same way that other irregular bodies would
## be created, like the moons of mars."* So the claims are: the content it becomes is shaped like a moon's,
## it lands on the irregular builder rather than the planet one, and it is as lumpy as the taper allows.
func _test_a_fragment_is_an_irregular_body(h) -> void:
	var belt := _belt_with_composition()
	var content := StoichonFragmentBodies.content_for(belt, "A-0007", 17.0)
	h.check_near(content.radius, 8.5, "its radius is half the diameter", 1.0e-9)
	h.check(content.id == "A-0007", "its id is the designation — which is what seeds the shape")
	h.check(content.layers.size() == 1, "it has one layer, its bulk")
	if content.layers.size() == 1:
		h.check_near(float(content.layers[0].composition.get("carbonaceous", 0.0)), 0.75,
			"and that layer is what the population says it is made of", 1.0e-9)
		h.check_near(content.layers[0].radius, content.radius, "with its boundary the body's own", 1.0e-9)

	# **The builder is chosen by radius against the material's own rounding radius**, the same rule that
	# decides a moon — and a 17 m rock of this stuff is four orders of magnitude below it.
	var materials := StoichonMaterialTable.engine_table()
	var rounding := StoichonIrregularBody.rounding_radius(content, materials)
	h.check(rounding > 1.0e5, "carbonaceous rock rounds at %.0f km" % (rounding / 1.0e3))
	h.check(content.radius < rounding, "so a fragment goes to the irregular builder, not the planet one")

	# **At full lumpiness**: the taper is `1 - radius/rounding`, so a fragment is at the top of it.
	var body := StoichonSceneBody.from_content(content, materials)
	h.check_near(StoichonIrregularBody.irregularity(body, materials), 1.0,
		"and it is as irregular as the taper allows", 1.0e-4)

	# **The seed is the designation**, so the same rock is the same shape every time it is extracted, and two
	# fragments of one population are different rocks.
	h.check(hash("A-0007") != hash("A-0008"), "two designations seed two shapes")
## **Evert's flight, reproduced headlessly.** Fly from Phobos towards Jupiter: the ship slows down, *Closest*
## reads an asteroid, and **no asteroid markers appear**.
##
## Sol has 40 significant bodies — nine places at `PRIMARY` and thirty-one moons at `CONTEXT`, every one of
## them a candidate at any distance — so a 24-slot pool was filled before a fragment was ever considered.
## The gathering and the drawing were both right; the tier ordering was not. This builds the real scene, the
## real field and the real 40 candidates, so the next regression of it fails here rather than in flight.
func _test_the_belt_reaches_the_marker_pool(h, root: Node) -> void:
	var sol: StoichonSolarSystem = SOL
	var scene := StoichonSystemScene.from_content(sol)
	h.check(scene != null, "the Sol scene wraps the content")
	if scene == null:
		return
	scene.build(root)

	var belt := sol.population_by_id("population:main_belt")
	var ship := Vector3(2.5 * AU, 0.0, 0.0)
	# **The nearest few rocks of Sol's real belt**, which is what the game hands the managers each tick:
	# the same query, on the same content, at the same place.
	var belt_rocks := StoichonPopulationRocks.of(belt)
	var near: Array[int] = belt_rocks.nearest_n(ship, 4, 1.0e11)
	h.check(near.size() == 4, "four rocks are in reach at 2.5 AU (%d)" % near.size())

	var markers := StoichonMarkers.new()
	root.add_child(markers)
	markers.orbits = scene.orbit_parents()

	# **Rocks are nodes, exactly like the moons beside them**: the manager makes a body per rock, and the
	# marker path reads one list. This is the real route rather than a hand-built one.
	var bodies := StoichonFragmentBodies.new(belt, scene)
	root.add_child(bodies)
	var camera := Camera3D.new()
	root.add_child(camera)
	bodies.update(belt_rocks.pieces(Vector3.ZERO, near), ship, camera, _pixel(camera), false)
	var context: Array[Node3D] = scene.significant_nodes()
	var rock_nodes := {}
	for rock in bodies.rocks():
		if rock.node == null:
			continue
		context.append(rock.node)
		rock_nodes[rock.node] = true
	h.check(rock_nodes.size() == near.size(),
		"every rock the query chose is a body with a node (%d)" % rock_nodes.size())
	markers.context_targets = context
	markers.rocks = rock_nodes

	var gathered := markers._candidates(ship)
	h.check(gathered.size() > 24, "a whole system is more candidates than the pool holds (%d)" % gathered.size())

	var chosen := StoichonMarkers.choose(gathered, {
		StoichonMarkers.Priority.PRIMARY: 16,
		StoichonMarkers.Priority.CONTEXT: 24,
		StoichonMarkers.Priority.ASTEROID: 4,
	})
	var places := 0
	var moons := 0
	var rocks := 0
	for entry in chosen:
		match int(entry["priority"]):
			StoichonMarkers.Priority.PRIMARY:
				places += 1
			StoichonMarkers.Priority.CONTEXT:
				moons += 1
			StoichonMarkers.Priority.ASTEROID:
				rocks += 1
	h.check(places == 9, "all nine places are marked (%d)" % places)
	h.check(rocks > 0, "**the belt reaches the pool** (%d rocks)" % rocks)
	h.check(rocks == 4, "and the rocks spend their own budget, not the moons' (%d)" % rocks)
	h.check(moons > 0, "while the moons keep theirs (%d)" % moons)
	root.remove_child(bodies)
	bodies.free()
	root.remove_child(camera)
	camera.free()
	root.remove_child(markers)
	markers.free()


## **A rock is built by the scene's own body path**, so it is a body like a moon: same node, same frame,
## same dispatch, same builder. What this checks is the thing a class of its own got wrong — that nothing
## was re-implemented — and that the bodies come and go with the rocks the query offers.
func _test_a_fragment_becomes_a_body(h, root: Node) -> void:
	var sol: StoichonSolarSystem = SOL
	var scene := StoichonSystemScene.from_content(sol)
	scene.build(root)
	var belt := sol.population_by_id("population:main_belt")
	var rocks := StoichonPopulationRocks.of(belt)
	var bodies := StoichonFragmentBodies.new(belt, scene)
	root.add_child(bodies)
	var camera := Camera3D.new()
	root.add_child(camera)

	var ship := Vector3(2.5 * AU, 0.0, 0.0)
	var near: Array[int] = rocks.nearest_n(ship, 4, 1.0e11)
	bodies.update(rocks.pieces(Vector3.ZERO, near), ship, camera, _pixel(camera), false)
	h.check(bodies.count() == near.size(),
		"one body per rock the query offers (%d)" % bodies.count())

	# **Under the system frame, beside the planets** — not in a container of its own, where a frame
	# transform would apply to the bodies and not to the rocks.
	var found := 0
	for child in scene.system_frame.get_children():
		if String(child.name).begins_with("A-"):
			found += 1
	h.check(found == bodies.count(), "and they live in the system frame with the other bodies (%d)" % found)

	# **A rock gets the one frame a small body needs**, sized by itself: without it the ship is left on the
	# system frame's 10 km floor and cannot go slow enough to stop beside it.
	var rock: Node3D = null
	for child in scene.system_frame.get_children():
		if String(child.name).begins_with("A-"):
			rock = child
			break
	h.check(rock != null, "a fragment has a node in the system frame")
	if rock != null:
		var orbital: StoichonFrame = rock.get_node_or_null("Orbital")
		h.check(orbital != null, "and an orbital frame of its own")
		if orbital != null:
			h.check_near(orbital.travel_length_min, 100.0,
				"whose floor is the surface band's, so the throttle can crawl", 1.0e-9)
			h.check(orbital.kind == StoichonFrame.Kind.ORBITAL, "and it is an orbital frame")

	# **Not places**: nothing else in the engine may learn about them.
	var places := 0
	for node in scene.significant_nodes():
		if String(node.name).begins_with("A-"):
			places += 1
	h.check(places == 0, "so no marker or save sees one")

	# **A rock far from the eye is no longer offered**, and the bodies go with it — **and the frames with
	# those**, or the tree would accumulate a coordinate space per rock ever approached. A mile from the
	# belt the query returns nothing, which is the same condition the old field's drop stood for.
	var rules_before := scene.frame_tree._rules.size()
	var far := rocks.nearest_n(Vector3(AU, 0.0, 0.0), 4, 1.0e11)
	h.check(far.is_empty(), "a query from 1 AU offers no rock")
	bodies.update(rocks.pieces(Vector3.ZERO, far), Vector3(AU, 0.0, 0.0), camera, _pixel(camera), false)
	h.check(bodies.count() == 0, "and a body is freed when its rock is no longer offered")
	h.check(scene.frame_tree._rules.size() < rules_before, "and its frame's rules go with it")

	root.remove_child(bodies)
	bodies.free()
	root.remove_child(camera)
	camera.free()


## **The rocks are the population**, built once, and every one of them is where the band says it can be.
##
## Sol's belt is 1.1 million at or above 1 km, which is the count the floor buys — so this is also the check
## that the floor and the count are one number and not two.
func _test_the_rocks_are_the_population(h) -> void:
	var belt := _belt()
	belt.size_floor = belt.reference_size
	var started := Time.get_ticks_usec()
	var rocks := StoichonPopulationRocks.of(belt)
	var build_ms := float(Time.get_ticks_usec() - started) / 1000.0

	h.check(rocks.count() == belt.count,
		"one rock per object at or above the floor (%d rocks, built in %.0f ms)" % [rocks.count(), build_ms])
	h.check(build_ms < 20000.0, "and building a million of them is not a stall (%.0f ms)" % build_ms)

	# Every rock at or above the floor, and every one inside the band — sampled, because the whole set is a
	# million trigonometric tests.
	var step := maxi(1, rocks.count() / 500)
	var outside := 0
	var sampled := 0
	var smallest := INF
	var largest := 0.0
	for rock in range(0, rocks.count(), step):
		sampled += 1
		if not belt.contains( rocks.position_of(rock)):
			outside += 1
		smallest = minf(smallest, rocks.diameter_of(rock))
		largest = maxf(largest, rocks.diameter_of(rock))
	h.check(outside == 0, "every rock is inside the band's own test (%d of %d outside)" % [outside, sampled])
	h.check(smallest >= belt.reference_size, "none is smaller than the floor (%.0f m)" % smallest)
	h.check(largest <= belt.size_ceiling, "and none is over the ceiling (%.0f m)" % largest)

	# N(>D) ~ D^-2.5 anchored at 1 km: the median is 1.32 km, so most of the belt is barely over the floor.
	var median := rocks.diameter_of(rocks.count() / 2)
	h.check(median > 1000.0 and median < 3000.0, "most rocks are a kilometre or so across (median %.0f m)" % median)
	h.check(rocks.designation_of(0) == "A-000001", "and the first is named from its index")

	# The mean spacing at this floor is 4.9 million km, so the nearest rock to a point in the middle of the
	# belt is millions of kilometres away — not on top of the ship.
	var middle := Vector3(2.7 * AU, 0.0, 0.0)
	var nearest := rocks.nearest(middle)
	h.check(nearest >= 0, "a point in the belt has a nearest rock")
	if nearest >= 0:
		var away := middle.distance_to(rocks.position_of(nearest))
		h.check(away > 1.0e9 and away < 2.0e10,
			"millions of km away, as the density says (%.1f M km)" % (away / 1.0e9))


## **The belt slows the ship by its own sparseness** — the number the whole change is for.
##
## The unit is `nearest / 10 s`, so a real belt of a million kilometre-sized rocks puts the ship at about a
## tenth of light speed inside it, against the system frame's own ceiling of 33 c in the void. That is what
## makes a crossing a crossing rather than a crawl: **nine minutes for an AU**, where the invented fragments
## held the ship for hours.
func _test_the_belt_slows_the_ship_by_its_own_sparseness(h) -> void:
	var belt := _belt()
	belt.size_floor = belt.reference_size
	var rocks := StoichonPopulationRocks.of(belt)
	var middle := Vector3(2.7 * AU, 0.0, 0.0)
	var nearest := rocks.nearest(middle)
	h.check(nearest >= 0, "there is a rock in the middle of the belt")
	if nearest < 0:
		return
	var away := middle.distance_to(rocks.position_of(nearest))

	# The frame's own band, as the ship uses it: a floor, and the void ceiling. The unit is the neighbourhood;
	# **full throttle crosses it in `TRAVERSE_SECONDS`**, so the speed is the unit over ten.
	var speed := StoichonTravelScale.speed_for(1.0, away, 1.0, 1.0e11)
	var void_speed := StoichonTravelScale.speed_for(1.0, 1.0e11, 1.0, 1.0e11)
	h.check_near(speed, away / 10.0, "full throttle inside the belt is a tenth of the distance to the rock", 1.0)
	h.check(speed < void_speed / 10.0,
		"and ten times below the void's own speed (%s m/s against %s)" % [str(speed), str(void_speed)])
	var crossing := AU / speed / 60.0
	h.check(crossing > 1.0 and crossing < 60.0,
		"so an AU takes minutes to cross, not hours (%.1f minutes)" % crossing)


## **A rock is the same rock the next time the system loads.** The whole point of the change: coming back
## to a place gives the same rocks, where the old field invented a new set every time.
func _test_two_builds_give_the_same_rocks(h) -> void:
	var first := StoichonPopulationRocks.of(_small_band())
	var second := StoichonPopulationRocks.of(_small_band())
	h.check(first.count() == second.count(), "two builds hold the same number of rocks")
	var identical := true
	for rock in first.count():
		identical = identical and first.position_of(rock) == second.position_of(rock)
	h.check(identical, "at identical positions, to the last bit")

	# And a different seed is a different belt, or the seed is not doing anything.
	var other := _small_band()
	other.seed_value = 109
	var third := StoichonPopulationRocks.of(other)
	h.check(third.position_of(0) != first.position_of(0), "and another seed places different rocks")


## **The grid against a linear scan over every rock.** The index is the one piece of this that could be
## wrong without looking wrong — a missed cell is a nearest rock that is not the nearest — so it is checked
## against the answer that cannot be wrong, on a band small enough to scan outright.
func _test_the_index_answers_like_a_linear_scan(h) -> void:
	var band := _small_band()
	var rocks := StoichonPopulationRocks.of(band)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var mismatches := 0
	var single := 0
	for _query in 40:
		var local := _random_in_band(rng, band)
		var wanted := _linear_nearest(rocks, local, 5)
		var found := rocks.nearest_n(local, 5)
		if found.size() != wanted.size():
			mismatches += 1
			continue
		for at in found.size():
			# Distances, not indices: two rocks can be equally near and then either order is right.
			var a := local.distance_squared_to(rocks.position_of(found[at]))
			var b := local.distance_squared_to(rocks.position_of(wanted[at]))
			if not is_equal_approx(a, b):
				mismatches += 1
		var one: int = rocks.nearest(local)
		if found.is_empty() or one != found[0]:
			single += 1
	h.check(mismatches == 0, "the grid finds the same five rocks a linear scan does (%d wrong)" % mismatches)
	h.check(single == 0, "and nearest is nearest_n of one (%d wrong)" % single)


## **Outside the band there is nothing, and the query says so cheaply.** One AU from the Sun is Earth; a
## walk that refuses to stop would pay for the whole grid every tick.
func _test_far_outside_the_band_there_is_nothing(h) -> void:
	var rocks := StoichonPopulationRocks.of(_small_band())
	var started := Time.get_ticks_usec()
	var found := rocks.nearest(Vector3(AU, 0.0, 0.0), 1.0e9)
	var elapsed := float(Time.get_ticks_usec() - started)
	h.check(found == -1, "no rock within a reach that does not cover the belt")
	h.check(elapsed < 50000.0, "and the query gives up rather than walking the grid (%.2f ms)" % (elapsed / 1000.0))


## A thousand rocks in Sol's band — the real geometry, few enough to scan outright.
func _small_band() -> StoichonPopulation:
	var population := _belt()
	population.count = 1000
	population.size_floor = population.reference_size
	return population


func _random_in_band(rng: RandomNumberGenerator, band: StoichonPopulation) -> Vector3:
	var radius := rng.randf_range(band.semi_major_axis.x, band.semi_major_axis.y)
	var azimuth := rng.randf() * TAU
	var half := sin(deg_to_rad(band.inclination.y))
	var height := rng.randf_range(-half * radius, half * radius)
	var across := sqrt(maxf(0.0, radius * radius - height * height))
	return Vector3(across * cos(azimuth), across * sin(azimuth), height)


## The answer that cannot be wrong, written independently of the grid: sort every rock by its distance.
func _linear_nearest(rocks: StoichonPopulationRocks, local: Vector3, n: int) -> Array[int]:
	var pairs: Array = []
	for rock in rocks.count():
		pairs.append(Vector2(local.distance_squared_to(rocks.position_of(rock)), float(rock)))
	pairs.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var out: Array[int] = []
	for at in mini(n, pairs.size()):
		out.append(int(pairs[at].y))
	return out


## The camera's pixel angle, as `update_lod` computes it — the tests hand their own camera in, so they need the
## same number rather than a made-up one.
func _pixel(camera: Camera3D) -> float:
	var viewport := camera.get_viewport()
	if viewport == null:
		return 0.0
	return StoichonLod.pixel_angle(camera.fov, float(viewport.size.y))
