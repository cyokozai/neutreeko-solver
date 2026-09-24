# 強解決の手法改善 — 先行研究の調査と次の実験計画

作成 2026-09-25。現行の後退解析（`src/solve.jl`、main `3f95c30`）を起点に、査読付き論文と類似ゲームの解決例から、本プログラムに取り込める手段を洗い出し、実験の順序と判定基準を決める。

## 1. 出発点: 現行手法はどこで時間とメモリを使っているか

基準計測は PR #9（`bench/baseline.jl`、Apple M3・Docker 8 CPU・Julia 1.11.9、7 回反復の中央値）による。

| 項目 | 値 |
|---|---:|
| `solve()` 全体 | 1.054 s |
| 　分類＋カウンタ初期化 | 168 ms（16.5%）— ほぼすべて `count_moves` |
| 　キュー伝播 | 839 ms（82.6%） |
| 　　直前局面の生成 | 約 480 ms（伝播の 57%） |
| 　　rank（番号付け） | 約 124 ms |
| 　　表とカウンタへの飛び飛びの読み書き（差し引きの推定） | 約 235 ms |
| 列挙した直前局面 | 45,964,108（うち 55% は確定済み・無効で捨てている） |
| 表（値・距離） | 6.75 MiB（各 3.38 MiB） |
| 作業配列（カウンタ・キュー） | 16.9 MiB（キュー Int32 が 13.5 MiB） |
| 直前局面 1 個の生成 / rank / 8 対称の正規形 | 約 10 / 2.6 / 69 ns |
| スレッド数による差 | なし（`-t 1` と `-t 8` で同じ 1.035 s） |

読み取れること:

- 手間の大半は「滑り」の計算にある。直前局面の生成（伝播の 57%）と `count_moves`（分類の 97%）は同じ計算である。
- メモリは表より作業配列が大きい。キューだけで表の 2 倍ある。
- 並列性はまったく使っていない。
- Neutreeko そのものは 1 秒で解けるので、手法の差は **5×5・3 駒のままでは小さく、規模を上げたときに効く**。改善は「Neutreeko で正しさと速さを測る」段と「変種で規模を上げて効き方を測る」段の二段で評価する。

## 2. 先行研究（照合済み）

書誌は Crossref / arXiv / 公開 PDF で一次照合した。定量値のうち原典で確認していないものは「未照合」と書く。

### 2.1 後退解析の技術

| 文献 | 査読 | 要点 | 本プログラムへの示唆 |
|---|---|---|---|
| K. Thompson, "Retrograde Analysis of Certain Endgames," *ICCA J.* 9(3):131–139, 1986. DOI 10.3233/ICG-1986-9302 | 有 | 終局から直前局面をさかのぼる後退解析の原型 | 現行手法の土台 |
| L. Stiller, "Exploiting Symmetry on Parallel Architectures," *ICCA J.* 18(2), 1995. DOI 10.3233/ICG-1995-18206 | 有 | 盤面対称を並列計算の上で活用 | E4（対称で畳む）と E3（並列）の組合せ |
| T. R. Lincke, A. Marzetta, "Large Endgame Databases with Limited Memory Space," *ICGA J.* 23(3), 2000. DOI 10.3233/ICG-2000-23302 | 有 | 限られたメモリでの大規模データベース構築（削減率は未照合） | E2・E5（作業配列と表の縮小） |
| R. Wu, D. F. Beal, "Parallel Retrograde Analysis on Different Architectures," *Proc. HPDC-10*, 2001. DOI 10.1109/HPDC.2001.945203 | 有 | 分散・共有メモリ上の並列後退解析 | E3（層ごとの並列化） |
| J. W. Romein, H. E. Bal, "Awari is Solved," *ICGA J.* 25(2), 2002. DOI 10.3233/ICG-2002-25306 ／ "Solving Awari with Parallel Retrograde Analysis," *IEEE Computer* 36(10):26–33, 2003. DOI 10.1109/MC.2003.1236468 | 有 | 約 8,890 億局面を分散並列の後退解析で強解決（規模・時間は未照合） | E3 の設計（局面の分割と非同期な伝播） |
| P.-h. Wu, P.-Y. Liu, T.-s. Hsu, "An External-Memory Retrograde Analysis Algorithm," *CG 2004*, LNCS, 2006. DOI 10.1007/11674399_10 | 有 | ディスクに退避しながら値を伝播 | 規模拡大（E9）でメモリに収まらない場合の退避策 |
| S. Edelkamp, D. Sulewski, C. Yücel, "Perfect Hashing for State Space Exploration on the GPU," *ICAPS 2010*. DOI 10.1609/icaps.v20i1.13414 | 有 | 完全ハッシュと 1〜2 ビット/局面のビット列で探索前線を一括処理（GPU で最大 27 倍は未照合） | E1（ビット並列）・E5（2 ビット表） |
| A. Kishimoto, M. Müller, "A Solution to the GHI Problem for Depth-First Proof-Number Search," *Information Sciences* 175(4), 2005. DOI 10.1016/j.ins.2004.04.012 | 有 | 循環を含むゲームで df-pn の証明数を正しく扱う方法（GHI 問題の解決） | E7（前向きの弱解決との比較） |
| J. Schaeffer ほか, "Checkers Is Solved," *Science* 317:1518–1522, 2007. DOI 10.1126/science.1144079 | 有 | 終盤データベース（後退解析）と前向きの証明探索の併用で弱解決 | E7 の構成、E8（検証）の考え方 |

### 2.2 類似ゲームの解決例

| ゲーム | 文献 | 査読 | 結論 | 手法の要点 |
|---|---|---|---|---|
| Nine Men's Morris | R. Gasser, "Solving Nine Men's Morris," in *Games of No Chance*, MSRI Publ. 29, 1996. <https://library.slmath.org/books/Book29/files/gasser.pdf> | 有（論文集） | 引き分け | 移動段階を後退解析、配置段階を αβ。対称除去と完全ハッシュ。移動で局面が循環する点が Neutreeko と共通 |
| Nine Men's Morris ほか | G. E. Gévay, G. Danner, "Calculating Ultrastrong and Extended Solutions for Nine Men's Morris, Morabaraba, and Lasker Morris," *IEEE TCIAIG* 8(3), 2016. DOI 10.1109/TCIAIG.2015.2420191 | 有 | 引き分け | **超強解決（ultra-strong）**: 最善手の中から、相手が誤りやすい手を選ぶための追加情報を後退解析で同時に求める |
| Fanorona | M. P. D. Schadd, M. H. M. Winands, J. W. H. M. Uiterwijk, H. J. van den Herik, "Best Play in Fanorona Leads to Draw," *New Math. Nat. Comput.* 4(3), 2008. DOI 10.1142/S1793005708001124 | 有 | 引き分け（弱解決） | 終盤データベースと前向きの証明探索の併用 |
| どうぶつしょうぎ | 田中哲朗, 「どうぶつしょうぎ」の完全解析, 情報処理学会研究報告 2009-GI-22 No.3, 2009 | 無（研究会） | 後手必勝 | 到達可能局面の後退解析。同一局面の反復を引き分けとして組み込み |
| Othello 8×8 | H. Takizawa, "Othello is Solved," arXiv:2310.19387, 2023 | 無（プレプリント） | 引き分け（**弱解決**） | 既存の探索プログラムを拡張した大規模な前向き探索 |
| Compressed game solving | J. Considine, "Compressed Game Solving," *CG 2024*, LNCS, 2025. DOI 10.1007/978-3-031-86585-5_7 | 有 | — | 局面集合を圧縮表現のまま扱って後退解析 |
| 2048 (4×3) | T. Kaneko, S. Yamashita, "Strongly Solving 2048 4x3," arXiv:2510.04580, 2025 | 無 | 強解決 | 状態をタイル合計（age）で層に分けて処理 |

調査の範囲では、Neutreeko の強解決を主題とする査読付き論文は見つからなかった。Teeko（Steele）・Dao の解析は、査読付きの出典を確認できていない。なお Teeko の駒は隣接マスへ 1 つ動くだけで、Neutreeko・Dao のような滑りではない（調査の一次回答にあった「Teeko も滑る」は誤り）。

## 3. 実験計画

### 共通の判定基準

- **正しさ**: どの改善も、現行の `solve()` の表と全 3,542,000 局面で値・距離が一致すること（基準の CRC32c は `fd057af6`、PR #9 の `bench/results/baseline.toml`）。圧縮表現は復号して比べる。
- **性能**: `bench/baseline.jl` と同じ条件（反復 7 回の中央値、他コンテナの CPU を記録）で、時間・常駐量・作業配列の大きさを基準と比べる。
- **テスト**: `Pkg.test()` と `verify/runtests.jl` が通ること（CI の必須チェック）。
- 数値の効果見込みはすべて推測で、実測で置き換える。

### 第 1 段: Neutreeko（5×5・3 駒）で個別に効かせる

| ID | 実験 | 根拠 | 狙う箇所（基準計測より） | 変更するファイル | 見込み（推測） |
|---|---|---|---|---|---|
| E1 | **滑りの表引き化・ビット演算化**: マス×方向×その筋の占有パターンから着地点を引く表に置き換え、前向き・後ろ向き生成と `count_moves` を速くする | Edelkamp ら 2010 のビット列処理、チェス系の滑り駒の表引き | 伝播の 57%、分類の 97% | `src/board.jl`, `src/position.jl` | 全体で 1.5〜3 倍 |
| E2 | **距離の層ごとの走査**: キューをやめ、距離 d の層を全局面の走査で拾う（ビット列の前線） | Lincke & Marzetta 2000、Edelkamp ら 2010 | キュー 13.5 MiB、55% の空振り | `src/solve.jl`（新関数 `solve_layered`） | 作業配列 16.9 → 数 MiB。時間は同程度 |
| E3 | **並列化**: E2 の層の中を `Threads.@threads` で分け、カウンタ減算を原子的に行う。分類段も並列化 | Romein & Bal 2002/2003、Wu & Beal 2001、Stiller 1995 | スレッド未使用 | `src/solve.jl`（E2 に続けて同じ担当） | 高性能 4 コアで 2〜3 倍 |
| E4 | **盤面対称で畳む**: 8 対称の正規形だけを番号付けし、表・作業配列を約 1/8 に。正規化は変換表で速くする | Gasser 1996、Schaeffer ら 2007、Stiller 1995 | 表 6.75 MiB、作業配列 | `src/symmetry.jl`, 新 `src/canon_index.jl` | メモリ約 1/8。正規形 69 ns を下げないと時間は悪化 |
| E5 | **表の詰め方**: 値と距離を 1 バイトに詰める／勝敗 2 ビット表と距離の再計算の組合せ | Schaeffer ら 2007、Edelkamp ら 2010 | 表 6.75 MiB | `src/table.jl` | 1 バイトで 3.38 MiB、2 ビットで 0.84 MiB（距離は引くたびに探索） |
| E6 | **超強解決の手選び**: 最善手が複数あるとき、相手の応手のうち負けになる手の割合など二次の指標で選ぶ。αβ エージェントとの対局で勝率を測る | Gévay & Danner 2016 | `PerfectAgent` は αβ:4 に 12.8% 引き分けられている | `src/agent.jl`, 新 `src/ultra.jl` | 引き分け率の低下（どこまで下がるかは未知） |
| E7 | **前向きの弱解決との比較**: GHI 対策つき df-pn で初期局面の値を証明し、後退解析と時間・メモリ・扱える問いを比べる | Kishimoto & Müller 2005、Schaeffer ら 2007、Schadd ら 2008 | — | 新 `src/dfpn.jl` | 教材としての比較。速さでは後退解析に及ばない見込み |
| E8 | **証明書の出力と独立検査**: 勝ちには勝ち手 1 つ、負けには全子の確認で済む証拠を表と一緒に書き出し、検証器側で線形時間の検査を行う | Schaeffer ら 2007 の独立検証、Lincke & Marzetta 2000 の一貫性検査 | 検証を「全局面の再計算」から「証拠の検査」へ | `scripts/certify.jl`, `verify/check_cert.jl` | 検査が後退解析より速くなるかは未知 |

### 第 2 段: 変種で規模を上げる

| ID | 実験 | 局面数（手番側視点） | 前提 |
|---|---|---:|---|
| E9a | 盤・駒数・並べる数を引数にした一般化（5×5・3 駒で現行と一致することを確認） | — | E1 の盤表現 |
| E9b | 6×6・3 駒 | C(36,3)·C(33,3) = 38,955,840 | E9a |
| E9c | 5×5・4 駒・4 並べ | C(25,4)·C(21,4) = 75,710,250 | E9a |
| E9d | 6×6・4 駒 | C(36,4)·C(32,4) = 2,118,223,800 | E2・E4・E5 が必須（現行の 2 バイト/局面では表だけで約 4 GiB） |

第 2 段では、E1〜E5 の組合せごとに「解けるか」「何秒・何 MiB か」を表にする。第 1 段で差が小さかった改善が、規模で逆転するかを見るのが目的である。

### 並列に進める単位と衝突

| 波 | worktree（1 本 = 1 PR） | 共有ファイルへの追記 |
|---|---|---|
| 第 1 波 | E1 / E2+E3 / E4 / E5 / E6 | `src/Neutreeko.jl` の include・export、`test/runtests.jl` の include。**挿入位置を担当ごとに離す**（E1 は先頭、E2+E3 は solve の直後、E4 は symmetry の直後、E5 は table の直後、E6 は末尾） |
| 第 2 波 | E7 / E8 / E9a | E9a は E1 のマージ後 |
| 第 3 波 | E9b〜E9d の測定 | E2〜E5 のマージ後 |

マージ順の目安: E1 → E5 → E4 → E2+E3 → E6（E1 が盤表現を変えるため最初に入れる）。

## 4. 未決事項

- テスト CI を GitHub のブランチ保護で必須チェックにするか（PR #8 にコマンドあり。リポジトリ設定の変更）
- 第 2 段の変種を説明資料に含めるか、別の付録にするか
- 超強解決（E6）の二次指標の定義（負けの応手の割合／相手が誤るまでの平均手数など）
