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
// **How much longer the structure is along the band than across it.** This is the number that separates filaments
// from smoke: the noise is sampled from a direction whose latitude axis is stretched, so a feature spans several
// times more longitude than latitude. Isotropic noise on the direction — what this was — gives round clouds, and no
// amount of colour tuning makes round clouds look like a galaxy.
const float STRUCTURE_STRETCH = 7.0;
// Where the arc fades: present through the middle, gone towards the anticentre, in degrees from the centre.
const float ARC_FADE_START = 115.0;
const float ARC_FADE_END = 155.0;
// Opaque dust is not a hole. It reads as very dark brown, so the composite is an "over" of that colour rather than
// a multiply down to black — and extinction is chromatic, eating blue first.
const vec3 DUST_COLOUR = vec3(0.055, 0.030, 0.016);
const vec3 DUST_ABSORPTION = vec3(0.60, 0.82, 1.10);

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

	// **Band coordinates, from the frame itself.** In galactic coordinates `z` is the sine of latitude and the
	// angle in the xy plane is longitude, zero at the centre and ±pi at the anticentre — so the band's own
	// coordinate system costs two lines rather than a pair of built basis vectors.
	float latitude = g.z;
	float along = degrees(atan(g.y, g.x));
	float towards_centre = exp(-pow(along / 66.0, 2.0));
	// The arc: present through the middle, gone towards the anticentre.
	float present = 1.0 - smoothstep(ARC_FADE_START, ARC_FADE_END, abs(along));

	// ------------------------------------------------------------------ the starlight behind
	float thickness = mix(BAND_THIN, BAND_THICK, towards_centre) * (1.0 - BAND_TAPER * (1.0 - towards_centre));
	float band = exp(-pow(latitude / thickness, 2.0)) * present;

	// **Anisotropic turbulence.** The sample point has its latitude axis stretched, so the field varies slowly along
	// the band and quickly across it: filaments that run *with* the plane, which is what a galaxy's structure is.
	// Sampling the direction isotropically gave round clouds, and no palette makes round clouds look like this.
	vec3 q = vec3(g.x, g.y, g.z * STRUCTURE_STRETCH);
	float clouds = fbm(q * 7.0, 4, 2.1);
	float clumps = fbm(q * 26.0, 3, 2.3);
	float n = smoothstep(0.30, 0.78, clouds * 0.62 + clumps * 0.38);
	// Knots: a thresholded fine field, so the band has bright star clouds *on* it rather than only gaps in it.
	float knots = smoothstep(0.62, 0.95, fbm(q * 70.0, 3, 2.4));
	float starlight = band * (0.18 + 1.55 * n + 1.10 * knots) * (0.25 + 1.8 * towards_centre);

	// ------------------------------------------------------------------ the core
	// The angle from the galactic centre, in degrees — a round bulge, not a band profile.
	float core_angle = degrees(acos(clamp(dot(g, vec3(1.0, 0.0, 0.0)), -1.0, 1.0)));
	float core = exp(-pow(core_angle / 9.0, 2.0));
	core *= mix(0.35, 1.0, n);   // the bulge has its own dust across it

	// ------------------------------------------------------------------ the dust, in front
	// Its own field, at its own scale and its own stretch, so the lanes do not line up with the bright band's gaps.
	vec3 qd = vec3(g.x, g.y, g.z * (STRUCTURE_STRETCH * 0.7));
	float dust_broad = fbm(qd * 12.0 + vec3(31.0, 17.0, 5.0), 4, 2.35);
	float dust_fine = fbm(qd * 40.0 + vec3(7.0, 23.0, 11.0), 3, 2.5);
	float dust_field = mix(dust_broad, dust_fine, 0.4);
	float lane = exp(-pow((latitude - DUST_OFFSET) / (DUST_WIDTH * (1.0 + 2.6 * dust_field)), 2.0));
	float dark = lane * present * (0.45 + 1.30 * smoothstep(0.25, 0.75, dust_field));

	// **Chromatic extinction, and an over-composite.** Dust eats blue first; where it is thick the result is a very
	// dark brown, not a hole in the sky, so the composite is `mix(dust, light_behind, T)`.
	vec3 transmission = exp(-DUST_ABSORPTION * DUST_TAU * dark);

	// ------------------------------------------------------------------ colour
	// The disk's integrated light is warm — G and K giants carry most of it — with young associations a little blue
	// and H II regions pink on the band.
	vec3 disk_colour = mix(vec3(0.90, 0.92, 1.00), vec3(1.00, 0.93, 0.84), towards_centre);
	vec3 young = vec3(0.70, 0.84, 1.00);
	vec3 light = disk_colour * starlight;
	light = mix(light, young * starlight, smoothstep(0.55, 0.90, knots) * 0.55);
	light += vec3(1.00, 0.90, 0.72) * core * 1.35;
	light += vec3(1.00, 0.42, 0.40) * smoothstep(0.70, 0.95, knots) * band * towards_centre * 0.35;

	return mix(DUST_COLOUR, light, transmission);
}
