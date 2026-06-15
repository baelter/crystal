# Incremental compilation: foundation and staged design

This document records the design work toward incremental compilation in the
Crystal compiler. It explains where recompile time goes, why naive incremental
compilation is hard for Crystal specifically, the dependency-tracking
foundation that has been added, what it measures, and a concrete staged plan
for the remaining work.

## Where recompile time goes

For a warm recompile (object-file cache populated), the cost of `crystal build`
breaks down roughly as:

1. **Parsing** — small.
2. **Semantic analysis** (`Semantic (top level)`, `Semantic (main)`, …) — the
   whole program is re-analyzed from scratch every build. This is the dominant
   front-end cost and the focus of incremental compilation.
3. **Code generation (LLVM IR)** — all IR is regenerated every build to feed
   the object-file cache.
4. **Object files** (`.bc`/`.o`) — *already incremental*: each type compiles to
   its own LLVM module → `.o`, cached and keyed by bitcode, and there is no
   cross-`.o` inlining, so unchanged objects are reused.
5. **Linking** — external.

Two reductions have already landed:

- **GC tuning for the compiler process** (`Crystal::GCTuning`): the compiler's
  live set (AST + type graph) is almost entirely reachable until exit, so the
  default GC wastes large amounts of time re-marking it. Disabling automatic
  collection (with a physical-memory-based safety valve) made semantic analysis
  ~35–45% faster on large programs. See `src/compiler/crystal/tune_gc.cr`.

The remaining big front-end cost — re-running whole-program semantic analysis —
is what true incremental compilation must attack.

## Why it is hard in Crystal

Crystal infers types globally. Argument and return types are usually not
annotated, so changing one definition can change inferred types arbitrarily far
away, and the type graph (types, instantiated methods, their cross-references)
is rebuilt with fresh object identities on every compile. There is no stable,
serializable per-file semantic result to cache directly.

Any incremental scheme therefore needs to answer one question first:

> When file (or definition) *X* changes, what else must be re-analyzed?

That requires a **dependency graph** of *semantic uses*, which is what this
foundation provides.

## The foundation: semantic-use dependency tracking

`crystal tool semantic-dependencies` records, during a full semantic pass, an
edge `A => B` whenever code defined in file `A` uses a definition that lives in
file `B`:

- a method call resolves to a `Def` in another file
  (`Call#recalculate`, `src/compiler/crystal/semantic/call.cr`), and
- a `Path` resolves to a type or constant defined in another file
  (`MainVisitor#visit(Path)`, `src/compiler/crystal/semantic/main_visitor.cr`).

Recording is gated on `Program#semantic_dependencies` being set, so ordinary
compilation pays nothing.

This is deliberately different from `crystal tool dependencies`, which prints
the `require` graph — *syntactic* visibility, in which essentially every file
transitively requires the prelude. The semantic-use graph captures the *actual*
uses that decide what an edit invalidates.

Output formats: `text` (default; an impact analysis, below), `json` (the raw
`{file => [files]}` graph), and `dot`.

## What it measures

Reverse-transitive closure over the use graph gives, for each file, the
*re-analysis impact*: the set of files that would need re-checking if it
changed. Running it on the compiler's own sources (682 files, ~16k use edges):

```
Re-analysis impact when a single file changes:
  min     1     (0.1%)
  median  586   (85.9%)
  max     587   (86.1%)

Distribution:
  <=  1%  31    (4.5%)
  <=100%  682   (100.0%)
```

The distribution is **bimodal**: 31 leaf files have tiny impact (≤ 1%), while
the other ~95% sit at ~86%. The high-impact files are `intrinsics.cr`,
`lib_c.cr`, the integer/primitive types, etc.

The interpretation is the crucial design input:

- At **file granularity**, the standard library forms one giant
  **strongly-connected component**: `String` uses `Char` uses `Int` uses
  primitives, which call back, so a change to almost any core file transitively
  invalidates almost everything. File-level incrementality cannot help *within*
  that core.
- But application/leaf code (the files a user actually edits) sits *above* the
  core and has **very small impact** — editing a leaf in the sample project
  invalidates only itself and its few dependents.

So the win is real for the edit-your-own-code loop, but only if the stable core
is handled as a unit and/or dependencies are tracked finer than whole files.

## Staged design

**Stage 0 — GC tuning** *(done)*. Front-end ~35–45% faster; see `GCTuning`.

**Stage 1 — Semantic-use dependency tracking + impact analysis** *(done, this
change)*. `crystal tool semantic-dependencies`. Establishes the graph and
quantifies the opportunity.

**Stage 2 — Definition-level dependencies.** Refine edges from
file→file to `Def`/type → `Def`/type. The tracker already observes the precise
`Def`/type endpoints (it only widens them to files today). Definition
granularity breaks the artificial file-level SCC: two files that mutually
`require` each other rarely have every definition mutually dependent.

**Stage 3 — Stable-prelude snapshot.** The standard library and shards do not
change across a project's edit/compile cycle. Persist the semantic state
(declarations, and ideally instantiations) after they are processed and restore
it on the next compile, so only the project's own code is analyzed. This
targets the common case directly, since user edits live in the low-impact
leaves. The hard part is serializing/identity-restoring the type graph;
candidate approaches: a deterministic id assignment for types/defs and a
relocatable on-disk image.

**Stage 4 — Incremental invalidation.** Persist per-definition typed results
keyed by a fingerprint (source + the resolved types it depends on). On
recompile, hash changed inputs, compute the impacted set via the dependency
graph (Stage 2), reuse results for everything outside it, and re-analyze only
the impacted definitions. Correctness hinges on the fingerprint being a
complete over-approximation of dependencies; conservative invalidation (when in
doubt, re-analyze) keeps it sound.

**Codegen — incremental IR generation.** Even with semantic results reused, the
back end regenerates *all* LLVM IR on every build to feed the per-type `.o`
cache. The goal of this stage is to skip IR generation for type-modules whose
typed definitions are unchanged and link their cached `.o` directly.

A prototype was built and is informative about exactly what a correct
implementation needs (it is **not** merged — see the blocker below):

- *Fingerprinting.* A global *structure epoch* hashed from every instantiated
  method's mangled name plus every type's layout (instance vars, ancestors)
  catches all structural/signature/instantiation-set changes. Per-type-module
  fingerprints hash each instantiation's mangled name and the `to_s` of its
  typed definition. Skipping is attempted only when the epoch is stable (pure
  body edits), where IR is a deterministic function of the body source. This
  part works and validated cleanly.
- *Linking.* Skipping a module's bodies prunes code generation's reachability,
  so most modules are never materialized. Their cached `.o` files must therefore
  be linked from a persisted `module name → object file` map (kept in the
  incremental state), **not** from the modules the current build happens to
  produce. Missing this links far too few objects.
- *Blocker — force-materialization.* Pruning means a changed function reachable
  only through a skipped (reused) module is never generated. It must be
  force-materialized after the main walk. But `CodeGenVisitor#codegen_fun`
  cannot be driven reliably outside the normal top-down walk: primitives and
  intrinsics (e.g. `allocate`, `Atomic::Ops#load`) have no standalone function
  and raise (`can't take proc pointer of atomic call`, `Empty enumerable`), and
  ordinary methods depend on walk-established context. So the entry point used
  to force-generate changed-but-pruned modules is not currently safe.

The path to a correct implementation is therefore one of:

1. Make IR generation for a single instantiation a well-defined, context-free
   entry point (so changed modules can be regenerated in isolation), handling
   primitives/intrinsics explicitly; **or**
2. Seed the reachability walk with all non-reused (changed) instantiations up
   front so the normal walk materializes them, while still emitting reused
   modules' functions as declarations only (the `check_mod_fun` machinery
   already emits the needed cross-module declarations).

Approach (2) reuses the existing, battle-tested walk and is the recommended
next step.

## Trying it

```
crystal tool semantic-dependencies path/to/main.cr             # impact report
crystal tool semantic-dependencies -f json path/to/main.cr     # raw graph
crystal tool semantic-dependencies -f dot  path/to/main.cr     # graphviz
```
