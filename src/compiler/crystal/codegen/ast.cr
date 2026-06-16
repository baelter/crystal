require "../syntax/ast"

module Crystal
  class ASTNode
    def no_returns?
      !!type?.try &.no_return?
    end
  end

  class Def
    property? abi_info = false

    def mangled_name(program, self_type)
      name = String.build do |str|
        str << '*'

        if owner = @owner
          if owner.metaclass?
            self_type.instance_type.llvm_name(str)
            if original_owner != self_type
              str << '@'
              original_owner.instance_type.llvm_name(str)
            end
            str << "::"
          elsif !owner.is_a?(Crystal::Program)
            self_type.llvm_name(str)
            if original_owner != self_type
              str << '@'
              original_owner.llvm_name(str)
            end
            str << '#'
          end
        end

        str << self.name.gsub('@', '.')

        next_def = self.next
        while next_def
          str << '\''
          next_def = next_def.next
        end

        if args.size > 0 || uses_block_arg?
          str << '<'
          if args.size > 0
            args.each_with_index do |arg, i|
              str << ", " if i > 0
              arg.type.llvm_name(str)
            end
          end
          if uses_block_arg?
            str << ", " if args.size > 0
            str << '&'
            block_arg.not_nil!.type.llvm_name(str)
          end
          str << '>'
        end
        if return_type = @type
          str << ':'
          return_type.llvm_name(str)
        end

        # Incremental codegen (Move 1): the symbol so far is a function of the
        # concrete self/arg/return TYPES only, so two distinct overloads whose
        # parameters render to the same concrete `llvm_name` collapse onto one
        # symbol with two different bodies (e.g. the two `Type#common_descendent`
        # overloads). Fold in a build-stable, structural identity of the resolved
        # `Def` so name -> body is a pure function and codegen can never land a
        # different overload body under a shared symbol. Only under `--incremental`
        # so normal builds keep their original (shorter) symbol names and output.
        str << "$D" << def_id_digest if program.codegen_incremental?
      end

      Crystal.safe_mangling(program, name)
    end

    @def_id_digest : String?

    # Build-stable disambiguator among same-mangled overloads. Derived purely
    # from the def's syntactic signature (name + parameter restrictions + splat/
    # block shape + free vars + return restriction) — NOT object_id (per-process)
    # and NOT source location (renders non-deterministically for macro
    # expansions / VirtualFiles). Overloads must differ in signature, so this
    # distinguishes them; `previous_def` chains are already disambiguated by the
    # `'` next-chain in the mangled name above.
    private def def_id_digest : String
      @def_id_digest ||= begin
        src = String.build do |io|
          io << @name << '|'
          @args.each { |a| io << a.restriction.try(&.to_s) << ',' }
          io << "|s" << @splat_index
          io << "|ds" << @double_splat.try(&.restriction).try(&.to_s)
          io << "|b" << @block_arg.try(&.restriction).try(&.to_s)
          io << "|ba" << @block_arity
          io << "|r" << @return_type.try(&.to_s)
          io << "|fv" << @free_vars.try(&.join(","))
        end
        ::Crystal::Digest::MD5.hexdigest { |ctx| ctx.update(src) }[0, 12]
      end
    end

    def varargs?
      false
    end

    def call_convention
      nil
    end

    @c_calling_convention : Bool? = nil
    property c_calling_convention

    # Returns `self` as an `External` if this Def is an External
    # that must respect the C calling convention.
    def c_calling_convention?
      if @c_calling_convention.nil?
        @c_calling_convention = compute_c_calling_convention
      end

      @c_calling_convention ? self : nil
    end

    def llvm_intrinsic?
      self.is_a?(External) && self.real_name.starts_with?("llvm.")
    end

    private def compute_c_calling_convention
      # One case where this is not true if for LLVM intrinsics.
      # For example overflow intrinsics return a tuple, like {i32, i1}:
      # in C ABI that is represented as i64, but we need to keep the original
      # type here, respecting LLVM types, not the C ABI.
      if self.is_a?(External)
        return !self.real_name.starts_with?("llvm.")
      end

      # Another case is when an argument is an external struct, in which
      # case we must respect the C ABI (this applies to Crystal methods
      # and procs too)

      # Only applicable to procs (no owner) for now
      owner = @owner
      if owner
        return false
      end

      proc_c_calling_convention?
    end

    def proc_c_calling_convention?
      # We use C ABI if:
      # - all arguments are allowed in lib calls (because then it can be passed to C)
      # - at least one argument type, or the return type, is an extern struct
      found_extern = false

      if (type = self.type?)
        type = type.remove_alias
        if type.extern?
          found_extern = true
        elsif !type.void? && !type.nil_type? && !type.allowed_in_lib?
          return false
        end
      end

      args.each do |arg|
        arg_type = arg.type.remove_alias
        if arg_type.extern?
          found_extern = true
        elsif !arg_type.allowed_in_lib?
          return false
        end
      end

      found_extern
    end
  end

  class Asm
    def dialect : LLVM::InlineAsmDialect
      intel? ? LLVM::InlineAsmDialect::Intel : LLVM::InlineAsmDialect::ATT
    end
  end
end
