# A throwaway single-node Elasticsearch for the relevance benchmark.
#
# `frontend/benchmark/run.mjs` issues one query per curated case, and an
# evolutionary search over the query shape multiplies that by the population
# size and the generation count. Against `search.nixos.org` a single `_search`
# costs ~800 ms of round trip, which puts a full sweep out of reach; against a
# loopback replica of the same index the same pass is bounded by ES itself.
#
# Everything mutable lives under `--data-dir`, so the same directory can be
# reused across runs and the loaded index survives a restart. The config
# directory is regenerated on every start, since it is a pure function of the
# flags.
#
# Deliberately unauthenticated and bound to the loopback interface: the OSS
# distribution has no security plugin, and `run.mjs` sends a `Basic` header
# unconditionally, which an unsecured cluster ignores.
{
  writeShellApplication,
  elasticsearch-oss,
  coreutils,
  gnused,
}:

writeShellApplication {
  name = "local-es";

  runtimeInputs = [
    elasticsearch-oss
    coreutils
    gnused
  ];

  text = ''
    data_dir=""
    port=9200
    heap=2g

    while [ $# -gt 0 ]; do
      case "$1" in
        --data-dir) data_dir="$2"; shift 2 ;;
        --port) port="$2"; shift 2 ;;
        --heap) heap="$2"; shift 2 ;;
        -h|--help)
          cat <<'USAGE'
    Usage: local-es --data-dir <dir> [--port <n>] [--heap <size>]

      --data-dir  where the index, logs and generated config live (required)
      --port      HTTP port on 127.0.0.1 (default 9200)
      --heap      JVM heap, both -Xms and -Xmx (default 2g)
    USAGE
          exit 0 ;;
        *) echo "local-es: unknown argument '$1'" >&2; exit 2 ;;
      esac
    done

    if [ -z "$data_dir" ]; then
      echo "local-es: --data-dir is required" >&2
      exit 2
    fi

    mkdir -p "$data_dir"
    data_dir="$(cd "$data_dir" && pwd)"
    mkdir -p "$data_dir/data" "$data_dir/logs" "$data_dir/tmp"

    conf="$data_dir/config"
    rm -rf "$conf"
    cp -r ${elasticsearch-oss}/config "$conf"
    chmod -R u+w "$conf"

    cat > "$conf/elasticsearch.yml" <<YAML
    cluster.name: nixos-search-benchmark
    node.name: local
    path.data: $data_dir/data
    path.logs: $data_dir/logs
    network.host: 127.0.0.1
    http.port: $port
    discovery.type: single-node
    bootstrap.memory_lock: false
    YAML

    # `bin/elasticsearch-env` ends with `cd "$ES_HOME"`, and `ES_HOME` is the
    # read-only store path, so the heap dump and GC log paths that upstream
    # `jvm.options` leaves relative are unwritable. Absolutize them rather than
    # patching the launcher, which would also change where the JVM resolves
    # `ES_TMPDIR` and the classpath from.
    sed -i \
      -e "s|-XX:HeapDumpPath=data|-XX:HeapDumpPath=$data_dir/data|" \
      -e "s|logs/|$data_dir/logs/|g" \
      "$conf/jvm.options"

    export ES_PATH_CONF="$conf"
    export ES_TMPDIR="$data_dir/tmp"
    export ES_JAVA_OPTS="-Xms$heap -Xmx$heap"

    exec elasticsearch
  '';

  meta = {
    description = "Run a single-node Elasticsearch 7.10.2 on 127.0.0.1 for the relevance benchmark";
    mainProgram = "local-es";
    inherit (elasticsearch-oss.meta) platforms;
  };
}
