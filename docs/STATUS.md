# Underfoot — build status (v1.0.0)

This file covers every BUILD.md phase: what was built, how each acceptance criterion was checked, and what is still open. The GUT suite is `tests/` (57 tests, about 2 minutes headless):

```bash
godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```

## Phases

| Phase | Built | Acceptance (measured) |
|---|---|---|
| 0 Skeleton | 8 autoloads: Events, Data, Settings, Clock, Game, Save, Audio, Profile. 20 Hz Clock, Data loader with loud errors, GUT, Main scene with Tab view switching | Suite passes; every data table loads with no errors |
| 1 Nest | `NestGrid` with procedural soil layers (sand lenses, stones, roots), dig orders, flow fields, chambers, queen and brood, span-based collapse | Queen + 5 workers dig 3 chambers by about hour 15, first hatch at hour 53. A 12-wide sand chamber collapses and clay holds. 500 nest ants ≈ 1 ms/tick |
| 2 Ants at scale | Structure-of-arrays `AntSim`, spatial hash, state machine with 3-antenna steering, MultiMesh renderer with shader interpolation, LOD density map when zoomed out | 10k ants ≈ 21–24 ms/tick in the test (budget 25 ms). No ant inside solid soil over 80k ant-ticks. Identical hash after 12,000 ticks with the same seed |
| 3 Surface + foraging | 20 m × 15 m yard from the yard JSON plus seeded scatter, lazy-decay pheromone grid, foraging loop, paint/erase/avoid brushes, house gaps, multi-ant hauling | Zero-input colony harvests 1.7–2.0 in-game h after foragers leave. A painted detour gives 12 ants reaching the food vs 0 without it. Dead beetle: 0 mm moved with 7 haulers, 140 mm with 8 |
| 4 Castes + economy | 6 producible castes (plus queen and royal), diet-based caste choice, daily upkeep with oldest-first starvation, HUD, caste panel, inspector, follow-cam | Slider change makes the brood in progress all soldiers by day 2; adults hatch by day 3 (see gaps). Food cut-off kills the oldest first |
| 5 Environment | Air / moisture / temperature / mould automaton, overlays 1–4, vent, sump, thatch, clay seal, pillar | Chamber air at depth 50: 6 with no vent (lethal), 109 with one vent. Rain floods a chamber without a sump; with one it stays dry |
| 6 Threats | 73 species: hunters, raiders, birds, worms, aphids, ambient critters, mount. Grapple combat, rival colony AI with raids, rain, heat wave, sprinkler, mower, 30 s telegraphs | 20 soldiers kill the spider 6/6, 20 workers 0/6. Trails 45 → 7 cells in rain → 46 afterwards. An ignored rival kills the queen on day 8 |
| 7 Seasons + evolution | 4 seasons × 7 days, winter closes the surface, nuptial flights, satellite nests with trade, 44 traits in 5 branches | Winter: unprepared colony 0 ants, stocked colony 20. Aphid ranching produces honeydew only when tended. Satellite lays eggs, hatches and receives trade |
| 8 House | Cross-section house, meal crumbs, cat with sleep windows, homeowner schedule, escalation 1–5 (wipe, seal, bait, spray), 3-phase Exterminator, queen relocation | Greedy foraging reaches level 3 and baits; quiet foraging stays at 0. Exterminator lasts 15.5 min, can be lost (queen dug out) and won (hidden or relocated queen) |
| 9 Content | 5 campaign chapters, Sandbox, seeded Endless Yard with leaderboard, Field Guide, rhino beetle mount | All chapters set up and evaluate. The same seed gives the same Endless yard |
| 10 Save + polish | Gzip `store_var` saves, autosave at dawn, v1→v2 migration, settings (resolution, UI scale, colour-blind palette, speed, buses, rebinding), dynamic music, dust, rain ripples, collapse shake, trail chime, one-shot hints | 10k-ant save → load gives an identical hash and identical playback. A v1 save migrates with matching ants and pheromones |
| 11 Art + audio | Procedural ant atlas, vector creatures and portraits, soil/ground shaders, 39 SFX + 13 music loops | Visual smoke via `tools/capture.gd` (see `docs/screenshots/`) |
| 12 Release | Export presets (Windows, macOS universal, Linux, Web demo with chapters 1–2), GitHub Actions CI, store copy (`docs/STORE.md`), 30 s trailer (`docs/trailer.mp4`), 6+ screenshots | Windows, Linux, Web and macOS exports built locally; the macOS build boots headless to the menu with no data errors. Soak: see below |

## Measured performance
- `tools/perf.gd -- 10000 300 mix` (10,000 ants, half nest, half surface, full world tick) on an Apple A18 Pro laptop at load average about 3: **25.4 ms average, 71 ms worst**, ant step alone 21.8 ms. The suite's mostly-surface 10k test measures 21–24 ms. That puts the total tick right at BUILD.md's 25 ms budget, and the ant step is well over its 12 ms sub-budget. BUILD.md's fallback (a GDExtension/C++ `AntSim`) was **not** done. The packed-array layout is ready for it.

## Known gaps / deviations
- **Grid resolution:** the surface grid is 25 mm, not the 10 mm tiles in BUILD.md §2.3. At 10 mm the yard would need about 30 M cells of pheromones in GDScript. Ground type and collision use the same 25 mm grid.
- **Pheromone diffusion:** happens on deposit (a neighbour spread at the `diffuse` rate) instead of a per-tick blur pass. Decay is exact (lazy, with a decay clock).
- **Caste ratio "within 2 days":** a full brood cycle takes about 2.5 days in spring temperatures. The panel shows the brood in progress switching by day 2; adults follow by day 3.
- **Not automated:** "survive a full year with a sensible plan", the 12–20 h campaign length, the 4-hour soak (a shorter soak was run), and playtesting with 5–10 people.
- **Art:** procedural, not hand-painted. Creatures are vector-drawn with leg animation and an attack lunge rather than 4-frame sprite sheets.
- **macOS export:** ad-hoc signed and not notarised (needs an Apple Developer account).
