# Neutreeko 強解決ソルバー

5×5 盤の二人用ゲーム Neutreeko を**後退解析で強解決**する Julia プログラムです。手番側から見た全 3,542,000 局面について、勝ち・負け・引き分けと決着までの手数（ply）を求め、表として保存します。

千葉工業大学「エージェントシステム特論」（原英樹先生）の最終課題「Neutreeko の強解決をするプログラムおよび説明資料」の提出物です。

## 結論

**初期局面は引き分けです。** ただし、引き分けを保つ初手は 14 手のうち b1-c1 と d1-c1 の 2 手だけで、残り 12 手は先手（黒）の負けになります。

| 項目 | 結果 |
|---|---|
| 初期局面 `B:.B.B...W.........B...W.W.` の値 | 引き分け |
| 有効局面 3,468,080 の内訳 | 勝ち 2,473,028（71.308%）/ 負け 890,392（25.674%）/ 引き分け 104,660（3.018%） |
| 最長の決着 | 51 ply（勝つ側 26 手、負ける側 25 手） |
| 後退解析の所要時間 | 1.09 秒（表は 7,084,013 バイト） |
| 作者 J. K. Haugland の公開値 | 初期局面の値・最長 51 手・引き分け約 3% のすべてで一致 |

アルゴリズム、検証、結果の考察は説明資料 [docs/report.md](docs/report.md) にまとめています。

## クイックスタート

ホストに Julia を入れる必要はありません。Docker（Compose v2）と `make` があれば動きます。

```sh
git clone git@github.com:cyokozai/neutreeko-solver.git
cd neutreeko-solver

make test      # テスト一式 Pkg.test()（21,185 件、約 28 秒）
make verify    # 独立検証器 verify/runtests.jl（まだ無ければ skip）
make solve     # 強解決して data/neutreeko_table.bin を作り、統計を出力
make shell     # リポジトリをマウントした bash
make help      # ターゲット一覧
```

- `make solve ARGS="--no-move=loss"` で、合法手 0 の局面を負けとして解きます（該当する局面は 0 件なので、表は変わりません）。
- `make` を使わない場合は `docker compose run --rm --build test` のように直接呼べます。
- VS Code では `.devcontainer/` の Dev Container が使えます。
- 対局: `julia --project=. scripts/play.jl --black human --white perfect`（盤面の表示、`hint` で全合法手の評価、`undo`、`--analyze "<局面>"`、`--games N` でエージェント同士の多数対局）。総当たりは `scripts/tournament.jl`（#6 で追加）。

### 表を引く

`make shell` で入ったコンテナの中で、次のように局面を調べられます。

```julia
# julia --project=.
using Neutreeko
t = load_table("data/neutreeko_table.bin")
p = parse_position("B:.B.B...W.........B...W.W.")   # 初期局面
lookup(t, p)       # (:draw, -1)   手番側から見た値と、決着までの手数
best_moves(t, p)   # b1-c1, d1-c1
```

局面は `"<手番>:<25文字>"` で表します。手番は `B` か `W`、25 文字は a1, b1, …, e1, a2, …, e5 の順にマスの中身を `B` / `W` / `.` で書いたものです。

## ディレクトリ構成

```
.
├── src/
│   ├── Neutreeko.jl    モジュール本体（公開 API の export）
│   ├── board.jl        盤の幾何、8 方向の射線、勝ち筋 48 本
│   ├── position.jl     局面と指し手、前向き生成・後ろ向き生成、文字列表記
│   ├── index.jl        組合せ数体系による局面番号、状態分類
│   ├── solve.jl        後退解析 solve()、検証用の前向き不動点反復 solve_fixpoint()
│   ├── table.jl        表の保存・読込、lookup / best_moves / principal_variation
│   ├── symmetry.jl     盤面の 8 対称、対称類の集計
│   ├── stats.jl        合法手 0 の局面、初期局面からの到達可能性
│   └── agent.jl        対戦エージェント（Perfect / AlphaBeta / Random）と play_game
├── test/               Pkg.test() のテスト一式
├── scripts/
│   ├── solve.jl        強解決して表を保存し、統計を出力する
│   ├── play.jl         対局 CLI（人間・エージェント、局面解析）
│   ├── tournament.jl   エージェント総当たりの勝率表
│   ├── export_tsv.jl   表を検証器の TSV 形式で書き出す
│   └── crosscheck.jl   表と αβ 検証器の突き合わせ
├── results/crosscheck.md  突き合わせの結果（6,942,827 回、不一致 0）
├── verify/             独立実装の αβ 検証器（本体とコードを共有しない）
├── docker/             Dockerfile と入口スクリプト
├── compose.yaml        test / verify / solve / shell のサービス定義
├── Makefile            make test / verify / solve / shell / build / clean
├── .devcontainer/      VS Code の Dev Container 設定
├── .github/workflows/  CI（Julia のテスト・検証器・手動のフル解析、Markdown の整形）
├── docs/report.md      説明資料
└── data/               生成される解の表（git 管理外）
```

## 資料

- 説明資料: [docs/report.md](docs/report.md)
- ルールの出典: J. K. Haugland, [Neutreeko](https://www.neutreeko.net/neutreeko.htm)（日本語の紹介: [じゃんご「Neutreeko 【ルール】」](http://djangorec.blog.fc2.com/blog-entry-1.html)）
