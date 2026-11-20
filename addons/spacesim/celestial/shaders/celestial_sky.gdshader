shader_type sky;
#include "res://addons/spacesim/render/radiance.gdshaderinc"
// Layer 1: the empty background and the galactic band.
//
// ------------------------------------------------------------------ WHY THE BAND IS HERE AND NOT ON A SPHERE
//
// The band is a **function of the direction you are looking in** — bright along the galactic plane, thinning with
// latitude, brighter towards the centre than the anticentre, with structure along it. A sky shader is handed
// exactly that direction, per pixel, for free (`EYEDIR`), and a sky is drawn behind all geometry by construction.
//
// It was a sphere mesh first, and it did not appear: this scene is 1.6e12 m across, and a 100 m sphere around the
// camera is not a thing the lens can be relied on to draw. There is no radius here at all, so there is nothing to
// be inside or outside of, nothing to clip against a near plane, and nothing to occlude.
//
// **Nothing else in here draws stars.** A procedural per-pixel star field was tried and removed: a pixel travels to
// a new direction every frame the camera moves, so the value under it is drawn afresh from the hash each frame and
// the field crawls. That is the same fault as the cell search this module replaced — the pixel as the unit
// instead of the star. The faint field is a sprite layer, one quad per star, snapped like any other.

// A world direction to galactic coordinates: `z` is the north galactic pole, `x` the galactic centre. Built by the
// host from the published pole and centre — see `SpacesimDeepSky.galactic_basis`.
uniform mat3 u_galactic = mat3(1.0);

// The band's own surface brightness, in lux per steradian: about 21.5 magnitudes per square arcsecond, which is
// the measured figure.
uniform float u_band_radiance = 2.9e-4;
// **A display gain, and it is one.** At 1.0 the band is the physical layer; at that level it is below the bottom
// of an eight-bit frame at the exposure a star field needs, because a surface that dim spread over the whole sky
// is not the same thing as a star.
uniform float u_gain = 30.0;
uniform vec3 u_tint = vec3(0.86, 0.88, 1.0);

const float LUX_PER_ENGINE_UNIT = 100000.0 / 3.14159265358979;

float hash13(vec3 cell) {
	vec3 p = fract(cell * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

// Value noise on the sphere, three octaves, evaluated on the direction so it has no seams at any angle.
float noise_band(vec3 direction) {
	float total = 0.0;
	float amplitude = 1.0;
	// **Low frequency on purpose.** The octaves reach a few cycles per radian, which at 720p and a wide field is
	// many pixels per cycle: structure that is visible and smooth enough that a turning camera slides it across
	// the frame. A higher frequency here is a band that crawls with noise, which is the fault this layer exists to
	// avoid.
	float scale = 2.0;
	for (int i = 0; i < 3; i++) {
		vec3 lattice = direction * scale;
		vec3 cell = floor(lattice);
		vec3 f = fract(lattice);
		f = f * f * (3.0 - 2.0 * f);
		float n = 0.0;
		for (int c = 0; c < 8; c++) {
			vec3 corner = vec3(float(c & 1), float((c >> 1) & 1), float((c >> 2) & 1));
			vec3 weight = mix(1.0 - f, f, corner);
			n += hash13(cell + corner) * weight.x * weight.y * weight.z;
		}
		total += n * amplitude;
		amplitude *= 0.5;
		scale *= 2.0;
	}
	return total;
}

void sky() {
	vec3 galactic = normalize(u_galactic * normalize(EYEDIR));

	// Latitude structure: a Gaussian in `sin(latitude)`, wider towards the centre of the galaxy.
	float centre = exp(-4.0 * pow(atan(galactic.y, galactic.x) / 3.14159265358979, 2.0));
	float width = mix(0.06, 0.20, centre);
	float band = exp(-pow(galactic.z / width, 2.0));
	float structure = noise_band(galactic);
	float dust = smoothstep(0.35, 0.75, noise_band(galactic + vec3(3.7, 1.1, 8.3)));

	float radiance = band * (0.35 + 0.65 * structure) * (0.25 + 1.75 * centre) * (1.0 - 0.55 * dust);
	COLOR = u_tint * radiance * (u_band_radiance * u_gain * RADIANCE_GAIN / LUX_PER_ENGINE_UNIT);
}
