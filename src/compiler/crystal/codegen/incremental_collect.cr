require "./codegen"

# Move 2 (experimental prototype): a reachability Collector that computes the
# set of codegen-reachable method instantiations WITHOUT generating LLVM IR, by
# walking the typed AST from roots and resolving each call via `Call#target_defs`
# (the exact overloads semantic resolved per call site) — never by re-resolving a
# mangled name through a collision-prone index. This is the rustc/Zig model: one
# pass, recomputed from roots every build, the single source of truth for "what
# to emit". If it reproduces the codegen walk's live set exactly, it can replace
# the divergent seed (`codegen_changed_instantiations`).
#
# Mirrors `CodeGenVisitor#visit(Call)` / `codegen_call`: self_type for an
# instantiation is `node.scope` for `super`, else `target_def.owner`; primitives
# and `External`s emit no function (inlined / declared), so they are not added.
class Crystal::IncrementalCodegen::Collector < Crystal::Visitor
  getter reachable = Set(String).new

  def initialize(@program : Crystal::Program)
    @worklist = [] of Crystal::Def
    @seen_defs = Set(UInt64).new
    @proc_counts = {} of String => Int32
  end

  @current_def : Crystal::Def?

  def collect(root : Crystal::ASTNode) : Set(String)
    root.accept(self)
    # Secondary codegen reachability roots that are NOT reached through the
    # top-down call walk (codegen emits them via dedicated machinery): class-var
    # initializers, finished hooks, and used consts' initializer expressions.
    @program.class_var_initializers.each { |i| i.node.accept(self) }
    @program.finished_hooks.each { |h| h.node.accept(self) }
    Crystal::IncrementalCodegen.walk_types(@program) do |t|
      t.value.accept(self) if t.is_a?(Crystal::Const) && t.used?
    end
    until @worklist.empty?
      d = @worklist.pop
      @current_def = d
      d.body.accept(self)
    end
    reachable
  end

  getter nil_target_calls = 0
  getter resolved_calls = 0
  getter nil_names = {} of String => Int32

  def visit(node : Crystal::Call) : Bool
    if tds = node.target_defs
      @resolved_calls += 1
      tds.each { |td| reach(td, node) }
    else
      @nil_target_calls += 1
      (@nil_names[node.name] ||= 0)
      @nil_names[node.name] += 1
      if (p = ENV["CRYSTAL_INC_COLLECT_PROBE"]?) && node.name == p
        cd = @current_def
        ctx = cd ? "#{cd.name}@#{cd.owner} (#{cd.location})" : "ROOT"
        obj = node.obj
        STDERR.puts "[probe] nil '#{node.name}' in #{ctx}  obj=#{obj.class} obj_type=#{obj.try(&.type?)} expanded=#{!node.expanded.nil?} call_loc=#{node.location}"
      end
    end
    true
  end

  # Mirror codegen `visit(Def)`: do NOT descend into the generic (untyped)
  # template body — method bodies are reached only as instantiations via the
  # worklist. Only the hook expansions are walked at definition time.
  def visit(node : Crystal::Def) : Bool
    node.hook_expansions.try &.each { |h| h.accept(self) }
    false
  end

  def visit(node : Crystal::Macro) : Bool
    false
  end

  # A proc literal materializes its `def` as a function; walk its (typed) body
  # for callee reachability. (The proc function's own special symbol name is not
  # reproduced here yet.)
  def visit(node : Crystal::ProcLiteral) : Bool
    # Reproduce codegen's fun_literal_name (codegen.cr `fun_literal_name`). The
    # per-(type,location) counter is order-dependent — matched here on a best
    # effort; the count==1 case (the vast majority) is order-independent. The
    # right long-term fix is content-addressed proc naming (Move 3).
    loc = node.location.try &.expanded_location
    if loc && (type = node.type?) && (fname = loc.filename).is_a?(String)
      base = Crystal.safe_mangling(@program, "~proc#{type}@#{Crystal.relative_filename(fname)}:#{loc.line_number}")
      cnt = (@proc_counts[base]? || 0) + 1
      @proc_counts[base] = cnt
      name = cnt > 1 ? "#{base[0...5]}#{cnt}#{base[5..-1]}" : base
      reachable << name
    end
    d = node.def
    @worklist << d if @seen_defs.add?(d.object_id)
    true
  end

  def visit(node : Crystal::ASTNode) : Bool
    true
  end

  private def reach(td : Crystal::Def, call : Crystal::Def | Crystal::Call)
    probe = ENV["CRYSTAL_INC_COLLECT_PROBE"]?
    if td.is_a?(Crystal::External)
      STDERR.puts "[probe] skip External: #{td.name}" if probe && td.name.includes?(probe)
      return
    end
    if td.body.is_a?(Crystal::Primitive)
      STDERR.puts "[probe] skip Primitive: #{td.name}" if probe && td.name.includes?(probe)
      return
    end

    self_type = (call.is_a?(Crystal::Call) && call.super?) ? call.scope : td.owner
    unless self_type
      STDERR.puts "[probe] skip nil self_type: #{td.name} owner=#{td.owner}" if probe && td.name.includes?(probe)
      return
    end

    name = td.mangled_name(@program, self_type)
    if probe && name.includes?(probe)
      STDERR.puts "[probe] REACH #{name} (new=#{!reachable.includes?(name)})"
    end
    return unless reachable.add?(name)
    return unless @seen_defs.add?(td.object_id)
    @worklist << td
  end
end

class Crystal::Program
  # Debug-only: compare the Collector's reachable instance set to the codegen
  # walk's actual live set (@generated_funs). Prints the symmetric difference so
  # the gap can be driven to zero. Gated on CRYSTAL_INC_COLLECT_CHECK.
  def incremental_collect_check(root : Crystal::ASTNode, live : Set(String)) : Nil
    collector = Crystal::IncrementalCodegen::Collector.new(self)
    collected = collector.collect(root)
    STDERR.puts "[inc-collect] resolved_calls=#{collector.resolved_calls} nil_target_calls=#{collector.nil_target_calls}"
    top = collector.nil_names.to_a.sort_by { |_, n| -n }.first(25)
    STDERR.puts "[inc-collect] top nil-target call names: #{top}"
    missing = live - collected # codegen emitted, collector missed (DANGEROUS)
    extra = collected - live   # collector found, codegen didn't (benign/over-count)
    STDERR.puts "[inc-collect] live=#{live.size} collected=#{collected.size} missing(live-collected)=#{missing.size} extra(collected-live)=#{extra.size}"
    if path = ENV["CRYSTAL_INC_COLLECT_DUMP"]?
      File.write("#{path}.missing", missing.to_a.sort.join('\n'))
      File.write("#{path}.extra", extra.to_a.sort.join('\n'))
    end
    STDERR.puts "[inc-collect] sample MISSING (codegen emitted, collector missed):"
    missing.to_a.sort.first(25).each { |m| STDERR.puts "[inc-collect]   #{m}" }
  end
end
