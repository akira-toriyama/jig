#!/bin/sh
# jig の dev ループ。jig は one-shot CLI なので、常駐アプリ家系の
# `./run.sh`(launch) に相当するのは「build してデモ filter を流す」こと。
# 本番配置 (~/.local/bin) は ./install.sh に分離 (= ./run.sh --install)。
#
#   ./run.sh               build + デモ filter 実行 (JIG_DEBUG=1 trace 付き)
#   ./run.sh --demo / -d   同上 (明示)
#   ./run.sh --install/-i  ~/.local/bin に配置 (= ./install.sh、静音)
#   ./run.sh --help        使い方
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

case "${1:-}" in
    ""|-d|--demo)
        ./build.sh
        # jig の今の言語 surface (v0) が一通り見えるデモ。dev loop なので
        # JIG_DEBUG=1 付き — filter parse / input サイズの trace が stderr
        # + /tmp/jig.log に出る (通常 install は静か)。
        demo='{"repo":"jig","tags":["jq","json","swift"],"owner":{"name":"akira-toriyama"},"big_id":12345678901234567890}'
        echo "--- .repo (field access, raw) ---------------------------------"
        printf '%s' "$demo" | JIG_DEBUG=1 ./bin/jig -r '.repo'
        echo "--- .tags[] (iterate) ------------------------------------------"
        printf '%s' "$demo" | ./bin/jig -c '.tags[]'
        echo "--- .owner.name, .big_id (comma + literal preservation) -------"
        printf '%s' "$demo" | ./bin/jig -c '.owner.name, .big_id'
        echo "--- .missing[] (humane diagnostics; exit 5 is expected) --------"
        printf '%s' "$demo" | ./bin/jig '.missing[]' || true
        echo "--- .missing[] --humane (H2: null iterates to nothing, exit 0) -"
        printf '%s' "$demo" | ./bin/jig --humane '.missing[]'; echo "(no output, exit $?)"
        echo "--- jig explain (plain-language + JS equivalent) ---------------"
        ./bin/jig explain '.tags[] | .'
        ;;
    -i|--install)
        exec ./install.sh
        ;;
    --help|-h)
        echo "usage: ./run.sh                build + demo filters (JIG_DEBUG=1)"
        echo "       ./run.sh --demo | -d     same (explicit)"
        echo "       ./run.sh --install | -i  deploy to ~/.local/bin (= ./install.sh)"
        ;;
    *)
        echo "unknown flag: $1" >&2
        exit 2
        ;;
esac
