// The extended objects, as a function of their own plane — **one source, two consumers**.
//
// `deep_sky_quad.gdshader` calls this per fragment for the real-time quad; `deep_sky_gpu.gd` calls it from a compute
// kernel to bake the same object into an atlas. Keeping the maths here is what makes a bake an *image of the same
// thing* rather than a second opinion that drifts.
//
// ------------------------------------------------------------------ WHAT THESE OBJECTS ARE
//
// Five classes, because they are not one kind of thing. The tints below are measured colours, not a palette: an
// old population is a warm G/K yellow, a young one is O/B blue-white, H-alpha at 656 nm is red, O III at 501 nm is
// teal-green, and scattering goes as 1/lambda^4 so a reflection nebula is blue.
//
//   spiral      a bulge of old stars, a disc, logarithmic arms, dust on the arms' inner edges, H II knots
//   irregular   a bar of old stars and the rest clumped into blue associations with pink knots
//   emission    GREEN inside (doubly ionised oxygen) and RED outside (hydrogen and [N II]), with a dust lane
//   reflection  blue, because the cloud scatters its cluster's light rather than emitting
//   globular    old, round, dense, warm
//
// `local` is the object's own plane, -1..1 across the major axis; `ratio` is minor/major, so the minor axis is
// divided out here and every caller sees the same ellipse. The value is dimensionless linear RGB, without the
// object's brightness — the currency is the caller's, which is what lets a baked atlas survive a change to the
// display gain.
float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(41.7, 289.3))) * 43758.5);
}

// Value noise on the object's own plane, so a galaxy's clumps are fixed in the galaxy and not in the screen.
float noise2(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash2(cell), hash2(cell + vec2(1.0, 0.0)), f.x),
		mix(hash2(cell + vec2(0.0, 1.0)), hash2(cell + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm2(vec2 p, int octaves) {
	float total = 0.0;
	float amplitude = 0.5;
	float norm = 0.0;
	for (int i = 0; i < 5; i++) {
		if (i >= octaves) {
			break;
		}
		total += amplitude * noise2(p);
		norm += amplitude;
		p *= 2.07;
		amplitude *= 0.5;
	}
	return total / max(norm, 1.0e-6);
}

vec3 object_emission(vec2 local_in, float ratio, float profile) {
	vec2 local = vec2(local_in.x, local_in.y / max(ratio, 1.0e-4));
	float radius = length(local);
	float angle = atan(local.y, local.x);
	// **The ellipse's edge, faded over the outer 40 % of the object.** An exponential profile has not reached zero
	// where the ellipse ends — `exp(-3)` is still five percent — so a narrow window there drew a rim around every
	// object, and against a star field a rim reads as a cut-out. Evert, 2026-11-21: *"their edges are a little too
	// sharply defined"*. The galaxies and nebulae in a photograph simply fade into the sky.
	float coverage = 1.0 - smoothstep(0.60, 1.0, radius);
	vec3 WARM_CORE = vec3(1.00, 0.86, 0.64);   // G and K stars, an old population
	vec3 YOUNG_BLUE = vec3(0.62, 0.78, 1.00);  // O and B stars, hot and short-lived
	vec3 HII_PINK = vec3(1.00, 0.42, 0.42);    // H-alpha + [N II]
	vec3 OIII_TEAL = vec3(0.30, 1.00, 0.80);   // doubly ionised oxygen, the inner part of an H II region
	vec3 DUST = vec3(0.35, 0.30, 0.28);

	vec3 emission = vec3(0.0);
	if (profile < 0.5) {
		// ---- an inclined spiral: bulge, disc, logarithmic arms, dust on their inner edges, sparse H II knots
		float bulge = exp(-pow(radius / 0.22, 2.0) * 3.2);
		// A log spiral in the object's own plane: the arm radius grows with the wound angle, so the arms wind.
		float wound = angle * 9.0 + log(max(radius, 1.0e-3)) * 5.5;
		float arm = pow(0.5 + 0.5 * cos(wound), 3.0);
		float arms = arm * exp(-radius / 0.55) * (1.0 - bulge);
		// Dust follows each arm's inner edge: the same spiral, offset half an arm-width in angle.
		float lane = pow(0.5 + 0.5 * cos(wound + 0.55), 6.0) * exp(-radius / 0.5);
		float knots = smoothstep(0.72, 0.95, fbm2(local * 9.0, 3)) * arm;
		emission = WARM_CORE * bulge
			+ YOUNG_BLUE * arms
			+ HII_PINK * knots * 0.45;
		emission *= 1.0 - 0.55 * lane;
	} else if (profile < 1.5) {
		// ---- an irregular: a bar of old stars, and the rest clumped into blue associations with pink knots
		float bar = exp(-pow(length(vec2(local.x / 0.75, local.y / 0.16)), 2.0) * 2.5);
		float clumps = fbm2(local * 5.5 + vec2(17.3, 4.1), 4);
		float knots = smoothstep(0.60, 0.85, fbm2(local * 13.0 + vec2(3.7, 9.2), 3));
		emission = WARM_CORE * bar * 0.8
			+ YOUNG_BLUE * clumps * (1.0 - bar) * 1.4
			+ HII_PINK * knots * 0.55;
	} else if (profile < 2.5) {
		// ---- an emission nebula. **Green inside, red outside** — that is not a palette either: the core is hot
		// enough to doubly ionise oxygen, which emits at 501 nm, while the cooler outskirts are dominated by
		// hydrogen's 656 nm line and [N II]. The dust lane across the middle is the one that separates M42 from M43.
		float inner = exp(-pow(radius / 0.34, 2.0) * 2.2);
		float outer = exp(-pow(radius / 0.90, 2.0) * 1.6);
		float filaments = 0.65 + 0.7 * fbm2(local * 7.0 + vec2(5.1, 2.3), 4);
		float lane = exp(-pow((local.y - 0.18 * local.x) / 0.13, 2.0)) * smoothstep(0.15, 0.9, radius);
		emission = OIII_TEAL * inner * filaments + HII_PINK * outer * filaments * 0.8;
		emission *= 1.0 - 0.75 * lane;
		// The Trapezium, at the centre: the hot cluster that lights the whole thing.
		float trapezium = smoothstep(0.10, 0.0, radius);
		emission += vec3(0.85, 0.92, 1.00) * trapezium * 2.0;
	} else if (profile < 3.5) {
		// ---- a reflection nebula: **blue**, because the cloud is scattering starlight rather than emitting, and
		// scattering goes as 1/lambda^4. The Pleiades are an open cluster first and a nebula second: the stars
		// themselves are the brightest thing in it.
		float halo = exp(-pow(radius / 0.62, 2.0) * 2.0) * (0.55 + 0.6 * fbm2(local * 6.0, 3));
		emission = YOUNG_BLUE * halo * 0.8;
		// A handful of unresolved cluster members, in fixed places in the object.
		for (int i = 0; i < 6; i++) {
			vec2 seat = (vec2(hash2(vec2(float(i), 3.1)), hash2(vec2(float(i), 8.6))) - 0.5) * 1.2;
			float d = length(local - seat);
			emission += vec3(0.80, 0.90, 1.00) * exp(-pow(d / 0.10, 2.0) * 4.0) * 1.6;
		}
	} else {
		// ---- a globular cluster: old, round and dense, with a core that is a swarm rather than a point.
		float mass = exp(-pow(radius / 0.30, 2.0) * 3.0) + exp(-radius / 0.55) * 0.35;
		float grain = 0.75 + 0.5 * fbm2(local * 22.0, 2);
		emission = WARM_CORE * mass * grain;
	}
	return emission * coverage;
}
