require "json"
require "../syntax/ast"

class Crystal::Command
  private def semantic_dependencies
    config = create_compiler "tool semantic-dependencies", no_codegen: true,
      allowed_formats: ["text", "json", "dot"]
    config.compiler.no_codegen = true

    tracker = Crystal::SemanticDependencyTracker.new
    config.compiler.semantic_dependencies = tracker

    config.compile

    tracker.report(STDOUT, format: config.output_format)
  end
end

module Crystal
  # Records *semantic* dependencies between source files: an edge `A => B` means
  # that code defined in file `A` refers to a definition that lives in file `B`
  # (a method `A` calls, or a type/constant `A` mentions).
  #
  # This is fundamentally different from the `require` graph printed by
  # `crystal tool dependencies`, which only captures syntactic visibility (and
  # in which essentially every file transitively requires the prelude). The
  # semantic-use graph instead captures the *actual* uses that decide what has
  # to be re-analyzed when a file changes, which is the information an
  # incremental semantic pass needs: if file `B` changes, every file that
  # transitively uses a definition from `B` may need to be re-checked, and
  # everything else can -- in principle -- be reused.
  #
  # The tracker is populated only when `Program#semantic_dependencies` is set
  # (i.e. by `crystal tool semantic-dependencies`), so it adds no overhead to
  # ordinary compilation.
  class SemanticDependencyTracker
    # Maps a file to the set of files whose definitions it uses.
    getter uses = {} of String => Set(String)

    # Records that the code at *from* uses a definition at *to*.
    def record(from : Location?, to : Location?) : Nil
      record_files from.try(&.original_filename), to.try(&.original_filename)
    end

    # Records that the code at *node* uses *type* (which may be defined and/or
    # reopened across several files).
    def record_type_use(node : ASTNode, type : Type) : Nil
      from = node.location.try(&.original_filename)
      return unless from
      type.locations.try &.each do |location|
        record_files from, location.original_filename
      end
    end

    private def record_files(from : String?, to : String?) : Nil
      return unless from && to
      return if from == to
      (uses[from] ||= Set(String).new) << to
    end

    # The reverse graph: maps a file to the set of files that directly use it.
    def dependents : Hash(String, Set(String))
      result = {} of String => Set(String)
      uses.each do |from, tos|
        tos.each { |to| (result[to] ||= Set(String).new) << from }
      end
      result
    end

    # All files mentioned in the graph (as a user or as a dependency).
    def files : Set(String)
      result = Set(String).new
      uses.each do |from, tos|
        result << from
        result.concat tos
      end
      result
    end

    # Every file that would need re-analysis if *changed* changed: itself, plus
    # everything that transitively uses a definition from it.
    def impact_of(changed : String, dependents : Hash(String, Set(String)) = self.dependents) : Set(String)
      affected = Set(String).new
      stack = [changed]
      until stack.empty?
        file = stack.pop
        next unless affected.add?(file)
        dependents[file]?.try &.each { |dep| stack << dep }
      end
      affected
    end

    def report(io : IO, format : String) : Nil
      case format
      when "json" then report_json(io)
      when "dot"  then report_dot(io)
      else             report_text(io)
      end
    end

    private def report_json(io : IO) : Nil
      JSON.build(io, indent: 2) do |json|
        json.object do
          uses.to_a.sort_by(&.[0]).each do |from, tos|
            json.field(from) { json.array { tos.to_a.sort.each { |to| json.string(to) } } }
          end
        end
      end
      io.puts
    end

    private def report_dot(io : IO) : Nil
      io.puts "digraph semantic_dependencies {"
      uses.each do |from, tos|
        tos.each { |to| io.puts %(  #{from.inspect} -> #{to.inspect};) }
      end
      io.puts "}"
    end

    private def report_text(io : IO) : Nil
      all = files.to_a
      dependents = self.dependents
      edges = uses.sum { |_, tos| tos.size }

      if all.empty?
        io.puts "No semantic dependencies recorded."
        return
      end

      impacts = all.map { |file| {file, impact_of(file, dependents).size} }
      sizes = impacts.map(&.[1]).sort!
      total = all.size

      pct = ->(n : Int32) { "%.1f%%" % (100.0 * n / total) }
      at = ->(q : Float64) { sizes[(q * (sizes.size - 1)).round.to_i] }

      io.puts "Semantic dependency analysis"
      io.puts "============================"
      io.puts "Files:           #{total}"
      io.puts "Use edges:       #{edges}"
      io.puts
      io.puts "Re-analysis impact when a single file changes"
      io.puts "(number of files that must be re-checked, including itself):"
      io.puts "  min     #{sizes.first}\t(#{pct.call sizes.first})"
      io.puts "  median  #{at.call 0.5}\t(#{pct.call at.call(0.5)})"
      io.puts "  p90     #{at.call 0.9}\t(#{pct.call at.call(0.9)})"
      io.puts "  p99     #{at.call 0.99}\t(#{pct.call at.call(0.99)})"
      io.puts "  max     #{sizes.last}\t(#{pct.call sizes.last})"
      io.puts "  mean    #{(sizes.sum / total).round(1)}"
      io.puts

      io.puts "Distribution (how many files have a given re-analysis impact):"
      [{0.01, "<=  1%"}, {0.05, "<=  5%"}, {0.25, "<= 25%"}, {0.50, "<= 50%"}, {1.00, "<=100%"}].each do |frac, label|
        threshold = (frac * total).ceil.to_i
        count = sizes.count { |s| s <= threshold }
        io.puts "  #{label}\t#{count}\t(#{pct.call count})"
      end
      io.puts
      io.puts "Lowest-impact files (cheap to change -- where incremental analysis pays off):"
      impacts.sort_by! { |_, size| size }
      impacts.first(5).each do |file, size|
        io.puts "  #{pct.call size}\t#{size}\t#{file}"
      end
      io.puts
      io.puts "Highest-impact files (changing these forces the widest re-analysis):"
      impacts.sort_by! { |_, size| -size }
      impacts.sort_by! { |_, size| -size }
      impacts.first(10).each do |file, size|
        io.puts "  #{pct.call size}\t#{size}\t#{file}"
      end
    end
  end
end
