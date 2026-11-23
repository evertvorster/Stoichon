# SpaceSim — agent notes

Supplement to `~/.pi/agent/AGENTS.md`, which applies here in full. **This file is short on purpose**: the
maps it points at are the documentation, and a second copy of them is how both go stale.

## Read these first

| | |
|---|---|
| `~/.pi/agent/skills/spacesim/SKILL.md` | **the process map** — the two trees, the toolchain, the working rhythm, which skills to load and when, the traps. Load it whenever work here starts. |
| `~/Insync/evorster@gmail.com/Google Drive/Notes/Projects/Programming/SpaceSim/Where to read.md` | **the subject map** — one row per subsystem: the document that governs it, the code it lives in, the tests that hold it. Open it before touching a subsystem you have not touched this session. |
| `docs/API.md` | what the engine exposes, as it is implemented. **Updated in the same commit as an interface change.** |

## The rules that bite here

- **SpaceSim is the engine; Cladogenesis is one story on it.** Capabilities live in `addons/spacesim/`, game
  code in `game/`, content in `systems/*.tres`. A system file must not require an engine change.
- **Derive, don't author.** A body's mass, air, temperature, albedo and terrain all come out of what it is
  made of. A constant that is neither derived nor measured is marked `A GUESS:` with what would settle it;
  the register is `grep -rn "A GUESS:" addons/`.
- **A shader cannot disagree with the model.** Everything a shader is given comes from the derivation, so a
  number typed into a shader is a second source for something that already has one.
- **Design, plans and bug write-ups go to the vault, never this repo.** The repo documents only what exists.
- **Tests:** `tests/run.sh` is the suite (headless, minutes — never into a pipe). Headless Godot compiles no
  shaders: `tests/shader_check.sh` does. Read the `godot` skill's `references/verification.md` before
  **writing** a test; running the suite needs no refresher.
- **A probe is a one-shot instrument.** Diagnostic code in the tree is removed once the run that justified it
  is over, not left behind for the next session to read past.
- **One logical change per commit**, and the message says why the change happened, not what it contains.
- **The engine is the double-precision build**: `/usr/bin/godot-double-mono`. A float build gives wrong
  numbers at AU scale, and the error looks like a design fault.

## Skills

`ponytail` before writing or reviewing code · `godot` for anything Godot, including before touching a
`.tscn`/`.tres` or writing a test · `shaders` before touching a shader · `obsidian-vault` before writing
anything in the vault · `mempalace-memory` before filing or searching memory.
