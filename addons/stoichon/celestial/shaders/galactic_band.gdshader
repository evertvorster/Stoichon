shader_type spatial;
#include "res://addons/stoichon/render/radiance.gdshaderinc"
// Additive light: the band is a source seen through everything else, and the sphere is only a surface to
// compute on.
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled;
// The galactic band, drawn on the inside of a sphere that carries the camera.
//
// Every pixel asks one question: **which way in the galactic frame am I looking?** The band is a function of that
// direction — bright along the plane, thinning with latitude, brighter towards the centre than the anticentre,
// with structure along it — so it has no resolution of its own to lose. A camera that turns changes which
// directions are on screen and nothing else, so the structure slides across the frame instead of being
// resampled off a pixel grid.
//
// **The sphere is only a surface to compute on.** Its radius (100 m, around the dome) never reaches the maths:
// what the fragment stage uses is the direction from the centre to the point, which is the same at any radius.
//
// The band's own surface brightness is 2.9e-4 lux per steradian — about 21.5 magnitudes per square arcsecond,
// which is the measured figure — so this is a physical radiance in the frame's currency, lifted with everything
// else by `RADIANCE_GAIN`.

// A world direction to galactic coordinates: `z` is the north galactic pole, `x` the galactic centre. Built by
// the host from the published pole and centre — see `StoichonDeepSky.galactic_basis`.
uniform mat3 u_galactic = mat3(1.0);

// The band's own surface brightness, in lux per steradian.
uniform float u_band_radiance = 2.9e-4;
// **A display gain, and it is one.** The band's measured surface brightness is about 21.5 magnitudes per square
// arcsecond — some fifteen times dimmer per pixel than a barely-visible magnitude-6.5 star — so at the exposure a
// star field needs, the band is below the bottom of an eight-bit frame. This lifts it to where it can be seen;
// at 1.0 the layer is the physical one.
uniform float u_gain = 30.0;
uniform vec3 u_tint = vec3(0.86, 0.88, 1.0);

const float LUX_PER_ENGINE_UNIT = 100000.0 / 3.14159265358979;

varying vec3 v_direction;

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
	// the frame. A higher frequency here is a band that crawls with noise, which is the fault this whole layer
	// exists to avoid.
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

void vertex() {
	v_direction = VERTEX;
}

void fragment() {
	vec3 galactic = normalize(u_galactic * normalize(v_direction));

	// Latitude structure: a Gaussian in `sin(latitude)`, wider towards the centre of the galaxy.
	float centre = exp(-4.0 * pow(atan(galactic.y, galactic.x) / 3.14159265358979, 2.0));
	float width = mix(0.06, 0.20, centre);
	float band = exp(-pow(galactic.z / width, 2.0));
	float structure = noise_band(galactic);
	float dust = smoothstep(0.35, 0.75, noise_band(galactic + vec3(3.7, 1.1, 8.3)));

	float radiance = band * (0.35 + 0.65 * structure) * (0.25 + 1.75 * centre) * (1.0 - 0.55 * dust);
	ALBEDO = u_tint * radiance * (u_band_radiance * u_gain * RADIANCE_GAIN / LUX_PER_ENGINE_UNIT);
}
