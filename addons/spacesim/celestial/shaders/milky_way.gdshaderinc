// The galactic band, as a function of the direction you look in — **one source, two consumers**.
//
// `celestial_sky.gdshader` calls it per pixel from `EYEDIR` at run time; `bake_band.gdshader` calls it from an
// equirectangular uv during a bake. Keeping the maths here is what makes a bake an *image of the same thing*
// rather than a second opinion that drifts: tune the band, re-bake, and the two cannot disagree.
//
// ------------------------------------------------------------------ WHAT A REAL MILKY WAY LOOKS LIKE
//
// Standing inside the disk it is three overlapping things, and they composite in this order:
//
//   1. **Dust, in front** — absorbing, cold, broken into filaments. The Great Rift, the Coalsack, the lanes between
//      the star clouds. It sits slightly off the midplane and reddens what survives it.
//   2. **Unresolved starlight, behind** — star clouds at several nested scales, thickest and brightest towards the
//      centre, thinning towards the anticentre.
//   3. **The core** near Sgr A* — warmer, much brighter per unit area, with its own dust in front of it.
//
// The frame: `u_galactic` takes a world direction to galactic coordinates, so `z` is the sine of galactic latitude
// and the angle in xy is longitude — zero at the centre, ±pi at the anticentre. Everything below is a function of
// those two numbers, so the band has no geometry, no radius and no resolution to lose.

const float PI_F = 3.14159265358979;

// ===== THE BAND'S SHAPE ============================================================================
const float BAND_THIN = 0.070;      // half-thickness in sine of latitude, away from the centre
const float BAND_THICK = 0.165;     // and towards it
const float BAND_TAPER = 0.45;      // how far the band thins towards the anticentre
const float DUST_TAU = 4.5;         // extinction through the densest dust
const float DUST_WIDTH = 0.055;
const float DUST_OFFSET = -0.022;   // the Great Rift is south of the midplane
const float CORE_WIDTH = 0.16;
const float CORE_THICK = 0.13;

float hash13(vec3 cell) {
	vec3 p = fract(cell * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

// Three-dimensional value noise. The argument is a *direction*, so the field has no seams and no poles — the same
// reason the band itself is a function of the direction rather than of a UV.
float value_noise(vec3 p) {
	vec3 cell = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n = 0.0;
	for (int c = 0; c < 8; c++) {
		vec3 corner = vec3(float(c & 1), float((c >> 1) & 1), float((c >> 2) & 1));
		vec3 weight = mix(1.0 - f, f, corner);
		n += hash13(cell + corner) * weight.x * weight.y * weight.z;
	}
	return n;
}

// Fractal sum. `octaves` is a loop bound, so it must be a constant expression at the call site.
float fbm(vec3 p, int octaves, float lacunarity) {
	float total = 0.0;
	float amplitude = 0.5;
	float norm = 0.0;
	for (int i = 0; i < 6; i++) {
		if (i >= octaves) {
			break;
		}
		total += amplitude * value_noise(p);
		norm += amplitude;
		p *= lacunarity;
		amplitude *= 0.5;
	}
	return total / max(norm, 1.0e-6);
}

// **The band's shape and colour, and nothing else**: a dimensionless linear RGB for a direction in the GALACTIC
// frame.
//
// It is deliberately not a radiance. The two consumers differ only in what they do with it — the sky multiplies it
// by the band's surface brightness, the display gain and the frame's currency; a bake writes it into a map — so
// keeping the currency out of here is what lets the same map serve a different gain without being baked again, and
// lets the compute baker compile this file as plain GLSL with no uniforms of its own.
//
// **RGB and not a luminance.** Collapsing this to one channel throws away the warm core, the cooler disk and the
// H II regions in one line, and no tint applied afterwards can put them back — they are different colours in the
// same frame.
vec3 band_shape(vec3 galactic_direction) {
	vec3 g = normalize(galactic_direction);
	float latitude = g.z;
	float longitude = atan(g.y, g.x);

	// How close to the galactic centre we are looking: 1 at the centre, 0 at the anticentre. The disk is brighter,
	// thicker and more structured there, and that asymmetry is most of what makes it look real.
	float towards_centre = exp(-pow(longitude / 1.15, 2.0));

	// ------------------------------------------------------------------ the starlight behind
	float thickness = mix(BAND_THIN, BAND_THICK, towards_centre) * (1.0 - BAND_TAPER * (1.0 - towards_centre));
	float band = exp(-pow(latitude / thickness, 2.0));

	// **Star clouds, at three scales**, each one warped by the one above it. That nesting is what gives the band its
	// clumpy, layered look instead of an even glow — the coarse field decides where the clouds are, the medium one
	// gives them a shape, the fine one gives them an edge.
	vec3 warp = g * 3.2 + vec3(11.7, 5.3, 9.1);
	float clouds = fbm(g * 7.0 + warp * 0.35, 4, 2.1);
	float clumps = fbm(g * 26.0, 3, 2.3);
	float grain = fbm(g * 90.0, 2, 2.4);
	float structure = clouds * 0.62 + clumps * 0.28 + grain * 0.10;
	// The turbulence modulates the band but never to nothing: even the gaps have light in them.
	float starlight = band * (0.30 + 1.55 * structure) * (0.22 + 1.9 * towards_centre);

	// ------------------------------------------------------------------ the core
	float core = exp(-pow(longitude / CORE_WIDTH, 2.0)) * exp(-pow(latitude / CORE_THICK, 2.0));
	core *= 0.55 + 0.9 * fbm(g * 16.0 + vec3(31.0, 7.0, 3.0), 3, 2.2);

	// ------------------------------------------------------------------ the dust, in front
	// Its own field, its own scale, and broken into filaments by a warped fbm rather than one smooth blob.
	vec3 dust_warp = vec3(
		fbm(g * 5.0 + vec3(1.0, 0.0, 0.0), 2, 2.0),
		fbm(g * 5.0 + vec3(0.0, 1.0, 0.0), 2, 2.0),
		fbm(g * 5.0 + vec3(0.0, 0.0, 1.0), 2, 2.0)
	);
	float dust_field = fbm(g * 13.0 + dust_warp * 1.6, 4, 2.35);
	// The lane: dense near the midplane (offset), and it widens where the dust field is strong.
	float lane = exp(-pow((latitude - DUST_OFFSET) / (DUST_WIDTH * (1.0 + 1.8 * dust_field)), 2.0));
	float tau = DUST_TAU * lane * smoothstep(0.34, 0.82, dust_field);
	float transmission = exp(-tau);
	// Dust reddens what survives it: blue is scattered out first.
	vec3 through = vec3(transmission * (1.0 - 0.35 * (1.0 - transmission)),
		transmission * 0.86,
		transmission * 0.68);
	through = max(through, vec3(1.0e-4));

	// ------------------------------------------------------------------ colour
	// The disk is slightly warm-neutral; the core is warmer; and HII regions sit *on* the band as small warm-pink
	// patches, which is what the eye picks out in a photograph of the Sagittarius arm.
	vec3 disk_colour = mix(vec3(0.80, 0.86, 1.00), vec3(1.00, 0.95, 0.86), towards_centre);
	vec3 core_colour = vec3(1.00, 0.88, 0.72);
	float hii = smoothstep(0.62, 0.86, clumps) * band * towards_centre;
	vec3 hii_colour = vec3(1.00, 0.42, 0.40);

	vec3 radiance = disk_colour * starlight * through
		+ core_colour * core * through
		+ hii_colour * hii * 0.35 * through;

	return radiance;
}
