shader_type sky;
// Layer 1: the empty background.
//
// **Nothing but black**, because interplanetary space has no ambient light and no scattered light: the only
// light in an empty direction is the stars in it, and the stars are drawn as objects rather than evaluated here.
//
// There *was* a procedural star field in this shader — the sphere cut into cells, each cell holding a hashed
// star, a pixel lit by its own cell's falloff. It is gone for the reason the cell search in the old sky shader is
// gone: **a per-pixel hash cannot be stable.** A pixel travels to a new direction every frame the camera moves,
// so the value under it is drawn afresh from the hash each frame, and a field of them crawls and flickers. It is
// the same fault as the lattice, seen from the other end: the pixel is the unit instead of the star.
//
// The faint field is a layer of sprites now — `Addons/spacesim/celestial` builds it below the catalogue's own
// depth, out of the same shader as the catalogue stars, so a faint star is snapped to a pixel and holds its
// light exactly as a bright one does.

void sky() {
	COLOR = vec3(0.0);
}
