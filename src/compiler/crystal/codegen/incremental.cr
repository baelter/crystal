require "json"
require "../crystal_path"

# Incremental code generation (experimental, opt-in via `--incremental`).
#
# Each Crystal type compiles to its own LLVM module -> its own `.o`, cached and
# keyed by bitcode content, with no cross-`.o` inlining. The compiler normally
# regenerates *all* LLVM IR every build just to rediscover that most `.o` are
# unchanged. This moves the cache check *before* IR generation: fingerprint each
# type-module's typed definitions, skip IR for unchanged modules, link cached
# `.o`.
#
# The hard part is that skipping a module's body walk loses two side effects:
# (1) reachability of callees and (2) emission of helper symbols that live in
# the *main* module (type_id globals, const read/init functions, the classname
# map, proc thunks, ...). The design is two layers:
#
# * **Layer 2 (replay):** persist, per build, the live function set and the
#   lazily-emitted main-resident helpers, and on a warm build re-seed callees
#   (`codegen_changed_instantiations`) and re-emit the helpers
#   (`force_main_symbols`). This is what delivers the speedup.
# * **Layer 1 (correctness backstop):** derive, from the *actually emitted* IR,
#   each `.o`'s exported and imported symbols (ground truth). A pre-flight
#   fixpoint (`satisfy`) computes the skip set so every reused `.o`'s imports
#   are provably satisfiable by something this build defines (a still-skipped
#   `.o`, a regenerated module, an eager main symbol, or a replayed helper).
#   Any symbol Layer 2 fails to reproduce shows up as an unsatisfiable import
#   and forces *that module* to regenerate — never a link failure, never a
#   stale binary. Replay completeness therefore affects speed, not correctness.
#
# Skipping is attempted only when the structure epoch is unchanged, so type
# layouts, type ids and method resolution match the last build and each
# instantiation's IR is a deterministic function of its body source.
module Crystal::IncrementalCodegen
  # The frozen cold-build emission shape of a const/class-var, so warm replay
  # reproduces the same branch instead of recomputing state-dependent flags.
  struct SymbolShape
    include JSON::Serializable
    getter emitted_read_fn : Bool
    getter no_init_flag : Bool

    def initialize(@emitted_read_fn, @no_init_flag)
    end
  end

  # One lazily-emitted main-resident helper the cold build pulled in. `name` is
  # the load-bearing primary LLVM symbol; `key` re-resolves the source object
  # next build; `shape`/`aux` freeze the exact emission.
  struct MainSymbolRecord
    include JSON::Serializable
    getter kind : String # "type_id" | "const" | "classname_map" | ...
    getter name : String
    getter key : String
    getter shape : SymbolShape?
    getter aux : Hash(String, String)?

    def initialize(@kind, @name, @key, @shape = nil, @aux = nil)
    end

    # Every LLVM symbol force_main_symbols will DEFINE when it replays this
    # record. Must be a subset of what the cold build emitted (under-claiming is
    # safe: it only causes extra, correct eviction).
    def defines : Array(String)
      case kind
      when "const"
        if (s = shape) && s.emitted_read_fn
          ["~#{key}:const_read", "~#{key}:const_init", key, "#{key}:const_init"]
        else
          [] of String
        end
      else
        [name]
      end
    end

    # Can force_main_symbols actually re-emit this record on a warm build?
    def replayable?(proc_replayable : Set(String)) : Bool
      case kind
      when "proc_thunk" then proc_replayable.includes?(name)
      when "match"      then aux.try(&.has_key?("ranges")) || false
      else                   true
      end
    end
  end

  # Persisted between builds as `incremental<opt-suffix>.json` in the cache dir.
  class State
    include JSON::Serializable

    getter epoch : String
    # type-module name (codegen `type_module` key) => fingerprint
    getter modules : Hash(String, String)
    # type-module name => object filename (relative to the cache dir)
    getter objects : Hash(String, String)
    # type-module name => mangled names of functions emitted with a body (the
    # reachable/live set), used to re-seed pruned-but-live callees.
    getter live : Hash(String, Array(String))
    # type-module name => external symbols this `.o` DEFINES (ground truth)
    getter exports : Hash(String, Array(String))
    # type-module name => external symbols this `.o` only DECLARES (imports)
    getter imports : Hash(String, Array(String))
    # main symbols present right after the visitor constructor: always re-emitted
    # every build, so always satisfiers regardless of the replay ledger.
    getter eager_main : Array(String)
    # lazily-emitted main-resident helpers to replay, in recorded order
    getter main_symbols : Array(MainSymbolRecord)
    # Type#to_s => assigned type_id integer; asserted equal on a warm build so
    # id drift (the one silent-miscompile hazard) forces a full rebuild instead.
    getter type_id_table : Hash(String, Int32)
    # caller type-module => callee type-modules whose trivial body it inlined.
    # A reused caller `.o` embeds those bodies, so `reusable` evicts the caller
    # when a listed callee module's fingerprint changes (defaults empty for
    # states written before this field existed — JSON leaves it `{}`).
    getter inline_deps : Hash(String, Array(String)) = {} of String => Array(String)

    def initialize(@epoch, @modules, @objects, @live, @exports, @imports,
                   @eager_main, @main_symbols, @type_id_table, @inline_deps = {} of String => Array(String))
    end

    def self.load(path : String) : State?
      return nil unless File.file?(path)
      from_json(File.read(path))
    rescue JSON::ParseException
      nil
    end

    def save(path : String) : Nil
      File.write(path, to_json)
    end
  end

  # The freshly computed epoch + per-module fingerprints for the current build.
  record Fingerprints, epoch : String, modules : Hash(String, String)

  # Ground-truth external symbols an LLVM module DEFINES (exports) vs only
  # DECLARES (imports). Internal/private linkage is module-local and ignored.
  # This is read from the emitted IR, so it cannot miss a symbol the linker
  # will demand — the foundation of the never-link-fail guarantee.
  def self.module_symbols(llvm_mod : LLVM::Module) : {Array(String), Array(String)}
    exports = [] of String
    imports = [] of String
    llvm_mod.functions.each do |f|
      next if f.linkage.internal? || f.linkage.private?
      name = f.name
      next if name.empty?
      (f.declaration? ? imports : exports) << name
    end
    llvm_mod.globals.each do |g|
      next if g.linkage.internal? || g.linkage.private?
      name = g.name
      next if name.empty?
      (g.initializer ? exports : imports) << name
    end
    {exports.uniq!.sort!, imports.uniq!.sort!}
  end

  # Mirror of `CodeGenVisitor#type_module`: the LLVM-module key a type's
  # functions are emitted under. Must stay in sync with `codegen/fun.cr`.
  def self.module_name(type : Type) : String
    type = type.remove_typedef
    case type
    when Program, LibType
      ""
    else
      type.instance_type.to_s
    end
  end

  # Walk the typed program and compute the epoch and per-module fingerprints.
  def self.compute(program : Program) : Fingerprints
    mangled = [] of String    # every instantiation's mangled name
    structures = [] of String # every type's structural layout
    module_entries = Hash(String, Array(String)).new { |h, k| h[k] = [] of String }

    # Skip types a prior resident codegen materialized — a fresh build computes
    # its epoch before its codegen mints them, so they must not perturb this
    # cycle's epoch either (they carry no def_instances). See `pin_type_ids`.
    codegen_types = program.regreen.try(&.codegen_created_types)

    walk_types(program) do |type|
      next if codegen_types && codegen_types.includes?(type.object_id)
      structures << type_structure(type)

      next unless type.is_a?(DefInstanceContainer)
      mod = module_name(type)
      type.def_instances.each_value do |typed_def|
        name = typed_def.mangled_name(program, type)
        mangled << name
        module_entries[mod] << "#{name}\n#{typed_def}"
      end
    end

    mangled.sort!
    structures.sort!
    epoch = ::Crystal::Digest::MD5.hexdigest do |ctx|
      mangled.each { |m| ctx.update(m); ctx.update("\n") }
      ctx.update("--structures--\n")
      structures.each { |s| ctx.update(s); ctx.update("\n") }
      # A symbol literal codegens to `int(@symbols[value])` — a bare integer
      # baked into the reading module's `.o`, where the index is the symbol's
      # position in `program.symbols` (codegen.cr `visit(SymbolLiteral)`; the
      # table itself is `External` in non-main modules). Inserting a symbol
      # shifts every later symbol's index, but a reader's per-module fingerprint
      # only renders symbols by NAME, so a skipped reader would keep a stale
      # baked index (silent miscompile). Symbol order is NOT sortable here (the
      # order IS the contract), so fold the ordered set into the epoch: any
      # symbol-set/order change forces a full rebuild, exactly as a type-layout
      # change does. (type_ids get the same protection via `pin_type_ids`.)
      ctx.update("--symbols--\n")
      program.symbols.each { |s| ctx.update(s); ctx.update("\n") }
    end

    modules = {} of String => String
    module_entries.each do |mod, entries|
      entries.sort!
      modules[mod] = ::Crystal::Digest::MD5.hexdigest do |ctx|
        entries.each { |e| ctx.update(e); ctx.update("\n") }
      end
    end

    Fingerprints.new(epoch, modules)
  end

  # Diagnostic (M3): per-module sorted entry list ("<mangled>\n<typed_def>"),
  # so a caller can diff the actual instances in a divergent module instead of
  # just the module hash.
  def self.module_entries(program : Program) : Hash(String, Array(String))
    module_entries = Hash(String, Array(String)).new { |h, k| h[k] = [] of String }
    walk_types(program) do |type|
      next unless type.is_a?(DefInstanceContainer)
      mod = module_name(type)
      type.def_instances.each_value do |typed_def|
        name = typed_def.mangled_name(program, type)
        module_entries[mod] << "#{name}\n#{typed_def}"
      end
    end
    module_entries.each_value(&.sort!)
    module_entries
  end

  # Diagnostic (M3): the raw epoch components — the sorted mangled-name list,
  # the sorted type-structure list, and the ordered symbol list — so a caller
  # can diff each part element-wise instead of just the combined epoch hash.
  def self.epoch_parts(program : Program) : {Array(String), Array(String), Array(String)}
    mangled = [] of String
    structures = [] of String
    walk_types(program) do |type|
      structures << type_structure(type)
      next unless type.is_a?(DefInstanceContainer)
      type.def_instances.each_value do |typed_def|
        mangled << typed_def.mangled_name(program, type)
      end
    end
    {mangled.sort!, structures.sort!, program.symbols.to_a}
  end

  # Candidate reuse set: epoch matches, fingerprint matches, recorded `.o`
  # exists. The main module ("") is never reusable. The pre-flight (`satisfy`)
  # then shrinks this so the link cannot fail.
  def self.reusable(prev : State?, cur : Fingerprints, output_dir : String) : Set(String)
    result = Set(String).new
    return result unless prev
    return result unless prev.epoch == cur.epoch

    cur.modules.each do |mod, fp|
      next if mod.empty?
      next unless prev.modules[mod]? == fp
      # Cross-module inline staleness: a callee whose trivial body this `.o`
      # inlined changed, so the cached copy is stale. The caller's own
      # fingerprint can't see it (it renders a Call, not the inlined body), so
      # gate on the callee modules' fingerprints here. (`compute` renders an
      # absent module to nil, so a vanished callee also evicts.)
      if (deps = prev.inline_deps[mod]?) && !ENV["CRYSTAL_INC_NO_INLINE_DEP"]?
        next if deps.any? { |callee| cur.modules[callee]? != prev.modules[callee]? }
      end
      object = prev.objects[mod]?
      next unless object
      path = File.join(output_dir, object)
      next unless File.file?(path) && File.size(path) > 0
      result << mod
    end
    result
  end

  # Pre-flight satisfaction fixpoint (Layer 1). Shrinks `candidate` so every
  # reused module's imports are satisfiable by symbols this build will define:
  #   - exports of modules that REMAIN skipped (their cached `.o`),
  #   - exports of regenerated (non-skipped) modules, restricted to names still
  #     instantiated this build (epoch equality keeps the name set stable),
  #   - eager main symbols (always re-emitted), and
  #   - the replayable subset of the main-symbol ledger.
  # Monotone (skip only shrinks over a finite set) so it terminates.
  def self.satisfy(prev : State?, candidate : Set(String),
                   index : Hash(String, {Def, Type}),
                   proc_replayable : Set(String)) : Set(String)
    return candidate unless prev
    skip = candidate.dup

    replayed = Set(String).new
    prev.eager_main.each { |s| replayed << s }
    prev.main_symbols.each do |rec|
      next unless rec.replayable?(proc_replayable)
      rec.defines.each { |s| replayed << s }
    end

    # Externally-resolved symbols: imported by some `.o` but defined by NO `.o`
    # (libc, libgc, runtime intrinsics). The cold build linked, so the linker
    # supplies them every build — always satisfiable, independent of the skip
    # set. Without this, the ubiquitous `GC_malloc`/libc imports would evict
    # almost every module.
    all_exports = Set(String).new
    prev.exports.each_value { |syms| syms.each { |s| all_exports << s } }
    prev.imports.each_value do |syms|
      syms.each { |s| replayed << s unless all_exports.includes?(s) }
    end

    debug = ENV["CRYSTAL_INC_DEBUG"]?
    round = 0
    round1_kinds = Hash(String, Int32).new(0) # direct (round-1) eviction drivers
    cascade_count = 0

    loop do
      round += 1
      satisfiers = replayed.dup
      prev.exports.each do |mod, syms|
        if skip.includes?(mod)
          syms.each { |s| satisfiers << s } # reused .o defines them
        else
          # Regenerated module (incl. main): only its still-instantiated method
          # exports return deterministically. Its lazily-emitted main helpers
          # are NOT assumed re-emitted — those come solely from `replayed`
          # (eager snapshot + replay ledger). Claiming them here would be an
          # over-claim that could link-fail when the helper isn't replayed.
          syms.each { |s| satisfiers << s if index.has_key?(s) }
        end
      end

      evict = skip.select do |mod|
        (prev.imports[mod]? || Array(String).new).any? { |s| !satisfiers.includes?(s) }
      end
      break if evict.empty?

      if debug
        evict.each do |mod|
          (prev.imports[mod]? || Array(String).new).each do |s|
            next if satisfiers.includes?(s)
            if round == 1
              round1_kinds[classify_symbol(s)] += 1
            end
          end
          cascade_count += 1 if round > 1
        end
      end

      evict.each { |mod| skip.delete(mod) }
    end

    if debug
      STDERR.puts "[inc] candidate=#{candidate.size} skipped=#{skip.size} evicted=#{candidate.size - skip.size} rounds=#{round}"
      STDERR.puts "[inc] round-1 (direct) eviction drivers: #{round1_kinds.to_a.sort_by { |_, n| -n }.first(12)}"
      STDERR.puts "[inc] cascade evictions (round>1): #{cascade_count}"
      whatif_skip(prev, candidate, index, replayed, "match")
      whatif_skip(prev, candidate, index, replayed, "proc_thunk")
      whatif_skip(prev, candidate, index, replayed, "match", "proc_thunk")
    end

    skip
  end

  # Counterfactual: how many more modules would skip if the given main-symbol
  # kinds were replayable (their defines added to the satisfier base). Reruns the
  # fixpoint with the real index; debug-only.
  private def self.whatif_skip(prev : State, candidate : Set(String),
                               index : Hash(String, {Def, Type}),
                               replayed_base : Set(String), *kinds : String) : Nil
    replayed = replayed_base.dup
    prev.main_symbols.each do |rec|
      next unless kinds.includes?(rec.kind)
      rec.defines.each { |s| replayed << s }
      replayed << rec.name
    end
    skip = candidate.dup
    loop do
      satisfiers = replayed.dup
      prev.exports.each do |mod, syms|
        if skip.includes?(mod)
          syms.each { |s| satisfiers << s }
        else
          syms.each { |s| satisfiers << s if index.has_key?(s) }
        end
      end
      evict = skip.select do |mod|
        (prev.imports[mod]? || Array(String).new).any? { |s| !satisfiers.includes?(s) }
      end
      break if evict.empty?
      evict.each { |mod| skip.delete(mod) }
    end
    STDERR.puts "[inc] what-if replay #{kinds.to_a}: skipped=#{skip.size} evicted=#{candidate.size - skip.size}"
  end

  # Coarse classification of an LLVM symbol name into a replay "kind", for the
  # `CRYSTAL_INC_DEBUG` eviction breakdown.
  def self.classify_symbol(s : String) : String
    case
    when s.ends_with?(":type_id")      then "type_id"
    when s.ends_with?(":const_read")   then "const_read"
    when s.ends_with?(":const_init")   then "const_init"
    when s.starts_with?("~match<")     then "match"
    when s == "~metaclass"             then "metaclass"
    when s.starts_with?("~procProc")   then "proc_thunk"
    when s.starts_with?("~check_proc") then "check_proc"
    when s.starts_with?("*")           then "method_or_thread_local"
    when s.starts_with?("~")           then "other_tilde"
    when s.includes?("class_var")      then "class_var"
    else                                    "other"
    end
  end

  # type_id integers are baked into reused `.o`. Their assignment is partly
  # codegen-order-dependent (`LLVMId#type_id` lazy fallback), so a `.o` first
  # produced by a plain (non-pinned) build can disagree with a later pinned
  # `--incremental` build. Assert equality; any drift forces a full rebuild
  # (the one place the failure mode would otherwise be a bad binary).
  # Compare the freshly pinned table against the previous one. Comparing whole
  # tables (not per-type) is essential: distinct types can share a `to_s`, so a
  # per-type lookup would falsely mismatch the collision "loser" even when the
  # tables are byte-identical. `pin_type_ids` resolves collisions deterministically.
  def self.type_ids_stable?(prev : State?, current_table : Hash(String, Int32)) : Bool
    return true unless prev
    old = prev.type_id_table
    return true if old.empty?
    stable = current_table == old
    if !stable && ENV["CRYSTAL_M3_UNION_DEBUG"]?
      only_new = current_table.keys.to_set - old.keys.to_set
      only_old = old.keys.to_set - current_table.keys.to_set
      reid = current_table.keys.select { |k| old.has_key?(k) && old[k] != current_table[k] }
      STDERR.puts "[m3drift] only_new=#{only_new.size} only_old=#{only_old.size} reid=#{reid.size}"
      reid.first(8).each { |k| STDERR.puts "[m3drift]   ~ #{k}: #{old[k]} -> #{current_table[k]}" }
      only_old.first(8).each { |k| STDERR.puts "[m3drift]   -old #{k} = #{old[k]}" }
      only_new.first(8).each { |k| STDERR.puts "[m3drift]   +new #{k} = #{current_table[k]}" }
    end
    stable
  end

  # Assign an id to every type up front in a deterministic (sorted) order, so
  # the lazy order-dependent fallback never decides an id, and snapshot the
  # table for the determinism assert above.
  def self.pin_type_ids(program : Program) : Hash(String, Int32)
    # In a resident process, types a PRIOR cycle's codegen materialized (unions,
    # metaclasses) linger; a fresh build mints them only after its own pin, so
    # they are absent from its pinned table. Skip them here so this cycle's table
    # matches the fresh build's exactly (they keep their cached codegen ids, so
    # this never changes a baked id). See `ReGreenEngine#codegen_created_types`.
    codegen_types = program.regreen.try(&.codegen_created_types)
    types = [] of Type
    walk_types(program) do |type|
      next if type.is_a?(VirtualType) || type.is_a?(VirtualMetaclassType)
      next if codegen_types && codegen_types.includes?(type.object_id)
      types << type
    end
    types.sort_by!(&.to_s)
    table = {} of String => Int32
    types.each { |type| table[type.to_s] = program.llvm_id.type_id(type) }
    table
  end

  # Pin const and class-var access decisions deterministically. Both set
  # `no_init_flag = true unless read?` during initialization, so whether they're
  # read via an init-flag-checked `~X:const_read` / `~X:read` function or as a
  # bare global depends on read-vs-init ORDER — which incremental reordering
  # changes, producing inconsistent access IR across modules (and stale/
  # uninitialized loads -> segfaults). Marking everything `read?` up front
  # removes that mutation: non-eager consts/class-vars always use the read
  # function (order-independent); eager ones stay bare globals by a stable
  # property. Cold and warm builds then agree.
  def self.pin_lazy_init_reads(program : Program) : Nil
    walk_types(program) do |type|
      type.read = true if type.is_a?(Const)
      if type.is_a?(ClassVarContainer)
        type.class_vars?.try &.each_value { |cv| cv.read = true }
      end
    end
  end

  # Index every instantiation by its mangled name, mapping to the typed def and
  # the type it is cached on (its codegen `self_type`).
  #
  # The seed (`codegen_changed_instantiations`) re-emits a callee's body into a
  # regenerated caller by looking the callee's mangled name up here, so on a name
  # collision the chosen entry decides which body is emitted. After an in-process
  # re-green the orphaned pre-edit instance still lingers in some type's
  # `def_instances` and shares its (body-independent) mangled name with the
  # re-greened instance; plain last-writer-wins would let the orphan's stale body
  # win and the seed would emit it as a dead copy into the caller, breaking byte
  # identity. Give the re-greened (live) instances priority: once a live body
  # claims a name, only another live body may overwrite it.
  def self.instantiation_index(program : Program) : Hash(String, {Def, Type})
    index = {} of String => {Def, Type}
    live = program.regreen.try &.last_regreen_instances.map(&.typed_def.object_id).to_set
    live_claimed = Set(String).new
    walk_types(program) do |type|
      next unless type.is_a?(DefInstanceContainer)
      type.def_instances.each_value do |typed_def|
        name = typed_def.mangled_name(program, type)
        is_live = live ? live.includes?(typed_def.object_id) : false
        next if live_claimed.includes?(name) && !is_live
        index[name] = {typed_def, type}
        live_claimed << name if is_live
      end
    end
    collision_audit(program) if ENV["CRYSTAL_INC_COLLIDE"]?
    index
  end

  # One colliding instantiation: the def-instance key (carries `block_type` and
  # `named_args`, the inputs the positional mangled name omits) plus the typed
  # def and the self type it codegens under.
  private record Collider, key : DefInstanceKey, typed_def : Def, self_type : Type

  # Deep collision characterization (CRYSTAL_INC_COLLIDE). Groups every distinct
  # typed def by its mangled name, then for each name carrying more than one
  # real (non-primitive, non-abstract) body classifies WHY they collide:
  #
  #   * different source def_object_id  -> genuinely different overloads sharing
  #     a symbol (the structural DefId should have split these; any survivor is
  #     a DefId completeness bug);
  #   * same source, differing arg_types.to_s -> distinct concrete types that
  #     render to the same llvm_name (different body types -> different IR ->
  #     REAL hazard);
  #   * same source, same arg types, differing block_type / named_args only ->
  #     codegen reuses the first body for all; benign iff the bodies' `to_s`
  #     match (what the per-module fingerprint already keys on).
  #
  # The load-bearing metric is BODY-DIVERGENT: collisions whose two typed bodies
  # render to different `to_s`. Those are the only never-stale hazard; the rest
  # are merge-equivalent and need no extra identity.
  def self.collision_audit(program : Program) : Nil
    groups = Hash(String, Array(Collider)).new { |h, k| h[k] = [] of Collider }
    walk_types(program) do |type|
      next unless type.is_a?(DefInstanceContainer)
      type.def_instances.each do |key, typed_def|
        name = typed_def.mangled_name(program, type)
        groups[name] << Collider.new(key, typed_def, type)
      end
    end

    total = 0
    non_primitive = 0
    diff_source = 0    # different source def (DefId completeness gap)
    diff_argtypes = 0  # same source, arg_types.to_s differ (llvm_name aliasing)
    body_divergent = 0 # bodies' to_s differ (the real never-stale hazard)
    benign = 0         # same source, bodies' to_s identical
    divergent_samples = [] of String
    benign_samples = [] of String

    groups.each do |name, colliders|
      # Distinct typed defs only (def_instances can hold the same object twice
      # under different keys when use_cache short-circuits).
      distinct = colliders.uniq { |c| c.typed_def.object_id }
      next if distinct.size < 2
      total += distinct.size - 1

      real = distinct.reject do |c|
        c.typed_def.body.is_a?(Crystal::Primitive) || c.typed_def.abstract?
      end
      next if real.size < 2
      non_primitive += real.size - 1

      a = real[0]
      real[1..].each do |b|
        same_source = a.key.def_object_id == b.key.def_object_id
        same_args = a.key.arg_types.map(&.to_s) == b.key.arg_types.map(&.to_s)
        # Compare bodies with auto-generated temp-var counters canonicalized:
        # `__temp_5516` vs `__temp_5756` is the same body instantiated at two
        # different points, not a real divergence. Codegen emits one body per
        # symbol, so only a post-normalization difference is a true hazard.
        same_body = normalize_body(a.typed_def.to_s) == normalize_body(b.typed_def.to_s)

        diff_source += 1 unless same_source
        diff_argtypes += 1 if same_source && !same_args

        if same_body
          benign += 1
          if benign_samples.size < 6
            benign_samples << "#{name}\n    same_source=#{same_source} same_args=#{same_args}" \
                              "\n    A block=#{a.key.block_type} named=#{named_args_shape(a.key)}" \
                              "\n    B block=#{b.key.block_type} named=#{named_args_shape(b.key)}"
          end
        else
          body_divergent += 1
          if divergent_samples.size < 8
            divergent_samples << "#{name}\n    same_source=#{same_source} same_args=#{same_args}" \
                                 "\n    A loc=#{a.typed_def.location} block=#{a.key.block_type} named=#{named_args_shape(a.key)}" \
                                 "\n    B loc=#{b.typed_def.location} block=#{b.key.block_type} named=#{named_args_shape(b.key)}" \
                                 "\n    --- A.to_s ---\n#{indent(a.typed_def.to_s)}" \
                                 "\n    --- B.to_s ---\n#{indent(b.typed_def.to_s)}"
          end
        end
      end
    end

    STDERR.puts "[inc-collide] total=#{total} NON-PRIMITIVE=#{non_primitive} " \
                "body-divergent(HAZARD)=#{body_divergent} benign(merge-equiv)=#{benign} " \
                "diff-source=#{diff_source} diff-argtypes=#{diff_argtypes}"
    unless divergent_samples.empty?
      STDERR.puts "[inc-collide] === BODY-DIVERGENT samples (real hazard) ==="
      divergent_samples.each { |s| STDERR.puts "[inc-collide] #{s}" }
    end
    STDERR.puts "[inc-collide] === BENIGN samples (merge-equivalent) ==="
    benign_samples.each { |s| STDERR.puts "[inc-collide] #{s}" }
  end

  # Canonicalize compiler-generated temp-var names (`__temp_<n>`) so two
  # instantiations of the same body that merely differ in the global temp
  # counter compare equal.
  private def self.normalize_body(s : String) : String
    s.gsub(/__temp_\d+/, "__temp_N")
  end

  private def self.named_args_shape(key : DefInstanceKey) : String
    na = key.named_args
    return "nil" unless na
    na.map { |n| "#{n.name}:#{n.type}" }.join(",")
  end

  private def self.indent(s : String) : String
    s.lines.map { |l| "      #{l}" }.join('\n')
  end

  # Structural identity of a type: its name, instance vars + their types, and
  # ancestry. Any change here bumps the epoch and forces a full rebuild.
  private def self.type_structure(type : Type) : String
    String.build do |str|
      str << type.class.name << ' ' << type.to_s
      if type.is_a?(InstanceVarContainer)
        type.all_instance_vars.each do |name, ivar|
          str << "\n @" << name << ' ' << (ivar.type? ? ivar.type.to_s : "?")
        end
      end
      type.ancestors.each { |anc| str << "\n < " << anc.to_s }
      # A const/enum-member with a compile-time value (Int/Bool/Char/Enum) is
      # INLINED into every reading module's `.o`, but the reader's fingerprint
      # only sees the const by name. Fold the value into the epoch so any
      # value-only edit forces a full rebuild (never a stale inlined literal).
      str << "\n =" << type.compile_time_value.inspect if type.is_a?(Const)
    end
  end

  # Public walk over every type in the program (deduped by object id), including
  # file-private types (FileModules), which live outside `program.types`.
  def self.walk_types(program : Program, &block : Type ->) : Nil
    visited = Set(UInt64).new
    each_type(program, visited, &block)
    program.file_modules.each_value { |fm| each_type(fm, visited, &block) }
    # Union types live only in `program.unions`, not under any namespace's `types?`,
    # so without this they're absent from `pin_type_ids` and get lazily-assigned
    # type_ids during codegen (in walk-vs-seed order) — which diverges cold-vs-warm.
    program.unions.each_value { |u| each_type(u, visited, &block) }
  end

  # Walk every type once: nested types, generic instantiations, metaclasses, and
  # virtual types (deduped by object id).
  private def self.each_type(type : Type, visited : Set(UInt64), &block : Type ->) : Nil
    return unless visited.add?(type.object_id)
    block.call(type)

    if type.is_a?(NamedType) || type.is_a?(Program) || type.is_a?(FileModule)
      type.types?.try &.each_value { |inner| each_type(inner, visited, &block) }
    end

    if type.is_a?(GenericType)
      type.each_instantiated_type { |inst| each_type(inst, visited, &block) }
    end

    # `existing_metaclass` (not `metaclass`) so this stays a pure read: the lazy
    # `metaclass` getter would materialize a never-demanded metaclass type, which
    # then gets a type_id and bloats the emitted type tables. A genuinely-used
    # metaclass already exists (typing `T.class` created it) and is still walked.
    metaclass = type.existing_metaclass
    each_type(metaclass, visited, &block) if metaclass && metaclass != type

    # Virtual types live only as `@virtual_type` on their base, never in any
    # parent's `types?`, so without this their `def_instances` (from `super`,
    # with-scope, proc pointers) are missed by fingerprinting/seeding -> their
    # methods become undefined symbols when a caller module is skipped.
    if type.is_a?(ClassType) || type.is_a?(GenericClassInstanceType)
      vt = type.virtual_type?
      each_type(vt, visited, &block) if vt && vt != type
    end
  end
end
