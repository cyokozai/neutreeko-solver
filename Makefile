# docker compose 経由の入口。ホストに Julia を入れずに回す。
#
#   make test                 # Pkg.test()（Project.toml が無ければ skip）
#   make verify               # 独立検証器 verify/runtests.jl（無ければ skip）
#   make solve ARGS="..."     # フル解析 scripts/solve.jl。解析表は ./data に残る
#   make shell                # リポジトリをマウントした bash
#   make build                # イメージだけ作る

COMPOSE ?= docker compose
ARGS    ?=

# コンテナをホストの UID/GID で動かす（data/ に root 所有のファイルを作らない）。
export HOST_UID := $(shell id -u)
export HOST_GID := $(shell id -g)

.DEFAULT_GOAL := help
.PHONY: help build test verify solve shell clean

help: ## ターゲット一覧
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  make %-8s %s\n", $$1, $$2}'

build: ## イメージをビルドする
	$(COMPOSE) build

data:
	mkdir -p data

test: data ## Pkg.test() を実行する
	$(COMPOSE) run --rm --build test

verify: data ## verify/runtests.jl を実行する
	$(COMPOSE) run --rm --build verify

solve: data ## scripts/solve.jl を実行する（ARGS で引数を渡す）
	$(COMPOSE) run --rm --build solve $(ARGS)

shell: data ## リポジトリをマウントした bash を開く
	$(COMPOSE) run --rm --build shell

clean: ## コンテナとイメージを片付ける（data/ は残す）
	$(COMPOSE) down --rmi all --remove-orphans
