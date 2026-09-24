# syntax=docker/dockerfile:1
#
# Neutreeko 強解決ソルバーの実行・テスト用イメージ。
# ビルドコンテキストはリポジトリのルート（compose.yaml / devcontainer.json から指定）。
#
#   docker build -f docker/Dockerfile -t neutreeko-solver:dev .
FROM julia:1.11

# 依存は標準ライブラリのみなので、depot はイメージ内に 1 つだけ置く。
# 末尾の ":" で同梱の標準ライブラリ depot も探索対象に残す（標準ライブラリの再コンパイルを避ける）。
# ホストの UID でも書き込めるよう、後で a+rwX にしておく。
ENV JULIA_DEPOT_PATH=/opt/julia-depot: \
    JULIA_NUM_THREADS=auto

COPY docker/run-if-present.sh /usr/local/bin/run-if-present

WORKDIR /work
COPY . /work

# Project.toml があるときだけ依存を解決してプリコンパイルまで済ませる。
# まだ無い段階でもイメージのビルド自体は通す。
RUN chmod 0755 /usr/local/bin/run-if-present \
 && mkdir -p /opt/julia-depot /work/data \
 && if [ -f Project.toml ]; then \
        julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'; \
    else \
        echo "[docker] Project.toml が無いため Pkg.instantiate() を省略します"; \
    fi \
 && chmod -R a+rwX /opt/julia-depot /work

CMD ["julia", "--project=."]
