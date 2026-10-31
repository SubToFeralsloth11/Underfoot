# 🐜 Underfoot

> One ant. One backyard. One day, the whole house.

**Underfoot** is a 2D colony-building strategy game. You wake up as a lone queen ant in an abandoned suburban backyard and grow a single burrow into a sprawling empire that eventually invades the house.

The yard is enormous at ant scale: the sprinkler is a flood, the barbecue is a volcano, the garden gnome is a mountain, and the cat is a god.

---

## The three views

| View | Perspective | What you do |
|---|---|---|
| **The Nest** | 2D side-on cross-section (ant-farm style) | Dig tunnels, paint chambers, raise brood, manage air, water, heat and mould |
| **The Surface** | 2D top-down, zoomable 20 m × 15 m lawn | Paint and erase scent trails, forage, fight, rally soldiers, found satellite nests |
| **The House** | 2D cross-section of kitchen, pantry, living room, bathroom, wall cavities | Raid crumbs without being seen; survive the cat and the Exterminator |

Press **Tab** to cycle views. Every view keeps simulating.

## How to play

- **Dig (W):** drag over soil to mark it; workers dig it out and carry the spoil to the mound. Shift-drag unmarks.
- **Chamber (R):** drag a rectangle and pick a type (Queen, Nursery, Food Store, Water, Midden, Sump, Fungus Garden). Solid cells inside are marked for digging.
- **Build (B):** vent shaft, drainage sump, clay seal door, support pillar, thatch dome (surface).
- **Trail (T) / Erase (Y) / Avoid (H):** paint scent on the surface or in the house. Ants follow pheromones, not orders.
- **Rally (K):** soldiers march to a point; rally onto the rival entrance to raid it. Right-click clears.
- **Castes (C):** set the target mix; nurses feed larvae the matching diet (protein makes soldiers).
- **Evolve (E):** spend trait points (nuptial flights, new years) across Jaws, Chemistry, Agriculture, Architecture, Swarm.
- **Field Guide (G):** 73 backyard species, unlocked on first encounter.
- Overlays: **P** scent, **1** air, **2** water, **3** heat, **4** mould. **F** follows the selected ant. **Space** pauses, **[ ]** change speed, **N** cycles nests, **F5/F9** quicksave/quickload, **Esc** menu. All keys can be rebound in Settings.

## Modes

- **Campaign:** five chapters — *First Burrow*, *The Lawn*, *War of the Gnome*, *Year One*, *Indoors*.
- **Sandbox:** everything unlocked, with sliders for the starting colony, threats, weather, rival and house.
- **Endless Yard:** seeded procedural yards that get harder every year, with a local leaderboard.

## Tech

- **Engine:** Godot 4.7, GDScript, 2D, GL Compatibility renderer.
- **Simulation:** fixed 20 Hz tick; render interpolation happens in the ant shader. Ants are rows in packed arrays (`sim/AntSim.gd`), one MultiMesh per view. Pheromones use lazy decay, so rain only changes a decay clock. Nest navigation uses flow fields, and every system has its own seeded RNG.
- **Data-driven:** every tunable lives in `data/*.json` (soils, castes, chambers, foods, creatures, traits, seasons, house, difficulty) or in `data/campaign/*.json` (chapters and yards).
- **Art:** all procedural. Ant sprites are a 16×16 two-frame atlas per caste, tinted in a shader. Creatures and portraits are vector-drawn from each species' `body` spec. Soil textures and edge blending come from `shaders/grid.gdshader`.
- **Audio:** 39 synthesized SFX and 13 music loops (`tools/gen_audio.py`). The music is a bed plus 3 intensity stems per layer, and the stems follow danger.

## Running

```bash
git clone https://github.com/SubToFeralsloth11/Underfoot.git
cd Underfoot
godot --path .                     # play
godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit   # tests
godot --headless --path . -s tools/perf.gd -- 10000 200                         # 10k-ant tick timing
```

Saves live in `user://saves/` (gzip `store_var`, versioned with migration). The game autosaves every in-game dawn.

## Docs

- **[BUILD.md](BUILD.md)** — the original phase-by-phase build plan and acceptance criteria.
- **[docs/STATUS.md](docs/STATUS.md)** — what is built, what each acceptance test measured, and known gaps.
