# Underfoot — Full Build Directions

This document is the complete plan for building Underfoot from an empty folder to a shippable 1.0. Work through the phases in order. Each phase ends with **acceptance tests**: do not start the next phase until every box is ticked.

---

## 0. Ground rules

| Rule | Why |
|---|---|
| Godot 4.3+, GDScript, 2D only | Fast iteration, free, exports everywhere |
| Simulation is **data-oriented**: ants are rows in packed arrays, not nodes | 10,000 nodes will not hit 60 fps; packed arrays will |
| Fixed simulation tick: **20 Hz**, rendering interpolated at display rate | Deterministic, cheap, save-friendly |
| All tunable numbers live in `data/*.json` or `.tres` resources, never hard-coded | Balancing without recompiling logic |
| Seeded RNG everywhere (`RandomNumberGenerator` per system) | Reproducible bugs, seeded Endless Yard |
| One autoload per global concern, nothing else global | Keeps coupling visible |

### Performance budget (per 50 ms sim tick, mid-range laptop)

| System | Budget |
|---|---|
| Ant AI + movement (10k ants) | 12 ms |
| Pheromone diffusion/decay | 4 ms |
| Nest environment (air, water, heat) | 3 ms |
| Combat + creatures | 3 ms |
| Everything else | 3 ms |
| **Total** | **≤ 25 ms** (half the tick, leaving headroom) |

If the GDScript ant loop misses budget in Phase 2, move `AntSim` to a **GDExtension (C++)** or **compute shader**. The data layout below is designed so this swap does not touch other systems.

---

## 1. Project layout

```
Underfoot/
├── project.godot
├── README.md
├── BUILD.md
├── addons/                    # gut (tests) only
├── autoload/
│   ├── Game.gd                # state machine: menu, playing, paused
│   ├── Clock.gd               # sim tick, day/night, seasons
│   ├── Events.gd              # signal bus
│   ├── Save.gd                # save/load
│   └── Data.gd                # loads data/*.json at boot
├── sim/
│   ├── AntSim.gd              # packed-array ant simulation
│   ├── PheromoneField.gd      # surface + nest scent grids
│   ├── NestGrid.gd            # soil cells, tunnels, chambers
│   ├── NestEnvironment.gd     # air, moisture, temperature, mould
│   ├── SurfaceWorld.gd        # yard tiles, objects, food sources
│   ├── Colony.gd              # queen, brood, stores, castes, traits
│   ├── Creatures.gd           # spiders, beetles, birds, rivals
│   ├── Weather.gd             # rain, heat, sprinkler, mower
│   └── HouseAI.gd             # human escalation (Phase 8)
├── view/
│   ├── NestView.tscn/.gd      # side-on renderer
│   ├── SurfaceView.tscn/.gd   # top-down renderer
│   ├── AntRenderer.gd         # MultiMeshInstance2D batching
│   └── FX/                    # dust, rain, scent overlay shaders
├── ui/
│   ├── HUD.tscn
│   ├── CastePanel.tscn
│   ├── EvolutionTree.tscn
│   ├── FieldGuide.tscn
│   └── menus/
├── data/
│   ├── soils.json
│   ├── castes.json
│   ├── chambers.json
│   ├── foods.json
│   ├── creatures.json
│   ├── traits.json
│   ├── seasons.json
│   └── campaign/*.json
├── art/  audio/  shaders/
└── tests/
```

---

## 2. Core data model

### 2.1 Ants (structure-of-arrays in `AntSim`)

| Array | Type | Meaning |
|---|---|---|
| `pos` | `PackedVector2Array` | Position (world units, 1 unit = 1 mm) |
| `vel` | `PackedVector2Array` | Velocity |
| `layer` | `PackedByteArray` | 0 = nest, 1 = surface, 2 = house |
| `caste` | `PackedByteArray` | Index into `castes.json` |
| `state` | `PackedByteArray` | Idle, Wander, FollowTrail, Carry, Dig, Nurse, Fight, Flee, Dead |
| `carry` | `PackedByteArray` | Item type carried (0 = none) |
| `hp` | `PackedFloat32Array` | Health |
| `age` | `PackedFloat32Array` | Ticks alive; old ants die |
| `target` | `PackedInt32Array` | Cell or entity id |

Dead ants go on a free list and their slots are reused, so arrays never shrink mid-game.

### 2.2 Nest grid (`NestGrid`)

- 2D grid, **cell = 4 mm**, starting size 256 × 192, growing to 1024 × 512.
- Per-cell packed arrays: `soil_type`, `solidity` (0 = open … 255 = intact), `moisture`, `temperature`, `air`, `chamber_id`.
- Soil layers top to bottom: topsoil, loam, clay, sand lens, gravel, bedrock. Roots and stones are placed by seeded noise.

### 2.3 Surface (`SurfaceWorld`)

- Tile grid, **tile = 10 mm**, yard = 2000 × 1500 tiles (20 m × 15 m).
- Tile layers: ground (grass/dirt/paving/mulch), height, wetness, object id.
- Objects (gnome, BBQ, hose, shed, patio, house wall) are multi-tile entities with collision and climb rules.

### 2.4 Pheromones (`PheromoneField`)

- Separate grids per layer, at half resolution of the layer's cells.
- Channels: `FOOD`, `HOME`, `ALARM`, `EXPLORE`, `PLAYER` (the trail you paint).
- Each tick: deposit → diffuse (3×3 blur, tunable rate) → decay (multiply by `1 - decay`).
- Stored as `PackedFloat32Array`; diffusion runs on a shader if it goes over budget.

### 2.5 Colony (`Colony`)

```gdscript
var queen_alive: bool
var egg_rate: float           # eggs per in-game hour
var brood: Array[Dictionary]  # {stage, age, diet, chamber}
var stores: Dictionary        # {sugar, protein, seeds, fungus, water}
var caste_targets: Dictionary # player-set ratios
var traits: PackedStringArray # unlocked trait ids
var generation: int
```

---

## 3. Phases

### Phase 0 — Project skeleton (1–2 days)

**Build**
1. `git init`, Godot 4.3 project, 1280×720 base, `canvas_items` stretch mode, pixel-snap on.
2. Create the folder layout from §1 and the five autoloads (empty but loading).
3. `Clock`: 20 Hz fixed tick with `Events.tick(delta)` and `Events.hour_passed`.
4. `Data`: loads every `data/*.json` into dictionaries; errors loudly on bad JSON.
5. Install **GUT** and add one passing test.
6. Main scene with placeholder Nest and Surface views, **Tab** to toggle.

**Acceptance**
- [ ] `godot --headless --path . -s addons/gut/gut_cmdln.gd` passes.
- [ ] Tab switches views; the tick counter keeps running in both.

---

### Phase 1 — The Nest (1–2 weeks)

**Build**
1. `NestGrid` with procedural soil layers from `soils.json`:
   ```json
   {"loam": {"dig_time": 1.0, "collapse_chance": 0.002, "drains": 0.5, "color": "#6b4a2b"}}
   ```
2. `NestView`: draws the grid to an `Image` → `ImageTexture`, updating only dirty rectangles.
3. **Dig orders:** the player drags to mark cells; worker ants path to them, remove solidity over time and carry the spoil to the surface entrance (a mound grows).
4. **Pathfinding in tunnels:** flow-field from the entrance and from each chamber, rebuilt only when the grid changes (not A* per ant).
5. **Chambers:** the player paints an area and assigns a type from `chambers.json`: Queen, Nursery, Food Store, Water, Midden, Fungus Garden (later). Each has a minimum size and requirements.
6. **Queen + brood:** egg → larva → pupa → adult. Larvae need nurses and food; an unfed larva dies.
7. **Collapse:** unsupported spans wider than the soil limit can cave in, crushing ants. Roots and support pillars stop it.

**Acceptance**
- [ ] Start with queen + 5 workers; dig a 3-chamber nest; the queen lays and the first new workers hatch.
- [ ] A 12-cell-wide sand chamber collapses; the same span in clay holds.
- [ ] 500 ants in the nest at 60 fps.

---

### Phase 2 — Ant simulation at scale (1–2 weeks)

**Build**
1. `AntSim` with the arrays from §2.1 and a single `step(dt)` loop per tick.
2. **Spatial hash** (cell = 16 mm) rebuilt each tick for neighbour queries.
3. **Behaviour as a state machine** per ant, with transitions driven by sensing:
   - sample pheromone at 3 points (left/forward/right antennae), steer toward the strongest of the wanted channel;
   - random wander noise scaled by caste;
   - separation from neighbours so ants don't stack.
4. `AntRenderer`: one `MultiMeshInstance2D` per layer; per-instance transform + colour (caste tint, carry indicator). 2-frame leg animation in the shader using `INSTANCE_ID` offset.
5. LOD: when zoomed out beyond a threshold, render density blobs instead of individual ants.
6. Profile. If ant step > 12 ms at 10k, port `AntSim.step` to GDExtension (C++), keeping the same arrays.

**Acceptance**
- [ ] 10,000 ants wandering across both layers at 60 fps, sim tick ≤ 25 ms.
- [ ] Ants never pass through solid soil.
- [ ] Same seed + same inputs → identical ant positions after 10 minutes (determinism test in GUT).

---

### Phase 3 — Surface and pheromone foraging (2 weeks)

**Build**
1. `SurfaceWorld` generated from a hand-authored base yard (`data/campaign/yard_01.json`) plus seeded scatter: grass clumps, pebbles, leaves, flowers, dropped food.
2. `SurfaceView` with a zoomable camera (from ant level to the whole yard), scent overlay toggle (**P**).
3. **Food sources** from `foods.json`:
   ```json
   {"dropped_chip": {"type": "sugar", "amount": 400, "carry_per_ant": 2, "decays_hours": 48}}
   ```
4. **Foraging loop:** scouts wander laying `EXPLORE`; on finding food they return laying `FOOD`; workers follow `FOOD` out and `HOME` back.
5. **Player trail painting:** brush to add `PLAYER` scent (ants strongly prefer it), eraser to wipe scent, and an "avoid" brush that lays `ALARM`.
6. **Entrances** connect nest and surface; ants change layer at an entrance cell.
7. **Large items:** items heavier than one ant need several; ants cluster and drag together (summed force).

**Acceptance**
- [ ] With zero player input, the colony finds and harvests the nearest food within 3 in-game hours.
- [ ] Painting a trail around an obstacle reroutes traffic within 30 s.
- [ ] A dead beetle needs 8+ ants to move.

---

### Phase 4 — Castes, economy, HUD (1–2 weeks)

**Build**
1. `castes.json`:
   ```json
   {"worker":  {"hp": 10, "speed": 1.0, "carry": 1, "dig": 1.0, "attack": 1, "food_cost": 1},
    "soldier": {"hp": 30, "speed": 0.8, "carry": 1, "dig": 0.3, "attack": 6, "food_cost": 3},
    "scout":   {"hp": 6,  "speed": 1.6, "carry": 0, "dig": 0,   "attack": 1, "food_cost": 1, "sense": 2.0},
    "nurse":   {"hp": 8,  "speed": 0.9, "carry": 1, "dig": 0.2, "attack": 0, "food_cost": 1}}
   ```
2. **Caste panel:** sliders for target ratios; nurses feed larvae the matching diet (protein-heavy → soldiers).
3. **Upkeep:** each ant eats from stores every in-game day; starvation kills the oldest first.
4. **HUD:** population by caste, stores bars, day/season clock, alerts (flood, attack, starvation), minimap.
5. **Ant inspector:** click any ant to see its caste, age, state and what it is carrying. Follow-cam with **F**.

**Acceptance**
- [ ] Changing the caste ratio visibly changes the population mix within 2 in-game days.
- [ ] Cutting off food leads to deaths in a predictable order.

---

### Phase 5 — Nest environment (1–2 weeks)

**Build**
1. `NestEnvironment` cellular automaton running on open cells:
   - **Air:** diffuses from entrances and vent shafts; ants consume it; low air slows ants, very low kills.
   - **Moisture:** seeps down from the surface after rain; open cells flood if inflow > drainage.
   - **Temperature:** follows surface temperature with depth lag; brood develops fastest at 25–30 °C.
   - **Mould:** grows in warm, wet, airless chambers; spoils food stores and sickens brood.
2. Overlay modes (**1** air, **2** water, **3** heat, **4** mould).
3. **Builds:** vent shaft, drainage sump, thatch dome (insulation), clay seal (door).
4. Brood auto-moving: nurses carry brood to the chamber with the best temperature.

**Acceptance**
- [ ] A nest with no vents suffocates below depth X; adding one vent fixes it.
- [ ] Heavy rain floods a chamber without a sump; with one, it drains.

---

### Phase 6 — Threats, combat, weather (2–3 weeks)

**Build**
1. `creatures.json` entries with HP, speed, damage, behaviour script id, loot (protein amount):
   - **Wolf spider** (hunts lone ants), **ground beetle** (raids food), **bird** (swoops on open trails), **earthworm** (harmless, collapses tunnels), **aphids** (passive, farmable later).
2. **Combat:** grapple model. Ants latch on; each attached ant adds damage and slows the target; soldiers attach first. `ALARM` scent pulls nearby soldiers.
3. **Rival colony:** a second `Colony` + AI with the same rules (data-driven difficulty). Border wars over food sources; raids on your brood.
4. `Weather.gd` events from `seasons.json`: rain (washes scent, floods), heat wave (surface lethal at midday), sprinkler (scheduled daily flood zone), **lawnmower** (telegraphed sweeping line; anything on the surface in its path dies).
5. Telegraphing: every big event gets a 30-second warning with an on-map marker.

**Acceptance**
- [ ] 20 soldiers kill a spider; 20 workers mostly don't.
- [ ] Rain erases trails; ants re-establish them afterwards.
- [ ] The rival colony can win if ignored for 3 in-game weeks on Normal.

---

### Phase 7 — Seasons, evolution, satellite nests (2–3 weeks)

**Build**
1. **Year cycle** (each season = 7 in-game days, about 25 real minutes):
   - Spring: food boom, egg rate up.
   - Summer: heat waves, mower, rival aggression.
   - Autumn: seeds and fallen fruit; stockpile.
   - Winter: surface closed, ants cluster, stores drain, survive to spring.
2. **Nuptial flight** at the end of spring: spend stores to raise winged royals. Successful flights give **trait points** and can found **satellite nests** elsewhere in the yard (a new `NestGrid` instance linked by surface trails).
3. **Evolution tree** (`traits.json`), 5 branches × 8+ traits, e.g.:
   | Branch | Example traits |
   |---|---|
   | Jaws | Trap-jaw, Majors caste, Decapitate |
   | Chemistry | Formic spray, Long-lasting scent, Fear musk |
   | Agriculture | Aphid ranching, Leafcutter fungus, Seed granary |
   | Architecture | Clay masons, Living bridges, Deep shafts |
   | Swarm | Raft in floods, Army march, Hive mind (bigger scent radius) |
4. Traits modify data (multipliers) or unlock behaviours/chambers by id, never with special-case code scattered through systems.

**Acceptance**
- [ ] A full year can be survived on Normal with a sensible plan; winter kills an unprepared colony.
- [ ] Unlocking Aphid ranching makes aphids produce sugar when tended.
- [ ] A satellite nest runs its own brood and trades with the main nest along trails.

---

### Phase 8 — The House (3–4 weeks)

**Build**
1. Third layer `layer = 2`: house cross-section reachable through gaps in the back wall. Rooms: kitchen, pantry, wall cavities, under-floor, bathroom (water source).
2. **Crumbs economy:** rich food appears on a schedule (meals), at the price of exposure.
3. **The cat:** patrols, swats, sleeps in sunbeams (safe windows to cross).
4. `HouseAI` escalation meter driven by sightings of ants:
   | Level | Response |
   |---|---|
   | 1 | Wipes the counter (scent erased) |
   | 2 | Seals food in containers |
   | 3 | Bait traps (poison carried home harms brood) |
   | 4 | Spray (area damage, lingering) |
   | 5 | **The Exterminator** boss |
5. **Exterminator boss:** a multi-phase event across house and yard: fogging rooms, tracing trails back to the nest, digging. You win by surviving and keeping the queen alive, or by relocating her through a hidden satellite.

**Acceptance**
- [ ] Careful foraging keeps escalation low; greedy foraging triggers traps.
- [ ] The exterminator fight can be won and lost, and takes 10–20 minutes.

---

### Phase 9 — Content, modes, Field Guide (3–4 weeks)

**Build**
1. **Campaign:** 5 chapters as JSON scripts (objectives, unlocks, events):
   1. *First Burrow* (tutorial: dig, brood)
   2. *The Lawn* (foraging, trails)
   3. *War of the Gnome* (rival colony)
   4. *Year One* (seasons, evolution)
   5. *Indoors* (the house, exterminator)
2. **Sandbox:** all unlocks, sliders for threats and weather.
3. **Endless Yard:** seeded procedural yards, increasing difficulty per year, leaderboard of years survived (local).
4. **Field Guide:** 60+ entries unlocked on first encounter, with stats, a short funny description and a pixel portrait.
5. **Beetle mount:** befriend one rhinoceros beetle (feed it sugar 3 times), and your champion ant rides it to move huge loads and smash rivals.

**Acceptance**
- [ ] Campaign playable start to finish (target 12–20 hours).
- [ ] Endless Yard with the same seed generates the same yard.

---

### Phase 10 — Save/load, settings, polish (2 weeks)

**Build**
1. `Save.gd`: write all packed arrays + colony state to `user://saves/slot_N.ufs` (binary via `FileAccess.store_var` with `full_objects = false`, gzip). Autosave each in-game dawn. Version field + migration function.
2. Settings: resolution, UI scale, colour-blind scent palettes, sim speed (pause, 1×, 2×, 4×), key rebinding, audio buses.
3. **Audio:** layered ambient (soil creaks, rain, birds), dynamic music that intensifies with alarm scent, crunchy dig sounds.
4. **Juice:** dust puffs on dig, ripple on rain, screen shake on collapse, satisfying "chain" sound when a trail goes busy.
5. **Tutorial hints** that fire on first occurrence only.

**Acceptance**
- [ ] Save at 10k ants and load back with identical state (GUT hash test).
- [ ] A save from the previous version loads after a migration.

---

### Phase 11 — Art and audio production (in parallel from Phase 3)

| Asset | Spec |
|---|---|
| Ants | 16×16 px, 2-frame walk, per-caste sprite, tinted by shader |
| Creatures | 32–128 px, 4-frame walk + attack |
| Soil | 16 px tileable textures per soil type, edge blending shader |
| Surface | Painterly 2D top-down, 1 px = 1 mm at max zoom |
| House | Large cross-section illustrations, parallax background |
| UI | Clean, readable, earthy palette (soil browns, leaf greens, warning amber) |
| SFX | ~150 sounds; music: 3 ambient beds + 3 intensity layers per layer |

---

### Phase 12 — Release (1–2 weeks)

1. Export presets: Windows (x64), macOS (universal, notarised), Linux (x64), Web (demo: chapters 1–2).
2. CI (GitHub Actions): run GUT headless on every push; build exports on tags.
3. Store page, trailer (30 s: one ant → huge colony → exterminator), 6 screenshots.
4. Playtest round with 5–10 people; fix the top-10 issues.
5. Tag `v1.0.0`.

**Acceptance**
- [ ] Clean install on each platform runs from main menu to chapter 1 complete.
- [ ] No crash in a 4-hour soak test at 4× speed.

---

## 4. Testing strategy

| Type | What | When |
|---|---|---|
| Unit (GUT) | Pheromone decay, brood stages, collapse rules, trait modifiers | Every phase |
| Determinism | Seed + recorded inputs → hash of sim state | Phase 2 onward, every push |
| Performance | 10k-ant scripted scene, assert tick ≤ 25 ms | Phase 2 onward |
| Save round-trip | Save → load → identical hash | Phase 10 onward |
| Soak | 4 hours at 4× speed | Before each release |

Run headless tests with:

```bash
godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```

---

## 5. Timeline summary

| Phase | Content | Estimate |
|---|---|---|
| 0 | Skeleton | 2 days |
| 1 | Nest | 1–2 wk |
| 2 | Ant sim at scale | 1–2 wk |
| 3 | Surface + foraging | 2 wk |
| 4 | Castes, economy, HUD | 1–2 wk |
| 5 | Nest environment | 1–2 wk |
| 6 | Threats, combat, weather | 2–3 wk |
| 7 | Seasons, evolution, satellites | 2–3 wk |
| 8 | The House | 3–4 wk |
| 9 | Content + modes | 3–4 wk |
| 10 | Save, settings, polish | 2 wk |
| 12 | Release | 1–2 wk |
| **Total** | | **~5–7 months solo** |

**Playable prototype** = end of Phase 3 (about 5 weeks): dig, raise, forage on a lawn. Test fun here before going further.

---

## 6. Risks

| Risk | Mitigation |
|---|---|
| 10k ants too slow in GDScript | SoA layout from day one; GDExtension/compute fallback planned in Phase 2 |
| Pheromone control feels indirect or frustrating | Strong `PLAYER` channel, scent overlay, quick trail feedback; playtest at Phase 3 |
| Nest environment becomes busywork | Clear overlays, telegraphed problems, automation traits later |
| Scope creep in the House phase | The House is self-contained; ship chapters 1–4 first if needed |
