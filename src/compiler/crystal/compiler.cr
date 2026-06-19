require "option_parser"
require "file_utils"
require "colorize"
require "crystal/digest/md5"
{% if flag?(:msvc) %}
  require "./loader"
{% end %}
{% if flag?(:preview_mt) %}
  require "wait_group"
{% end %}

module Crystal
  # This exception describes an error in the compiler.
  # It usually leads to an unsuccessful process exit.
  class CompilerError < Exception
    getter status

    def self.new(message, exit : Command::Exit)
      new message, status: exit.to_i
    end

    def initialize(message, *, @status : Int32 = 1)
      super message
    end
  end

  @[Flags]
  enum Debug
    LineNumbers
    Variables
    Default     = LineNumbers
  end

  enum FramePointers
    Auto
    Always
    NonLeaf
  end

  # Main interface to the compiler.
  #
  # A Compiler parses source code, type checks it and
  # optionally generates an executable.
  class Compiler
    DEFAULT_LINKER = ENV["CC"]? || {{ env("CRYSTAL_CONFIG_CC") || "cc" }}
    MSVC_LINKER    = ENV["CC"]? || {{ env("CRYSTAL_CONFIG_CC") || "cl.exe" }}

    # A source to the compiler: its filename and source code.
    record Source,
      filename : String,
      code : String

    # The result of a compilation: the program containing all
    # the type and method definitions, and the parsed program
    # as an ASTNode.
    record Result,
      program : Program,
      node : ASTNode

    # If `true`, doesn't generate an executable but instead
    # creates a `.o` file and outputs a command line to link
    # it in the target machine.
    property? cross_compile = false

    # Compiler flags. These will be true when checked in macro
    # code by the `flag?(...)` macro method.
    property flags = [] of String

    # Controls generation of frame pointers.
    property frame_pointers = FramePointers::Auto

    # If `true`, the executable will be generated with debug code
    # that can be understood by `gdb` and `lldb`.
    property debug = Debug::Default

    # If `true`, `.ll` files will be generated in the default cache
    # directory for each generated LLVM module.
    property? dump_ll = false

    # Additional link flags to pass to the linker.
    property link_flags : String?

    # Sets the mcpu. Check LLVM docs to learn about this.
    property mcpu : String?

    # Sets the mattr (features). Check LLVM docs to learn about this.
    property mattr : String?

    # If `false`, color won't be used in output messages.
    property? color = true

    # If `true`, skip cleanup process on semantic analysis.
    property? no_cleanup = false

    # If `true`, no executable will be generated after compilation
    # (useful to type-check a program)
    property? no_codegen = false

    # Maximum number of LLVM modules that are compiled in parallel
    property n_threads : Int32 = {% if flag?(:execution_context) %}
      Fiber::ExecutionContext.default_workers_count
    {% elsif flag?(:preview_mt) %}
      ENV["CRYSTAL_WORKERS"]?.try(&.to_i?) || 4
    {% elsif flag?(:win32) %}
      1
    {% else %}
      8
    {% end %}

    # Default prelude file to use. This ends up adding a
    # `require "prelude"` (or whatever name is set here) to
    # the source file to compile.
    property prelude = "prelude"

    # Optimization mode
    enum OptimizationMode
      # [default] no optimization, fastest compilation, slowest runtime
      O0 = 0

      # low, compilation slower than O0, runtime faster than O0
      O1 = 1

      # middle, compilation slower than O1, runtime faster than O1
      O2 = 2

      # high, slowest compilation, fastest runtime
      # enables with --release flag
      O3 = 3

      # optimize for size, enables most O2 optimizations but aims for smaller
      # code size
      Os

      # optimize aggressively for size rather than speed
      Oz

      def suffix
        ".#{to_s.downcase}"
      end

      def self.from_level?(level : String) : self?
        case level
        when "0" then O0
        when "1" then O1
        when "2" then O2
        when "3" then O3
        when "s" then Os
        when "z" then Oz
        end
      end
    end

    # Sets the Optimization mode.
    property optimization_mode = OptimizationMode::O0

    # Sets the code model. Check LLVM docs to learn about this.
    property mcmodel = LLVM::CodeModel::Default

    # If `true`, generates a single LLVM module. By default
    # one LLVM module is created for each type in a program.
    # --release automatically enable this option
    property? single_module = false

    # A `ProgressTracker` object which tracks compilation progress.
    property progress_tracker = ProgressTracker.new

    # Codegen target to use in the compilation.
    # If not set, asks LLVM the default one for the current machine.
    property codegen_target = Config.host_target

    # If `true`, prints the link command line that is performed
    # to create the executable.
    property? verbose = false

    # If `true`, doc comments are attached to types and methods
    # and can later be used to generate API docs.
    property? wants_doc = false

    # Warning settings and all detected warnings.
    property warnings = WarningCollection.new

    @[Flags]
    enum EmitTarget
      ASM
      OBJ
      LLVM_BC
      LLVM_IR
    end

    # Can be set to a set of flags to emit other files other
    # than the executable file:
    # * asm: assembly files
    # * llvm-bc: LLVM bitcode
    # * llvm-ir: LLVM IR
    # * obj: object file
    property emit_targets : EmitTarget = EmitTarget::None

    # Base filename to use for `emit` output.
    property emit_base_filename : String?

    # By default the compiler cleans up the default cache directory
    # to keep the most recent 10 directories used. If this is set
    # to `false` that cleanup is not performed.
    property? cleanup = true

    # Default standard output to use in a compilation.
    property stdout : IO = STDOUT

    # Default standard error to use in a compilation.
    property stderr : IO = STDERR

    # Whether to show error trace
    property? show_error_trace = false

    # Whether to link statically
    property? static = false

    property dependency_printer : DependencyPrinter? = nil

    # When set, semantic analysis records cross-file use dependencies into it.
    # See `Crystal::SemanticDependencyTracker` and `crystal tool
    # semantic-dependencies`.
    property semantic_dependencies : SemanticDependencyTracker? = nil

    # Experimental: skip regenerating LLVM IR for type-modules whose typed
    # definitions are unchanged since the last build, linking their cached `.o`
    # directly. See `Crystal::IncrementalCodegen`. Off by default.
    property? incremental = false

    # Experimental `--watch`: after the first build, watch the required source
    # files and re-run an `--incremental` build (a child process, so each rebuild
    # is a fresh, sound, never-stale build) whenever one changes. Off by default.
    property? watch = false

    # The original invocation args (captured before option parsing consumed
    # them) used to reconstruct the child build command in `run_watch`.
    property watch_argv : Array(String)? = nil

    # Program that was created for the last compilation.
    property! program : Program

    # Compiles the given *source*, with *output_filename* as the name
    # of the generated executable.
    #
    # Raises `Crystal::CodeError` if there's an error in the
    # source code.
    #
    # Raises `InvalidByteSequenceError` if the source code is not
    # valid UTF-8.
    def compile(source : Source | Array(Source), output_filename : String) : Result
      compile_configure_program(source, output_filename) { }
    end

    # :ditto:
    #
    # Yields a `Program` instance before compiling.
    def compile_configure_program(source : Source | Array(Source), output_filename : String, & : Program -> Nil) : Result
      source = [source] unless source.is_a?(Array)
      program = new_program(source)
      yield program
      # Experimental incremental-semantic graph (phase 2): record def-level
      # caller->callee edges during inference, dump after semantic. Off unless
      # CRYSTAL_SEM_GRAPH is set, so ordinary builds are unaffected.
      sem_graph_path = ENV["CRYSTAL_SEM_GRAPH"]?
      program.semantic_graph = SemanticGraph.new if sem_graph_path
      # Phase-2 (M3) incremental-semantic experiments. Cleanup is disabled in
      # these modes so the fingerprint reflects raw inference output (cleanup is
      # a separate post-pass not re-run by partial re-inference), keeping the
      # warm/cold comparison fair. Modes (env, off by default):
      #   CRYSTAL_M3=a     — M3a idempotence: re-infer a subset, assert unchanged
      #   CRYSTAL_M3B_NEW  — M3b re-green: splice an edited source, re-infer, dump
      #   CRYSTAL_M3_FP    — dump the cold fingerprint (ground truth) and exit
      # M3 modes are an INCREMENTAL-only experiment (they compare against a cold
      # `--incremental` build). Gate activation on `incremental?` so a nested
      # macro-`run` host compilation (e.g. ECR's `{{ run("ecr/process") }}`,
      # triggered on a cold cache) — which is a fresh non-incremental `Compiler`
      # that inherits the `CRYSTAL_M3_*` env — does NOT enter the experiment path
      # and `exit 0`, hijacking the parent build.
      incr = incremental?
      m3a_mode = incr ? ENV["CRYSTAL_M3"]? : nil
      m3b_new = incr ? ENV["CRYSTAL_M3B_NEW"]? : nil
      m3_fp = incr ? ENV["CRYSTAL_M3_FP"]? : nil
      m3_noexit = incr ? ENV["CRYSTAL_M3_NOEXIT"]? : nil
      m3_resident = incr ? ENV["CRYSTAL_M3_RESIDENT"]? : nil
      m3_dump_files = incr ? ENV["CRYSTAL_M3_DUMP_FILES"]? : nil
      # `--watch` drives the in-process re-green resident loop by default (no env):
      # record instantiations during this cold build, leave the AST uncleaned for
      # re-green, and hand off to `run_watch_resident` after the first build.
      watch_resident = incr && watch? && !@no_codegen
      m3_mode = m3a_mode || m3b_new || m3_fp || m3_resident || m3_dump_files || watch_resident
      program.regreen = ReGreenEngine.new if m3a_mode || m3b_new || m3_resident || m3_dump_files || watch_resident
      node = parse program, source

      # M3 experiments disable main-node cleanup so re-green operates on raw
      # inference output (cleanup is a post-pass that partial re-inference does
      # not re-run); the NOEXIT binary-equivalence experiment runs cleanup AFTER
      # re-green (below), matching the real feature's order (re-green is part of
      # inference, cleanup follows), then proceeds to codegen.
      begin
        node = program.semantic node, cleanup: (m3_mode ? false : !no_cleanup?)
      rescue ex : SkipMacroCodeCoverageException
        program.macro_expansion_error_hook.try &.call(ex.cause)
      end

      if (graph = program.semantic_graph) && (path = sem_graph_path)
        File.open(path, "w") { |f| graph.dump(program, f) }
      end

      if (engine = program.regreen) && m3_dump_files
        # Diagnostic: histogram of files holding instantiated, cached (re-green-
        # eligible) templates, so a self-build edit can target a method that
        # actually re-greens. Counts distinct (line:col:name) defs per file.
        only = m3_dump_files == "1" ? nil : m3_dump_files
        if only
          # Per-method dump for files whose path contains the given substring:
          # exact (line:col:name) of every recorded, re-green-eligible template.
          seen = Set(String).new
          engine.instances.each do |i|
            fn = i.untyped_def.location.try(&.filename)
            next unless fn.is_a?(String) && fn.includes?(only)
            key = ReGreenEngine.loc_key(i.untyped_def)
            next unless key
            stderr.puts "[m3def] #{key}" if seen.add?(key)
          end
        else
          hist = Hash(String, Int32).new(0)
          seen = Set({String, String}).new
          engine.instances.each do |i|
            fn = i.untyped_def.location.try(&.filename)
            next unless fn.is_a?(String)
            key = ReGreenEngine.loc_key(i.untyped_def)
            next unless key
            hist[fn] += 1 if seen.add?({fn, key})
          end
          hist.to_a.sort_by! { |_, n| -n }.first(40).each do |fn, n|
            stderr.puts "[m3files] #{n}\t#{fn}"
          end
        end
        exit 0
      end

      if path = m3_fp
        program.codegen_incremental = true
        m3_stabilize(program) # settle the walk's lazy type materialization
        m3_dump_fp(IncrementalCodegen.compute(program), path)
        if reach_path = ENV["CRYSTAL_M3_REACH"]?
          File.write(reach_path, m3_reach(program, node).to_a.sort!.join('\n'))
        end
        exit 0
      end

      if watch_resident && (engine = program.regreen)
        run_watch_resident(program, engine, node, source, output_filename)
        return Result.new program, node
      end

      if (engine = program.regreen) && m3_resident
        run_m3_resident(program, engine, node, source)
      end

      if (engine = program.regreen) && (new_path = m3b_new) && !m3_resident
        run_m3b_experiment(program, engine, new_path, source.first.filename, node)
      end

      if (engine = program.regreen) && !m3b_new && !m3_resident
        run_m3_experiment(program, engine, node)
      end

      # NOEXIT binary-equivalence experiment: re-green ran on the uncleaned
      # program above; now run the normal cleanup pass (as the real feature
      # would, after inference) so codegen can proceed.
      if m3_noexit && program.regreen
        node = program.cleanup(node)
        program.cleanup_types
        program.cleanup_files
      end

      units = codegen program, node, source, output_filename unless @no_codegen

      @progress_tracker.clear
      print_macro_run_stats(program)
      print_codegen_stats(units)

      Result.new program, node
    end

    # `--watch`: hold the typed program in memory after the first build and, on
    # each source change, re-green only the edited method bodies and re-run
    # `--incremental` codegen IN PROCESS — the semantic-amortizing fast rebuild.
    # Any edit outside the body-only splice envelope (a signature/def-set change,
    # a const/top-level edit, a new or removed `require`), or a re-green that
    # can't reproduce the cold result, falls back to a fresh `crystal build
    # --incremental` subprocess and then re-execs `--watch` so the resident
    # program matches disk again. Never stale by construction: every rebuild is
    # byte-identical to a cold build of that source, or IS a cold build.
    private def run_watch_resident(program, engine, node, sources, output_filename) : Nil
      program.codegen_incremental = true
      # First build: clean + codegen the initial binary and capture the dead-
      # external baseline the per-cycle codegen reset needs (externals dead since
      # semantic — duplicate fun declarations — must stay dead across cycles).
      cleaned = program.cleanup(node)
      program.cleanup_types
      program.cleanup_files
      semantic_dead = ReGreenEngine.collect_dead_externals(cleaned)
      m3_stabilize(program)
      codegen program, cleaned, sources, output_filename

      # Snapshot each watched file's CONTENT (the pre-edit source the gate diffs
      # against — the file is edited in place) and mtime.
      watched = Set(String).new
      program.requires.each { |f| watched << f if File.file?(f) }
      sources.each { |s| watched << s.filename if File.file?(s.filename) }
      src = {} of String => String
      mtime = {} of String => Time
      watched.each do |f|
        src[f] = File.read(f)
        mtime[f] = File.info(f).modification_time
      end

      child = (watch_argv || ARGV).reject { |a| a == "--watch" }
      child << "--incremental" unless child.includes?("--incremental")
      exe = Process.executable_path || PROGRAM_NAME
      stderr.puts "[watch] watching #{watched.size} files — in-process re-green (Ctrl-C to stop)"
      loop do
        sleep 300.milliseconds
        changed = [] of String
        watched.each do |f|
          info = File.info?(f)
          next unless info
          mt = info.modification_time
          next if mtime[f]? == mt
          mtime[f] = mt
          changed << f
        end
        next if changed.empty?
        names = changed.map { |f| File.basename(f) }.join(", ")
        stderr.print "[watch] #{Time.local.to_s("%H:%M:%S")} #{names} — "
        t0 = Time.instant

        # Gate every changed file; the first one outside the body-only envelope
        # (or a brand-new/removed file with no snapshot) forces a full rebuild.
        seeds = Set(UInt64).new
        in_envelope = changed.all? do |f|
          old = src[f]?
          if old && (s = m3_seeds_from_src(program, engine, old, File.read(f), f))
            seeds.concat(s)
            true
          else
            false
          end
        end

        if in_envelope
          n, errors, unsound = engine.reinfer_defs(program, seeds, node)
          if errors == 0 && unsound == 0
            cleaned = program.cleanup(node)
            engine.last_regreen_instances.each { |inst| program.cleanup_transformer.cleanup_def(inst.typed_def) }
            program.cleanup_types
            program.cleanup_files
            ReGreenEngine.reset_codegen_emission_state(program, cleaned, semantic_dead)
            m3_stabilize(program)
            before_types = ReGreenEngine.materialized_type_ids(program)
            codegen program, cleaned, sources, output_filename
            engine.note_codegen_types(before_types, ReGreenEngine.materialized_type_ids(program))
            changed.each { |f| src[f] = File.read(f) }
            stderr.puts "re-green #{n} def(s) (#{(Time.instant - t0).total_seconds.round(2)}s)"
            next
          end
        end

        # Out of envelope: a sound full rebuild, then re-exec `--watch` so the
        # held program matches disk again.
        stderr.puts "full rebuild…"
        status = Process.run(exe, child, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
        dt = (Time.instant - t0).total_seconds.round(2)
        if status.success?
          stderr.puts "[watch] ok (#{dt}s) — reloading"
          Process.exec(exe, watch_argv || ARGV)
        else
          stderr.puts "[watch] FAILED (exit #{status.exit_code}, #{dt}s)"
        end
      end
    end

    # Phase-2 (M3) in-process re-green experiment. Computes the codegen
    # fingerprint, re-infers a subset of instantiations, recomputes the
    # fingerprint, and asserts byte-identity (M3a idempotence: re-inferring a
    # subset against the fixed green boundary must reproduce the whole-program
    # result). Prints a diagnostic report and exits.
    private def run_m3_experiment(program, engine, node)
      program.codegen_incremental = true
      filter = ENV["CRYSTAL_M3_FILTER"]? || ""

      # `compute`/`type_structure` lazily MATERIALIZES generic-module metaclass
      # types as a side effect of rendering ancestors, so two back-to-back calls
      # differ until that settles. Stabilize to a fixpoint so the measurement
      # reflects re-inference only, not the walk's own lazy type creation.
      warm = m3_stabilize(program)
      m0, s0, y0 = IncrementalCodegen.epoch_parts(program)
      fp0 = IncrementalCodegen.compute(program)
      entries0 = IncrementalCodegen.module_entries(program)

      n, errors, unsound = engine.reinfer(program, filter, node)

      m3_stabilize(program)
      m1, s1, y1 = IncrementalCodegen.epoch_parts(program)
      fp1 = IncrementalCodegen.compute(program)
      entries1 = IncrementalCodegen.module_entries(program)

      stderr.puts "[m3a] reinferred #{n} instance(s) (filter=#{filter.inspect}), recalc errors=#{errors}, unexpanded(unsound)=#{unsound}, warmup_iters=#{warm}"
      stderr.puts "[m3a] epoch parts: mangled=#{m0 == m1 ? "==" : "DIFF"} structures=#{s0 == s1 ? "==" : "DIFF"} symbols=#{y0 == y1 ? "==" : "DIFF"}"
      m3_report_list_diff("mangled", m0, m1)
      m3_report_list_diff("structures", s0, s1)
      m3_report_list_diff("symbols", y0, y1)

      all_keys = (fp0.modules.keys + fp1.modules.keys).uniq!
      changed = all_keys.select { |k| fp0.modules[k]? != fp1.modules[k]? }.sort!
      stderr.puts "[m3a] modules: #{fp1.modules.size} total, #{changed.size} differ"
      changed.first(30).each do |k|
        tag = fp0.modules[k]? ? (fp1.modules[k]? ? "changed" : "removed") : "added"
        stderr.puts "   DIFF[#{tag}]: #{k.empty? ? "<main>" : k}"
      end
      # Entry-level diff of the first divergent module: which instances were
      # added/removed (vs changed-in-place), to pinpoint the mechanism.
      changed.first(2).each do |k|
        b = (entries0[k]? || [] of String).to_set
        a = (entries1[k]? || [] of String).to_set
        added = (a - b).to_a.sort!
        removed = (b - a).to_a.sort!
        stderr.puts "   --- module #{k.empty? ? "<main>" : k}: +#{added.size} -#{removed.size} entries ---"
        added.first(4).each { |e| stderr.puts "      +#{e.lines.first?}" }
        removed.first(4).each { |e| stderr.puts "      -#{e.lines.first?}" }
      end
      # Classify each changed module: is the divergence COSMETIC — identical
      # after normalizing the `__temp_<n>` locals that re-inference renumbers
      # (these are SSA-ish names that never reach the `.o`) — or REAL (different
      # instance set / body shape)? Cosmetic-only divergence is a measurement
      # artifact of `compute` hashing the raw `typed_def.to_s`; the emitted code
      # is byte-identical.
      cosmetic = changed.count do |k|
        m3_normalize(entries0[k]? || [] of String) == m3_normalize(entries1[k]? || [] of String)
      end
      stderr.puts "[m3a] of #{changed.size} changed module(s): #{cosmetic} cosmetic (temp-renumber only), #{changed.size - cosmetic} real" unless changed.empty?

      # Reachability of the added/changed instances after re-green: run the
      # from-root collector (the codegen reachability oracle) on the re-greened
      # program and report whether each ADDED mangled name is reachable. Same
      # collector used cold-side (CRYSTAL_M3_REACH), so its incompleteness
      # cancels in the cold-vs-warm comparison. Reachable adds => cold/warm
      # reachability genuinely differs (order-dependence fix); unreachable adds
      # => a post-re-green sweep can evict them.
      reach = m3_reach(program, node)
      added_names = (m1.to_set - m0.to_set).to_a.sort!
      unless added_names.empty?
        n_reachable = added_names.count { |x| reach.includes?(x) }
        stderr.puts "[m3a] reachability of #{added_names.size} added instance(s): #{n_reachable} reachable, #{added_names.size - n_reachable} unreachable (from-root collector, |reach|=#{reach.size})"
        added_names.first(12).each do |x|
          stderr.puts "      #{reach.includes?(x) ? "REACH " : "unreach"} #{x}"
        end
      end
      # Junk measurement: how many of the PRE-re-green instances (== a cold
      # build's def_instances) are themselves unreachable from root? If this is
      # ~0, cold's def_instances == its reachable set and a global reachability
      # sweep is exactly right; if large, cold retains unreachable junk and a
      # global sweep would over-evict.
      junk = (m0.to_set - reach).size
      stderr.puts "[m3a] cold junk: #{m0.size} pre-re-green instances, #{junk} unreachable from root (#{(100.0 * junk / m0.size).round(1)}%)"
      if reach_path = ENV["CRYSTAL_M3_REACH"]?
        File.write(reach_path, reach.to_a.sort!.join('\n'))
      end

      ok = fp0.epoch == fp1.epoch && changed.empty? && errors == 0 && unsound == 0
      stderr.puts "[m3a] RESULT: #{ok ? "IDEMPOTENT" : "DIVERGED"}#{unsound > 0 ? " (UNSOUND: #{unsound} unexpanded node(s) -> would fail closed)" : ""}"
      # CRYSTAL_M3_NOEXIT: proceed to codegen instead of exiting, so the caller
      # can compare the actual emitted binary (re-green vs a no-op-filter cold
      # build, both in this cleanup:false mode) — testing whether the
      # over-instantiation is pruned by codegen and thus correctness-neutral.
      return if ENV["CRYSTAL_M3_NOEXIT"]?
      exit(ok ? 0 : 1)
    end

    # Run the from-root reachability Collector (codegen's reachability oracle,
    # `incremental_collect.cr`) on the typed program and return the set of
    # reachable mangled instance names. Used by the M3 experiments to decide
    # whether over-instantiated virtual instances are genuinely reachable.
    private def m3_reach(program, node) : Set(String)
      Crystal::IncrementalCodegen::Collector.new(program).collect(node)
    end

    # Normalize a module's entry list for cosmetic-vs-real divergence comparison:
    # collapse the auto-generated `__temp_<n>` local counters that re-inference
    # renumbers. Two entry lists that match after this differ only in names that
    # never reach the emitted object.
    private def m3_normalize(entries : Array(String)) : Array(String)
      entries.map(&.gsub(/__temp_\d+/, "__temp_N")).sort!
    end

    # M3b re-green: splice an edited source's changed method bodies into the
    # just-inferred program, re-infer only those defs' instances, and dump the
    # resulting fingerprint. A shell harness compares it to a cold build of the
    # edited source (CRYSTAL_M3_FP). Rung 1 handles body-only (signature-stable)
    # edits; a changed signature (different DefId) is reported and skipped.
    private def run_m3b_experiment(program, engine, new_path, main_file, main_node)
      program.codegen_incremental = true
      edited_file = ENV["CRYSTAL_M3B_FILE"]? || main_file
      seeds = m3_compute_seeds(program, engine, new_path, edited_file)
      unless seeds
        stderr.puts "[m3b] verdict=FAIL_CLOSED reason=non-body-edit (structure/initializer/top-level changed)"
        exit 0 unless ENV["CRYSTAL_M3_NOEXIT"]?
        # Under NOEXIT the caller proceeds to codegen the (un-re-greened) old
        # program; a real wire-up would instead re-infer the new source from
        # scratch. The classifier treats this verdict as the (safe) fail-closed
        # outcome, not a byte-identity claim.
        return
      end

      stderr.puts "[m3b] verdict=SPLICEABLE spliced #{seeds.size} edited def(s)"
      m3_stabilize(program)
      n, errors, unsound = engine.reinfer_defs(program, seeds, main_node)
      m3_stabilize(program)
      out_path = ENV["CRYSTAL_M3B_OUT"]? || "/tmp/m3b_warm.fp"
      m3_dump_fp(IncrementalCodegen.compute(program), out_path)
      stderr.puts "[m3b] reinferred #{n} instance(s), recalc errors=#{errors}, unexpanded(unsound)=#{unsound}, dumped #{out_path}"
      # NOEXIT: proceed to cleanup + codegen (caller) so the spliced/re-greened
      # binary can be compared to a cold build of the edited source.
      return if ENV["CRYSTAL_M3_NOEXIT"]?
      exit 0
    end

    # Gate + splice for ONE edit. Returns the set of spliced seed def object_ids,
    # or `nil` if the edit is not body-only (the caller must FAIL CLOSED). On a
    # non-nil result the matched templates' bodies have already been replaced with
    # the edited (normalized) bodies, ready for `reinfer_defs`.
    private def m3_compute_seeds(program, engine, new_path, edited_file) : Set(UInt64)?
      # Test-harness entry: the edited content lives in a separate file, the
      # original is still pristine on disk. A real watch (`watch_seeds`) instead
      # passes the in-memory pre-edit snapshot, since the file is edited in place.
      m3_seeds_from_src(program, engine, File.read(edited_file), File.read(new_path), edited_file)
    end

    # Gate + splice core shared by the test harness and the watch loop. Returns
    # the set of template object-ids to re-green (empty = no body changed), or
    # nil if the edit is outside the body-only splice envelope (caller fails
    # closed). *old_src*/*new_src* are the file's content before/after the edit;
    # *edited_file* is its path (spliced nodes are parsed under it so locations
    # match an in-place edit and the warm binary stays byte-identical to cold).
    private def m3_seeds_from_src(program, engine, old_src : String, new_src : String, edited_file : String) : Set(UInt64)?
      new_parser = Crystal::Parser.new(new_src)
      new_parser.filename = edited_file
      new_raw = new_parser.parse
      old_raw = Crystal::Parser.new(old_src).parse

      # SOUND EDIT GATE: re-green can only apply a pure method-body change. Any
      # other change (a def's signature, the set/order of defs, a constant or
      # class-var initializer, top-level code) is outside the splice envelope, and
      # `__END_LINE__` (baked at parse from the enclosing end, which a body edit can
      # move without moving the token) is too subtle to track — any presence fails
      # closed. (`__LINE__` is handled below: its baked `NumberLiteral` value moves
      # with its def, so ordinal matching re-splices it.)
      return nil if ReGreenEngine.has_end_line_token?(old_src) || ReGreenEngine.has_end_line_token?(new_src)
      return nil unless ReGreenEngine.body_only_edit?(old_raw, new_raw)

      # Normalize the edited source the same way the cold path does
      # (`SemanticVisitor` normalizes every file before inference) so the extracted
      # bodies match the in-place-normalized templates and a spliced body never
      # carries un-normalized sugar (e.g. `OpAssign`) into re-inference.
      # Snapshot the RAW (un-normalized) body STRINGS by ordinal BEFORE
      # normalizing: `normalize` mutates `new_raw`'s Def nodes in place, and
      # `collect_defs` returns references to those same nodes, so reading their
      # `body.to_s` after normalize would see normalized bodies and make the raw
      # edit-diff below compare raw-vs-normalized (every sugared def reads as
      # changed). Capturing the strings now freezes the pre-normalize source.
      old_defs = collect_defs(old_raw) # RAW old defs (== the templates' source)
      old_raw_bodies = old_defs.map(&.body.to_s)
      new_raw_bodies = collect_defs(new_raw).map(&.body.to_s)

      new_ast = program.normalize(new_raw)
      # Match templates to edited defs by ORDINAL (source-order index), NOT by
      # `line:col:name`: a body edit that changes line count shifts every later
      # def's line, so a location key mis-matches those defs and silently drops
      # their edits (and a `__LINE__` whose def moved). The body-only gate
      # guarantees old and new hold the same defs in the same order, so the i-th
      # corresponds. `old_raw` shares the templates' (old) source, so map a template
      # to its index by its own location, then index into the new defs.
      new_defs = collect_defs(new_ast) # NORMALIZED new defs — the spliced body source
      loc_to_index = {} of String => Int32
      old_defs.each_with_index do |d, i|
        if key = ReGreenEngine.loc_key(d)
          loc_to_index[key] ||= i
        end
      end

      seeds = Set(UInt64).new
      seed_names = Set(String).new
      udl = engine.untyped_defs_by_location(edited_file)
      n_matched = 0
      n_bodydiff = 0
      udl.each do |key, template|
        index = loc_to_index[key]?
        next unless index
        n_matched += 1
        old_body = old_raw_bodies[index]?
        new_body = new_raw_bodies[index]?
        new_def = new_defs[index]?
        next unless old_body && new_body && new_def
        # Detect the edit by diffing the RAW (un-normalized, un-inferred) source
        # bodies at this ordinal: `old_body` is the templates' own source and
        # `new_body` the edited source. Comparing the TEMPLATE body instead is
        # wrong — inference mutates templates in place (macro expansion, type
        # annotations) and normalization renumbers `__temp_<n>` locals, so a
        # source-identical def reads as changed and gets spuriously seeded; re-
        # greening those extra seeds re-runs their (often virtual-dispatch) calls
        # and perturbs unrelated modules, breaking byte identity at scale. The raw
        # source diff seeds exactly the edited defs.
        next if old_body == new_body
        n_bodydiff += 1
        template.body = new_def.body
        seeds << template.object_id
        seed_names << template.name
      end
      if ENV["CRYSTAL_M3_SEED_DEBUG"]?
        stderr.puts "[seeddbg] edited_file=#{edited_file.inspect} udl=#{udl.size} old_defs=#{old_defs.size} matched=#{n_matched} seeded(bodydiff)=#{n_bodydiff} instances=#{engine.instances.size}"
      end

      # FAIL CLOSED if an edited method is named by an argument default value: that
      # value is cloned into an expansion def the rebind scan can't reach, so the
      # default-arg site would keep the stale binding (silent staleness).
      return nil if ReGreenEngine.seed_in_default_arg?(program, seed_names)
      seeds
    end

    private def collect_defs(ast) : Array(Crystal::Def)
      collector = ReGreenEngine::DefCollector.new
      ast.accept collector
      collector.defs
    end

    # Resident-loop feasibility probe (M5 transport). The base program was
    # inferred once (uncleaned); now apply a SEQUENCE of edits to the SAME
    # resident program. Each cycle: gate+splice+reinfer (timed) on the live
    # program, then cleanup + `--incremental` codegen to its own output. The
    # question this answers: does cleanup + codegen mutating the shared program in
    # one cycle poison the next re-green? A shell harness compares each output to
    # a cold build of that edit. Env: CRYSTAL_M3_RESIDENT=1, CRYSTAL_M3B_NEW
    # (edit 1), CRYSTAL_M3B_NEW2 (edit 2), CRYSTAL_M3B_FILE (main path),
    # CRYSTAL_M3_RES_OUT (output prefix).
    private def run_m3_resident(program, engine, node, sources)
      program.codegen_incremental = true
      edited_file = ENV["CRYSTAL_M3B_FILE"]? || sources.first.filename
      out_prefix = ENV["CRYSTAL_M3_RES_OUT"]? || "/tmp/m3res"
      # FINAL_ONLY mode: re-green every edit but only cleanup+codegen after the
      # last one — isolates "is repeated RE-GREEN sound?" from the separate fact
      # that in-process --incremental codegen is one-shot (the per-cycle codegen
      # path crashes on the 2nd build; the resident design instead forks per edit).
      final_only = ENV["CRYSTAL_M3_RES_FINAL_ONLY"]?
      edits = [ENV["CRYSTAL_M3B_NEW"]?, ENV["CRYSTAL_M3B_NEW2"]?,
               ENV["CRYSTAL_M3B_NEW3"]?, ENV["CRYSTAL_M3B_NEW4"]?].compact
      # Externals already dead before the first codegen (duplicate fun
      # declarations) must stay dead across all cycles; only the live funs codegen
      # flips to "already emitted" get reset. Captured from the first cycle's
      # CLEANED tree (the tree codegen walks), since the pre-cleanup `node` does
      # not expose the prelude funs.
      semantic_dead = nil
      edits.each_with_index do |ef, i|
        seeds = m3_compute_seeds(program, engine, ef, edited_file)
        unless seeds
          stderr.puts "[m3res] edit #{i}: FAIL_CLOSED (non-body)"
          next
        end
        t0 = Time.instant
        n, errors, unsound = engine.reinfer_defs(program, seeds, node)
        sem = (Time.instant - t0).total_milliseconds
        stderr.puts "[m3res] edit #{i}: spliced=#{seeds.size} reinfer=#{n} err=#{errors} uns=#{unsound} regreen=#{sem.round(2)}ms"
        if errors > 0 || unsound > 0
          stderr.puts "[m3res] edit #{i}: FAIL_CLOSED (gate)"
          next
        end
        next if final_only && i < edits.size - 1
        cleaned = program.cleanup(node)
        # The memoized cleanup transformer skips any def whose callers were
        # cleaned on an earlier cycle, so the walk above never reaches the bodies
        # re-green just created. Clean them explicitly (the `@transformed` guard
        # makes already-clean ones a no-op).
        engine.last_regreen_instances.each do |inst|
          program.cleanup_transformer.cleanup_def(inst.typed_def)
        end
        program.cleanup_types
        program.cleanup_files
        # In-process re-codegen: clear the per-build state codegen mutates on
        # shared AST/type objects (fun "already emitted" flags, baked const
        # initializers) so this cycle emits as if from a fresh process. The
        # incremental `.o`/state reuse is already cross-cycle by construction
        # (cycle N loads cycle N-1's on-disk state for the same source path).
        # The first codegen needs no reset (nothing emitted yet); it just records
        # the pre-codegen dead baseline.
        if base = semantic_dead
          ReGreenEngine.reset_codegen_emission_state(program, cleaned, base)
        else
          semantic_dead = ReGreenEngine.collect_dead_externals(cleaned)
        end
        # Settle `compute`'s lazy type materialization to a fixpoint so the epoch
        # is stable across in-process cycles. `compute`/`type_structure` lazily
        # materializes generic-module metaclass types as a render side effect, so
        # the epoch a cycle SAVES differs from the next cycle's freshly-computed
        # one until it settles; without this, `reusable` bails on the epoch
        # mismatch (`incremental.cr` `prev.epoch == cur.epoch`) and NO module is
        # skipped. Resident-only — a normal build computes once and never compares
        # across cycles, and stabilizing there would needlessly re-walk all types.
        m3_stabilize(program) unless ENV["CRYSTAL_M3_NOSTAB"]?
        # Snapshot the materialized type set around codegen so the engine learns
        # which types this codegen lazily materialized (metaclasses via the
        # `metaclass` getter, unions into `program.unions`). A fresh build mints
        # those only after its own pin/epoch snapshot, so the next cycle must
        # exclude them to match it — see `ReGreenEngine#codegen_created_types`.
        before_types = ReGreenEngine.materialized_type_ids(program)
        cg0 = Time.instant
        codegen program, cleaned, sources, "#{out_prefix}.#{i}"
        cg = (Time.instant - cg0).total_milliseconds
        engine.note_codegen_types(before_types, ReGreenEngine.materialized_type_ids(program))
        stderr.puts "[m3res] edit #{i}: codegen -> #{out_prefix}.#{i} (#{cg.round(1)}ms, re-green+codegen=#{(sem + cg).round(1)}ms)"
      end
      exit 0
    end

    # Write a fingerprint as a deterministic, diffable text file: the epoch on
    # the first line, then sorted "module<TAB>hash" lines.
    private def m3_dump_fp(fp, path)
      File.open(path, "w") do |f|
        f.puts fp.epoch
        fp.modules.keys.sort!.each { |k| f.puts "#{k}\t#{fp.modules[k]}" }
      end
    end

    # Call `epoch_parts` until two consecutive results match (the lazy-type
    # materialization side effect of the walk has settled). Returns the number
    # of iterations needed (-1 if it never settled). Capped against a loop.
    private def m3_stabilize(program) : Int32
      prev = IncrementalCodegen.epoch_parts(program)
      (1..6).each do |i|
        cur = IncrementalCodegen.epoch_parts(program)
        return i if cur == prev
        prev = cur
      end
      -1
    end

    # Report the set difference between two epoch-component lists (added/removed
    # entries), capped, so a divergence names the exact strings involved.
    private def m3_report_list_diff(label, before : Array(String), after : Array(String))
      return if before == after
      b = before.to_set
      a = after.to_set
      added = (a - b).to_a.sort!
      removed = (b - a).to_a.sort!
      stderr.puts "   [#{label}] +#{added.size} -#{removed.size}"
      added.first(15).each { |x| stderr.puts "      + #{x}" }
      removed.first(15).each { |x| stderr.puts "      - #{x}" }
    end

    # Runs the semantic pass on the given source, without generating an
    # executable nor analyzing methods. The returned `Program` in the result will
    # contain all types and methods. This can be useful to generate
    # API docs, analyze type relationships, etc.
    #
    # Raises `Crystal::CodeError` if there's an error in the
    # source code.
    #
    # Raises `InvalidByteSequenceError` if the source code is not
    # valid UTF-8.
    def top_level_semantic(source : Source | Array(Source)) : Result
      source = [source] unless source.is_a?(Array)
      program = new_program(source)
      node = parse program, source
      node, _ = program.top_level_semantic(node)

      @progress_tracker.clear
      print_macro_run_stats(program)

      Result.new program, node
    end

    # Set maximum level of optimization.
    def release!
      @optimization_mode = OptimizationMode::O3
      @single_module = true
    end

    def release?
      @optimization_mode.o3? && @single_module
    end

    private def new_program(sources)
      @program = program = Program.new
      program.compiler = self
      program.filename = sources.first.filename
      program.codegen_target = codegen_target
      program.target_machine = create_target_machine
      program.flags << "release" if release?
      program.flags << "debug" unless debug.none?
      program.flags << "static" if static?
      program.flags.concat @flags
      program.wants_doc = wants_doc?
      program.color = color?
      program.stdout = stdout
      program.show_error_trace = show_error_trace?
      program.progress_tracker = @progress_tracker
      program.warnings = @warnings
      program.optimization_mode = @optimization_mode
      program.semantic_dependencies = @semantic_dependencies
      program
    end

    private def parse(program, sources : Array)
      @progress_tracker.stage("Parse") do
        nodes = sources.map do |source|
          # We add the source to the list of required file,
          # so it can't be required again
          program.requires.add source.filename
          parse(program, source).as(ASTNode)
        end
        nodes = Expressions.from(nodes)

        # Prepend the prelude to the parsed program
        location = Location.new(program.filename, 1, 1)
        nodes = Expressions.new([Require.new(prelude).at(location), nodes] of ASTNode)

        # And normalize
        program.normalize(nodes)
      end
    end

    private def parse(program, source : Source)
      parser = program.new_parser(source.code)
      parser.filename = source.filename
      parser.wants_doc = wants_doc?
      parser.parse
    rescue ex : InvalidByteSequenceError
      stderr.print colorize("Error: ").red.bold
      stderr.print colorize("file '#{Crystal.relative_filename(source.filename)}' is not a valid Crystal source file: ").bold
      stderr.puts ex.message
      exit 1
    end

    private def bc_flags_changed?(output_dir)
      bc_flags_changed = true
      # `debug` and `frame_pointers` change the emitted `.o` but not a module's
      # incremental fingerprint, so without them here a skipped (reused) module
      # could carry a `.o` built under different settings. Folding them in forces
      # a full rebuild when they change, which is correct (never stale).
      current_bc_flags = "#{@codegen_target}|#{@mcpu}|#{@mattr}|#{@link_flags}|#{@mcmodel}|#{debug}|#{frame_pointers}"
      bc_flags_filename = "#{output_dir}/bc_flags#{optimization_mode.suffix}"
      if File.file?(bc_flags_filename)
        previous_bc_flags = File.read(bc_flags_filename).strip
        bc_flags_changed = previous_bc_flags != current_bc_flags
      end
      File.write(bc_flags_filename, current_bc_flags)
      bc_flags_changed
    end

    private def codegen(program, node : ASTNode, sources, output_filename)
      {% if LibLLVM::IS_LT_130 %}
        if @codegen_target.architecture == "aarch64"
          stderr.puts "Error: Target #{@codegen_target} requires a Crystal compiler built with LLVM 13 or a later version."
          exit 1
        end
      {% end %}

      single_module = @single_module || @cross_compile || !@emit_targets.none?
      output_dir = CacheDir.instance.directory_for(sources)
      bc_flags_changed = bc_flags_changed? output_dir

      # Incremental codegen: fingerprint the typed program before generating IR,
      # then run the pre-flight that shrinks the skip set so the link cannot fail
      # (Layer 1). Codegen runs exactly once — no re-run fallback.
      prev_state = nil
      fingerprints = nil
      skip_modules = Set(String).new
      if incremental? && !single_module
        # Make `Def#mangled_name` fold in the structural DefId for every name it
        # builds this build (fingerprint, instantiation index, seed, codegen),
        # consistently. Must be set before the first `mangled_name` call below.
        program.codegen_incremental = true
        prev_state = IncrementalCodegen::State.load(incremental_state_path(output_dir))
        fingerprints = IncrementalCodegen.compute(program)
        unless bc_flags_changed
          # Pin ids now so the determinism assert sees the same integers a warm
          # build will bake; id drift forces a full rebuild (never a bad binary).
          current_type_ids = IncrementalCodegen.pin_type_ids(program)
          if IncrementalCodegen.type_ids_stable?(prev_state, current_type_ids)
            candidate = IncrementalCodegen.reusable(prev_state, fingerprints, output_dir)
            index = IncrementalCodegen.instantiation_index(program)
            proc_ok = Set(String).new # proc-thunk replay is Phase C; none yet
            skip_modules = IncrementalCodegen.satisfy(prev_state, candidate, index, proc_ok)
            if ENV["CRYSTAL_INC_DEBUG"]?
              stderr.puts "[inc] modules=#{fingerprints.modules.size} reusable=#{candidate.size} skipped=#{skip_modules.size} evicted=#{candidate.size - skip_modules.size}"
            end
          elsif ENV["CRYSTAL_INC_DEBUG"]?
            stderr.puts "[inc] type_id drift -> full rebuild"
          end
        end
      end

      units = codegen_attempt(program, node, output_filename, output_dir, single_module,
        bc_flags_changed, fingerprints, prev_state, skip_modules)

      CacheDir.instance.cleanup if @cleanup

      units
    end

    private def codegen_attempt(program, node, output_filename, output_dir, single_module,
                                bc_flags_changed, fingerprints, prev_state, skip_modules)
      llvm_modules = @progress_tracker.stage("Codegen (crystal)") do
        program.codegen node, debug: debug, frame_pointers: frame_pointers,
          single_module: single_module, skip_modules: skip_modules,
          prev_state: prev_state, track_generated_funs: fingerprints != nil
      end

      target_triple = target_machine.triple

      objects = {} of String => String
      reused_object_names = [] of String
      units = [] of CompilationUnit
      llvm_modules.each do |type_name, info|
        next if skip_modules.includes?(type_name)
        llvm_mod = info.mod
        llvm_mod.target = target_triple
        unit = CompilationUnit.new(self, program, type_name, llvm_mod, output_dir, bc_flags_changed)
        units << unit
        objects[type_name] = unit.object_filename
      end

      # Carry forward cached objects for skipped modules and link them directly.
      if prev_state
        skip_modules.each do |mod|
          if obj = prev_state.objects[mod]?
            objects[mod] = obj
            reused_object_names << obj
          end
        end
      end

      {% if LibLLVM::IS_LT_170 %}
        # initialize the legacy pass manager once in the main thread/process
        # before we start codegen in threads (MT) or processes (fork)
        init_llvm_legacy_pass_manager unless optimization_mode.o0?
      {% end %}

      if @cross_compile
        cross_compile program, units, output_filename
      else
        units = with_file_lock(output_dir) do
          codegen program, units, output_filename, output_dir, reused_object_names
        end

        # Persist state only after a successful build, so the next incremental
        # run never reuses an object file this build failed to produce.
        if fingerprints
          live = {} of String => Array(String)
          program.codegen_live_funs.try &.each { |mod, names| live[mod] = names.to_a }

          # Cross-module inline edges from this build's regenerated modules; a
          # skipped module keeps the cached `.o`'s edges (carried forward below).
          inline_deps = {} of String => Array(String)
          program.codegen_inline_deps.try &.each { |mod, callees| inline_deps[mod] = callees.to_a }

          # Layer 1: derive each regenerated `.o`'s exports/imports from the
          # emitted IR (ground truth); carry forward reused modules' tables.
          exports = {} of String => Array(String)
          imports = {} of String => Array(String)
          llvm_modules.each do |type_name, info|
            next if skip_modules.includes?(type_name)
            exports[type_name], imports[type_name] = IncrementalCodegen.module_symbols(info.mod)
          end
          if prev_state
            skip_modules.each do |mod|
              live[mod] = prev_state.live[mod]? || [] of String
              exports[mod] = prev_state.exports[mod]? || [] of String
              imports[mod] = prev_state.imports[mod]? || [] of String
              if d = prev_state.inline_deps[mod]?
                inline_deps[mod] = d
              end
            end
          end

          IncrementalCodegen::State.new(
            fingerprints.epoch, fingerprints.modules, objects, live, exports, imports,
            program.codegen_eager_main || [] of String,
            program.codegen_main_symbols || [] of IncrementalCodegen::MainSymbolRecord,
            program.codegen_type_id_table || {} of String => Int32,
            inline_deps,
          ).save(incremental_state_path(output_dir))
        end

        {% if flag?(:darwin) %}
          run_dsymutil(output_filename) unless debug.none?
        {% end %}

        {% if flag?(:msvc) %}
          copy_dlls(program, output_filename) unless static?
        {% end %}
      end

      units
    end

    private def incremental_state_path(output_dir)
      File.join(output_dir, "incremental#{optimization_mode.suffix}.json")
    end

    private def with_file_lock(output_dir, &)
      File.open(File.join(output_dir, "compiler.lock"), "w") do |file|
        file.flock_exclusive do
          yield
        end
      end
    end

    private def run_dsymutil(filename)
      dsymutil = Process.find_executable("dsymutil")
      return unless dsymutil

      @progress_tracker.stage("dsymutil") do
        Process.run(dsymutil, ["--flat", filename])
      end
    end

    private def copy_dlls(program, output_filename)
      not_found = nil
      output_directory = File.dirname(output_filename)

      program.each_dll_path do |path, found|
        if found
          dest = File.join(output_directory, File.basename(path))
          File.copy(path, dest) unless File.exists?(dest)
        else
          not_found ||= [] of String
          not_found << path
        end
      end

      if not_found
        stderr << "Warning: The following DLLs are required at run time, but Crystal is unable to locate them in CRYSTAL_LIBRARY_PATH, the compiler's directory, or PATH: "
        not_found.sort!.join(stderr, ", ")
      end
    end

    private def cross_compile(program, units, output_filename)
      unit = units.first
      emit_targets = @emit_targets | EmitTarget::OBJ

      @progress_tracker.stage("Codegen (bc+obj)") do
        sequential_codegen(units)
        unit.emit(emit_targets, emit_base_filename || output_filename)
      end

      object_names = [output_filename]
      output_filename = output_filename.rchop(unit.object_extension)
      _, command, args = linker_command(program, object_names, output_filename, nil)
      print_command(command, args)
    end

    private def print_command(command, args)
      stdout.puts command.sub(%("${@}"), args && Process.quote(args))
    end

    private def linker_command(program : Program, object_names, output_filename, output_dir, expand = false)
      if program.has_flag? "msvc"
        lib_flags = program.lib_flags(@cross_compile)
        lib_flags = expand_lib_flags(lib_flags) if expand

        object_arg = Process.quote_windows(object_names)
        output_arg = Process.quote_windows("/Fe#{output_filename}")

        linker, link_args = program.msvc_compiler_and_flags
        linker = Process.quote_windows(linker)
        link_args.map! { |arg| Process.quote_windows(arg) }

        link_args << "/DEBUG:FULL /PDBALTPATH:%_PDB%" unless debug.none?
        link_args << "/INCREMENTAL:NO /STACK:0x800000"
        link_args << lib_flags
        @link_flags.try { |flags| link_args << flags }

        {% if flag?(:msvc) %}
          unless @cross_compile
            extra_suffix = static? ? "-static" : "-dynamic"
            search_result = Loader.search_libraries(Process.parse_arguments_windows(link_args.join(' ').gsub('\n', ' ')), extra_suffix: extra_suffix)
            if not_found = search_result.not_found?
              raise CompilerError.new("Cannot locate the .lib files for the following libraries: #{not_found.join(", ")}", :FAILURE)
            end

            link_args = search_result.remaining_args.concat(search_result.library_paths).map { |arg| Process.quote_windows(arg) }
          end
        {% end %}

        args = %(/nologo #{object_arg} #{output_arg} /link #{link_args.join(' ')}).gsub("\n", " ")
        cmd = "#{linker} #{args}"

        if cmd.to_utf16.size > 32000
          # The command line would be too big, pass the args through a UTF-16-encoded file instead.
          # TODO: Use a proper way to write encoded text to a file when that's supported.
          # The first character is the BOM; it will be converted in the same endianness as the rest.
          args_16 = "\ufeff#{args}".to_utf16
          args_bytes = args_16.to_unsafe_bytes

          args_filename = "#{output_dir}/linker_args.txt"
          File.write(args_filename, args_bytes)
          cmd = "#{linker} #{Process.quote_windows("@" + args_filename)}"
        end

        {linker, cmd, nil}
      elsif program.has_flag? "wasm32"
        link_flags = @link_flags || ""
        {"wasm-ld", %(wasm-ld "${@}" -o #{Process.quote_posix(output_filename)} #{link_flags} -lc #{program.lib_flags(@cross_compile)}), object_names}
      elsif program.has_flag? "avr"
        link_flags = @link_flags || ""
        link_flags += " --target=avr-unknown-unknown -mmcu=#{@mcpu} -Wl,--gc-sections"
        {DEFAULT_LINKER, %(#{DEFAULT_LINKER} "${@}" -o #{Process.quote_posix(output_filename)} #{link_flags} #{program.lib_flags(@cross_compile)}), object_names}
      elsif program.has_flag?("win32") && program.has_flag?("gnu")
        link_flags = @link_flags || ""
        link_flags += " -Wl,--stack,0x800000"
        link_flags = use_modern_linker(link_flags)
        lib_flags = program.lib_flags(@cross_compile)
        lib_flags = expand_lib_flags(lib_flags) if expand
        cmd = %(#{DEFAULT_LINKER} #{Process.quote_windows(object_names)} -o #{Process.quote_windows(output_filename)} #{link_flags} #{lib_flags}).gsub('\n', ' ')

        if cmd.size > 32000
          # The command line would be too big, pass the args through a file instead.
          # GCC response file does not interpret those args as shell-escaped
          # arguments, we must rebuild the whole command line
          args_filename = "#{output_dir}/linker_args.txt"
          File.open(args_filename, "w") do |f|
            object_names.each do |object_name|
              f << object_name.gsub(GCC_RESPONSE_FILE_TR) << ' '
            end
            f << "-o " << output_filename.gsub(GCC_RESPONSE_FILE_TR) << ' '
            f << link_flags << ' ' << lib_flags
          end
          cmd = "#{DEFAULT_LINKER} #{Process.quote_windows("@" + args_filename)}"
        end

        {DEFAULT_LINKER, cmd, nil}
      else
        link_flags = @link_flags || ""
        link_flags += " -rdynamic"

        if program.has_flag?("freebsd") || program.has_flag?("openbsd")
          # pkgs are installed to usr/local/lib but it's not in LIBRARY_PATH by
          # default; we declare it to ease linking on these platforms:
          link_flags += " -L/usr/local/lib"
        end

        link_flags = use_modern_linker(link_flags)

        {DEFAULT_LINKER, %(#{DEFAULT_LINKER} "${@}" -o #{Process.quote_posix(output_filename)} #{link_flags} #{program.lib_flags(@cross_compile)}), object_names}
      end
    end

    # Tests if `mold` or `lld` are available and prefers them as linkers over
    # the default `ld`. Only works when `cc` is the linker driver and can be
    # disabled with `--link-flags=-fuse-ld=bfd`.
    private def use_modern_linker(link_flags)
      return link_flags unless DEFAULT_LINKER == "cc"
      return link_flags if link_flags.includes?("-fuse-ld=")

      if Process.find_executable("mold")
        link_flags + " -fuse-ld=mold"
      elsif Process.find_executable("ld.lld")
        link_flags + " -fuse-ld=lld"
      else
        link_flags
      end
    end

    private GCC_RESPONSE_FILE_TR = {
      " ":  %q(\ ),
      "'":  %q(\'),
      "\"": %q(\"),
      "\\": "\\\\",
    }

    private def expand_lib_flags(lib_flags)
      lib_flags.gsub(/`(.*?)`/) do
        command = $1
        begin
          error_io = IO::Memory.new
          output = Process.run(command, shell: true, output: :pipe, error: error_io) do |process|
            process.output.gets_to_end
          end
          unless $?.success?
            error_io.rewind
            raise CompilerError.new("Error executing subcommand for linker flags: #{command.inspect}: #{error_io}", :FAILURE)
          end
          output.chomp
        rescue exc
          raise CompilerError.new("Error executing subcommand for linker flags: #{command.inspect}: #{exc}", :FAILURE)
        end
      end
    end

    private def codegen(program, units : Array(CompilationUnit), output_filename, output_dir, reused_object_names = [] of String)
      object_names = units.map(&.object_filename) + reused_object_names
      # Incremental builds split objects into regenerated `units` and reused
      # `reused_object_names`, so their concatenation order differs from a cold
      # build's (and across warm builds). Object order is semantically irrelevant
      # (symbols are unique; startup order is driven by `__crystal_main`, not link
      # order) but determines the final binary's layout, so sort for a deterministic,
      # byte-identical incremental==cold executable.
      object_names.sort! if incremental?

      unless units.empty?
        @progress_tracker.stage("Codegen (bc+obj)") do
          @progress_tracker.stage_progress_total = units.size

          n_threads = @n_threads.clamp(1..units.size)

          if n_threads == 1
            sequential_codegen(units)
          else
            parallel_codegen(units, n_threads)
          end

          if units.size == 1
            units.first.emit(@emit_targets, emit_base_filename || output_filename)
          end
        end
      end

      # We check again because maybe this directory was created in between (maybe with a macro run)
      if Dir.exists?(output_filename)
        raise CompilerError.new("can't use `#{output_filename}` as output filename because it's a directory", :USAGE_ERROR)
      end

      output_filename = File.expand_path(output_filename)

      @progress_tracker.stage("Codegen (linking)") do
        Dir.cd(output_dir) do
          run_linker *linker_command(program, object_names, output_filename, output_dir, expand: true)
        end
      end

      units
    end

    private def sequential_codegen(units)
      units.each do |unit|
        unit.compile
        @progress_tracker.stage_progress += 1
      end
    end

    private def parallel_codegen(units, n_threads)
      {% if flag?(:preview_mt) %}
        raise "LLVM isn't multithreaded and cannot fork compiler in multithread mode." unless LLVM.multithreaded?
        mt_codegen(units, n_threads)
      {% elsif LibC.has_method?("fork") %}
        fork_codegen(units, n_threads)
      {% else %}
        raise "Cannot fork compiler. `Crystal::System::Process.fork` is not implemented on this system."
      {% end %}
    end

    private def mt_codegen(units, n_threads)
      channel = Channel(CompilationUnit).new(n_threads * 2)
      wg = WaitGroup.new
      mutex = Sync::Mutex.new

      {% if flag?(:execution_context) %}
        # Run the workers in a dedicated execution context rather than spawning
        # them into the default one alongside the producing main fiber. With the
        # experimental `execution_context` scheduler a same-context enqueue only
        # does a local push and never calls `wake_scheduler`, so a fiber woken
        # while every scheduler has parked can be stranded (the default context's
        # monitor stops waking schedulers once none are active). The heavy channel
        # churn of many small modules makes that window reachable and the build
        # deadlocks. Sending across context boundaries instead routes through
        # `external_enqueue` -> `wake_scheduler`, which interrupts the event loop
        # and wakes parked schedulers, so the producer/worker handoff always
        # makes progress.
        context = Fiber::ExecutionContext::Parallel.new("codegen", n_threads)
        n_threads.times do
          wg.add
          context.spawn do
            codegen_worker(channel, mutex)
          ensure
            wg.done
          end
        end
      {% else %}
        n_threads.times do
          wg.spawn { codegen_worker(channel, mutex) }
        end
      {% end %}

      units.each do |unit|
        # We generate the bitcode in the main thread because LLVM contexts
        # must be unique per compilation unit, but we share different contexts
        # across many modules (or rely on the global context); trying to
        # codegen in parallel would segfault!
        #
        # Luckily generating the bitcode is quick and once the bitcode is
        # generated we don't need the global LLVM contexts anymore but can
        # parse the bitcode in an isolated context and we can parallelize the
        # slowest part: the optimization pass & compiling the object file.
        unit.generate_bitcode

        channel.send(unit)
      end
      channel.close

      wg.wait
    end

    private def codegen_worker(channel : Channel(CompilationUnit), mutex : Sync::Mutex) : Nil
      while unit = channel.receive?
        unit.compile(isolate_context: true)
        mutex.synchronize { @progress_tracker.stage_progress += 1 }
      end
    end

    private def fork_codegen(units, n_threads)
      workers = fork_workers(n_threads) do |input, output|
        while i = input.gets(chomp: true).presence
          unit = units[i.to_i]
          unit.compile
          result = {name: unit.name, reused: unit.reused_previous_compilation?}
          output.puts result.to_json
        end
      rescue ex
        result = {exception: {name: ex.class.name, message: ex.message, backtrace: ex.backtrace}}
        output.puts result.to_json
      end

      overqueue = 1
      indexes = Atomic(Int32).new(0)
      channel = Channel(String).new(n_threads)
      completed = Channel(Nil).new(n_threads)

      workers.each do |pid, input, output|
        spawn do
          overqueued = 0

          overqueue.times do
            if (index = indexes.add(1)) < units.size
              input.puts index
              overqueued += 1
            end
          end

          while (index = indexes.add(1)) < units.size
            input.puts index

            if response = output.gets(chomp: true)
              channel.send response
            else
              Crystal::System.print_error "\nBUG: a codegen process failed\n"
              exit 1
            end
          end

          overqueued.times do
            if response = output.gets(chomp: true)
              channel.send response
            else
              Crystal::System.print_error "\nBUG: a codegen process failed\n"
              exit 1
            end
          end

          input << '\n'
          input.close
          output.close

          Process.new(Crystal::System::Process.new(pid)).wait
          completed.send(nil)
        end
      end

      spawn do
        n_threads.times { completed.receive }
        channel.close
      end

      while response = channel.receive?
        result = JSON.parse(response)

        if ex = result["exception"]?
          Crystal::System.print_error "\nBUG: a codegen process failed: %s (%s)\n", ex["message"].as_s, ex["name"].as_s
          ex["backtrace"].as_a?.try(&.each { |frame| Crystal::System.print_error "  from %s\n", frame })
          exit 1
        end

        if @progress_tracker.stats?
          if result["reused"].as_bool
            name = result["name"].as_s
            unit = units.find! { |unit| unit.name == name }
            unit.reused_previous_compilation = true
          end
        end
        @progress_tracker.stage_progress += 1
      end
    end

    private def fork_workers(n_threads, &)
      workers = [] of {Int32, IO::FileDescriptor, IO::FileDescriptor}

      n_threads.times do
        iread, iwrite = IO.pipe
        oread, owrite = IO.pipe

        iwrite.flush_on_newline = true
        owrite.flush_on_newline = true

        pid = Crystal::System::Process.fork do
          iwrite.close
          oread.close

          yield iread, owrite

          iread.close
          owrite.close
          exit 0
        end

        iread.close
        owrite.close

        workers << {pid, iwrite, oread}
      end

      workers
    end

    private def print_macro_run_stats(program)
      return unless @progress_tracker.stats?
      return if program.compiled_macros_cache.empty?

      puts
      puts "Macro runs:"
      program.compiled_macros_cache.each do |filename, compiled_macro_run|
        print " - "
        print filename
        print ": "
        if compiled_macro_run.reused
          print "reused previous compilation (#{compiled_macro_run.elapsed})"
        else
          print compiled_macro_run.elapsed
        end
        puts
      end
    end

    private def print_codegen_stats(units)
      return unless @progress_tracker.stats?
      return unless units

      reused = units.count(&.reused_previous_compilation?)

      puts
      puts "Codegen (bc+obj):"
      case reused
      when units.size
        puts " - all previous .o files were reused"
      when .zero?
        puts " - no previous .o files were reused"
      else
        puts " - #{reused}/#{units.size} .o files were reused"
        puts
        puts "These modules were not reused:"
        units.each do |unit|
          next if unit.reused_previous_compilation?
          puts " - #{unit.original_name} (#{unit.name}.bc)"
        end
      end
    end

    getter(target_machine : LLVM::TargetMachine) do
      create_target_machine
    end

    def create_target_machine
      @codegen_target.to_target_machine(@mcpu || "", @mattr || "", @optimization_mode, @mcmodel)
    rescue ex : ArgumentError
      stderr.print colorize("Error: ").red.bold
      stderr.print "llc: "
      stderr.puts ex.message
      exit 1
    end

    {% if LibLLVM::IS_LT_170 %}
      property! pass_manager_builder : LLVM::PassManagerBuilder

      private def init_llvm_legacy_pass_manager
        registry = LLVM::PassRegistry.instance
        registry.initialize_all

        builder = LLVM::PassManagerBuilder.new
        builder.size_level = 0

        case optimization_mode
        in .o3?
          builder.opt_level = 3
          builder.use_inliner_with_threshold = 275
        in .o2?
          builder.opt_level = 2
          builder.use_inliner_with_threshold = 275
        in .o1?
          builder.opt_level = 1
          builder.use_inliner_with_threshold = 150
        in .o0?
          # default behaviour, no optimizations
        in .os?
          builder.opt_level = 2
          builder.size_level = 1
          builder.use_inliner_with_threshold = 50
        in .oz?
          builder.opt_level = 2
          builder.size_level = 2
          builder.use_inliner_with_threshold = 5
        end

        @pass_manager_builder = builder
      end

      private def optimize_with_pass_manager(llvm_mod)
        fun_pass_manager = llvm_mod.new_function_pass_manager
        pass_manager_builder.populate fun_pass_manager
        fun_pass_manager.run llvm_mod

        module_pass_manager = LLVM::ModulePassManager.new
        pass_manager_builder.populate module_pass_manager
        module_pass_manager.run llvm_mod
      end
    {% end %}

    protected def optimize(llvm_mod, target_machine)
      {% if LibLLVM::IS_LT_130 %}
        optimize_with_pass_manager(llvm_mod)
      {% else %}
        optimization_mode = @optimization_mode
        optimization_mode = OptimizationMode::O2 if optimization_mode.os? || optimization_mode.oz?

        LLVM::PassBuilderOptions.new do |options|
          LLVM.run_passes(llvm_mod, "default<#{optimization_mode}>", target_machine, options)
        end
      {% end %}
    end

    private def run_linker(linker_name, command, args)
      print_command(command, args) if verbose?

      begin
        Process.run(command, args, shell: true,
          input: Process::Redirect::Close, output: Process::Redirect::Inherit, error: Process::Redirect::Pipe) do |process|
          process.error.each_line(chomp: false) do |line|
            # Linker output is not guaranteed valid UTF-8 (incremental `.o` names
            # embed raw digest bytes), and `gsub` with a Regex raises on invalid
            # bytes; scrub them first so a benign linker note can't abort the build.
            line = line.scrub
            hint_string = colorize("(this usually means you need to install the development package for lib\\1)").yellow.bold
            line = line.gsub(/cannot find -l(\S+)\b/, "cannot find -l\\1 #{hint_string}")
            line = line.gsub(/unable to find library -l(\S+)\b/, "unable to find library -l\\1 #{hint_string}")
            line = line.gsub(/library not found for -l(\S+)\b/, "library not found for -l\\1 #{hint_string}")
            STDERR << line
          end
        end
      rescue exc : File::AccessDeniedError | File::NotFoundError
        linker_not_found exc.class, linker_name
      end

      status = $?
      unless status.success?
        exit_code = status.exit_code?
        case exit_code
        when 126
          linker_not_found File::AccessDeniedError, linker_name
        when 127
          linker_not_found File::NotFoundError, linker_name
        when nil
          # abnormal exit
          exit_code = 1
        end
        raise CompilerError.new("execution of command failed with exit status #{status}: #{command}", status: exit_code)
      end
    end

    private def linker_not_found(exc_class, linker_name)
      verbose_info = "\nRun with `--verbose` to print the full linker command." unless verbose?
      case exc_class
      when File::AccessDeniedError
        raise CompilerError.new("Could not execute linker: `#{linker_name}`: Permission denied#{verbose_info}", :FAILURE)
      else
        raise CompilerError.new("Could not execute linker: `#{linker_name}`: File not found#{verbose_info}", :FAILURE)
      end
    end

    private def colorize(obj)
      obj.colorize.toggle(@color)
    end

    # An LLVM::Module with information to compile it.
    class CompilationUnit
      getter compiler
      getter name
      getter original_name
      getter llvm_mod
      property? reused_previous_compilation = false
      getter object_extension : String
      @memory_buffer : LLVM::MemoryBuffer?
      @object_name : String?
      @bc_name : String?

      def initialize(@compiler : Compiler, program : Program, @name : String,
                     @llvm_mod : LLVM::Module, @output_dir : String, @bc_flags_changed : Bool)
        @name = "_main" if @name == ""
        @original_name = @name
        @name = String.build do |str|
          @name.each_char do |char|
            case char
            when 'a'..'z', '0'..'9', '_'
              str << char
            when 'A'..'Z'
              # Because OSX has case insensitive filenames, try to avoid
              # clash of 'a' and 'A' by using 'A-' for 'A'.
              str << char << '-'
            else
              str << char.ord
            end
          end
        end

        if @name.size > 50
          # 17 chars from name + 1 (dash) + 32 (md5) = 50
          @name = "#{@name[0..16]}-#{::Crystal::Digest::MD5.hexdigest(@name)}"
        end

        @name = "#{@name}#{@compiler.optimization_mode.suffix}"
        # Incremental builds pin type ids and force the read-fn const path, so
        # their `.o`/`.bc` differ from a plain build's. Namespace them so a plain
        # `crystal build` into the same cache can't silently overwrite (poison)
        # the `.o` a later `--incremental` build reuses.
        @name = "#{@name}-inc" if @compiler.incremental?
        @object_extension = compiler.codegen_target.object_extension
      end

      def generate_bitcode
        @memory_buffer ||= begin
          # Incremental codegen emits a module's functions in walk order plus
          # seed/force-appended ones, so the function layout (and thus `.text`/
          # `.eh_frame`) drifts vs a cold build. Sorting by name makes the object
          # file deterministic, a prerequisite for byte-identical incremental==cold.
          llvm_mod.sort_functions! if @compiler.incremental?
          llvm_mod.write_bitcode_to_memory_buffer
        end
      end

      # To compile a file we first generate a `.bc` file and then create an
      # object file from it. These `.bc` files are stored in the cache
      # directory.
      #
      # On a next compilation of the same project, and if the compile flags
      # didn't change (a combination of the target triple, mcpu and link flags,
      # amongst others), we check if the new `.bc` file is exactly the same as
      # the old one. In that case the `.o` file will also be the same, so we
      # simply reuse the old one. Generating an `.o` file is what takes most
      # time.
      #
      # However, instead of directly generating the final `.o` file from the
      # `.bc` file, we generate it to a temporary name (`.o.tmp`) and then we
      # rename that file to `.o`. We do this because the compiler could be
      # interrupted while the `.o` file is being generated, leading to a
      # corrupted file that later would cause compilation issues. Moving a file
      # is an atomic operation so no corrupted `.o` file should be generated.
      def compile(isolate_context = false)
        if must_compile?
          isolate_module_context if isolate_context
          update_bitcode_cache
          compile_to_object
        else
          @reused_previous_compilation = true
        end
        dump_llvm_ir
      end

      private def must_compile?
        memory_buffer = generate_bitcode

        return true unless compiler.emit_targets.none?
        return true if @bc_flags_changed
        return true unless File.exists?(bc_name)
        return true unless File.exists?(object_name)

        # If the user cancelled a previous compilation
        # it might be that the .o file is empty
        return true if File.size(object_name) == 0

        memory_io = IO::Memory.new(memory_buffer.to_slice)

        changed = File.open(bc_name) { |bc_file| !IO.same_content?(bc_file, memory_io) }

        memory_buffer.dispose unless changed

        changed
      end

      # Parse the previously generated bitcode into the LLVM module using a
      # dedicated context, so we can safely optimize & compile the module in
      # multiple threads (llvm contexts can't be shared across threads).
      private def isolate_module_context
        @llvm_mod = LLVM::Module.parse(@memory_buffer.not_nil!, LLVM::Context.new)
      end

      private def update_bitcode_cache
        return unless memory_buffer = @memory_buffer

        # Delete existing .o file. It cannot be used anymore.
        File.delete?(object_name)
        # Create the .bc file (for next compilations)
        File.write(bc_name, memory_buffer.to_slice)
        memory_buffer.dispose
      end

      private def compile_to_object
        temporary_object_name = self.temporary_object_name
        target_machine = compiler.create_target_machine
        compiler.optimize llvm_mod, target_machine unless compiler.optimization_mode.o0?
        target_machine.emit_obj_to_file llvm_mod, temporary_object_name
        File.rename(temporary_object_name, object_name)
      end

      private def dump_llvm_ir
        llvm_mod.print_to_file ll_name if compiler.dump_ll?
      end

      def emit(emit_targets : EmitTarget, output_filename)
        if emit_targets.asm?
          compiler.target_machine.emit_asm_to_file llvm_mod, "#{output_filename}.s"
        end
        if emit_targets.llvm_bc?
          FileUtils.cp(bc_name, "#{output_filename}.bc")
        end
        if emit_targets.llvm_ir?
          llvm_mod.print_to_file "#{output_filename}.ll"
        end
        if emit_targets.obj?
          FileUtils.cp(object_name, output_filename + @object_extension)
        end
      end

      def object_name
        Crystal.relative_filename("#{@output_dir}/#{object_filename}")
      end

      def object_filename
        @name + @object_extension
      end

      def temporary_object_name
        Crystal.relative_filename("#{@output_dir}/#{object_filename}.tmp")
      end

      def bc_name
        "#{@output_dir}/#{@name}.bc"
      end

      def bc_name_new
        "#{@output_dir}/#{@name}.new.bc"
      end

      def ll_name
        "#{@output_dir}/#{@name}.ll"
      end
    end
  end
end
