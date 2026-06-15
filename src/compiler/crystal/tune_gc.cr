module Crystal
  # Tunes the garbage collector for the way the compiler allocates memory.
  #
  # The compiler is a short-lived process whose live data set -- the parsed AST
  # and the type graph -- grows steadily and stays almost entirely reachable
  # until the process exits. With the GC's default heuristics, collections
  # become more and more frequent as that live set grows, and each one re-marks
  # all of it. A large share of compilation time is therefore spent scanning
  # memory that is never going to be freed; during code generation, where almost
  # nothing becomes garbage, collections are pure overhead.
  #
  # We disable automatic collections, trading a bounded amount of memory for a
  # substantial speedup in semantic analysis and code generation. To avoid
  # running out of memory on very large programs, `enforce_memory_limit` is
  # called at every compilation phase boundary (see `ProgressTracker#stage`) and
  # re-enables the GC once the heap grows past a limit derived from the amount
  # of physical memory on the machine. Re-enabling from there is safe because it
  # runs on the main fiber without the GC's internal lock held (unlike a
  # heap-resize callback, which would dead-lock).
  #
  # This is only a default: it is skipped, leaving the GC untouched, whenever the
  # user sets the standard `GC_DONT_GC` or `GC_FREE_SPACE_DIVISOR` environment
  # variables.
  module GCTuning
    @@enabled = false

    # Heap size, in bytes, past which the GC is re-enabled.
    @@heap_limit = 0_u64

    # Disables the GC (unless overridden by the user or unsupported) and arms the
    # memory limit checked by `enforce_memory_limit`.
    def self.setup : Nil
      {% if flag?(:gc_none) || flag?(:wasm32) || flag?(:tracing) %}
        # Nothing to tune: there is no Boehm GC, or we want to observe the GC's
        # default behavior.
      {% else %}
        # Respect an explicit choice by the user.
        return if ENV.has_key?("GC_DONT_GC") || ENV.has_key?("GC_FREE_SPACE_DIVISOR")

        @@heap_limit = memory_limit
        @@enabled = true
        GC.disable
      {% end %}
    end

    # Re-enables the GC if it was disabled by `setup` and the heap has grown past
    # the limit. Called at phase boundaries, so the worst-case extra memory is
    # roughly one phase's worth of allocations beyond the limit.
    def self.enforce_memory_limit : Nil
      return unless @@enabled
      if GC.stats.heap_size >= @@heap_limit
        @@enabled = false
        GC.enable
      end
    end

    # Heap size (in bytes) past which the GC is re-enabled. Defaults to ~60% of
    # physical memory, clamped to a sane range, so that ordinary programs build
    # without any collections while pathologically large ones stay bounded.
    private def self.memory_limit : UInt64
      total = total_physical_memory
      limit = total > 0 ? total // 10 * 6 : 4_u64 * 1024 * 1024 * 1024
      limit.clamp(2_u64 * 1024 * 1024 * 1024, 32_u64 * 1024 * 1024 * 1024)
    end

    # Total physical memory in bytes, or `0` if it can't be determined.
    private def self.total_physical_memory : UInt64
      {% if flag?(:linux) %}
        begin
          File.read("/proc/meminfo").each_line do |line|
            if line.starts_with?("MemTotal:")
              if kb = line.split[1]?.try(&.to_u64?)
                return kb * 1024
              end
            end
          end
        rescue
          # fall through to the default
        end
      {% end %}
      0_u64
    end
  end
end
