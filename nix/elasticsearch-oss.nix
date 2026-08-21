# Elasticsearch 7.10.2, Apache-2.0 ("OSS") distribution.
#
# search.nixos.org runs exactly this version, and the relevance benchmark in
# `frontend/benchmark` compares BM25 scores against a local replica of a pinned
# production index. Scoring parity is the whole point of the replica, so the
# version has to match the cluster rather than whatever is current: nixpkgs
# dropped the OSS builds when Elastic relicensed, and its `elasticsearch7` is
# 7.17 under the Elastic licence.
#
# Derived from `pkgs/servers/search/elasticsearch/7.x.nix` as it existed in
# nixpkgs 21.05, the last release carrying the `enableUnfree = false` variant.
# Two deliberate departures from it:
#
#   - the `no-jdk` tarball plus nixpkgs `jdk11_headless`, rather than the
#     bundled JDK, which would need patchelf'ing;
#   - no `es-home` patch. That patch exists so `ES_HOME` survives being reached
#     through a profile symlink; `nix run .#local-es` invokes the store path
#     directly, and `bin/elasticsearch-env` then resolves `ES_HOME` to `$out`
#     on its own.
#
# The OSS distribution ships no native code (the ELF binaries in the default
# distribution all live under the unfree `x-pack-ml` module), so there is
# nothing here for `autoPatchelfHook` to do.
{
  lib,
  stdenv,
  fetchurl,
  makeWrapper,
  jdk11_headless,
  util-linux,
  gnugrep,
  coreutils,
}:

stdenv.mkDerivation rec {
  pname = "elasticsearch-oss";
  version = "7.10.2";

  src = fetchurl {
    url = "https://artifacts.elastic.co/downloads/elasticsearch/${pname}-${version}-no-jdk-linux-x86_64.tar.gz";
    hash = "sha256-EyLe7wBXnKz+ggwORwlBGFkCbOJ18YecTzCxmkWGQsw=";
  };

  nativeBuildInputs = [ makeWrapper ];

  # `bin/elasticsearch-env` derives the classpath from `ES_HOME`, which is the
  # unpacked tree during the build and `$out` afterwards. Pin it to `$out`.
  postPatch = ''
    substituteInPlace bin/elasticsearch-env \
      --replace-fail 'ES_CLASSPATH="$ES_HOME/lib/*"' "ES_CLASSPATH=\"$out/lib/*\""

    substituteInPlace bin/elasticsearch-cli \
      --replace-fail 'ES_CLASSPATH="$ES_CLASSPATH:$ES_HOME/$additional_classpath_directory/*"' \
        "ES_CLASSPATH=\"\$ES_CLASSPATH:$out/\$additional_classpath_directory/*\""

    # Resolved against the working directory, which is the data directory.
    substituteInPlace bin/elasticsearch \
      --replace-fail 'bin/elasticsearch-keystore' "$out/bin/elasticsearch-keystore"
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -R bin config lib modules plugins $out
    chmod +x $out/bin/*

    for exe in elasticsearch elasticsearch-plugin elasticsearch-keystore; do
      wrapProgram $out/bin/$exe \
        --prefix PATH : "${
          lib.makeBinPath [
            util-linux
            coreutils
            gnugrep
          ]
        }" \
        --set JAVA_HOME "${jdk11_headless}"
    done

    runHook postInstall
  '';

  meta = {
    description = "Open Source, Distributed, RESTful Search Engine";
    homepage = "https://www.elastic.co/elasticsearch/";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
    mainProgram = "elasticsearch";
    sourceProvenance = [ lib.sourceTypes.binaryBytecode ];
  };
}
