# Incremental compilation — session handoff / runbook

This is a working handoff for continuing the incremental-compilation effort in a
fresh session. It captures the environment setup (non-obvious, took a while to
get right), what is already done and committed, benchmark methodology and
numbers, and a detailed, step-by-step plan for the remaining work — especially
the incremental code-generation prototype that was built, validated to a point,
and then **reverted** because of a specific architectural blocker.

Companion design doc: `doc/incremental-compilation.md` (read it too).

Branch: `claude/crystal-compiler-perf-w69t8u`.

---

## 1. Environment setup (do this first in a fresh session)

This container has LLVM 18 and a C toolchain but **no system `libgc`, no
`crystal`**, and the LLVM shared lib isn't named the way `llvm-config` expects.
The compiler also can't bootstrap itself without an existing Crystal.

```sh
# 1. Bootstrap compiler (the repo needs a prior crystal to build itself)
cd /tmp
curl -sL https://github.com/crystal-lang/crystal/releases/download/1.17.1/crystal-1.17.1-1-linux-x86_64.tar.gz -o crystal.tar.gz
tar xzf crystal.tar.gz   # -> /tmp/crystal-1.17.1-1/{bin/crystal, lib/crystal/libgc.a}

# 2. LLVM shared lib: llvm-config wants libLLVM-18.so but only libLLVM.so.1 exists
ln -sf /usr/lib/llvm-18/lib/libLLVM.so.1 /usr/lib/llvm-18/lib/libLLVM-18.so

# 3. Environment used for every build/run (save as /tmp/cenv.sh and `source` it)
export PATH=/tmp/crystal-1.17.1-1/bin:$PATH
export CRYSTAL=/tmp/crystal-1.17.1-1/bin/crystal           # bootstrap compiler
export LLVM_CONFIG=/usr/bin/llvm-config                    # v18
export LLVM_LDFLAGS="$(/usr/bin/llvm-config --libs --system-libs --ldflags --link-shared | tr '\n' ' ')"
export CRYSTAL_PATH=/home/user/crystal/lib:/home/user/crystal/src
export CRYSTAL_LIBRARY_PATH=/tmp/crystal-1.17.1-1/lib/crystal   # provides libgc.a at link time
export GCLIB=/tmp/crystal-1.17.1-1/lib/crystal

# Build the in-repo compiler (debug, ~40s) directly with the bootstrap compiler:
build_crystal() {            # build_crystal <output> [extra flags...]
  local out="$1"; shift
  .build/crystal build \
    -D strict_multi_assign -D preview_overload_order \
    -Dwithout_interpreter -Dwithout_libxml2 -Dwithout_openssl -Dwithout_zlib \
    -Dpreview_mt -Dexecution_context \
    --link-flags="-L$GCLIB" "$@" -o "$out" src/compiler/crystal.cr
}
```

Notes / gotchas:
- `make crystal` also works (it figures out LLVM), but won't rebuild when it
  thinks the target is up to date — use `build_crystal` for iteration. First
  `make crystal` produces `.build/crystal`, the debug compiler you then use as a
  faster bootstrap (`build_crystal` above calls `.build/crystal`).
- A **debug** compiler rebuild is ~40s; a **release** (`--release`) rebuild is
  ~8–12 min. Iterate on debug; measure on release.
- `--release` must actually recompile: if the output exists and is newer, `make`
  no-ops. Build to a fresh `-o` path.
- To compile/link a normal user program with a freshly built compiler you need
  `CRYSTAL_PATH` and `CRYSTAL_LIBRARY_PATH` as above, plus
  `-Dpreview_mt -Dexecution_context` for programs that use
  `Fiber::ExecutionContext`.
- `spec/std_spec.cr` won't *link* here (needs libxml2/gmp/etc. that aren't
  installed) but compiles fine for `--no-codegen` / semantic measurements. The
  **compiler itself** (`src/compiler/crystal.cr`) links fine.
- Parallel codegen (default threads) occasionally **segfaults** in this
  container (both baseline and patched) — a preview_mt/fork flakiness, not your
  change. Re-run, or use `--threads 1/2` for stable timing.

### Profiling tools available
- `valgrind --tool=callgrind` + `callgrind_annotate` (slow but reliable; use
  `--collect-atstart=no --toggle-collect='*Func*'` to focus).
- `gdb -p <pid> -batch -ex "bt 25"` sampling in a loop (poor-man's profiler);
  aggregate frames with `grep -oE "at .../src/[^ ]+:[0-9]+" | sort | uniq -c`.
  Note: with preview_mt the heavy work may be on a worker thread, not main.
- No `perf`.

---

## 2. Baseline numbers (release compiler, this tree)

Measured on the compiler's own source and `spec/std_spec.cr`. "Semantic" =
`build --no-codegen`. Phase times via `--stats`.

| Workload | metric | baseline | with GC patch |
|---|---|---|---|
| compiler src | `--no-codegen` | 15.5s | 10.0s (−36%) |
| std_spec | `--no-codegen` | 17.5s | 10.3s (−42%) |
| std_spec | `Semantic (main)` only | 14.7s | 7.5s (−49%) |
| compiler src | full warm recompile | ~25s | ~19–20s (−20–26%) |

Phase breakdown of a **warm full recompile** of the compiler (post-GC):
`top-level 0.75s · ivars 4.4s · main 4.8s · Codegen(crystal) ~6.8s ·
Codegen(bc+obj) ~3.7s · link ~2.6s`. After GC, the remaining big costs are
**whole-program semantic re-analysis** and **LLVM IR regeneration**.

Pathology worth knowing: compiling the compiler, one initializer line
(`@splat_expansions : Hash(Def, Array(Type)) = (...).compare_by_identity` in
`program.cr`) triggers **~105k method instantiations** (`Hash`/`Array` over the
megamorphic `Type`), ~9s of semantic on its own. Genuine instantiation work, not
a caching bug; relevant if you profile the compiler's self-build.

---

## 3. What is done and committed

- `3f093b5` **GC tuning** — `src/compiler/crystal/tune_gc.cr`, wired in
  `src/compiler/crystal.cr` and `progress_tracker.cr`. Disables automatic GC for
  the compiler run, re-enables past a physical-memory-based ceiling
  (checked at phase boundaries). Honors `GC_DONT_GC`/`GC_FREE_SPACE_DIVISOR`.
- `66e2a54` **Semantic-use dependency tracking** —
  `src/compiler/crystal/tools/semantic_dependencies.cr` (+ hooks in
  `semantic/call.cr` at the `@target_defs = matches` site, and
  `semantic/main_visitor.cr` in `visit(Path)`; `Program#semantic_dependencies`).
  `crystal tool semantic-dependencies [-f text|json|dot]`.
- `c790d4a` + this file — docs.

**Key empirical finding:** at file granularity the stdlib is one giant
strongly-connected component (median file edit ⇒ re-analyze ~86% of the
compiler's files); only leaf/app files have small impact. Implications drive the
plan below.

---

## 4. Staged plan (remaining)

Ordered by value-for-effort given the SCC finding. Stages 0–1 done.

### Stage A (recommended first) — Incremental code generation
Skip regenerating LLVM IR for type-modules whose typed definitions are
unchanged; link their cached `.o`. This is the back-end half of recompile
(~10s for the compiler) and is **more tractable than incremental semantics**
because the `.o` layer is already content-cached and there's no cross-`.o`
inlining. A prototype exists (reverted) — see §5 for the exact design, what
worked, the blocker, and the fix to try.

### Stage B — Definition-level dependencies
Refine the Stage-1 tracker from file→file to `Def`/type→`Def`/type (it already
*observes* the precise endpoints; it only widens to files today). This breaks
the artificial file-level SCC and is the substrate for Stage D.

### Stage C — Stable-prelude semantic snapshot
The stdlib + shards don't change between edits. Persist the typed program state
after they're processed and restore it, analyzing only project code. Hard part:
serializing/identity-restoring the type graph (types, instantiated defs, their
cross-references) deterministically. Candidate: assign stable ids to
types/defs and build a relocatable on-disk image. Targets the common edit loop
directly (user edits live in low-impact leaves).

### Stage D — Incremental semantic invalidation
Persist per-definition typed results keyed by a fingerprint (source + resolved
dependency types). On recompile: hash changed inputs, compute the impacted set
via the Stage-B graph, reuse everything outside it, re-analyze only the impacted
set. Correctness rests on the fingerprint being a complete *over*-approximation;
conservative invalidation keeps it sound. This is the multi-month core of "true
incremental compilation."

---

## 5. Incremental codegen prototype — design, status, blocker, fix

> This was implemented, partially validated, then **reverted** (it can produce
> stale binaries today). Reconstruct from here. None of it is in the tree now.

### Mechanism
1. **Structure epoch** (global, conservative): hash of the sorted set of all
   instantiated method mangled names + every type's structure (name, instance
   vars with types, ancestors). *Any* structural/signature/instantiation-set
   change (new type/field/method/overload, or a body edit that changes inferred
   types or which methods get instantiated) changes the epoch.
2. **Per-type-module fingerprint**: hash of, for each instantiation in the
   module (sorted), `mangled_name + "\n" + typed_def.to_s`.
3. Persist `{epoch, modules: {name=>fp}, objects: {name=>o_filename}}` as
   `incremental.json` in the cache dir (`CacheDir.directory_for(sources)`).
4. On recompile, **only when the epoch is unchanged**, a module is *reusable* iff
   its fingerprint matches the previous build **and** the previously recorded
   `.o` still exists. Reusable ⇒ skip its IR, link its cached `.o`.

Rationale for the epoch gate: when the epoch is stable, type layouts, type ids
and method resolution are identical to the last build, so each instantiation's
IR is a deterministic function of its body source (captured by `to_s`). This
restricts skipping to pure body edits and keeps fingerprints sound. Structural
edits bump the epoch ⇒ full rebuild (correct, conservative).

### Where it hooks (when you rebuild it)
- New file `src/compiler/crystal/codegen/incremental.cr`: `module
  IncrementalCodegen` with `State`, `compute(program)`, `reusable(prev, cur,
  output_dir)`, `module_name(type)` (mirror of `CodeGenVisitor#type_module`:
  `Program`/`LibType` ⇒ `""`, else `type.instance_type.to_s`), and an
  `each_type(program)` walk (program.types recursively + `each_instantiated_type`
  for generics + metaclasses; iterate `def_instances` of
  `DefInstanceContainer`s). Use `::Crystal::Digest::MD5.hexdigest`.
- `Compiler#codegen(node, sources, output_filename)` in `compiler.cr`
  (~line 365): compute `bc_flags_changed` *first*; **always** compute+save state
  when `incremental?`, but only build the skip set when `!bc_flags_changed`
  (else cached `.o` are stale). Pass `skip_modules` to `program.codegen`.
- `Program#codegen` in `codegen/codegen.cr` (~line 155): accept `skip_modules`,
  set it on the visitor before `accept`.
- `CodeGenVisitor#codegen_fun` in `codegen/fun.cr` (~line 113): if
  `self_type`'s module is in `skip_modules` (and not the main module `""`, not a
  fun literal), set `needs_body = false` ⇒ declaration only.
- Partition in `compiler.cr`: for each materialized module, skip those in
  `skip_modules`; record `objects[type_name] = unit.object_filename`. For
  **every** skipped module, append `previous_state.objects[name]` to
  `reused_objects` and carry it into the new `objects` map.
- Inner `codegen(units, …, reused_objects)`: `object_names = units.map(&.
  object_filename) + reused_objects`. Save `IncrementalCodegen::State.new(epoch,
  modules, objects)` after.
- CLI: `--incremental` flag in `command.cr` setting `compiler.incremental = true`
  (`property? incremental` on `Compiler`). Keep it **experimental/off by
  default**.

### What worked (validated)
- Epoch + fingerprint correctly distinguish body edits from structural edits
  (the `to_s` of a typed def reflects `x*2` vs `x*3`; epoch stays stable for body
  edits, bumps for added fields/methods).
- Linking the cached `.o` for all skipped modules from the persisted `objects`
  map (necessary because pruning, below, means most modules aren't
  re-materialized, so you can't get their `.o` from the current build).
- Pure-body-edit + structural-edit cases produced correct output once the link
  set was fixed — **as long as the changed module's caller was the main module**
  (always materialized).

### The blocker (why it was reverted)
Skipping a module's bodies **prunes code generation's reachability**: the walk
starts at main and only descends into bodies it generates, so a changed function
reachable *only through a skipped (reused) caller* is never generated. Concrete
repro that produced a **stale binary** (printed 42 instead of 63):

```
helper.cr:  class Helper;  def double(x:Int32):Int32;  x*2;  end;  end
calc.cr:    class Calc;    def compute(x:Int32):Int32;  Helper.new.double(x); end; end
main.cr:    puts Calc.new.compute(21)
# edit Helper#double x*2 -> x*3 ; Calc is unchanged -> skipped -> compute body not
# walked -> Helper#double never reached -> stale Helper.o linked.
```

The attempted fix — force-materialize every non-skipped instantiation after the
walk by calling `target_def_fun`/`codegen_fun` directly — **does not work**:
`codegen_fun` can't be driven outside the normal top-down walk. Primitives and
intrinsics have no standalone function and raise, e.g.:
- `Helper.class#allocate: Enumerable::EmptyError: Empty enumerable`
- `Atomic::Ops#load: can't take proc pointer of atomic call`

and ordinary methods rely on walk-established context. So isolated regeneration
of changed-but-pruned modules is unsafe.

### Recommended fix (do this next)
**Approach 2 — seed the walk, don't force-generate in isolation.** Before/at the
start of `visitor.accept`, seed the worklist with *all non-reused (changed)
instantiations* so the existing, battle-tested top-down walk materializes them
and discovers their callees naturally. Emit reused modules' functions as
declarations only (the `check_mod_fun`/`declare_fun` machinery already adds the
needed cross-module declarations, and there is no cross-`.o` inlining, so a
declaration + the cached `.o` definition is correct at any `-O`). This keeps
codegen on its normal path and avoids the primitive/intrinsic problem entirely.

Validate with, at minimum: (a) body edit whose caller is unchanged/skipped
(the repro above) — must match a full build; (b) generics; (c) add/remove a
field/method (epoch bump ⇒ full rebuild); (d) build the **compiler itself**
incrementally across a body edit and run its spec suite through the result;
(e) diff incrementally-built `.o`/binary against a full build.

### Caveat to verify regardless of approach
The fingerprint assumes "epoch stable ⇒ a module's IR depends only on its body
source." Audit anything that breaks that determinism without changing the epoch:
closures/captured-var layout, constants whose *value* (not type) changed (these
live in the always-regenerated main module and are referenced by symbol, so
likely fine), `flag?`-dependent macro expansion (the post-expansion body is in
`to_s`, so fine), and `previous_def`/`super` chains. When unsure, fold the
input into the epoch (more conservative = more full rebuilds, never wrong).

---

## 6. Quick validation harness (small multi-file program)

```sh
source /tmp/cenv.sh
mkdir -p /tmp/inc && cd /tmp/inc
# helper.cr / calc.cr / main.cr as in the repro above
CACHE=$(mktemp -d); OUT=$(mktemp)
CRYSTAL_CACHE_DIR=$CACHE /path/to/built/crystal build --incremental main.cr -o $OUT && $OUT  # cold
# edit a body, rebuild --incremental, run; compare to a fresh full build:
CRYSTAL_CACHE_DIR=$(mktemp -d) /path/to/built/crystal build main.cr -o $OUT2 && $OUT2
```
Inspect `incremental.json` in `$CACHE/<subdir>/` and md5 the per-module `.o`
to confirm exactly which modules were regenerated vs reused.
