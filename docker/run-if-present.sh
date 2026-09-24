#!/bin/sh
# 必要なファイルがあるときだけコマンドを実行する小さな入口。
#
#   run-if-present [--strict] <必要なファイル> <コマンド> [引数...]
#
# - ファイルがあれば <コマンド> を exec する（終了コードはそのまま返る）。
# - ファイルが無ければ「[skip]」を出して 0 で終わる。
#   --strict を付けたときは「[error]」を出して 1 で終わる。
#
# ソルバー本体（Project.toml など）がまだ main に無い段階でも
# test / verify を落とさずに回すためのもの。
set -eu

strict=0
if [ "${1:-}" = "--strict" ]; then
    strict=1
    shift
fi

if [ "$#" -lt 2 ]; then
    echo "usage: run-if-present [--strict] <file> <command> [args...]" >&2
    exit 2
fi

file=$1
shift

if [ ! -e "$file" ]; then
    if [ "$strict" -eq 1 ]; then
        echo "[error] $file が見つからないため実行できません: $*" >&2
        exit 1
    fi
    echo "[skip] $file が見つからないため実行を省略します: $*"
    exit 0
fi

exec "$@"
