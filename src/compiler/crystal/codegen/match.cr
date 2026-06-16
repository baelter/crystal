require "./codegen"

class Crystal::CodeGenVisitor
  def match_type_id(type, restriction, type_id)
    match_type_id_impl(type.remove_indirection, restriction.remove_indirection, type_id)
  end

  private def match_type_id_impl(type, restriction : Program, type_id)
    llvm_true
  end

  private def match_type_id_impl(type, restriction : FileModule, type_id)
    llvm_true
  end

  private def match_type_id_impl(type : UnionType | VirtualType | VirtualMetaclassType, restriction, type_id)
    match_any_type_id(restriction, type_id)
  end

  private def match_type_id_impl(type : AliasType, restriction, type_id)
    match_type_id type.aliased_type, restriction, type_id
  end

  private def match_type_id_impl(type, restriction, type_id)
    equal? type_id(restriction), type_id
  end

  def match_any_type_id(type, type_id)
    match_any_type_id_impl(type.remove_indirection, type_id)
  end

  private def match_any_type_id_impl(type : UnionType | VirtualType | VirtualMetaclassType, type_id)
    match_any_type_id_with_function(type, type_id)
  end

  private def match_any_type_id_impl(type, type_id)
    equal? type_id(type), type_id
  end

  private def match_any_type_id_with_function(type, type_id)
    match_fun_name = "~match<#{type.llvm_name}>"
    record_main_symbol("match", match_fun_name, type.to_s, aux: match_aux(type))
    func = typed_fun?(@main_mod, match_fun_name) || create_match_fun(match_fun_name, type)
    func = check_main_fun match_fun_name, func
    call func, [type_id] of LLVM::Value
  end

  # Incremental replay payload for a `~match<T>` function: the exact set of
  # type_ids the function returns true for, captured as normalized [lo,hi]
  # ranges. The function is a pure predicate over an i32 type_id; reproducing
  # the same matched id-set yields a behaviorally identical function, so warm
  # replay needs no type re-resolution (type_ids are pinned and asserted stable).
  private def match_aux(type) : Hash(String, String)?
    return nil unless track_generated_funs?
    ranges = normalize_id_ranges(match_id_ranges(type))
    {"ranges" => ranges.map { |lo, hi| "#{lo}:#{hi}" }.join(",")}
  end

  # Matched id-ranges of a `~match<T>` body, mirroring `create_match_fun_body`'s
  # overloads (the per-type overload is what gives `each_concrete_type` etc. a
  # narrow enough static type to resolve).
  private def match_id_ranges(type : UnionType) : Array(Tuple(Int32, Int32))
    ranges = [] of Tuple(Int32, Int32)
    type.expand_union_types.each { |sub| ranges.concat any_match_id_ranges(sub) }
    ranges
  end

  private def match_id_ranges(type : VirtualType) : Array(Tuple(Int32, Int32))
    min, max = @program.llvm_id.min_max_type_id(type.base_type).not_nil!
    [{min, max}]
  end

  private def match_id_ranges(type) : Array(Tuple(Int32, Int32))
    ranges = [] of Tuple(Int32, Int32)
    type.each_concrete_type do |sub|
      tid = @program.llvm_id.type_id(sub)
      ranges << {tid, tid}
    end
    ranges
  end

  # Mirror of `match_any_type_id` for a union member: recurse for nested
  # union/virtual types, otherwise a single matched type_id (point range).
  private def any_match_id_ranges(type) : Array(Tuple(Int32, Int32))
    t = type.remove_indirection
    case t
    when UnionType, VirtualType, VirtualMetaclassType
      match_id_ranges(t)
    else
      tid = @program.llvm_id.type_id(t)
      [{tid, tid}]
    end
  end

  # Sort and merge contiguous/overlapping integer ranges (a point is [id,id]).
  # The matched set is unchanged; only the representation is compacted.
  private def normalize_id_ranges(ranges : Array(Tuple(Int32, Int32))) : Array(Tuple(Int32, Int32))
    return ranges if ranges.size <= 1
    sorted = ranges.sort_by { |lo, _| lo }
    merged = [sorted.first]
    sorted[1..].each do |lo, hi|
      last_lo, last_hi = merged.last
      if lo <= last_hi + 1
        merged[-1] = {last_lo, Math.max(last_hi, hi)}
      else
        merged << {lo, hi}
      end
    end
    merged
  end

  private def create_match_fun(name, type)
    in_main do
      define_main_function(name, ([llvm_context.int32]), llvm_context.int1) do |func|
        set_internal_fun_debug_location(func, name)
        type_id = func.params.first
        # Incremental: emit the predicate from baked pinned-type_id ranges, exactly
        # as the warm replay (`ensure_main_match_fun`) reconstructs it, so cold and
        # warm produce byte-identical `~match` bodies. The cold walk would otherwise
        # load `:type_id` globals and compare per-type, diverging from the replay.
        # Sound because type_ids are pinned and asserted stable.
        if track_generated_funs?
          emit_match_id_ranges_body(normalize_id_ranges(match_id_ranges(type)), type_id)
        else
          create_match_fun_body(type, type_id)
        end
      end
    end
  end

  # Emit a `~match` predicate body from normalized id-ranges, baking pinned
  # type_ids as constants (point => eq, range => signed lo<=id<=hi), OR-combined.
  # Shared by the cold walk (above) and the warm replay so their IR is identical.
  def emit_match_id_ranges_body(ranges : Array(Tuple(Int32, Int32)), type_id) : Nil
    result = nil
    ranges.each do |(lo, hi)|
      cond = if lo == hi
               equal?(int(lo), type_id)
             else
               and(builder.icmp(LLVM::IntPredicate::SGE, type_id, int(lo)),
                 builder.icmp(LLVM::IntPredicate::SLE, type_id, int(hi)))
             end
      result = result ? or(result, cond) : cond
    end
    ret(result || llvm_false)
  end

  private def create_match_fun_body(type : UnionType, type_id)
    result = nil
    type.expand_union_types.each do |sub_type|
      sub_type_cond = match_any_type_id(sub_type, type_id)
      result = result ? or(result, sub_type_cond) : sub_type_cond
    end
    ret result.not_nil!
  end

  private def create_match_fun_body(type : VirtualType, type_id)
    min, max = @program.llvm_id.min_max_type_id(type.base_type).not_nil!
    ret(
      and(
        builder.icmp(LLVM::IntPredicate::SGE, type_id, int(min)),
        builder.icmp(LLVM::IntPredicate::SLE, type_id, int(max))
      )
    )
  end

  private def create_match_fun_body(type, type_id)
    result = nil
    type.each_concrete_type do |sub_type|
      sub_type_cond = equal? type_id(sub_type), type_id
      result = result ? or(result, sub_type_cond) : sub_type_cond
    end
    ret result.not_nil!
  end
end
