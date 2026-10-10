# Reference examples

[Manual contents](../README.md)

Each file is a complete self-checking program for the current interpreter:

```sh
make dlua
bin/dlua docs/examples/relations.lua
bin/dlua docs/examples/state.lua
bin/dlua docs/examples/narrative.lua
```

- [relations.lua](relations.lua): recursive rules, construction-time snapshots,
  local relation lifetime, nil-preserving records, inheritance, cross-world queries.
- [state.lua](state.lua): explicit key order, atomic updates, nested rollback,
  invalidated iterators, aggregate assignments, escaping-error rollback.
- [narrative.lua](narrative.lua): immutable presentation, seeded variants, choice
  effects, sticky display order, optional choice titles, quality constraints, event
  turns, consumed tokens, canonical save/load.

Each prints its filename category followed by `: ok` only after its assertions
pass. All examples use the current `bin/dlua` command and `.lua` suffix; their
language is Varis. Smaller fragments in the manual can depend on the surrounding
schema/context and are not advertised as standalone programs.
