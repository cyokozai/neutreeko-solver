# 後退解析の表（本体 module Neutreeko）と、独立実装の αβ 検証器（module NeutreekoOracle）を
# 突き合わせ、結果を Markdown の表で出力する。
#
# 実行（リポジトリ直下で。検証器が verify/ に無ければ --oracle でパスを渡す）:
#   docker run --rm -v "$PWD":/work -v <dir>:/scratch -w /work julia:1.11 \
#     julia -t 8 --project=. scripts/crosscheck.jl --oracle /scratch/Oracle.jl --out results/crosscheck.md
#
# オプション:
#   --oracle PATH        Oracle.jl のパス（またはそれを含むディレクトリ）。verify/Oracle.jl があればそちらを優先
#   --table PATH         表のファイル（既定 data/neutreeko_table.bin。無ければ solve() する）
#   --out PATH           Markdown の出力先（既定は標準出力のみ）
#   --seed S             抽出の乱数の種（既定 20260924）
#   --maxdepth N         (a) の探索深さ（既定 13）
#   --per-dist N         (a) 距離 0..maxdepth の各距離から抽出する件数の上限（既定 200）
#   --draws N            (a) 引分けの抽出件数（既定 2000）
#   --far-per-dist N     (a) 距離 > maxdepth の各距離から抽出する件数の上限（既定 50）
#   --shallow N          (c) 距離 ≤ N の全局面を maxdepth N で（既定 5）
#   --shallow-every K    (c) K 件に 1 件だけ検査する（既定 1 = 全件）
#   --shallow-side S     (c) 手番の色 black / white / both（既定 both）
#   --shallow-all        (c) 距離 ≤ N に限らず有効な全局面を maxdepth N で（距離 > N と引分けは :unknown を期待）
#   --draw-depth N       (b) 引分けの初手の子局面を読む深さ（既定 20）
#   --skip-initial       (b) を飛ばす（動作確認用）
#   --core-sha X / --oracle-sha Y   報告に載せるコミット SHA（コンテナ内に git が無いので外から渡す）
#   --host TEXT          報告に載せるホストの説明（コンテナ内からは CPU 名が見えないので外から渡す）
#
# 判定規則（verify/compare.jl と同じ）:
#   表が勝ち・負けで距離 d ≤ maxdepth → oracle が同じ (値, d) を返すこと
#   表が引分け、または d > maxdepth    → oracle が (:unknown, maxdepth) を返すこと

include(joinpath(@__DIR__, "export_tsv.jl"))

using Neutreeko
using Printf
using SHA
using .NeutreekoExport: select_indices, sample_indices, index_positions, load_or_solve

const NT = Neutreeko
const DEFAULT_SEED = NeutreekoExport.DEFAULT_SEED

# ---------------------------------------------------------------------------
# 引数と検証器の読み込み
# ---------------------------------------------------------------------------

function parse_cli(args)
    o = Dict{Symbol,Any}(:oracle => nothing, :table => NeutreekoExport.DEFAULT_TABLE, :out => nothing,
                         :seed => DEFAULT_SEED, :maxdepth => 13, :per_dist => 200, :draws => 2000,
                         :far_per_dist => 50, :shallow => 5, :shallow_every => 1, :shallow_side => :both,
                         :draw_depth => 20, :skip_initial => false, :shallow_all => false, :host => "(未指定)", :core_sha => "(未指定)",
                         :oracle_sha => "(未指定)")
    ints = Dict("--seed" => :seed, "--maxdepth" => :maxdepth, "--per-dist" => :per_dist,
                "--draws" => :draws, "--far-per-dist" => :far_per_dist, "--shallow" => :shallow,
                "--shallow-every" => :shallow_every, "--draw-depth" => :draw_depth)
    strs = Dict("--oracle" => :oracle, "--table" => :table, "--out" => :out,
                "--core-sha" => :core_sha, "--oracle-sha" => :oracle_sha, "--host" => :host)
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("--skip-initial", "--shallow-all")
            o[a == "--skip-initial" ? :skip_initial : :shallow_all] = true
            i += 1
            continue
        end
        i < length(args) || error("$a に値が無い")
        v = args[i+1]
        if haskey(ints, a)
            o[ints[a]] = parse(Int, v)
        elseif haskey(strs, a)
            o[strs[a]] = v
        elseif a == "--shallow-side"
            o[:shallow_side] = Symbol(v)
            o[:shallow_side] in (:black, :white, :both) || error("--shallow-side は black / white / both")
        else
            error("知らないオプション: $a")
        end
        i += 2
    end
    return (; (k => v for (k, v) in o)...)
end

"verify/Oracle.jl があればそれを、無ければ --oracle のパスを返す"
function oracle_path(opt)
    local_path = joinpath(@__DIR__, "..", "verify", "Oracle.jl")
    isfile(local_path) && return normpath(local_path)
    opt === nothing && error("verify/Oracle.jl が無い。--oracle で Oracle.jl のパスを渡すこと")
    p = isdir(opt) ? joinpath(opt, "Oracle.jl") : opt
    isfile(p) || error("Oracle.jl が見つからない: $p")
    return p
end

const OPTS = parse_cli(ARGS)
const ORACLE_PATH = oracle_path(OPTS.oracle)
include(ORACLE_PATH)
const NO = NeutreekoOracle

# ---------------------------------------------------------------------------
# 突き合わせの部品
# ---------------------------------------------------------------------------

"表の値 (v, d) から、深さ maxdepth の oracle に期待する返り値"
expected(v::Symbol, d::Int, maxdepth::Int) =
    (v === :draw || d > maxdepth) ? (:unknown, maxdepth) : (v, d)

struct Item
    pos::String
    value::Symbol    # 表の値（手番側視点）
    dist::Int        # 表の距離（引分けは -1）
end

Item(t::NT.SolveTable, p::Position) = Item(format_position(p), lookup(t, p)...)

struct Mismatch
    section::String
    item::Item
    maxdepth::Int
    want::Tuple{Symbol,Int}
    got::Tuple{Symbol,Int}
end

"""
    run_oracle(items, maxdepth; ttcap) -> Vector{Tuple{Symbol,Int}}

全スレッドで oracle を回す。置換表はスレッドごとに 1 つを使い回し、`ttcap` 件を超えたら捨てる
（検証器の置換表は深さつきで格納し、浅い問い合わせでは落として使うので、共有・破棄のどちらでも
結果は変わらない。verify/README.md 参照）。
"""
function run_oracle(items::Vector{Item}, maxdepth::Int; ttcap::Int = 1_500_000)
    n = length(items)
    out = Vector{Tuple{Symbol,Int}}(undef, n)
    nchunk = max(1, min(Threads.nthreads(), n))
    @sync for c in 1:nchunk
        Threads.@spawn begin
            s = NO.Searcher()
            for k in c:nchunk:n
                length(s.tt) > ttcap && empty!(s.tt)
                out[k] = NO.oracle(items[k].pos; maxdepth = maxdepth, searcher = s)
            end
        end
    end
    return out
end

"items を深さ maxdepth で検査し、(一致数, 不一致の一覧, 秒) を返す"
function check_items(section::String, items::Vector{Item}, maxdepth::Int)
    t0 = time()
    got = run_oracle(items, maxdepth)
    el = time() - t0
    ms = Mismatch[]
    for (it, g) in zip(items, got)
        w = expected(it.value, it.dist, maxdepth)
        g == w || push!(ms, Mismatch(section, it, maxdepth, w, g))
    end
    return length(items) - length(ms), ms, el
end

"""
    convention_mismatches(items) -> Int

局面表記と合法手の取り決めが両実装で同じか。本体の parse → format と検証器の parse → format が
同じ文字列に戻り、合法手の集合（from, to のマス番号）が一致しない局面の数。
"""
function convention_mismatches(items::Vector{Item})
    bad = 0
    for it in items
        p = parse_position(it.pos)
        q = NO.parse_pos(it.pos)
        ok = format_position(p) == it.pos && NO.format_pos(q) == it.pos
        mine = sort!([(Int(m.from), Int(m.to)) for m in legal_moves(p)])
        theirs = sort!(NO.legal_moves(q))
        ok &= mine == theirs
        bad += !ok
    end
    return bad
end

fmt_s(x) = x < 10 ? @sprintf("%.2f", x) : x < 100 ? @sprintf("%.1f", x) : @sprintf("%.0f", x)
fmt_n(n::Integer) = replace(string(n), r"(?<=\d)(?=(\d{3})+$)" => ",")
vd(v, d) = d < 0 ? string(v) : "$(v)($(d))"
vd(t::Tuple) = vd(t...)

# ---------------------------------------------------------------------------
# 本体
# ---------------------------------------------------------------------------

function main(o)
    md = IOBuffer()
    all_ms = Mismatch[]
    T0 = time()

    t = load_or_solve(o.table)
    tablefile = isfile(o.table) ? normpath(o.table) : "(その場で solve())"
    tablesha = isfile(o.table) ? bytes2hex(sha256(read(o.table))) : "-"
    oraclesha = bytes2hex(sha256(read(ORACLE_PATH)))

    # JIT コンパイルを計時から外す
    NO.oracle(NO.INITIAL_POS_STR; maxdepth = 3)
    run_oracle([Item(t, initial_position())], 3)

    # 距離ごとの母集団
    maxd = Int(maximum(t.dist[i] for i in eachindex(t.value) if t.value[i] in (NT.VAL_WIN, NT.VAL_LOSS)))
    by_dist = [Int[] for _ in 0:maxd]
    draws = Int[]
    for i in eachindex(t.value)
        v = t.value[i]
        if v == NT.VAL_WIN || v == NT.VAL_LOSS
            push!(by_dist[t.dist[i]+1], i)
        elseif v == NT.VAL_DRAW
            push!(draws, i)
        end
    end

    println(md, "# 後退解析の表と独立 αβ 検証器の突き合わせ")
    println(md)
    println(md, "`scripts/crosscheck.jl` の出力。後退解析（`src/`、module `Neutreeko`）が作った全局面の表から局面を選び、",
            "コードを共有しない前向きの αβ 探索（`verify/Oracle.jl`、module `NeutreekoOracle`）で同じ局面を読み直して、",
            "値（勝ち・負け・引分け）と決着までの手数（ply）が一致するかを確かめた。")
    println(md)
    println(md, "判定規則（`verify/compare.jl` と同じ）: 表が勝ち・負けで距離 d ≤ maxdepth なら oracle が同じ値・同じ距離を返すこと。",
            "表が引分け、または d > maxdepth なら oracle が maxdepth 手以内に決着しない（`:unknown`）こと。",
            "oracle は反復深化なので、距離 d で決着を返したことは d − 1 手以内では決着しないことも含む。")
    println(md)

    # ---- (a) 層別無作為抽出 ---------------------------------------------------
    D = o.maxdepth
    rows_a = Any[]
    conv_items = Item[]
    na_total = 0
    nmatch_total = 0
    ta_total = 0.0
    for d in 0:maxd
        pop = by_dist[d+1]
        isempty(pop) && continue
        k = d <= D ? o.per_dist : o.far_per_dist
        idx = sample_indices(pop, k; seed = o.seed + d)
        items = [Item(t, p) for p in index_positions(idx; side = :random, seed = o.seed + 1000 + d)]
        nm, ms, el = check_items("a", items, D)
        append!(all_ms, ms)
        append!(conv_items, items)
        v = items[1].value
        push!(rows_a, (d <= D ? "距離 $d" : "距離 $(d)（> $(D)）", string(v), length(pop), length(items), nm, length(ms), el,
                       d <= D ? "$(v)($(d))" : "unknown"))
        na_total += length(items); nmatch_total += nm; ta_total += el
    end
    let idx = sample_indices(draws, o.draws; seed = o.seed + 999)
        items = [Item(t, p) for p in index_positions(idx; side = :random, seed = o.seed + 1999)]
        nm, ms, el = check_items("a", items, D)
        append!(all_ms, ms)
        append!(conv_items, items)
        push!(rows_a, ("引分け", "draw", length(draws), length(items), nm, length(ms), el, "unknown"))
        na_total += length(items); nmatch_total += nm; ta_total += el
    end
    nconv_bad = convention_mismatches(conv_items)

    println(md, "## (a) 層別無作為抽出（maxdepth $(D)）")
    println(md)
    println(md, "勝ち・負けは距離ごとに、距離 0〜$D は最大 $(o.per_dist) 件、距離 $(D+1)〜$maxd は最大 $(o.far_per_dist) 件、",
            "引分けは $(o.draws) 件を無作為に選んだ（seed $(o.seed)、層ごとに seed + 距離。手番の色も無作為）。",
            "距離 $D を超える層は「maxdepth $D では決着しない」ことを確かめる。")
    println(md)
    println(md, "| 層 | 表の値 | 母集団 | 抽出 | oracle に期待 | 一致 | 不一致 | 秒 |")
    println(md, "|---|---|---:|---:|---|---:|---:|---:|")
    for (name, v, npop, n, nm, nbad, el, want) in rows_a
        println(md, "| $name | $v | $(fmt_n(npop)) | $(fmt_n(n)) | $want | $(fmt_n(nm)) | $nbad | $(fmt_s(el)) |")
    end
    println(md, "| **計** | | | **$(fmt_n(na_total))** | | **$(fmt_n(nmatch_total))** | **$(na_total - nmatch_total)** | **$(fmt_s(ta_total))** |")
    println(md)
    println(md, "母集団は手番側視点に正規化した局面の数（黒番・白番の 2 通りの絶対表現が 1 つに対応する）。",
            "取り決めの確認として、抽出した $(fmt_n(length(conv_items))) 局面すべてで、局面文字列の読み書きが両実装で同じ文字列に戻ること、",
            "合法手の集合（移動元・移動先）が一致することも確かめた: 不一致 $(nconv_bad) 件。")
    println(md)

    # ---- (b) 初期局面の 14 手 ------------------------------------------------
    rows_b = Any[]
    tb_total = 0.0
    root_row = nothing
    if !o.skip_initial
        p0 = initial_position()
        flip = Dict(:win => :loss, :loss => :win, :draw => :draw)
        ok_init = format_position(p0) == NO.INITIAL_POS_STR
        for m in legal_moves(p0)
            c = apply_move(p0, m)
            it = Item(t, c)
            checks = Tuple{Int,Tuple{Symbol,Int},Tuple{Symbol,Int},Float64}[]
            depths = it.value === :draw ? [o.draw_depth] : it.dist == 0 ? [0] : [it.dist, it.dist - 1]
            for dd in depths
                t1 = time()
                g = NO.oracle(it.pos; maxdepth = dd)   # 問い合わせごとに新しい置換表
                el = time() - t1
                w = expected(it.value, it.dist, dd)
                g == w || push!(all_ms, Mismatch("b", it, dd, w, g))
                push!(checks, (dd, w, g, el))
                tb_total += el
            end
            push!(rows_b, (format_move(m), it, flip[it.value], checks))
        end
        t1 = time()
        g0 = NO.oracle(format_position(p0); maxdepth = o.draw_depth)
        el0 = time() - t1
        tb_total += el0
        w0 = expected(lookup(t, p0)..., o.draw_depth)
        g0 == w0 || push!(all_ms, Mismatch("b", Item(t, p0), o.draw_depth, w0, g0))
        root_row = (Item(t, p0), g0, w0, el0, ok_init)

        println(md, "## (b) 初期局面の 14 手")
        println(md)
        println(md, "初期局面 `$(format_position(p0))`（黒 b1, d1, c4 / 白 b5, d5, c2、黒番）。表では引分け。",
                "本体と検証器の初期局面の文字列は", ok_init ? "一致する" : "**一致しない**", "。")
        println(md, "各初手の後の局面（白番）について、表の値・距離 d を oracle で maxdepth = d と d − 1 の 2 回読んだ",
                "（問い合わせごとに置換表を新しくし、1 スレッドで順に実行）。",
                "maxdepth = d で表と同じ値・距離が出て、maxdepth = d − 1 では決着しない（`:unknown`）ことを確かめる。",
                "引分けの初手は maxdepth $(o.draw_depth) で決着しないことを確かめる。黒の値は初期局面から見た値で、距離は初手を含めて d + 1。")
        println(md)
        println(md, "| 初手 | 黒の値（初期局面から） | 子局面（白番）の表の値 | maxdepth | oracle に期待 | oracle | 判定 | 秒 |")
        println(md, "|---|---|---|---:|---|---|---|---:|")
        for (mv, it, bv, checks) in rows_b
            black = it.value === :draw ? "draw" : "$(bv)($(it.dist + 1))"
            for (j, (dd, w, g, el)) in enumerate(checks)
                a, b, c = j == 1 ? ("`$mv`", black, vd(it.value, it.dist)) : ("", "", "")
                println(md, "| $a | $b | $c | $dd | $(vd(w)) | $(vd(g)) | $(g == w ? "一致" : "**不一致**") | $(fmt_s(el)) |")
            end
        end
        let (it, g, w, el, _) = root_row
            println(md, "| （初期局面そのもの） | draw | — | $(o.draw_depth) | $(vd(w)) | $(vd(g)) | $(g == w ? "一致" : "**不一致**") | $(fmt_s(el)) |")
        end
        println(md)
        nb = sum(length(r[4]) for r in rows_b) + 1
        nb_bad = count(m -> m.section == "b", all_ms)
        println(md, "問い合わせ $nb 回、一致 $(nb - nb_bad)、不一致 $(nb_bad)、計 $(fmt_s(tb_total)) 秒。")
        println(md)
    end

    # ---- (c) 距離 ≤ S の全局面（--shallow-all なら有効局面すべて） ---------------
    S = o.shallow
    idx_c = o.shallow_all ? select_indices(t) : select_indices(t; maxdist = S)
    npop_c = length(idx_c)
    every = o.shallow_every
    every > 1 && (idx_c = idx_c[1:every:end])
    pos_c = index_positions(idx_c; side = o.shallow_side)
    items_c = [Item(t, p) for p in pos_c]
    nm_c, ms_c, el_c = check_items("c", items_c, S)
    append!(all_ms, ms_c)
    # 層: 距離 0..S はそれぞれ 1 層、距離 > S の勝ち・負けはまとめて 1 層、引分けで 1 層
    layer(v, d) = v === :draw ? S + 2 : min(d, S + 1)
    npop_layer = zeros(Int, S + 3)
    for d in 0:maxd
        npop_layer[min(d, S + 1)+1] += length(by_dist[d+1])
    end
    npop_layer[S+3] = length(draws)
    nchk = zeros(Int, S + 3)
    nbad = zeros(Int, S + 3)
    for it in items_c
        nchk[layer(it.value, it.dist)+1] += 1
    end
    for m in ms_c
        nbad[layer(m.item.value, m.item.dist)+1] += 1
    end
    rows_c = Any[]
    for L in 0:S+2
        nchk[L+1] == 0 && continue
        name, v, want = L <= S ? ("$L", isodd(L) ? "win" : "loss", isodd(L) ? "win($L)" : "loss($L)") :
                        L == S + 1 ? ("$(S+1)〜$maxd", "win / loss", "unknown") : ("—", "draw", "unknown")
        push!(rows_c, (name, v, npop_layer[L+1], nchk[L+1], nchk[L+1] - nbad[L+1], nbad[L+1], want))
    end

    println(md, o.shallow_all ? "## (c) 有効な全局面の浅い検査（maxdepth $(S)）" :
                                "## (c) 距離 ≤ $S の全局面（maxdepth $(S)）")
    println(md)
    sidetxt = o.shallow_side === :both ? "黒番・白番の両方の絶対表現" : o.shallow_side === :black ? "黒番の絶対表現" : "白番の絶対表現"
    target = o.shallow_all ? "無効でない正規化局面すべて（$(fmt_n(npop_c)) 件）" :
                             "勝ち・負けかつ距離 ≤ $S の正規化局面（$(fmt_n(npop_c)) 件）"
    println(md, "表で$(target)",
            every > 1 ? "を $every 件に 1 件に間引き（間引き率 1/$(every)）、" : "の全件を、",
            "$(sidetxt)で検査した（$(fmt_n(length(items_c))) 局面）。",
            o.shallow_all ? "距離 ≤ $S の局面は値と距離の一致を、距離 > $S と引分けの局面は maxdepth $S で決着しないことを確かめる。" : "")
    println(md)
    println(md, "| 距離 | 表の値 | 正規化局面 | 検査した局面 | oracle に期待 | 一致 | 不一致 |")
    println(md, "|---:|---|---:|---:|---|---:|---:|")
    for (name, v, npop, n, nm, nb, want) in rows_c
        println(md, "| $name | $v | $(fmt_n(npop)) | $(fmt_n(n)) | $want | $(fmt_n(nm)) | $nb |")
    end
    println(md, "| **計** | | **$(fmt_n(npop_c))** | **$(fmt_n(length(items_c)))** | | **$(fmt_n(nm_c))** | **$(length(ms_c))** |")
    println(md)
    let nshort = sum(nchk[1:S+1])
        println(md, "うち距離 ≤ $S の局面は正規化で $(fmt_n(sum(npop_layer[1:S+1]))) 件、検査 $(fmt_n(nshort)) 局面、",
                "不一致 $(sum(nbad[1:S+1])) 件。所要 $(fmt_s(el_c)) 秒（$(Threads.nthreads()) スレッド）。")
    end
    println(md)

    # ---- (d) 不一致 ---------------------------------------------------------
    println(md, "## (d) 不一致")
    println(md)
    if isempty(all_ms)
        println(md, "**0 件。** すべての問い合わせで、後退解析の表と αβ 検証器の結果が一致した。")
    else
        println(md, "**$(length(all_ms)) 件。** どちらが正しいかはこの出力だけでは決めない（手で追って別に報告する）。")
        println(md)
        println(md, "| 節 | 局面 | 表の値 | maxdepth | oracle に期待 | oracle |")
        println(md, "|---|---|---|---:|---|---|")
        for m in all_ms[1:min(end, 50)]
            println(md, "| $(m.section) | `$(m.item.pos)` | $(vd(m.item.value, m.item.dist)) | $(m.maxdepth) | $(vd(m.want)) | $(vd(m.got)) |")
        end
        length(all_ms) > 50 && println(md, "\n（先頭 50 件のみ。全 $(length(all_ms)) 件）")
        println(md)
        # 手で追うための材料: 不一致局面の各子について、表の値と oracle（1 手浅く）の値
        println(md, "### 不一致局面の子局面（手で追うための材料）")
        for m in all_ms[1:min(end, 5)]
            p = parse_position(m.item.pos)
            println(md, "\n`$(m.item.pos)`（表 $(vd(m.item.value, m.item.dist))、oracle $(vd(m.got))、maxdepth $(m.maxdepth)）\n")
            println(md, "| 手 | 子の表の値 | 子の oracle（maxdepth $(m.maxdepth - 1)） |")
            println(md, "|---|---|---|")
            for mv in legal_moves(p)
                c = apply_move(p, mv)
                cv = lookup(t, c)
                cg = NO.oracle(format_position(c); maxdepth = max(m.maxdepth - 1, 0))
                println(md, "| `$(format_move(mv))` | $(vd(cv)) | $(vd(cg)) |")
            end
        end
    end
    println(md)

    # ---- 実行環境 -----------------------------------------------------------
    total = time() - T0
    nq = na_total + length(items_c) + (o.skip_initial ? 0 : sum(length(r[4]) for r in rows_b) + 1)
    println(md, "## まとめと実行環境")
    println(md)
    println(md, "| 項目 | 値 |")
    println(md, "|---|---|")
    println(md, "| 問い合わせの総数 | $(fmt_n(nq)) |")
    println(md, "| 不一致 | $(length(all_ms)) |")
    println(md, "| 総所要時間 | $(fmt_s(total)) 秒（表の読込・抽出を含む） |")
    println(md, "| 本体（後退解析）のコミット | `$(o.core_sha)` |")
    println(md, "| 検証器（αβ）のコミット | `$(o.oracle_sha)` |")
    println(md, "| 検証器ファイルの SHA-256 | `$(oraclesha)` |")
    println(md, "| 表のファイル | `$(basename(tablefile))`（SHA-256 `$(tablesha)`） |")
    println(md, "| 表の件数 | 勝ち $(fmt_n(count(==(NT.VAL_WIN), t.value))) / 負け $(fmt_n(count(==(NT.VAL_LOSS), t.value))) / 引分け $(fmt_n(length(draws))) / 無効 $(fmt_n(count(==(NT.VAL_INVALID), t.value)))（手番側視点に正規化した局面） |")
    println(md, "| 最長の距離 | $maxd ply |")
    println(md, "| Julia | $(VERSION)（Docker イメージ `julia:1.11`） |")
    println(md, "| ホスト | $(o.host) |")
    println(md, "| OS / CPU（コンテナ内） | $(Sys.KERNEL) $(Sys.ARCH) / $(Sys.CPU_THREADS) 論理 CPU、メモリ $(round(Sys.total_memory() / 2^30, digits = 1)) GiB |")
    println(md, "| スレッド数 | $(Threads.nthreads())（(b) は 1 スレッドで順に実行） |")
    println(md, "| 乱数の種 | $(o.seed)（`Random.Xoshiro`、層ごとに種をずらす） |")

    s = String(take!(md))
    print(s)
    if o.out !== nothing
        mkpath(dirname(abspath(o.out)))
        write(o.out, s)
    end
    return isempty(all_ms) ? 0 : 1
end

exit(main(OPTS))
