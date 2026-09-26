# odecs (vendored)

An archetype ECS for Odin by Nate Martin.

- Upstream: https://github.com/NateTheGreatt/odecs
- Commit: e3ca0a5 (2026-02-28)
- License: MIT (see LICENSE)

Only the library sources (`src/*.odin` upstream) are copied, unmodified.
Import as `ecs "dr:third_party/odecs"`.

The simulation runs on it (docs/decisions.md D39, D47), so `mise run
purity` checks this folder too, and fails on any use of its internals or
encoded query terms outside it. Things the sim relies on, worth
rechecking when updating:

- The public API it calls: `create_world`, `delete_world`,
  `register_component`, `add_entity`, `add_component`, `get_component`,
  `has_component`, `query_raw`, `get_table`, `get_entities`,
  `get_entity_archetype`.
- Components live in `[dynamic]byte` columns, so a pointer is only good
  until the next structural change. The sim makes every entity at build,
  with all its components, and changes nothing after, so the views it
  takes then stay good for the session.
- A table's rows are in the order the entities were added, which is what
  makes two worlds with the same mods snapshot alike.
- Pair, not and or query terms go through a package-global counter that
  every query resets. The sim uses plain component terms only, and does
  `without` by subtracting archetype sets.
