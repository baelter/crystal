require "json"

module Crystal
  # Def-instance-level semantic dependency graph — phase 2 of `--incremental`
  # (incremental *semantic* analysis). Records dependency edges between method
  # instantiations as type inference creates them, so a change's re-inference
  # closure can be computed. Node identity is the codegen mangled name
  # (build-stable, proven by the `--incremental` byte-identity gate), so the
  # graph aligns with codegen type-modules.
  #
  # Edge convention: `A -> B` means "A depends on B" (A used/observed B); if B's
  # inferred signature changes, A must be re-checked. So change propagation walks
  # edges in REVERSE (B -> its dependents A). Edge kinds:
  #   * caller -> callee  (a call, resolved via target_defs)
  #   * reader -> @ivar -> writer  (instance-variable type flow: a reader of an
  #     ivar depends on every def that assigns it, via an ivar intermediary node)
  #
  # Populated only when `Program#semantic_graph` is set (env `CRYSTAL_SEM_GRAPH`),
  # so it adds no overhead to ordinary builds.
  class SemanticGraph
    ROOT = 0_u64 # synthetic node for a top-level / unknown def

    # caller object_id => callee object_ids (resolved to stable ids at dump time)
    @edges = {} of UInt64 => Set(UInt64)
    # object_id => Def instance (for stable-id resolution after inference)
    @defs = {} of UInt64 => Def
    # var (ivar/cvar) node id => reader def object_ids
    @var_readers = {} of String => Set(UInt64)
    # var node id => writer def object_ids (assignments inside method bodies)
    @var_writers = {} of String => Set(UInt64)
    # var node id => fingerprint of its class-body initializer, if any. This makes
    # a non-def type root (e.g. `@@x = 1` at class level) itself seedable: when the
    # initializer changes, the var node's body changes and propagation starts here.
    @var_init = {} of String => String

    def record(caller : Def?, callee : Def) : Nil
      cid = register(callee)
      kid = caller ? register(caller) : ROOT
      return if cid == kid
      (@edges[kid] ||= Set(UInt64).new) << cid
    end

    def record_ivar_read(reader : Def?, owner : Type?, name : String) : Nil
      add_reader var_id("@ivar", owner, name), reader
    end

    def record_ivar_write(writer : Def?, owner : Type?, name : String) : Nil
      add_writer var_id("@ivar", owner, name), writer
    end

    def record_cvar_read(reader : Def?, owner : Type?, name : String) : Nil
      add_reader var_id("@@cvar", owner, name), reader
    end

    def record_cvar_write(writer : Def?, owner : Type?, name : String) : Nil
      add_writer var_id("@@cvar", owner, name), writer
    end

    # The class-body initializer that fixes a class var's type (a non-def root).
    # *owner* is a ClassVarContainer (a module mixed into types), not statically a
    # Type, so it's untyped here; only its `to_s` is used, matching the read site.
    def record_cvar_init(owner, name : String, init_fp : String) : Nil
      @var_init["@@cvar #{owner.try(&.to_s) || "?"}#{name}"] = init_fp
    end

    private def add_reader(id : String, reader : Def?) : Nil
      (@var_readers[id] ||= Set(UInt64).new) << (reader ? register(reader) : ROOT)
    end

    private def add_writer(id : String, writer : Def?) : Nil
      (@var_writers[id] ||= Set(UInt64).new) << (writer ? register(writer) : ROOT)
    end

    private def var_id(kind : String, owner : Type?, name : String) : String
      "#{kind} #{owner.try(&.to_s) || "?"}#{name}"
    end

    private def register(d : Def) : UInt64
      oid = d.object_id
      @defs[oid] ||= d
      oid
    end

    # Emit JSON: {"nodes":{"<id>":{"mod","body","key"}}, "edges":{"<id>":["<id>"...]}}
    def dump(program : Program, io : IO) : Nil
      idof = {} of UInt64 => String
      idof[ROOT] = "<root>"
      # id => {owner-module, body-fingerprint, return-type-independent match key}
      nodes = {} of String => Tuple(String, String, String)

      @defs.each do |oid, d|
        sid = stable_id(program, d)
        idof[oid] = sid
        nodes[sid] = {owner_module(d), body_fp(d), match_key(program, d)}
      end

      out = {} of String => Set(String)
      add = ->(from : String, to : String) do
        return if from == to
        (out[from] ||= Set(String).new) << to
      end

      @edges.each do |from, tos|
        f = idof[from]? || "<root>"
        tos.each { |t| (id = idof[t]?) && add.call(f, id) }
      end

      # var (ivar/cvar) flow: reader -> var (reader depends on the var's type),
      #                       var    -> writer (var's type depends on the writer).
      # The var node's body is its initializer fingerprint when it has one, so a
      # class-body initializer change seeds propagation from the var node itself.
      (@var_readers.keys | @var_writers.keys | @var_init.keys).each do |vid|
        nodes[vid] ||= {vid.partition(' ')[2].partition('#')[0], @var_init[vid]? || "var", vid}
        @var_readers[vid]?.try &.each { |r| add.call(idof[r]? || "<root>", vid) }
        @var_writers[vid]?.try &.each { |w| add.call(vid, idof[w]? || "<root>") }
      end

      JSON.build(io) do |j|
        j.object do
          j.field("nodes") do
            j.object do
              nodes.each do |id, info|
                j.field(id) do
                  j.object do
                    j.field("mod", info[0])
                    j.field("body", info[1])
                    j.field("key", info[2])
                  end
                end
              end
            end
          end
          j.field("edges") do
            j.object do
              out.each do |f, ts|
                next if ts.empty?
                j.field(f) { j.array { ts.each { |t| j.string(t) } } }
              end
            end
          end
        end
      end
      io.puts
    end

    private def stable_id(program : Program, d : Def) : String
      if owner = d.owner?
        d.mangled_name(program, owner)
      else
        "*top*#{d.name}$D#{d.def_id_digest}"
      end
    rescue
      "*err*#{d.name}##{d.object_id}"
    end

    # Identity stable under the def's own inferred RETURN TYPE changing, so a
    # return-type change (propagation) is detectable rather than looking like a
    # removed+added node.
    private def match_key(program : Program, d : Def) : String
      if owner = d.owner?
        d.mangled_name(program, owner, include_return: false)
      else
        "*top*#{d.name}$D#{d.def_id_digest}"
      end
    rescue
      "*errkey*#{d.name}##{d.object_id}"
    end

    private def owner_module(d : Def) : String
      d.owner?.try(&.to_s) || "<top>"
    end

    private def body_fp(d : Def) : String
      ::Crystal::Digest::MD5.hexdigest { |ctx| ctx.update(d.body.to_s) }[0, 12]
    end
  end
end
