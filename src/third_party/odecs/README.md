# odecs (vendored)

An archetype ECS for Odin by Nate Martin.

- Upstream: https://github.com/NateTheGreatt/odecs
- Commit: e3ca0a5 (2026-02-28)
- License: MIT (see LICENSE)

Only the library sources (`src/*.odin` upstream) are copied, unmodified.
Import as `ecs "dr:third_party/odecs"`.

The simulation runs on it (docs/decisions.md D39), so `mise run purity`
checks this folder too. Things the sim relies on, worth rechecking when
updating:

- Entities are recycled with a bumped generation, and the first entity of
  a new world gets index 1. The sim creates all its entities once, in a
  fixed order, so the ids are the same in every world.
- Components live in `[dynamic]byte` columns and removal swap-removes the
  last row. A component pointer is only good until the next structural
  change in its archetype.
- Pair, not and or query terms bump a package-global counter. The sim uses
  plain component terms only.
