# Art direction — target look (from owner's reference image)

The reference: three fighters mid-exchange on a wooden coastal dojo deck at sunset,
arcade top-bar HUD. Steps 8 (HUD) and 11 (arena) build to this.

## Arena composition (camera faces roughly north; fight axis runs east-west)

- **Deck:** wide horizontal wooden planks, warm brown, subtle sheen from the low sun.
  Slightly weathered. Fight area is the open center.
- **Left/back-left:** open ocean with the low golden sun, bright specular path on the
  water, a few dark rock outcrops. Wooden railing with small stone lanterns along the
  deck's back edge.
- **Center-back:** layered hazy mountains against the sunset.
- **Right:** dojo building — dark timber, tiled roof visible top-right, weathered wall
  panels, one **large paper lantern with dark glyphs** hanging from the eave. A small
  group of **spectators in plain gis** stands at the far right edge of the deck.
- **Overhanging right + mid:** **red maple** canopy (deep red foliage), a couple of
  stone lanterns and low stone monuments mid-deck behind the fight line.
- **Banners:** tall vertical banners on poles behind the fight area — dark indigo
  cloth, abstract white glyph blocks (no real text).
- **Sky/grading:** dramatic sunset — gold/orange around the sun, heavy warm clouds
  above; strong warm rim-light on fighters from the sun side; AgX, high contrast,
  restrained glow.

## Fighters

- P1 / player: **red gi**, P2: **white gi**, P3: **indigo/navy gi** — all black belts,
  barefoot, dark hair. (FighterConfig gi_color values; belts stay dark.)

## HUD (adapt the arcade language to point-based first-to-6 scoring)

Top strip, three fighter panels + center timer:

- **Corner portraits:** small square portrait chips far left (P1) and far right (P3) —
  placeholder: gi-colored rounded rect with a lighter silhouette.
- **Per-fighter panel:** name tag ("P1"/"P2"/"P3") colored per gi (red/white/blue),
  score numerals right-aligned; below, a **big red segmented bar = score progress
  (6 segments, first to >= 6)**, with a thin white/blue secondary strip underneath
  (repurposed: flashes as the sudden-death indicator / round state).
- **Center:** "TIME" label above **large white outlined numerals** counting down 60.
- Player panel carries a small "YOU" tag; the player's current target's panel gets a
  subtle highlight ring (target_changed signal).
- Overlays (Ready/Fight!/Sudden Death/Winner) use the same big outlined-numeral style.
