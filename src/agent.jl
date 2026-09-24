# 対戦エージェントと対局進行
#
# エージェントは「局面と履歴を受け取って手を 1 つ返す」ものとして抽象化する。
# 目標（自分の色で 3 つ並べる）は対局進行 `play_game` が勝敗として与え、各エージェントは
# それぞれの知識（強解決の表・探索・無作為）に基づいて自律的に手を選ぶ。

"""
    AbstractAgent

対戦エージェントの抽象型。具象型は `choose_move(agent, pos, history) -> Move` を実装する。
"""
abstract type AbstractAgent end

"""
    choose_move(agent, pos::Position, history::Vector{Position}) -> Move

局面 `pos`（手番側が `agent`）で指す手を返す。`history` は対局開始から `pos` までの
局面の列（`pos` 自身を末尾に含む）。終局済み・合法手 0 の局面では呼ばれない。
"""
function choose_move end

# ---------------------------------------------------------------------------
# 終局判定
# ---------------------------------------------------------------------------

"""
    _outcome(p, reps) -> Union{Nothing,Tuple{Symbol,Symbol}}

局面 `p` がその対局で `reps` 回目に現れたときの終局判定。続行なら `nothing`、
終局なら `(勝者, 理由)`。判定の順は 並び → 3 回反復 → 合法手 0。
"""
function _outcome(p::Position, reps::Integer)
    w = winner(p)
    w === :both && throw(ArgumentError("両者が並んでいる局面: $(format_position(p))"))
    w === nothing || return (w, :line)
    reps >= 3 && return (:draw, :repetition)
    # 合法手 0 の局面（全数で 0 件だが規定として）は、表の既定 no_move_rule = :draw に合わせて引分け
    count_moves(mover_bits(p)...) == 0 && return (:draw, :no_moves)
    return nothing
end

"""
    game_outcome(history::Vector{Position}) -> Union{Nothing,Tuple{Symbol,Symbol}}

対局の局面列 `history` の末尾の局面で対局が終わっているかを判定する。

- 直前の手で並んだ: `(:black | :white, :line)`
- 末尾の局面（手番込み）が履歴に 3 回現れた: `(:draw, :repetition)`
- 手番側に合法手が無い: `(:draw, :no_moves)`
- 続行: `nothing`
"""
function game_outcome(history::AbstractVector{Position})
    p = history[end]
    return _outcome(p, count(==(p), history))
end

"""
    GameResult

`play_game` の結果。

- `winner` — `:black` / `:white` / `:draw`
- `reason` — `:line`（3 つ並んだ）/ `:repetition`（同一局面 3 回）/ `:max_plies`（手数上限）/
             `:no_moves`（合法手 0）。CLI の中断では `:quit`
- `plies`  — 指した手数
- `moves`  — 棋譜（`record = false` なら空）
- `start` / `final` — 開始局面と最終局面
"""
struct GameResult
    winner::Symbol
    reason::Symbol
    plies::Int
    moves::Vector{Move}
    start::Position
    final::Position
end

"""
    play_game(black, white; start = initial_position(), max_plies = 1000, record = true) -> GameResult

黒 `black` と白 `white` のエージェントを対局させる。各手番で `choose_move` を呼び、
返った手が非合法なら `ArgumentError`。同一局面（配置と手番）が 3 回現れたら引分け、
`max_plies` 手に達したら引分け（理由 `:max_plies`）とする。
"""
function play_game(black::AbstractAgent, white::AbstractAgent;
                   start::Position = initial_position(), max_plies::Integer = 1000, record::Bool = true)
    history = Position[start]
    counts = Dict{Position,Int}(start => 1)
    moves = Move[]
    p = start
    plies = 0
    while true
        o = _outcome(p, counts[p])
        o === nothing || return GameResult(o[1], o[2], plies, moves, start, p)
        plies >= max_plies && return GameResult(:draw, :max_plies, plies, moves, start, p)
        m = choose_move(p.black_to_move ? black : white, p, history)
        p = apply_move(p, m)   # 非合法手なら ArgumentError
        plies += 1
        record && push!(moves, m)
        push!(history, p)
        counts[p] = get(counts, p, 0) + 1
    end
end

# ---------------------------------------------------------------------------
# 無作為・完全なエージェント
# ---------------------------------------------------------------------------

"""
    RandomAgent(rng = nothing)

合法手から一様に選ぶエージェント。`rng` を省くと大域の乱数を使う。
"""
struct RandomAgent{R} <: AbstractAgent
    rng::R
end
RandomAgent() = RandomAgent(nothing)

function choose_move(a::RandomAgent, p::Position, history)
    ms = legal_moves(p)
    isempty(ms) && throw(ArgumentError("合法手が無い: $(format_position(p))"))
    return a.rng === nothing ? rand(ms) : rand(a.rng, ms)
end

"""
    PerfectAgent(table; rng = nothing)

強解決の表を引いて最善手を指すエージェント（`best_moves` と同じ基準）。

- 勝ちの局面: 最短で勝つ手
- 負けの局面: 最も長く粘る手
- 引分けの局面: 引分けを保つ手

同点手が複数あれば、`rng` を与えたときはその乱数で選び、省いたときは先頭を選ぶ（決定的）。
"""
struct PerfectAgent{R} <: AbstractAgent
    table::SolveTable
    rng::R
end
PerfectAgent(table::SolveTable; rng = nothing) = PerfectAgent(table, rng)

function choose_move(a::PerfectAgent, p::Position, history)
    bm = best_moves(a.table, p)
    isempty(bm) && throw(ArgumentError("最善手が無い（終局済みか無効）: $(format_position(p))"))
    return a.rng === nothing ? bm[1] : rand(a.rng, bm)
end

# ---------------------------------------------------------------------------
# 深さ制限αβ探索のエージェント（表を使わない）
# ---------------------------------------------------------------------------

"詰みの得点。ply 手目に決着するなら ±(AB_MATE − ply)（早い勝ち・遅い負けを好む）"
const AB_MATE = 1_000_000
const AB_INF = 2 * AB_MATE

"盤の中央 3×3（b2〜d4）"
const CENTER_MASK = let m = Bits(0)
    for r in 1:3, c in 1:3
        m |= bit(make_sq(r, c))
    end
    m
end

"""
    _fill_children!(buf, me, opp) -> Bool

手番側視点 (me, opp) の各合法手を指した後の手番側の駒 `me′` を `buf` に `(0, me′)` として積み、
その中に並ぶ手があれば `true` を返す（`foreach_move` と同じ滑り。クロージャの箱詰めを避けて展開）。
"""
@inline function _fill_children!(buf::Vector{Tuple{Int,Bits}}, me::Bits, opp::Bits)
    empty!(buf)
    won = false
    occ = me | opp
    m = me
    @inbounds while m != 0
        s = trailing_zeros(m)
        m &= m - Bits(1)
        rays = RAYS[s+1]
        for d in 1:8
            to = -1
            for x in rays[d]
                (occ >> x) & 1 == 1 && break
                to = x
            end
            to < 0 && continue
            nm = me ⊻ bit(s) ⊻ bit(to)
            won |= is_win_line(nm)
            push!(buf, (0, nm))
        end
    end
    return won
end

"`me` の手番で 1 手で並べる手の数（`me` を動かして並ぶ手）"
function count_winning_moves(me::Bits, opp::Bits)
    n = 0
    occ = me | opp
    m = me
    @inbounds while m != 0
        s = trailing_zeros(m)
        m &= m - Bits(1)
        rays = RAYS[s+1]
        for d in 1:8
            to = -1
            for x in rays[d]
                (occ >> x) & 1 == 1 && break
                to = x
            end
            to >= 0 && is_win_line(me ⊻ bit(s) ⊻ bit(to)) && (n += 1)
        end
    end
    return n
end

"`me` の 2 駒が乗り、残り 1 マスが空いている勝ち筋の数（並びかけ）"
function count_open_pairs(me::Bits, opp::Bits)
    n = 0
    @inbounds for l in WIN_LINES
        (count_ones(me & l) == 2 && (opp & l) == 0) && (n += 1)
    end
    return n
end

"""
    default_eval(me, opp) -> Int

αβ探索の末端で使う簡単な評価関数（手番側 `me` から見た得点）。末端では手番側に 1 手勝ちが
無いことを確かめてから呼ぶので、次の 3 項だけを見る:

- 並びかけ（2 駒が乗り残りが空いている勝ち筋）の差 × 10
- 相手の 1 手勝ちの数 × −40（手番側が防がないと負ける手の数）
- 中央 3×3 の駒数の差 × 2
"""
function default_eval(me::Bits, opp::Bits)
    return 10 * (count_open_pairs(me, opp) - count_open_pairs(opp, me)) -
           40 * count_winning_moves(opp, me) +
           2 * (count_ones(me & CENTER_MASK) - count_ones(opp & CENTER_MASK))
end

"""
    AlphaBetaAgent(depth = 4; eval = default_eval, rng = nothing)

強解決の表を使わず、深さ `depth` 手（ply）のαβ探索（negamax）と評価関数で手を選ぶエージェント。

- `eval(me::Bits, opp::Bits) -> Int` は手番側から見た末端の得点。`Bits` は 25 ビットのビットボード。
- 並んだら ±(AB_MATE − 手数) で、速い勝ちと遅い負けを好む。
- 末端（残り深さ 0）では、手番側に 1 手勝ちがあれば評価関数の代わりに勝ちの得点を返す
  （勝ちだけを 1 手延長する静止探索）。したがって深さ 1 でも相手の 1 手勝ちは見える。
- 残り深さ 2 以上の節点では、子を評価関数の値で並べ替えてから探索する（枝刈りを効かせるため）。
- 根で同点の手が複数あれば `rng` で選び、省けば合法手の順で先頭を選ぶ。
- 同一局面 3 回の規定は探索に入れていない（履歴は見ない）。

`nodes` は直前の `choose_move` で訪れた節点数、`total_nodes` はその累計。
"""
mutable struct AlphaBetaAgent{F,R} <: AbstractAgent
    depth::Int
    eval::F
    rng::R
    nodes::Int
    total_nodes::Int
    buffers::Vector{Vector{Tuple{Int,Bits}}}   # 手数ごとの子の一時置き場（割り当てを避ける）
end

function AlphaBetaAgent(depth::Integer = 4; eval = default_eval, rng = nothing)
    depth >= 1 || throw(ArgumentError("探索の深さは 1 以上: $depth"))
    return AlphaBetaAgent(Int(depth), eval, rng, 0, 0, [Tuple{Int,Bits}[] for _ in 1:depth+1])
end

Base.show(io::IO, a::AlphaBetaAgent) = print(io, "AlphaBetaAgent(", a.depth, ")")
Base.show(io::IO, ::PerfectAgent) = print(io, "PerfectAgent")
Base.show(io::IO, ::RandomAgent) = print(io, "RandomAgent")

"""
    _negamax(a, me, opp, depth, ply, alpha, beta) -> Int

手番側視点 (me, opp) の局面を残り深さ `depth` で探索した得点（fail-hard）。
`ply` は根からの手数（詰みの得点を決める）。
"""
function _negamax(a::AlphaBetaAgent, me::Bits, opp::Bits, depth::Int, ply::Int, alpha::Int, beta::Int)
    a.nodes += 1
    # 直前に相手が並べていれば手番側の負け
    is_win_line(opp) && return -(AB_MATE - ply)
    buf = a.buffers[ply]   # 子はそれぞれ ply + 1 以降の置き場を使うので、ここは探索中に上書きされない
    _fill_children!(buf, me, opp) && return AB_MATE - (ply + 1)   # 1 手勝ち（最短なのでこれ以上探さない）
    isempty(buf) && return 0                    # 合法手 0 は引分け
    depth == 0 && return clamp(a.eval(me, opp), -AB_MATE + 1000, AB_MATE - 1000)
    if depth >= 2
        # 子の評価（子の手番側＝相手から見た値）が低い順＝自分に良い順
        @inbounds for k in eachindex(buf)
            nm = buf[k][2]
            buf[k] = (a.eval(opp, nm), nm)
        end
        sort!(buf; by = first)
    end
    for (_, nm) in buf
        v = -_negamax(a, opp, nm, depth - 1, ply + 1, -beta, -alpha)
        v >= beta && return beta
        v > alpha && (alpha = v)
    end
    return alpha
end

function choose_move(a::AlphaBetaAgent, p::Position, history)
    is_terminal(p) && throw(ArgumentError("終局済みの局面: $(format_position(p))"))
    ms = legal_moves(p)
    isempty(ms) && throw(ArgumentError("合法手が無い: $(format_position(p))"))
    me, opp = mover_bits(p)
    a.nodes = 0
    best = -AB_INF
    cands = Move[]
    for m in ms
        nm = me ⊻ bit(m.from) ⊻ bit(m.to)
        # 同点の手も正確な値が出るよう、下限を best − 1 にして探す
        v = is_win_line(nm) ? AB_MATE - 1 : -_negamax(a, opp, nm, a.depth - 1, 1, -AB_INF, -(best - 1))
        if v > best
            best = v
            empty!(cands)
            push!(cands, m)
        elseif v == best
            push!(cands, m)
        end
    end
    a.total_nodes += a.nodes
    return a.rng === nothing ? cands[1] : rand(a.rng, cands)
end
