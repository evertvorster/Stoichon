shader_type sky;
#include "res://addons/spacesim/render/radiance.gdshaderinc"
// Layer 1: the galactic band, and the empty background behind it.
//
// ------------------------------------------------------------------ WHAT A REAL MILKY WAY LOOKS LIKE
//
// Standing inside the disk, the Milky Way is three overlapping things, and they must be composited in this order:
//
//   1. **Dust, in front.** Not a notch cut out of the light — absorbing, cold, and broken into filaments. This is
//      the feature that makes the band recognisable: the Great Rift, the Coalsack, the lanes between the star
//      clouds. It sits slightly off the midplane and reddens what is behind it.
//   2. **Unresolved starlight, behind.** Many overlapping star clouds at several scales, thickest and brightest
//      towards the centre, thinning and fading towards the anticentre.
//   3. **The core.** The bulge, near Sgr A*, warmer and much brighter per unit area than the disk, with its own
//      dust in front of it.
//
// A single smooth band with a noise mask subtracted — which is what was here — reads as a featureless smear,
// because everything above is a *scale* question: the structure lives at octaves that a two-octave field does not
// have.
//
// ------------------------------------------------------------------ THE FRAME
//
// `u_galactic` takes a world direction to galactic coordinates: `z` is the north galactic pole, `x` the direction
// of the galactic centre. So `z` is the sine of galactic latitude, and the angle in the xy plane is longitude,
// zero at the centre and ±pi at the anticentre. Everything below is a function of those two numbers, so the band
// has no geometry, no radius and no resolution to lose.

uniform mat3 u_galactic = mat3(1.0);

// The band's surface brightness at the centre, in lux per steradian. About 21.5 magnitudes per square arcsecond is
// the measured figure for the bright band.
uniform float u_band_radiance = 2.9e-4;
// **A display gain, and it is one.** At 1.0 this is the physical layer, which is below the bottom of an eight-bit
// frame at the exposure a star field needs: a surface that dim, spread over the whole sky, is not the same thing
// as a star.
uniform float u_gain = 30.0;

const float LUX_PER_ENGINE_UNIT = 100000.0 / 3.14159265358979;
const float PI_F = 3.14159265358979;

// ===== THE BAND'S OWN SHAPE ========================================================================
// Half-thickness of the bright band, in sine of latitude: the disk is thicker towards the centre.
const float BAND_THIN = 0.070;
const float BAND_THICK = 0.165;
// How far the band thins out towards the anticentre.
const float BAND_TAPER = 0.45;
// How opaque the dust gets, and the widths of its dense core and its outer falloff.
const float DUST_TAU = 4.5;
const float DUST_WIDTH = 0.055;
// The dust lane sits just south of the midplane near the centre — the Great Rift is not centred on the plane.
const float DUST_OFFSET = -0.022;
// The core's angular size along the band and across it.
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

void sky() {
	vec3 g = normalize(u_galactic * normalize(EYEDIR));
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

	COLOR = radiance * (u_band_radiance * u_gain * RADIANCE_GAIN / LUX_PER_ENGINE_UNIT);
}
