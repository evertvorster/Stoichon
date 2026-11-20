shader_type sky;
#include "res://addons/spacesim/render/radiance.gdshaderinc"
#include "res://addons/spacesim/celestial/shaders/milky_way.gdshaderinc"
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

// **The baked band, if the host made one.** An equirectangular map of the band's shape and colour in the galactic
// frame — see `SpacesimBandGpu` — sampled here instead of evaluating the maths. The bake is the same function, so
// the picture is the same picture; what changes is where the work happened.
uniform sampler2D u_band_map : filter_linear_mipmap;
uniform bool u_use_baked = false;

const float LUX_PER_ENGINE_UNIT = 100000.0 / 3.14159265358979;

void sky() {
	// The band is defined in galactic coordinates, so the rotation happens here, once, and the shape function stays
	// a function of the galactic direction alone.
	vec3 galactic = normalize(u_galactic * normalize(EYEDIR));
	vec3 shape = band_shape(galactic);
	if (u_use_baked) {
		// The map's own convention, the inverse of the bake's: longitude across, latitude up.
		float longitude = atan(galactic.y, galactic.x);
		float latitude = asin(clamp(galactic.z, -1.0, 1.0));
		vec2 uv = vec2(longitude / (2.0 * PI_F) + 0.5, latitude / PI_F + 0.5);
		shape = texture(u_band_map, uv).rgb;
	}
	COLOR = shape * (u_band_radiance * u_gain * RADIANCE_GAIN / LUX_PER_ENGINE_UNIT);
}
