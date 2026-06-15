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
      when "match"      then false # union/virtual/nilable types aren't all
      # re-resolvable by name yet; let the pre-flight evict importers, which
      # regenerate and re-emit the `~match` themselves.
      else true
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

    def initialize(@epoch, @modules, @objects, @live, @exports, @imports,
                   @eager_main, @main_symbols, @type_id_table)
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

    walk_types(program) do |type|
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

    loop do
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
      evict.each { |mod| skip.delete(mod) }
    end

    if ENV["CRYSTAL_INC_DEBUG"]?
      satisfiers = replayed.dup
      prev.exports.each do |mod, syms|
        syms.each { |s| satisfiers << s if skip.includes?(mod) || mod.empty? || index.has_key?(s) }
      end
      unmet = Hash(String, Int32).new(0)
      (candidate - skip).each do |mod|
        (prev.imports[mod]? || Array(String).new).each do |s|
          unmet[classify_symbol(s)] += 1 unless satisfiers.includes?(s)
        end
      end
      STDERR.puts "[inc] candidate=#{candidate.size} skipped=#{skip.size} evicted=#{candidate.size - skip.size}"
      STDERR.puts "[inc] unmet-import kinds (evicting): #{unmet.to_a.sort_by { |_, n| -n }.first(12)}"
    end

    skip
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
    return true if prev.type_id_table.empty?
    current_table == prev.type_id_table
  end

  # Assign an id to every type up front in a deterministic (sorted) order, so
  # the lazy order-dependent fallback never decides an id, and snapshot the
  # table for the determinism assert above.
  def self.pin_type_ids(program : Program) : Hash(String, Int32)
    types = [] of Type
    walk_types(program) do |type|
      next if type.is_a?(VirtualType) || type.is_a?(VirtualMetaclassType)
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
  def self.instantiation_index(program : Program) : Hash(String, {Def, Type})
    index = {} of String => {Def, Type}
    walk_types(program) do |type|
      next unless type.is_a?(DefInstanceContainer)
      type.def_instances.each_value do |typed_def|
        index[typed_def.mangled_name(program, type)] = {typed_def, type}
      end
    end
    index
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

    metaclass = type.metaclass
    each_type(metaclass, visited, &block) if metaclass != type

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
