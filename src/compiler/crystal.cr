# This is the file that is compiled to generate the
# executable for the compiler.

{% raise("Please use `make crystal` to build the compiler, or set the i_know_what_im_doing flag if you know what you're doing") unless env("CRYSTAL_HAS_WRAPPER") || flag?("i_know_what_im_doing") %}

require "log"
require "./requires"
require "./crystal/tune_gc"

# Configure the GC for the compiler's allocation pattern before doing any work.
# See `Crystal::GCTuning` for details.
Crystal::GCTuning.setup

Log.setup_from_env(default_level: :warn, default_sources: "crystal.*")

{% if flag?(:execution_context) %}
  Fiber::ExecutionContext.default.resize(Fiber::ExecutionContext.default_workers_count)
{% end %}

Crystal::Command.run
