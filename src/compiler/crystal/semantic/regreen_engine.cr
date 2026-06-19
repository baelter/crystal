module Crystal
  # Phase-2 incremental semantic analysis (M3): the in-process "re-green" engine.
  #
  # During a full inference pass it records, for every freshly created method
  # instantiation, the originating `Call` plus the `DefInstanceKey`/owner that
  # cache it. A chosen subset can then be torn down (cache entry evicted) and
  # re-inferred by re-running each originating call's `Call#recalculate` — the
  # compiler's own fixpoint re-entry point, which already unbinds the old
  # targets, re-runs `lookup_matches`/`instantiate`, and re-binds, propagating
  # any signature change forward through the dataflow graph.
  #
  # The M3a gate (re-infer idempotence, no source edit) asserts that re-inferring
  # a subset against the fixed (green) rest of the program reproduces a
  # byte-identical typed program, measured by the sound codegen fingerprint
  # (`IncrementalCodegen.compute`). This isolates the central "no firewall" risk:
  # inference is a push-based fixpoint, so re-running part of it must reproduce
  # the whole-program result.
  #
  # Active only when `Program#regreen` is set (env `CRYSTAL_M3`), so ordinary
  # builds pay nothing.
  class ReGreenEngine
    record Instance,
      call : Call,
      key : DefInstanceKey,
      owner : DefInstanceContainer,
      typed_def : Def,
      untyped_def : Def,
      cached : Bool

    getter instances = [] of Instance

    # The instances freshly created during the most recent re-green. Their typed
    # bodies are new and have NOT passed through the (memoized) cleanup
    # transformer; the resident re-codegen path cleans them explicitly, because
    # the main cleanup walk skips any def whose callers were cleaned on an earlier
    # cycle and so never descends far enough to reach them.
    getter last_regreen_instances = [] of Instance

    # Object ids of `Type`s first materialized during a prior re-green cycle's
    # codegen: a union memoized into `program.unions`, or a metaclass the IR walk
    # reached through the lazy `metaclass` getter. A fresh build mints these only
    # AFTER its pin/epoch snapshot (during its one-shot codegen), so they are
    # absent from its saved state. In a resident process they linger in the type
    # graph and `LLVMId`'s id cache, so a later cycle's `compute` (epoch) and
    # `pin_type_ids` (id table) would otherwise diverge from the saved state —
    # bloating the type-id map / forcing a spurious full rebuild. Both skip these
    # so a cycle's fingerprint matches the fresh build's exactly. They keep their
    # cached codegen ids (which already match the fresh build's), so excluding
    # them from the PIN TABLE never changes a baked id. A type the re-green
    # SEMANTIC pass creates is never here (the snapshot is taken around codegen
    # only), so it still counts. Accumulated by `note_codegen_types`.
    getter codegen_created_types = Set(UInt64).new

    # The object ids of every currently-materialized type (a pure read — uses the
    # non-creating metaclass walk). The resident diffs this around each codegen to
    # learn which types that codegen materialized.
    def self.materialized_type_ids(program : Program) : Set(UInt64)
      ids = Set(UInt64).new
      IncrementalCodegen.walk_types(program) { |t| ids << t.object_id }
      ids
    end

    # Fold the types a just-finished codegen materialized (*after* − *before*,
    # the resident's snapshots around the codegen call) into the exclusion set.
    def note_codegen_types(before : Set(UInt64), after : Set(UInt64)) : Nil
      fresh = after - before
      @codegen_created_types.concat(fresh)
      STDERR.puts "[m3union] codegen materialized #{fresh.size} type(s)" if ENV["CRYSTAL_M3_UNION_DEBUG"]?
    end

    # Maps an edited method's identity (owner object-id, name) to its current
    # re-greened (canonical) instance. A virtual multidispatch realizes per-
    # subtype branches at inference and codegen INLINES a trivial leaf's body
    # straight from a clone in the branch's `target_defs`; that clone is uncached
    # and unrecorded, so re-green's call-rebind never reaches it and codegen would
    # emit the stale body. Codegen consults this map (see `canonical_for`) to
    # inline the re-greened body instead. Keyed by identity, not object, so it
    # also catches clones the engine never saw.
    getter canonical_instances = {} of {UInt64, String} => Def

    # The re-greened instance to inline in place of *target_def* when codegen is
    # about to inline a trivial method during a re-green build, or nil if
    # *target_def* is already canonical / not an edited method. (See
    # `canonical_instances`.)
    def canonical_for(target_def : Def) : Def?
      return nil if @canonical_instances.empty?
      ow = target_def.owner?
      return nil unless ow
      canon = @canonical_instances[{ow.object_id, target_def.name}]?
      canon if canon && canon.object_id != target_def.object_id
    end

    # Called from `Call#instantiate` at the creation site of a fresh instance.
    # *untyped_def* is the template (`match.def`) the instance was cloned from;
    # its `object_id` matches `key.def_object_id` and identifies an edit seed.
    def record(call : Call, key : DefInstanceKey, owner : DefInstanceContainer,
               typed_def : Def, untyped_def : Def, cached : Bool) : Nil
      @instances << Instance.new(call, key, owner, typed_def, untyped_def, cached)
    end

    # Re-infer every recorded instance whose mangled name contains *filter*
    # (all instances if *filter* is empty): evict the cache entry, then re-run
    # the originating call. *main_node* is the program's top-level AST (so calls
    # to edited methods made from top level, not just from other instances, are
    # rebound — see `rebind_referencing_calls`). Returns {reinferred,
    # recalc_errors, unsound}.
    def reinfer(program : Program, filter : String, main_node : ASTNode? = nil) : {Int32, Int32, Int32}
      # Name-filter (M3a idempotence) selection is INCIDENTAL: a virtual-
      # multidispatch branch caught here has an unchanged body, so skipping its
      # unsound re-dispatch is correct.
      reinfer_instances(program, select_victims(program, filter), skip_dispatch: true, main_node: main_node)
    end

    # Re-infer the instances cloned from any of *seed_def_ids* (the untyped defs
    # whose bodies were spliced for an edit). Re-running each originating call
    # re-clones the now-edited body and re-infers; binding propagation flows any
    # signature change to observers. Returns {reinferred, recalc_errors, unsound}.
    def reinfer_defs(program : Program, seed_def_ids : Set(UInt64), main_node : ASTNode? = nil) : {Int32, Int32, Int32}
      victims = @instances.select { |i| seed_def_ids.includes?(i.untyped_def.object_id) }
      # Edit (M3b) selection is INTENTIONAL: these instances' bodies changed and
      # MUST be re-inferred. Skipping a virtual-multidispatch branch here would
      # leave the edit un-applied (silently stale), so do NOT skip — re-run it;
      # if that over-instantiates / leaves unexpanded nodes, the soundness gate
      # reports it and the caller fails closed (editing a virtually-dispatched
      # method is out of the proven envelope).
      reinfer_instances(program, victims, skip_dispatch: false, main_node: main_node)
    end

    # Map of the distinct untyped defs that were instantiated and live in
    # *only_file*, keyed by "line:column:name". Filename-independent in the key
    # (so it matches a re-parsed edited source at a different path) but scoped to
    # the edited file, so a prelude def at the same line:col:name can't collide.
    def untyped_defs_by_location(only_file : String) : Hash(String, Def)
      result = {} of String => Def
      @instances.each do |i|
        d = i.untyped_def
        next unless d.location.try(&.filename) == only_file
        if key = ReGreenEngine.loc_key(d)
          result[key] ||= d
        end
      end
      result
    end

    def self.loc_key(node : Def) : String?
      loc = node.location
      return nil unless loc
      "#{loc.line_number}:#{loc.column_number}:#{node.name}"
    end

    # The splice path can only soundly apply an edit that changes method BODIES
    # with unchanged signatures: re-green re-infers the body-changed instances in
    # place. Anything else — an added/removed/renamed/re-signatured def, a changed
    # constant or class-var initializer, a changed top-level expression, a new
    # `require` — alters program state the splice never touches, so the warm build
    # would silently keep the old value. `body_only_edit?` is the gate: it holds
    # iff *old_ast* and *new_ast* differ ONLY inside def bodies. When it is false
    # the caller must FAIL CLOSED to a full re-inference. Pass the RAW (un-
    # normalized) parsed ASTs: normalization expands sugar (array/range literals,
    # `OpAssign`, ...) into program-counter-numbered `__temp_N` vars, and two
    # separate normalize passes number them differently, which would make even an
    # unchanged top-level expression skeleton-differ (a spurious fail-closed).
    def self.body_only_edit?(old_ast : ASTNode, new_ast : ASTNode) : Bool
      skeleton(old_ast) == skeleton(new_ast)
    end

    # `__END_LINE__` resolves to the ENCLOSING construct's end line, baked at parse;
    # a body edit can change that end without moving the `__END_LINE__` token, so
    # neither the skeleton nor ordinal seed-matching can detect the change. It is
    # rare, so the caller fails closed whenever it is present. Over-approximates
    # (matches in comments/strings too) — safe, a false hit only costs a fail-closed.
    # (`__LINE__` needs no such check: it bakes a `NumberLiteral` of its own line,
    # which moves with its def, so ordinal seed-matching re-splices it.)
    def self.has_end_line_token?(src : String) : Bool
      src.matches?(/\b__END_LINE__\b/)
    end

    # An AST's structural "skeleton": its source rendering with every `Def` body
    # blanked to `Nop`. Two ASTs share a skeleton iff they differ only in def
    # bodies — every signature, constant/class-var initializer, top-level
    # statement and the set+order of defs is otherwise identical. Bodies are
    # blanked in place and restored, so the AST is unchanged on return.
    def self.skeleton(ast : ASTNode) : String
      collector = DefCollector.new
      ast.accept(collector)
      saved = collector.defs.map(&.body)
      collector.defs.each { |d| d.body = Nop.new }
      begin
        ast.to_s
      ensure
        collector.defs.each_with_index { |d, i| d.body = saved[i] }
      end
    end

    # Collects every `Def` node in an AST (including those nested in type
    # bodies), for matching a re-parsed edited source against the recorded defs.
    class DefCollector < Visitor
      getter defs = [] of Def

      def visit(node : Def)
        @defs << node
        true
      end

      def visit(node : ASTNode)
        true
      end
    end

    # An instance is a VIRTUAL-MULTIDISPATCH BRANCH when its originating call
    # resolves over a virtual receiver to many concrete subtype methods (the
    # call's `target_defs` holds one entry per matching subtype). Re-running such
    # a call via `recalculate` re-walks `instance_type.subtypes` against the now
    # fully-populated hierarchy and synthesizes nested per-subtype dispatchers
    # (e.g. `*File::Error+@File::Error::to_s` for subtypes that themselves have
    # subclasses) that a cold build's incremental subclass-observer construction
    # never produced — and whose `{{ @type.name }}` macro bodies are left
    # unexpanded, crashing codegen. The branch body itself is unchanged by an
    # edit elsewhere, so it needs no re-inference; skip it. (Re-greening an edit
    # to a virtually-dispatched method itself is out of the current envelope and
    # must fall back to full re-inference.)
    private def multidispatch_branch?(i : Instance) : Bool
      (tds = i.call.target_defs) ? tds.size > 1 : false
    end

    private def reinfer_instances(program : Program, all_victims : Array(Instance), skip_dispatch : Bool, main_node : ASTNode? = nil) : {Int32, Int32, Int32}
      # CRYSTAL_M3_NOSKIP reverts to the pre-fix behavior (re-run every victim,
      # including virtual-multidispatch branches) so the skip's effect can be
      # A/B'd against the baseline.
      if skip_dispatch && !ENV["CRYSTAL_M3_NOSKIP"]?
        dispatch, victims = all_victims.partition { |i| multidispatch_branch?(i) }
      else
        dispatch = [] of Instance
        victims = all_victims
      end
      STDERR.puts "[m3] skipped #{dispatch.size} virtual-multidispatch branch victim(s)" if !dispatch.empty? && ENV["CRYSTAL_M3_ATTRIBUTE"]?
      regreen_start = @instances.size
      victims.each { |i| i.owner.def_instances.delete(i.key) }
      errors = 0
      attribute = ENV["CRYSTAL_M3_ATTRIBUTE"]?
      if attribute
        victims.each do |i|
          c = i.call
          obj = c.obj
          STDERR.puts "[m3-call] victim #{mangled_name(program, i).inspect} <- call name=#{c.name.inspect} obj_type=#{obj.try(&.type?)} scope=#{c.scope?} target_defs=#{c.target_defs.try(&.size)}"
        end
      end
      victims.each do |i|
        before = attribute ? all_instance_names(program) : Set(String).new
        i.call.recalculate
        if attribute
          created = all_instance_names(program) - before
          unless created.empty?
            STDERR.puts "[m3-attr] recalc #{mangled_name(program, i).inspect} created #{created.size} new instance(s):"
            created.to_a.sort!.first(20).each { |c| STDERR.puts "[m3-attr]    + #{c}" }
          end
        end
      rescue ex
        errors += 1
        STDERR.puts "[m3] recalculate raised for #{mangled_name(program, i).inspect}: #{ex.message}"
      end
      # Re-running each victim's ORIGINATING call rebinds that one call site to
      # the freshly created instance, but other references to the edited method
      # keep their stale binding, so codegen still emits the old body. Two kinds:
      #   * sibling CALL SITES still bound to the evicted instance (a method
      #     called from several callers); a type-stable body edit fires no
      #     dataflow propagation, so the fixpoint never refreshes them;
      #   * STALE CLONES — uncached per-subtype copies a virtual multidispatch
      #     minted at inference (never cached, never recorded by `record`),
      #     reachable only through a dispatch's `expanded` branch `target_defs`.
      #     They share the edited template's (owner, name) but are a different
      #     object carrying the old body.
      # Both are exactly the defs whose (owner, name) matches an edited template
      # yet are NOT one of the instances this re-green just created. Rebind every
      # call referencing one; recalculating re-resolves it to the cached instance.
      created = @instances[regreen_start..]
      @last_regreen_instances = created
      good_ids = created.map(&.typed_def.object_id).to_set
      edited = Set({UInt64, String}).new
      victims.each do |v|
        if ow = v.untyped_def.owner?
          edited << {ow.object_id, v.untyped_def.name}
        end
      end
      rebound = rebind_stale_clones(program, main_node, edited, good_ids)
      STDERR.puts "[m3] rebound #{rebound} stale call site(s)" if rebound > 0 && ENV["CRYSTAL_M3_ATTRIBUTE"]?
      # Record each edited method's current canonical instance so codegen can
      # inline its (re-greened) body instead of a stale uncached multidispatch
      # clone (see `canonical_instances`).
      victims.each do |v|
        ow = v.untyped_def.owner?
        canon = v.owner.def_instances[v.key]?
        @canonical_instances[{ow.object_id, v.untyped_def.name}] = canon if ow && canon
      end
      {victims.size, errors, unsound_count(created)}
    end

    # Find every `Call` whose `target_defs` holds a STALE instance of an edited
    # template — a def matching an edited (owner, name) that is not one of the
    # instances this re-green created — and recalculate it so it re-resolves to
    # the cached, re-greened instance. Walks the top-level *main_node* and every
    # live def-instance body, descending into `expanded` (where a multidispatch's
    # per-subtype branch calls live; `Call#accept_children` skips `expanded`).
    private def rebind_stale_clones(program : Program, main_node : ASTNode?, edited : Set({UInt64, String}), good_ids : Set(UInt64)) : Int32
      return 0 if edited.empty?
      scanner = StaleCloneScanner.new(edited, good_ids)
      main_node.try &.accept(scanner)
      IncrementalCodegen.walk_types(program) do |type|
        next unless type.is_a?(DefInstanceContainer)
        type.def_instances.each_value { |td| td.body.accept(scanner) }
      end
      scanner.calls.each do |c|
        c.recalculate
      rescue
        # A site that fails to recalculate leaves an orphan reference; the
        # unexpanded-node soundness gate / the caller's fail-closed contract
        # cover the resulting divergence.
      end
      scanner.calls.size
    end

    # FAIL-CLOSED gate for the default-argument hazard. When a method `m` with a
    # defaulted arg is called with that arg omitted, the default VALUE expression
    # is cloned into a synthetic expansion def; that clone is not reliably reached
    # by `rebind_referencing_calls`, so if the default value calls an EDITED
    # (re-greened) method, the default-arg site silently keeps the old binding.
    # Detect it conservatively: true if any *seed_names* method is named by a Call
    # inside ANY def's argument default value. Over-approximates by name (a same-
    # named unrelated method also trips it) — safe, costing only a fail-closed.
    def self.seed_in_default_arg?(program : Program, seed_names : Set(String)) : Bool
      return false if seed_names.empty?
      finder = DefaultArgCallFinder.new(seed_names)
      IncrementalCodegen.walk_types(program) do |type|
        next unless type.is_a?(ModuleType)
        type.defs.try &.each_value do |list|
          list.each do |dwm|
            dwm.def.args.each do |arg|
              arg.default_value.try &.accept(finder)
            end
          end
        end
      end
      finder.found
    end

    # Sets `found` if it visits a `Call` named in the given set (used to scan
    # argument default-value expressions for references to edited methods).
    class DefaultArgCallFinder < Visitor
      getter found = false

      def initialize(@names : Set(String))
      end

      def visit(node : Call)
        @found = true if @names.includes?(node.name)
        true
      end

      def visit(node : ASTNode)
        true
      end
    end

    # Soundness gate: count the instances FRESHLY created during this re-green
    # whose typed body still holds an unexpanded `ExpandableNode` (`||`, `&&`,
    # macro expression, literal sugar, ...). A fully-inferred cold build has none
    # — `MainVisitor` expands every instantiated body — and codegen raises
    # "should have been expanded" on any it reaches. So a non-zero count means
    # re-inference failed to reproduce the cold result for these bodies (a known
    # limitation for some cascade paths); the caller must FAIL CLOSED to a full
    # re-inference rather than emit a stale/crashing program.
    private def unsound_count(created : Array(Instance)) : Int32
      scanner = UnexpandedScanner.new
      created.each { |i| i.typed_def.body.accept(scanner) }
      scanner.count
    end

    # Counts unexpanded `ExpandableNode`s (those whose `expanded` is still nil)
    # reachable in a typed body.
    class UnexpandedScanner < Visitor
      getter count = 0

      def visit(node : ExpandableNode)
        @count += 1 if node.expanded.nil?
        true
      end

      def visit(node : ASTNode)
        true
      end
    end

    # Collects every `Call` whose `target_defs` includes a STALE instance of an
    # edited template: a def whose (owner, name) matches an edited template but
    # whose object is not among the freshly re-greened instances (the evicted
    # victim, or an uncached multidispatch clone). Descends into `expanded`, which
    # `Call#accept_children` skips but codegen emits — that is where a
    # multidispatch's per-subtype branch calls (and their stale clones) live.
    class StaleCloneScanner < Visitor
      getter calls = [] of Call

      def initialize(@edited : Set({UInt64, String}), @good : Set(UInt64))
      end

      def visit(node : Call)
        if (tds = node.target_defs) && tds.any? { |td| stale?(td) }
          @calls << node
        end
        node.expanded.try &.accept(self)
        true
      end

      private def stale?(td : Def) : Bool
        return false if @good.includes?(td.object_id)
        (ow = td.owner?) ? @edited.includes?({ow.object_id, td.name}) : false
      end

      def visit(node : ASTNode)
        true
      end
    end

    # All current def-instance mangled names (walk every type). Used only by the
    # CRYSTAL_M3_ATTRIBUTE diagnostic to attribute newly-created instances to the
    # originating recalculated call.
    private def all_instance_names(program : Program) : Set(String)
      names = Set(String).new
      IncrementalCodegen.walk_types(program) do |type|
        next unless type.is_a?(DefInstanceContainer)
        type.def_instances.each_value do |typed_def|
          names << typed_def.mangled_name(program, type.as(Type))
        end
      end
      names
    end

    private def select_victims(program : Program, filter : String) : Array(Instance)
      return @instances if filter.empty?
      @instances.select { |i| mangled_name(program, i).includes?(filter) }
    end

    private def mangled_name(program : Program, i : Instance) : String
      i.typed_def.mangled_name(program, i.owner.as(Type))
    rescue
      "<#{i.typed_def.name}>"
    end

    # Clear the per-build state that codegen mutates on shared AST/type objects,
    # so a resident process can codegen the (re-greened) program again as if in a
    # fresh process. A normal build never needs this — it runs once per process —
    # but in-process repeated codegen would otherwise inherit stale flags:
    #   * `External#dead` — `Codegen#visit(FunDef)` sets it `true` to avoid
    #     emitting a fun twice WITHIN one build; left set, the 2nd cycle skips
    #     re-emitting funs like `__crystal_raise_overflow` into the fresh main
    #     module, and codegen raises "Missing __crystal_raise_overflow". Externals
    #     dead since *semantic_dead* (duplicate fun declarations) stay dead.
    #   * `Const#initializer` — `initialize_simple_const` bakes the LLVM init
    #     value here (unguarded by incremental); left set, the 2nd cycle's
    #     `initialize_const` early-returns without emitting the initializer.
    #   * `MetaTypeVar#simple_initializer` — set when a simple class var's value
    #     is baked straight into its main-module global; left set, the 2nd cycle
    #     short-circuits `create_initialize_class_var_function` and never re-bakes
    #     the global into the fresh main module, so it links undefined.
    def self.reset_codegen_emission_state(program : Program, main_node : ASTNode, semantic_dead : Set(UInt64)) : Nil
      main_node.accept(FunDefDeadResetter.new(semantic_dead))
      IncrementalCodegen.walk_types(program) do |type|
        type.initializer = nil if type.is_a?(Const)
        if type.is_a?(ClassVarContainer)
          type.class_vars?.try &.each_value(&.simple_initializer = false)
        end
      end
    end

    # Object ids of externals already dead after semantic — `add_external` marks
    # all but the LAST declaration of a fun dead. Those must stay dead across all
    # codegen cycles; only the live funs codegen flips ("already emitted") reset.
    def self.collect_dead_externals(main_node : ASTNode) : Set(UInt64)
      collector = DeadExternalCollector.new
      main_node.accept(collector)
      collector.ids
    end

    class DeadExternalCollector < Visitor
      getter ids = Set(UInt64).new

      def visit(node : FunDef) : Bool
        if (ext = node.external?) && ext.dead?
          @ids << ext.object_id
        end
        false
      end

      def visit(node : ASTNode) : Bool
        true
      end
    end

    # Resets `External#dead` on the top-level funs codegen marked emitted, leaving
    # the *semantic_dead* (duplicate-declaration) externals untouched, so the next
    # codegen re-emits the live funs (see `reset_codegen_emission_state`).
    class FunDefDeadResetter < Visitor
      def initialize(@semantic_dead : Set(UInt64))
      end

      def visit(node : FunDef) : Bool
        if (ext = node.external?) && !@semantic_dead.includes?(ext.object_id)
          ext.dead = false
        end
        false
      end

      def visit(node : ASTNode) : Bool
        true
      end
    end
  end
end
