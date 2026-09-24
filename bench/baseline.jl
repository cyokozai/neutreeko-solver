# 現行の後退解析（src/solve.jl の solve()）の基準計測。
#
# アルゴリズムは変えない。src/ は触らず、内訳が要る箇所は solve() と同じ手順を
# この中で段階ごとに呼び直して測る（段階版の表が solve() の表と全局面一致することを確かめる）。
#
# 実行（リポジトリ直下で。ホストの情報も記録するなら bench/run_baseline.sh を使う）:
#   docker run --rm -v <リポジトリの絶対パス>:/work -w /work julia:1.11 \
#       julia --project=. bench/baseline.jl --out bench/results/baseline.toml
#
# 引数:
#   --out PATH          TOML の出力先（既定 bench/results/baseline.toml）。同じ名前の .md に表も書く
#   --reps N            各項目の反復回数（JIT 初回を除いた回数。既定 5）
#   --fixpoint-reps N   solve_fixpoint() の反復回数（既定は --reps と同じ）
#   --threads LIST      スレッド数の確認で子プロセスを起こす -t の値（既定 "1,8"。"none" で省略）
#   --rule draw|loss    合法手 0 の扱い（既定 draw）
#   --probe             内部用: solve() を測って TOML を標準出力へ書くだけ（スレッド確認の子プロセス）

using Neutreeko
using Neutreeko: NSTATES, N_ME, N_OPP, Bits, bit, RAYS, OPPOSITE_DIR, rank_state, unrank_state,
                 VAL_DRAW, VAL_WIN, VAL_LOSS, VAL_INVALID, SolveTable, initial_labels, state_kind,
                 count_moves, foreach_child, foreach_predecessor, solve_fixpoint, state_index,
                 position_from_index, SYMMETRIES, transform_index,
                 ME_BITS, OPP_COMBOS22, FREE_SQUARES, BINOM, LINE_BY_RANK, WIN_LINES
using TOML, CRC32c, Random, Printf

const NT = Neutreeko

# ---------------------------------------------------------------------------
# 引数
# ---------------------------------------------------------------------------

function parse_args(args)
    opt = Dict{String,Any}(
        "out" => joinpath(@__DIR__, "results", "baseline.toml"),
        "reps" => 5,
        "fixpoint-reps" => nothing,
        "threads" => "1,8",
        "rule" => "draw",
        "probe" => false,
    )
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--probe"
            opt["probe"] = true
        elseif startswith(a, "--")
            k = a[3:end]
            if occursin('=', k)
                k, v = split(k, '=', limit = 2)
            else
                i += 1
                i <= length(args) || error("引数 $a に値が無い")
                v = args[i]
            end
            haskey(opt, k) || error("未知の引数: $a")
            opt[k] = k in ("reps", "fixpoint-reps") ? parse(Int, v) : String(v)
        else
            error("未知の引数: $a")
        end
        i += 1
    end
    opt["fixpoint-reps"] === nothing && (opt["fixpoint-reps"] = opt["reps"])
    opt["reps"] >= 1 || error("--reps は 1 以上")
    return opt
end

# ---------------------------------------------------------------------------
# 計時の道具
# ---------------------------------------------------------------------------

"最適化で消されないよう、計測した関数の戻り値をここへ流す"
const SINK = Ref{Any}(nothing)

function summarize(ts::Vector{Float64})
    s = sort(ts)
    n = length(s)
    med = isodd(n) ? s[(n+1)÷2] : (s[n÷2] + s[n÷2+1]) / 2
    return Dict{String,Any}("median" => med, "min" => s[1], "max" => s[end], "n" => n, "samples" => ts)
end

"""
    measure(f, reps) -> Dict

`f()` を 1 回（JIT 込み）捨ててから `reps` 回測る。各回の前に GC.gc() で前回のごみを片付ける。
秒・割り当てバイト・GC 秒をそれぞれ中央値・最小・最大で返す。
"""
function measure(f, reps::Int)
    SINK[] = f()
    ts = Float64[]; bytes = Float64[]; gcs = Float64[]
    for _ in 1:reps
        GC.gc()
        st = @timed f()
        SINK[] = st.value
        push!(ts, st.time); push!(bytes, st.bytes); push!(gcs, st.gctime)
    end
    return Dict{String,Any}("seconds" => summarize(ts), "allocated_bytes" => summarize(bytes),
                            "gc_seconds" => summarize(gcs))
end

"表の同一性を見るための CRC32c（value と dist を続けて）"
function table_checksum(t::SolveTable)
    c = crc32c(Vector{UInt8}(reinterpret(UInt8, t.value)))
    c = crc32c(t.dist, c)
    return string(c, base = 16, pad = 8)
end

same_table(a::SolveTable, b::SolveTable) = a.value == b.value && a.dist == b.dist

# ---------------------------------------------------------------------------
# solve() を段階に分けて呼ぶ版（手順は src/solve.jl の solve() と同じ）
# ---------------------------------------------------------------------------

"段階 2: 終局（負け 0 手）をキューに積む"
function seed_queue(value::Vector{Int8})
    queue = Vector{Int32}(undef, NSTATES)
    tail = 0
    @inbounds for i in 1:NSTATES
        if value[i] == VAL_LOSS
            tail += 1
            queue[tail] = i
        end
    end
    return queue, tail
end

"段階 3: キュー伝播。solve() の while ループをそのまま写したもの。処理後の tail を返す"
function propagate!(value::Vector{Int8}, dist::Vector{UInt8}, cnt::Vector{UInt8},
                    queue::Vector{Int32}, tail::Int)
    head = 1
    @inbounds while head <= tail
        q = queue[head]
        head += 1
        vq = value[q]
        dnext = dist[q] + UInt8(1)
        dnext == 0 && error("距離が UInt8 を超えた")
        me, opp = unrank_state(q)
        occ = me | opp
        m = opp
        while m != 0
            s = trailing_zeros(m)
            m &= m - Bits(1)
            rays = RAYS[s+1]
            for d in 1:8
                fwd = rays[d]
                (!isempty(fwd) && (occ >> fwd[1]) & 1 == 0) && continue
                for t in rays[OPPOSITE_DIR[d]]
                    (occ >> t) & 1 == 1 && break
                    p = rank_state(opp ⊻ bit(s) ⊻ bit(t), me)
                    value[p] == VAL_DRAW || continue
                    if vq == VAL_LOSS
                        value[p] = VAL_WIN
                        dist[p] = dnext
                        tail += 1
                        queue[tail] = p
                    else
                        cnt[p] -= UInt8(1)
                        if cnt[p] == 0
                            value[p] = VAL_LOSS
                            dist[p] = dnext
                            tail += 1
                            queue[tail] = p
                        end
                    end
                end
            end
        end
    end
    return tail
end

"""
    staged_solve(rule) -> (table, seconds::NamedTuple, nprocessed, ndraw)

段階 1 分類＋カウンタ初期化（`initial_labels`）/ 段階 2 キューの初期化 / 段階 3 キュー伝播 /
段階 4 引分け確定。現行の solve() に段階 4 の処理は無い（未確定の `VAL_DRAW` がそのまま
引き分けとして残る）ので、ここでは未確定数を数えて表の構造体を作るだけの時間になる。
"""
function staged_solve(rule::Symbol)
    t0 = time_ns()
    value, dist, cnt = initial_labels(rule)
    t1 = time_ns()
    queue, tail = seed_queue(value)
    t2 = time_ns()
    nproc = propagate!(value, dist, cnt, queue, tail)
    t3 = time_ns()
    ndraw = count(==(VAL_DRAW), value)
    table = SolveTable(value, dist, rule)
    t4 = time_ns()
    secs = (classify = (t1 - t0) / 1e9, seed = (t2 - t1) / 1e9, propagate = (t3 - t2) / 1e9,
            draw = (t4 - t3) / 1e9, total = (t4 - t0) / 1e9)
    return table, secs, nproc, ndraw
end

# 段階 1 の中身をさらに分けた参考計測（initial_labels の 1 本のループを二つに割ったもの）

"参考: 全局面の unrank と state_kind だけ（合法手を数えない）"
function classify_only()
    value = fill(VAL_DRAW, NSTATES)
    @inbounds for i in 1:NSTATES
        me, opp = unrank_state(i)
        k = state_kind(me, opp)
        value[i] = k === :invalid ? VAL_INVALID : k === :loss0 ? VAL_LOSS : VAL_DRAW
    end
    return value
end

"参考: 内部局面の合法手を数えるだけ（value は classify_only の結果を使う）"
function count_only(value::Vector{Int8})
    nmoves = zeros(UInt8, NSTATES)
    @inbounds for i in 1:NSTATES
        value[i] == VAL_DRAW || continue
        me, opp = unrank_state(i)
        nmoves[i] = count_moves(me, opp)
    end
    return nmoves
end

# ---------------------------------------------------------------------------
# 伝播の統計（計数を足した版。時間は計数の分だけ膨らむので参考値）
# ---------------------------------------------------------------------------

const MAXLAYER = 256

mutable struct LayerStats
    processed::Vector{Int}      # 距離 d で取り出した局面数（= 距離 d の層の大きさ）
    processed_win::Vector{Int}
    processed_loss::Vector{Int}
    preds::Vector{Int}          # 列挙した直前局面（rank_state の呼び出し回数）
    preds_undecided::Vector{Int} # そのうち未確定だったもの（値を書き換える候補）
    set_win::Vector{Int}        # 勝ち d+1 に確定させた数
    decrements::Vector{Int}     # カウンタ減算の回数
    set_loss::Vector{Int}       # カウンタが 0 になって負け d+1 に確定させた数
    seconds::Vector{Float64}    # 層ごとの時間（計数込み）
    peak_live::Int              # キューの未処理分（tail − head + 1）の最大
end
LayerStats() = LayerStats((zeros(Int, MAXLAYER) for _ in 1:8)..., zeros(Float64, MAXLAYER), 0)

function propagate_stats!(value, dist, cnt, queue, tail::Int, st::LayerStats)
    head = 1
    curd = -1
    tlayer = time_ns()
    @inbounds while head <= tail
        st.peak_live = max(st.peak_live, tail - head + 1)
        q = queue[head]
        head += 1
        vq = value[q]
        dq = Int(dist[q])
        if dq != curd
            now = time_ns()
            curd >= 0 && (st.seconds[curd+1] += (now - tlayer) / 1e9)
            tlayer = now
            curd = dq
        end
        L = dq + 1
        st.processed[L] += 1
        vq == VAL_LOSS ? (st.processed_loss[L] += 1) : (st.processed_win[L] += 1)
        dnext = dist[q] + UInt8(1)
        dnext == 0 && error("距離が UInt8 を超えた")
        me, opp = unrank_state(q)
        occ = me | opp
        m = opp
        while m != 0
            s = trailing_zeros(m)
            m &= m - Bits(1)
            rays = RAYS[s+1]
            for d in 1:8
                fwd = rays[d]
                (!isempty(fwd) && (occ >> fwd[1]) & 1 == 0) && continue
                for t in rays[OPPOSITE_DIR[d]]
                    (occ >> t) & 1 == 1 && break
                    p = rank_state(opp ⊻ bit(s) ⊻ bit(t), me)
                    st.preds[L] += 1
                    value[p] == VAL_DRAW || continue
                    st.preds_undecided[L] += 1
                    if vq == VAL_LOSS
                        st.set_win[L] += 1
                        value[p] = VAL_WIN
                        dist[p] = dnext
                        tail += 1
                        queue[tail] = p
                    else
                        st.decrements[L] += 1
                        cnt[p] -= UInt8(1)
                        if cnt[p] == 0
                            st.set_loss[L] += 1
                            value[p] = VAL_LOSS
                            dist[p] = dnext
                            tail += 1
                            queue[tail] = p
                        end
                    end
                end
            end
        end
    end
    curd >= 0 && (st.seconds[curd+1] += (time_ns() - tlayer) / 1e9)
    return tail
end

function solve_with_stats(rule::Symbol)
    value, dist, cnt = initial_labels(rule)
    cnt0 = copy(cnt)
    queue, tail = seed_queue(value)
    st = LayerStats()
    nproc = propagate_stats!(value, dist, cnt, queue, tail, st)
    return SolveTable(value, dist, rule), st, nproc, cnt0, cnt
end

# ---------------------------------------------------------------------------
# 番号付け・手の生成・参照の速さ
# ---------------------------------------------------------------------------

function bench_unrank_seq()
    acc = Bits(0)
    @inbounds for i in 1:NSTATES
        me, opp = unrank_state(i)
        acc ⊻= me ⊻ (opp << 1)
    end
    return acc
end

function bench_unrank_idx(idx::Vector{Int32})
    acc = Bits(0)
    @inbounds for i in idx
        me, opp = unrank_state(i)
        acc ⊻= me ⊻ (opp << 1)
    end
    return acc
end

function bench_rank(mes::Vector{Bits}, opps::Vector{Bits})
    acc = 0
    @inbounds for i in eachindex(mes)
        acc += rank_state(mes[i], opps[i])
    end
    return acc
end

mutable struct Acc
    x::UInt64
    n::Int
end

"前向き生成だけ（子局面のビットボードを畳み込むだけで番号は付けない）"
function bench_children(mes::Vector{Bits}, opps::Vector{Bits})
    a = Acc(0, 0)
    @inbounds for i in eachindex(mes)
        foreach_child(mes[i], opps[i]) do cm, co
            a.x += cm ⊻ (UInt64(co) << 25)
            a.n += 1
        end
    end
    return a
end

"前向き生成 + 子局面の rank_state（前向き解法が実際にする仕事）"
function bench_children_rank(mes::Vector{Bits}, opps::Vector{Bits})
    a = Acc(0, 0)
    @inbounds for i in eachindex(mes)
        foreach_child(mes[i], opps[i]) do cm, co
            a.x += rank_state(cm, co)
            a.n += 1
        end
    end
    return a
end

"後ろ向き生成だけ"
function bench_preds(mes::Vector{Bits}, opps::Vector{Bits})
    a = Acc(0, 0)
    @inbounds for i in eachindex(mes)
        foreach_predecessor(mes[i], opps[i]) do pm, po
            a.x += pm ⊻ (UInt64(po) << 25)
            a.n += 1
        end
    end
    return a
end

"後ろ向き生成 + 直前局面の rank_state（solve() の内側ループがする仕事から表の読み書きを除いたもの）"
function bench_preds_rank(mes::Vector{Bits}, opps::Vector{Bits})
    a = Acc(0, 0)
    @inbounds for i in eachindex(mes)
        foreach_predecessor(mes[i], opps[i]) do pm, po
            a.x += rank_state(pm, po)
            a.n += 1
        end
    end
    return a
end

"参考（対称で畳む案の下調べ）: 8 変換の最小番号＝正規形の番号を求める"
function bench_canonical(idx::Vector{Int32})
    acc = 0
    @inbounds for i in idx
        c = Int(i)
        for k in 2:length(SYMMETRIES)
            c = min(c, transform_index(i, SYMMETRIES[k]))
        end
        acc += c
    end
    return acc
end

function bench_lookup(t::SolveTable, ps::Vector{Position})
    acc = 0
    for p in ps
        v, d = lookup(t, p)
        acc += d + (v === :win)
    end
    return acc
end

function bench_value_index(t::SolveTable, ps::Vector{Position})
    acc = 0
    @inbounds for p in ps
        acc += t.value[state_index(p)]
    end
    return acc
end

function bench_best_moves(t::SolveTable, ps::Vector{Position})
    acc = 0
    for p in ps
        acc += length(best_moves(t, p))
    end
    return acc
end

"1 回あたり ns の要約（秒の要約を n で割る）"
function per_op(m::Dict, n::Integer)
    s = m["seconds"]
    return Dict{String,Any}("ns_median" => s["median"] / n * 1e9, "ns_min" => s["min"] / n * 1e9,
                            "ns_max" => s["max"] / n * 1e9, "ops" => n,
                            "seconds_median" => s["median"])
end

# ---------------------------------------------------------------------------
# 実行環境
# ---------------------------------------------------------------------------

readfile_or(path, default = "") = isfile(path) ? strip(read(path, String)) : default

"""
    proc_status_bytes(key) -> Int

/proc/self/status の `VmHWM`（最大常駐量）・`VmRSS`（現在の常駐量）をバイトで返す（Linux 以外は -1）。
`Sys.maxrss()` は getrusage の ru_maxrss で、Linux では exec をまたいで親の値を引き継ぐため、
子プロセスでは親の最大値が出てしまう。VmHWM は exec で新しいアドレス空間ごとに測り直される。
"""
function proc_status_bytes(key::AbstractString)
    isfile("/proc/self/status") || return -1
    for line in eachline("/proc/self/status")
        startswith(line, key * ":") || continue
        return parse(Int, split(line)[2]) * 1024
    end
    return -1
end

rss_snapshot() = Dict{String,Any}("maxrss" => Int(Sys.maxrss()), "vmhwm" => proc_status_bytes("VmHWM"),
                                  "vmrss" => proc_status_bytes("VmRSS"))

function environment_info()
    env = Dict{String,Any}()
    env["julia_version"] = string(VERSION)
    env["julia_threads"] = Threads.nthreads()
    env["arch"] = string(Sys.ARCH)
    env["kernel"] = string(Sys.KERNEL)
    env["uname"] = try readchomp(`uname -a`) catch; "" end
    env["cpu_threads_visible"] = Sys.CPU_THREADS
    ci = Sys.cpu_info()
    env["cpu_model_in_container"] = isempty(ci) ? "" : ci[1].model
    env["total_memory_bytes_in_container"] = Int(Sys.total_memory())
    env["cgroup_cpu_max"] = readfile_or("/sys/fs/cgroup/cpu.max", "(読めない)")
    env["cgroup_memory_max"] = readfile_or("/sys/fs/cgroup/memory.max", "(読めない)")
    env["nproc"] = try readchomp(`nproc`) catch; "" end
    # ホスト側の情報は bench/run_baseline.sh が環境変数で渡す（無ければ空）
    host = Dict{String,Any}()
    for (k, v) in ENV
        startswith(k, "BENCH_") || continue
        k in ("BENCH_DOCKER_STATS_BEFORE", "BENCH_DOCKER_STATS_LOG_IN_CONTAINER") && continue
        host[lowercase(k[7:end])] = v
    end
    env["host"] = host
    return env
end

"""
    docker_stats_summary() -> Dict

bench/run_baseline.sh が渡す計測直前の `docker stats` と、計測中に一定間隔で取った記録を読み、
自分以外のコンテナの CPU 使用率（%、100% = 1 コア）の最大を名前ごとにまとめる。
"""
function docker_stats_summary()
    selfname = get(ENV, "BENCH_CONTAINER_NAME", "")
    before = get(ENV, "BENCH_DOCKER_STATS_BEFORE", "")
    logp = get(ENV, "BENCH_DOCKER_STATS_LOG_IN_CONTAINER", "")
    during = (!isempty(logp) && isfile(logp)) ? read(logp, String) : ""
    out = Dict{String,Any}("before_raw" => before, "during_raw" => during, "container_name" => selfname)
    isempty(before) && isempty(during) && return out
    maxcpu = Dict{String,Float64}()
    per_sample_other = Float64[]
    cur = 0.0; rows = 0
    for line in Iterators.flatten((split(before, '\n'), ["--"], split(during, '\n'), ["--"]))
        f = split(line, '\t')
        if length(f) < 2
            # 時刻の行（または区切り）で 1 回分の記録が切り替わる
            rows > 0 && push!(per_sample_other, cur)
            cur = 0.0; rows = 0
            continue
        end
        rows += 1
        name = String(f[1])
        c = tryparse(Float64, replace(f[2], "%" => ""))
        c === nothing && continue
        if name == selfname
            maxcpu["(self) " * name] = max(get(maxcpu, "(self) " * name, 0.0), c)
        else
            maxcpu[name] = max(get(maxcpu, name, 0.0), c)
            cur += c
        end
    end
    out["max_cpu_percent_by_container"] = maxcpu
    out["others_total_cpu_percent_max"] = isempty(per_sample_other) ? 0.0 : maximum(per_sample_other)
    out["samples"] = length(per_sample_other)
    return out
end

# ---------------------------------------------------------------------------
# スレッド数の確認（子プロセス）
# ---------------------------------------------------------------------------

function probe(opt)
    rule = Symbol(opt["rule"])
    before = rss_snapshot()
    m = measure(() -> NT.solve(no_move_rule = rule), opt["reps"])
    t = NT.solve(no_move_rule = rule)
    out = Dict{String,Any}("nthreads" => Threads.nthreads(), "checksum" => table_checksum(t),
                           "solve" => m, "rss_before_solve" => before, "rss_after_solve" => rss_snapshot())
    TOML.print(stdout, out)
end

function run_thread_probes(opt)
    lst = opt["threads"]
    lst == "none" && return Dict{String,Any}()
    res = Dict{String,Any}()
    proj = dirname(Base.active_project())
    for tn in split(lst, ',')
        cmd = `$(Base.julia_cmd()) -t $(strip(tn)) --project=$proj $(@__FILE__) --probe --reps $(opt["reps"]) --rule $(opt["rule"])`
        @info "スレッド確認の子プロセス" cmd
        txt = read(cmd, String)
        res["t$(strip(tn))"] = TOML.parse(txt)
    end
    return res
end

# ---------------------------------------------------------------------------
# 本体
# ---------------------------------------------------------------------------

function main(args)
    opt = parse_args(args)
    if opt["probe"]
        probe(opt)
        return
    end
    rule = Symbol(opt["rule"])
    reps = opt["reps"]
    R = Dict{String,Any}()
    R["meta"] = Dict{String,Any}("reps" => reps, "fixpoint_reps" => opt["fixpoint-reps"],
                                 "rule" => string(rule), "nstates" => NSTATES,
                                 "started_utc" => string(Libc.strftime("%Y-%m-%dT%H:%M:%SZ", time())),
                                 "note" => "時間は秒。各項目は JIT 込みの 1 回を捨てた後の reps 回の中央値・最小・最大")
    R["environment"] = environment_info()
    rss = Dict{String,Any}("1_after_load" => rss_snapshot())

    # --- solve() 全体 ------------------------------------------------------
    @info "solve() 全体"
    R["solve"] = measure(() -> NT.solve(no_move_rule = rule), reps)
    ref = NT.solve(no_move_rule = rule)
    rss["2_after_solve"] = rss_snapshot()
    R["solve"]["checksum"] = table_checksum(ref)

    # --- 内訳 ---------------------------------------------------------------
    @info "solve() の内訳（段階版）"
    tb, _, _, _ = staged_solve(rule)   # JIT
    same_table(tb, ref) || error("段階版の表が solve() と一致しない")
    stages = Dict(k => Float64[] for k in ("classify", "seed", "propagate", "draw", "total"))
    nproc = 0; ndraw = 0
    for _ in 1:reps
        GC.gc()
        t, secs, nproc, ndraw = staged_solve(rule)
        same_table(t, ref) || error("段階版の表が solve() と一致しない")
        for k in keys(stages)
            push!(stages[k], getfield(secs, Symbol(k)))
        end
    end
    R["breakdown"] = Dict{String,Any}(k => summarize(v) for (k, v) in stages)
    R["breakdown"]["identical_to_solve"] = true
    R["breakdown"]["processed"] = nproc
    R["breakdown"]["draws_left"] = ndraw
    # 段階 1 の中をさらに割った参考値
    v0 = classify_only()
    R["breakdown_classify_detail"] = Dict{String,Any}(
        "unrank_and_state_kind" => measure(classify_only, reps),
        "count_moves_interior" => measure(() -> count_only(v0), reps),
    )

    # --- 伝播の統計 ---------------------------------------------------------
    @info "伝播の統計"
    solve_with_stats(rule)   # JIT
    ts, st, nproc_s, cnt0, cntend = solve_with_stats(rule)
    same_table(ts, ref) || error("計数版の表が solve() と一致しない")
    maxd = findlast(>(0), st.processed) - 1
    layers = Dict{String,Any}[]
    for d in 0:maxd
        L = d + 1
        push!(layers, Dict{String,Any}("dist" => d, "size" => st.processed[L],
            "win" => st.processed_win[L], "loss" => st.processed_loss[L],
            "preds" => st.preds[L], "preds_undecided" => st.preds_undecided[L],
            "set_win" => st.set_win[L], "decrements" => st.decrements[L], "set_loss" => st.set_loss[L],
            "seconds_instrumented" => st.seconds[L]))
    end
    R["propagation"] = Dict{String,Any}(
        "processed" => nproc_s,
        "preds_enumerated" => sum(st.preds),
        "preds_undecided" => sum(st.preds_undecided),
        "preds_skipped" => sum(st.preds) - sum(st.preds_undecided),
        "set_win" => sum(st.set_win),
        "decrements" => sum(st.decrements),
        "set_loss_by_counter" => sum(st.set_loss),
        "peak_live_queue" => st.peak_live,
        "max_dist" => maxd,
        "initial_counter_sum" => sum(Int, cnt0),
        "counter_sum_left" => sum(Int, cntend),
        "draws" => count(==(VAL_DRAW), ref.value),
        "wins" => count(==(VAL_WIN), ref.value),
        "losses" => count(==(VAL_LOSS), ref.value),
        "invalid" => count(==(VAL_INVALID), ref.value),
        "seconds_instrumented_total" => sum(st.seconds),
        "layers" => layers,
    )

    # --- メモリ -------------------------------------------------------------
    @info "メモリ"
    mem = Dict{String,Any}()
    mem["table_value_bytes"] = sizeof(ref.value)
    mem["table_dist_bytes"] = sizeof(ref.dist)
    mem["work_cnt_bytes"] = NSTATES * sizeof(UInt8)
    mem["work_queue_bytes"] = NSTATES * sizeof(Int32)
    mem["solve_allocated_bytes_median"] = R["solve"]["allocated_bytes"]["median"]
    mem["solve_gc_seconds_median"] = R["solve"]["gc_seconds"]["median"]
    mem["const_tables_bytes"] = Dict{String,Any}(
        "RAYS" => Base.summarysize(RAYS), "ME_BITS" => Base.summarysize(ME_BITS),
        "OPP_COMBOS22" => Base.summarysize(OPP_COMBOS22), "FREE_SQUARES" => Base.summarysize(FREE_SQUARES),
        "BINOM" => Base.summarysize(BINOM), "LINE_BY_RANK" => Base.summarysize(LINE_BY_RANK),
        "WIN_LINES" => Base.summarysize(WIN_LINES))
    R["memory"] = mem

    # --- 番号付け・手の生成 -------------------------------------------------
    @info "番号付け・手の生成"
    rng = MersenneTwister(20260924)
    mes = Vector{Bits}(undef, NSTATES); opps = Vector{Bits}(undef, NSTATES)
    for i in 1:NSTATES
        mes[i], opps[i] = unrank_state(i)
    end
    perm = Int32.(randperm(rng, NSTATES))
    mes_r = mes[perm]; opps_r = opps[perm]
    gen = Dict{String,Any}()
    gen["unrank_sequential"] = per_op(measure(bench_unrank_seq, reps), NSTATES)
    gen["unrank_random_order"] = per_op(measure(() -> bench_unrank_idx(perm), reps), NSTATES)
    gen["rank_sequential"] = per_op(measure(() -> bench_rank(mes, opps), reps), NSTATES)
    gen["rank_random_order"] = per_op(measure(() -> bench_rank(mes_r, opps_r), reps), NSTATES)

    interior = [i for i in 1:NSTATES if state_kind(mes[i], opps[i]) === :interior]
    nonvalid = [i for i in 1:NSTATES if ref.value[i] != VAL_INVALID]
    decided = [i for i in 1:NSTATES if ref.value[i] == VAL_WIN || ref.value[i] == VAL_LOSS]
    sets = (("interior", interior), ("valid", nonvalid), ("decided", decided))
    for (name, ix) in sets
        me_s = mes[ix]; op_s = opps[ix]; n = length(ix)
        for (label, f) in (("child", bench_children), ("child_rank", bench_children_rank),
                           ("pred", bench_preds), ("pred_rank", bench_preds_rank))
            # 前向きは内部局面だけ、後ろ向きは有効局面と確定局面（solve が実際に取り出す集合）
            startswith(label, "child") && name != "interior" && continue
            startswith(label, "pred") && name == "interior" && continue
            m = measure(() -> f(me_s, op_s), reps)
            a = SINK[]::Acc
            d = per_op(m, n)
            d["states"] = n
            d["generated"] = a.n
            d["branching_mean"] = a.n / n
            d["ns_per_generated_median"] = m["seconds"]["median"] / a.n * 1e9
            gen["$(label)_over_$(name)"] = d
        end
    end
    sample = perm[1:1_000_000]
    gen["canonical_8sym_random"] = per_op(measure(() -> bench_canonical(sample), reps), length(sample))
    R["generation"] = gen

    # --- 参照 ---------------------------------------------------------------
    @info "参照"
    nvalid = length(nonvalid)
    ps = [position_from_index(nonvalid[rand(rng, 1:nvalid)], rand(rng, Bool)) for _ in 1:1_000_000]
    look = Dict{String,Any}()
    look["lookup_random"] = per_op(measure(() -> bench_lookup(ref, ps), reps), length(ps))
    look["value_by_state_index_random"] = per_op(measure(() -> bench_value_index(ref, ps), reps), length(ps))
    ps_b = ps[1:100_000]
    look["best_moves_random"] = per_op(measure(() -> bench_best_moves(ref, ps_b), reps), length(ps_b))
    R["lookup"] = look
    mes = opps = mes_r = opps_r = ps = nothing
    GC.gc()

    # --- 不動点反復（比較用） -----------------------------------------------
    rss["3_before_fixpoint"] = rss_snapshot()
    @info "solve_fixpoint()（比較用）" reps = opt["fixpoint-reps"]
    fp = measure(() -> solve_fixpoint(no_move_rule = rule), opt["fixpoint-reps"])
    tf = SINK[]::SolveTable
    fp["identical_to_solve"] = same_table(tf, ref)
    fp["iterations_derived"] = maxd + 1   # 反復 j で距離 j の局面が確定し、最後の 1 回で何も変わらない
    R["fixpoint"] = fp
    rss["4_after_fixpoint"] = rss_snapshot()

    # --- スレッド数 ---------------------------------------------------------
    @info "スレッド数の確認"
    probes = run_thread_probes(opt)
    if !isempty(probes)
        cks = unique(p["checksum"] for p in values(probes))
        R["threads"] = Dict{String,Any}("probes" => probes, "all_identical" => length(cks) == 1 && cks[1] == R["solve"]["checksum"],
                                        "uses_threads_in_src" => false,
                                        "note" => "src/ に Threads.@threads / @spawn は無い。-t を変えても solve() は単一スレッドで走る")
    end

    rss["5_end"] = rss_snapshot()
    R["memory"]["rss_bytes"] = rss
    R["meta"]["finished_utc"] = string(Libc.strftime("%Y-%m-%dT%H:%M:%SZ", time()))

    # docker stats の記録（bench/run_baseline.sh が並行して書いている場合）
    R["environment"]["docker_stats"] = docker_stats_summary()

    out = opt["out"]
    mkpath(dirname(abspath(out)))
    stringify!(R)
    open(out, "w") do io
        TOML.print(io, R; sorted = true)
    end
    md = markdown_report(R)
    mdpath = replace(out, r"\.toml$" => "") * ".md"
    write(mdpath, md)
    println(md)
    @info "書き出し" out mdpath
end

"TOML.print が扱えない Symbol を文字列にそろえる"
function stringify!(x)
    x isa Dict || return x
    for (k, v) in x
        if v isa Dict
            stringify!(v)
        elseif v isa Vector && !isempty(v) && v[1] isa Dict
            foreach(stringify!, v)
        elseif v isa Symbol
            x[k] = string(v)
        end
    end
    return x
end

# ---------------------------------------------------------------------------
# Markdown
# ---------------------------------------------------------------------------

fmt_s(x) = x >= 1 ? @sprintf("%.3f s", x) : x >= 1e-3 ? @sprintf("%.2f ms", x * 1e3) : @sprintf("%.1f µs", x * 1e6)
fmt_mib(b) = @sprintf("%.2f MiB", b / 2^20)
fmt_int(n) = replace(string(n), r"(?<=\d)(?=(\d{3})+$)" => ",")
row_s(name, s::Dict) = "| $name | $(fmt_s(s["median"])) | $(fmt_s(s["min"])) | $(fmt_s(s["max"])) |"

function markdown_report(R)
    io = IOBuffer()
    e = R["environment"]; h = e["host"]
    println(io, "## 基準計測の結果（", R["meta"]["started_utc"], "）\n")
    println(io, "反復 ", R["meta"]["reps"], " 回（JIT 込みの 1 回を除く）。合法手 0 の扱い `", R["meta"]["rule"], "`。\n")
    println(io, "### 実行環境\n")
    println(io, "| 項目 | 値 |\n|---|---|")
    println(io, "| コミット | `", get(h, "commit", "(不明)"), "` |")
    println(io, "| ホスト CPU | ", get(h, "host_cpu", "(不明)"), "（論理 ", get(h, "host_ncpu", "?"), "） |")
    println(io, "| ホストのメモリ | ", haskey(h, "host_mem_bytes") ? fmt_mib(parse(Int, h["host_mem_bytes"])) : "(不明)", " |")
    println(io, "| コンテナ実行環境 | ", get(h, "docker_runtime", "(不明)"), " / VM の CPU ", get(h, "docker_ncpu", "?"),
            " / VM のメモリ ", haskey(h, "docker_mem_bytes") ? fmt_mib(parse(Int, h["docker_mem_bytes"])) : "?", " |")
    println(io, "| docker run の CPU 指定 | ", get(h, "docker_cpus_flag", "(指定なし)"), " / cgroup cpu.max = `", e["cgroup_cpu_max"], "` |")
    println(io, "| コンテナから見える CPU | ", e["cpu_threads_visible"], " (", e["arch"], ", ", e["cpu_model_in_container"], ") |")
    println(io, "| Julia | ", e["julia_version"], "（スレッド ", e["julia_threads"], "） |")
    ds = e["docker_stats"]
    if haskey(ds, "max_cpu_percent_by_container")
        lst = join(["$(k) $(@sprintf("%.2f", v))%" for (k, v) in sort(collect(ds["max_cpu_percent_by_container"]), by = first)], "、")
        println(io, "| 他のコンテナの CPU（計測直前と計測中 ", ds["samples"], " 回の記録、名前ごとの最大） | ", lst, " |")
        println(io, "| 自分以外の合計 CPU の最大（1 回の記録内の和、100% = 1 コア） | ", @sprintf("%.2f", ds["others_total_cpu_percent_max"]), "% |")
        ds["others_total_cpu_percent_max"] > 5 &&
            println(io, "| **注意** | 計測中に他のコンテナが CPU を使っていた。比較には使わず、落ち着いてから測り直すこと |")
    else
        println(io, "| 他のコンテナの CPU | (未記録。bench/run_baseline.sh 経由で実行すると記録する) |")
    end
    println(io, "| 対象の src/ | tree `", get(h, "src_tree", "(不明)"), "`（未コミットの変更 ", get(h, "src_dirty_files", "?"), " 件） |")
    println(io, "| ホスト OS / コア種別 | ", get(h, "host_os", "(不明)"), " / ", get(h, "host_core_types", ""), " |")
    println(io)

    println(io, "### 時間\n")
    println(io, "| 項目 | 中央値 | 最小 | 最大 |\n|---|---:|---:|---:|")
    println(io, row_s("`solve()` 全体", R["solve"]["seconds"]))
    b = R["breakdown"]
    println(io, row_s("段階版の合計", b["total"]))
    println(io, row_s("　1. 分類＋カウンタ初期化（`initial_labels`）", b["classify"]))
    d = R["breakdown_classify_detail"]
    println(io, row_s("　　参考: unrank＋`state_kind` だけ", d["unrank_and_state_kind"]["seconds"]))
    println(io, row_s("　　参考: 内部局面の `count_moves` だけ", d["count_moves_interior"]["seconds"]))
    println(io, row_s("　2. キューの初期化（終局を積む）", b["seed"]))
    println(io, row_s("　3. キュー伝播", b["propagate"]))
    println(io, row_s("　4. 引分け確定（明示の処理なし。未確定の集計のみ）", b["draw"]))
    println(io, row_s("`solve_fixpoint()`（比較用）", R["fixpoint"]["seconds"]))
    tot = b["total"]["median"]
    println(io, "\n内訳の割合（中央値）: 分類 ", @sprintf("%.1f", 100b["classify"]["median"] / tot), "% / 初期化 ",
            @sprintf("%.1f", 100b["seed"]["median"] / tot), "% / 伝播 ", @sprintf("%.1f", 100b["propagate"]["median"] / tot),
            "% / 引分け ", @sprintf("%.1f", 100b["draw"]["median"] / tot), "%。段階版の表は `solve()` の表と全局面一致。",
            " `solve_fixpoint()` は `solve()` の ", @sprintf("%.1f", R["fixpoint"]["seconds"]["median"] / R["solve"]["seconds"]["median"]),
            " 倍（反復 ", R["fixpoint"]["iterations_derived"], " 回、表は一致: ", R["fixpoint"]["identical_to_solve"], "）。\n")

    p = R["propagation"]
    println(io, "### 伝播の統計\n")
    println(io, "| 項目 | 値 |\n|---|---:|")
    for (k, lab) in (("processed", "キューから取り出した局面（勝ち＋負け）"), ("preds_enumerated", "列挙した直前局面（= rank_state 呼び出し）"),
                     ("preds_undecided", "　うち未確定だった直前局面"), ("preds_skipped", "　うち確定済み・無効で飛ばした"),
                     ("set_win", "勝ちに確定（負けの子から）"), ("decrements", "カウンタ減算の回数"),
                     ("set_loss_by_counter", "カウンタ 0 で負けに確定"), ("initial_counter_sum", "カウンタ初期値の総和（内部局面の合法手の総数）"),
                     ("counter_sum_left", "伝播後に残ったカウンタの総和"), ("peak_live_queue", "キューの未処理分の最大"),
                     ("max_dist", "最大距離"), ("wins", "勝ち"), ("losses", "負け"), ("draws", "引分け"), ("invalid", "無効"))
        println(io, "| ", lab, " | ", fmt_int(p[k]), " |")
    end
    println(io, "\n1 局面あたりの直前局面 ", @sprintf("%.2f", p["preds_enumerated"] / p["processed"]),
            "、そのうち未確定 ", @sprintf("%.1f", 100p["preds_undecided"] / p["preds_enumerated"]), "%。\n")
    println(io, "距離ごとの層（取り出した局面の数。時間は計数を足した版での参考値）\n")
    println(io, "| 距離 | 層の大きさ | 勝ち | 負け | 直前局面 | 未確定 | 勝ち確定 | 減算 | 負け確定 | 時間（参考） |")
    println(io, "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for L in p["layers"]
        println(io, "| ", L["dist"], " | ", fmt_int(L["size"]), " | ", fmt_int(L["win"]), " | ", fmt_int(L["loss"]), " | ",
                fmt_int(L["preds"]), " | ", fmt_int(L["preds_undecided"]), " | ", fmt_int(L["set_win"]), " | ",
                fmt_int(L["decrements"]), " | ", fmt_int(L["set_loss"]), " | ", fmt_s(L["seconds_instrumented"]), " |")
    end
    println(io)

    m = R["memory"]
    println(io, "### メモリ\n")
    println(io, "| 項目 | 値 |\n|---|---:|")
    println(io, "| 表 `value`（Int8 × 局面数） | ", fmt_mib(m["table_value_bytes"]), " |")
    println(io, "| 表 `dist`（UInt8 × 局面数） | ", fmt_mib(m["table_dist_bytes"]), " |")
    println(io, "| 作業 `cnt`（UInt8 × 局面数） | ", fmt_mib(m["work_cnt_bytes"]), " |")
    println(io, "| 作業 キュー（Int32 × 局面数） | ", fmt_mib(m["work_queue_bytes"]), " |")
    println(io, "| 表＋作業の合計 | ", fmt_mib(m["table_value_bytes"] + m["table_dist_bytes"] + m["work_cnt_bytes"] + m["work_queue_bytes"]), " |")
    println(io, "| `solve()` の `@allocated`（中央値） | ", fmt_mib(m["solve_allocated_bytes_median"]), " |")
    println(io, "| `solve()` の GC 時間（中央値） | ", fmt_s(m["solve_gc_seconds_median"]), " |")
    ct = sum(values(m["const_tables_bytes"]))
    println(io, "| 定数表（RAYS・ME_BITS・FREE_SQUARES など）の合計 | ", @sprintf("%.1f KiB", ct / 1024), " |")
    println(io, "| `solve_fixpoint()` の `@allocated`（中央値） | ", fmt_mib(R["fixpoint"]["allocated_bytes"]["median"]), " |")
    println(io, "| `solve_fixpoint()` の GC 時間（中央値） | ", fmt_s(R["fixpoint"]["gc_seconds"]["median"]), " |")
    println(io)
    println(io, "常駐量（主プロセス。`Sys.maxrss()` と /proc/self/status の VmHWM・VmRSS）\n")
    println(io, "| 時点 | `Sys.maxrss()` | VmHWM | VmRSS |\n|---|---:|---:|---:|")
    labs = Dict("1_after_load" => "読み込み直後", "2_after_solve" => "solve() 計測後", "3_before_fixpoint" => "番号付け等の計測後",
                "4_after_fixpoint" => "solve_fixpoint() 計測後", "5_end" => "終了時")
    for k in sort(collect(keys(m["rss_bytes"])))
        v = m["rss_bytes"][k]
        println(io, "| ", get(labs, k, k), " | ", fmt_mib(v["maxrss"]), " | ", fmt_mib(v["vmhwm"]), " | ", fmt_mib(v["vmrss"]), " |")
    end
    if haskey(R, "threads")
        println(io, "\nsolve() だけを走らせる子プロセス（`Sys.maxrss()` は exec で親の値を引き継ぐので VmHWM を見る）\n")
        println(io, "| `-t` | solve() 前の VmRSS | solve() 後の VmHWM | 差 |\n|---:|---:|---:|---:|")
        for (k, v) in sort(collect(R["threads"]["probes"]), by = x -> x[2]["nthreads"])
            a = v["rss_before_solve"]["vmrss"]; b = v["rss_after_solve"]["vmhwm"]
            println(io, "| ", v["nthreads"], " | ", fmt_mib(a), " | ", fmt_mib(b), " | ", fmt_mib(b - a), " |")
        end
    end
    println(io)

    g = R["generation"]
    println(io, "### 番号付け・手の生成\n")
    println(io, "| 項目 | 中央値 | 最小 | 最大 | 対象 | 平均分岐数 |\n|---|---:|---:|---:|---:|---:|")
    labels = [("unrank_sequential", "unrank（番号順）"), ("unrank_random_order", "unrank（無作為順）"),
              ("rank_sequential", "rank（番号順）"), ("rank_random_order", "rank（無作為順）"),
              ("child_over_interior", "foreach_child（内部局面、生成のみ）"),
              ("child_rank_over_interior", "foreach_child＋rank（内部局面）"),
              ("pred_over_valid", "foreach_predecessor（有効局面、生成のみ）"),
              ("pred_rank_over_valid", "foreach_predecessor＋rank（有効局面）"),
              ("pred_over_decided", "foreach_predecessor（勝ち負け確定局面、生成のみ）"),
              ("pred_rank_over_decided", "foreach_predecessor＋rank（勝ち負け確定局面）"),
              ("canonical_8sym_random", "参考: 8 対称の正規形番号（無作為 100 万）")]
    for (k, lab) in labels
        x = g[k]
        br = haskey(x, "branching_mean") ? @sprintf("%.3f", x["branching_mean"]) : "—"
        println(io, "| ", lab, " | ", @sprintf("%.2f", x["ns_median"]), " ns | ", @sprintf("%.2f", x["ns_min"]), " ns | ",
                @sprintf("%.2f", x["ns_max"]), " ns | ", fmt_int(x["ops"]), " | ", br, " |")
    end
    println(io, "\n手の生成の ns は 1 局面あたり（その局面の子・直前局面をすべて列挙する時間）。\n")

    l = R["lookup"]
    println(io, "### 参照\n")
    println(io, "| 項目 | 中央値 | 最小 | 最大 | 回数 |\n|---|---:|---:|---:|---:|")
    for (k, lab) in (("lookup_random", "`lookup(t, p)`（無作為な有効局面）"),
                     ("value_by_state_index_random", "`t.value[state_index(p)]`"),
                     ("best_moves_random", "`best_moves(t, p)`"))
        x = l[k]
        println(io, "| ", lab, " | ", @sprintf("%.2f", x["ns_median"]), " ns | ", @sprintf("%.2f", x["ns_min"]), " ns | ",
                @sprintf("%.2f", x["ns_max"]), " ns | ", fmt_int(x["ops"]), " |")
    end
    println(io)

    if haskey(R, "threads")
        th = R["threads"]
        println(io, "### スレッド数\n")
        println(io, "| `-t` | `Threads.nthreads()` | `solve()` 中央値 | 最小 | 最大 | 表の CRC32c |\n|---:|---:|---:|---:|---:|---|")
        for (k, v) in sort(collect(th["probes"]), by = x -> x[2]["nthreads"])
            s = v["solve"]["seconds"]
            println(io, "| ", k[2:end], " | ", v["nthreads"], " | ", fmt_s(s["median"]), " | ", fmt_s(s["min"]), " | ",
                    fmt_s(s["max"]), " | `", v["checksum"], "` |")
        end
        println(io, "\n全スレッド数で表が一致し、主プロセスの表（`", R["solve"]["checksum"], "`）とも一致: ", th["all_identical"], "。\n")
    end
    return String(take!(io))
end

main(ARGS)
