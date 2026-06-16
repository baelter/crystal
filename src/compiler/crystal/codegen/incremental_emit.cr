require "./codegen"

# Incremental codegen replay (Layer 2): re-emit, in main, the lazily-emitted
# helper symbols a reused (skipped) module's cached `.o` references but that the
# pruned walk would not re-emit. Driven by the persisted `main_symbols` ledger.
#
# The helpers below create only the *definitions* in `@main_mod`; they must not
# emit use-instructions (`load`/`call`/`gep`) into the current block, which is
# positioned inside whatever function the walk last generated.
#
# Replay is best-effort for the speedup: any kind not handled here simply isn't
# re-emitted, so the pre-flight (`IncrementalCodegen.satisfy`) evicts the
# importing module and it regenerates. Correctness never depends on this being
# complete.
class Crystal::CodeGenVisitor
  def force_main_symbols(prev : IncrementalCodegen::State)
    return if prev.main_symbols.empty?

    const_index = {} of String => Const
    IncrementalCodegen.walk_types(@program) do |type|
      const_index[type.llvm_name] = type if type.is_a?(Const)
    end

    prev.main_symbols.each do |rec|
      case rec.kind
      when "type_id"
        # No type lookup: emit the global directly from the captured integer.
        if id = rec.aux.try &.["id"]?
          ensure_main_type_id_global(rec.name, id.to_i)
        end
      when "const"
        if (const = const_index[rec.key]?) && (shape = rec.shape)
          ensure_main_const(const, shape)
        end
      when "classname_map"
        ensure_main_classname_map
      when "metaclass"
        ensure_main_metaclass_fun
      when "check_proc"
        ensure_main_check_proc_fun
      when "match"
        if ranges = rec.aux.try &.["ranges"]?
          ensure_main_match_fun(rec.name, ranges)
        end
      end
    end
  end

  # Re-emit a `~match<T>` predicate from its captured id-ranges (point => eq,
  # range => signed lo<=id<=hi), OR-combined. Behaviorally identical to the
  # cold build's function because type_ids are pinned; uses constants instead of
  # loading `:type_id` globals, so it carries no extra imports.
  private def ensure_main_match_fun(name : String, ranges : String)
    return if typed_fun?(@main_mod, name)
    parsed = ranges.split(',').reject(&.empty?).map do |pair|
      lo, _, hi = pair.partition(':')
      {lo.to_i, hi.to_i}
    end
    in_main do
      define_main_function(name, [llvm_context.int32], llvm_context.int1) do |func|
        set_internal_fun_debug_location(func, name)
        type_id = func.params.first
        emit_match_id_ranges_body(parsed, type_id)
      end
    end
  end

  # `~metaclass`: one global fun whose body switches over the pinned
  # `id_to_metaclass` map.
  private def ensure_main_metaclass_fun
    name = "~metaclass"
    return if typed_fun?(@main_mod, name)
    create_metaclass_fun(name)
  end

  # `~check_proc_is_not_closure`: one global fun with a fixed body.
  private def ensure_main_check_proc_fun
    name = "~check_proc_is_not_closure"
    return if typed_fun?(@main_mod, name)
    create_check_proc_is_not_closure_fun(name)
  end

  # Mirror of the `@main_mod` global creation in `type_id_impl` (type_id.cr),
  # without the trailing `load`. The integer is the one captured at cold-build
  # emit time (pinned, so stable), so no type object is needed — robust for any
  # type, including lib/ephemeral types not in the type-name walk.
  private def ensure_main_type_id_global(name : String, id : Int32)
    return if @main_mod.globals[name]?

    global = @main_mod.globals.add(@main_llvm_context.int32, name)
    global.linkage = LLVM::Linkage::Internal if @single_module
    global.initializer = @main_llvm_context.int32.const_int(id)
    global.global_constant = true
  end

  # Define the const's main symbols the same way `read_const_pointer` would, but
  # without the use-site `call`. The cold build's branch (read fn vs bare global)
  # and mutable flags are restored from the frozen shape, then restored back so
  # `process_finished_hooks`/`finish` never observe replay-set values.
  private def ensure_main_const(const, shape : IncrementalCodegen::SymbolShape)
    saved_read = const.read?
    saved_nif = const.no_init_flag?
    begin
      if shape.emitted_read_fn
        name = "~#{const.llvm_name}:const_read"
        return if typed_fun?(@main_mod, name)
        const.read = true
        const.no_init_flag = shape.no_init_flag
        create_read_const_function(name, const) # read fn + init fn + global + flag
      else
        declare_const(const)
      end
    ensure
      const.read = saved_read
      const.no_init_flag = saved_nif
    end
  end

  # Mirror of the `@main_mod` global creation in `type_id_to_class_name`
  # (codegen.cr), without the trailing `gep`/`load`.
  private def ensure_main_classname_map
    name = "__crystal_type_id_to_class_name_map"
    return if @main_mod.globals[name]?

    global = @main_mod.globals.add(@main_llvm_typer.llvm_type(@program.string).array(@program.llvm_id.@ids.size), name)
    global.linkage = LLVM::Linkage::Internal if @single_module
    global.initializer = create_type_id_to_class_name_map
    global.global_constant = true
  end
end
