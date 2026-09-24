# NeutreekoOracle — 後退解析とは独立な前向き探索（ミニマックス / αβ）による検証器。
#
# 後退解析ソルバー（src/ 以下）とはコードを一切共有しない。書き方も意図的に変えてある:
#   - 盤は 25 要素の配列（Vector{Int8}）。ビットボードは使わない
#   - 並び判定は 3 駒の (行, 列) 座標を整列し、隣り合う差が等しく単位方向であるかで直接判定する
#   - 探索は深さ制限付き αβ（反復深化・深さを考慮した置換表つき）
#
# 値の定義（後退解析の距離 ply と同じ）:
#   - 相手が既に並んでいる局面          → (:loss, 0)
#   - 手番側が 1 手で並べられる局面      → (:win, 1)
#   - 手番側が最短 d 手で勝てる          → (:win, d)   （d は奇数）
#   - 手番側がどう指しても d 手で負ける  → (:loss, d)  （最長抵抗。d は偶数）
#   - maxdepth 手以内に決着しない        → (:unknown, maxdepth)
#
# 同一局面 3 回の引き分けは探索では扱わない。勝者の最短手順では勝ちまでの距離が一手ごとに
# 厳密に減るため同じ局面は現れず、敗者も勝者の最短手順を外して繰り返しに持ち込めない。
# よって有限手数の勝ち負けと距離は繰り返し規則の有無で変わらない（README 参照）。

module NeutreekoOracle

export oracle, oracle_naive, parse_pos, format_pos

const EMPTY = Int8(0)
const BLACK = Int8(1)
const WHITE = Int8(2)

opponent(side::Int8) = side == BLACK ? WHITE : BLACK

# ---------------------------------------------------------------------------
# 座標とマス番号: sq = (row-1)*5 + (col-1)、row・col は 1..5、列 a..e
# ---------------------------------------------------------------------------

sq_row(sq::Integer) = sq ÷ 5 + 1
sq_col(sq::Integer) = sq % 5 + 1
rc_to_sq(r::Integer, c::Integer) = (r - 1) * 5 + (c - 1)
on_board(r::Integer, c::Integer) = 1 <= r <= 5 && 1 <= c <= 5

function sqname_to_sq(name::AbstractString)
    length(name) == 2 || throw(ArgumentError("マス名が不正: $name"))
    c = Int(name[1]) - Int('a') + 1
    r = Int(name[2]) - Int('0')
    on_board(r, c) || throw(ArgumentError("マス名が不正: $name"))
    return rc_to_sq(r, c)
end

sq_to_sqname(sq::Integer) = string(Char(Int('a') + sq_col(sq) - 1), sq_row(sq))

# ---------------------------------------------------------------------------
# 局面と文字列表記 "<手番>:<25文字>"
# ---------------------------------------------------------------------------

struct Pos
    board::Vector{Int8}   # 添字 sq+1。EMPTY / BLACK / WHITE
    side::Int8            # 手番
end

function parse_pos(s::AbstractString)
    cs = collect(s)
    length(cs) == 27 || throw(ArgumentError("局面文字列の長さが 27 でない: \"$s\""))
    cs[2] == ':' || throw(ArgumentError("2 文字目が ':' でない: \"$s\""))
    side = cs[1] == 'B' ? BLACK : cs[1] == 'W' ? WHITE :
           throw(ArgumentError("手番が B/W でない: \"$s\""))
    board = Vector{Int8}(undef, 25)
    for i in 1:25
        ch = cs[i+2]
        board[i] = ch == '.' ? EMPTY : ch == 'B' ? BLACK : ch == 'W' ? WHITE :
                   throw(ArgumentError("盤の文字が不正 '$ch': \"$s\""))
    end
    nb = count(==(BLACK), board)
    nw = count(==(WHITE), board)
    (nb == 3 && nw == 3) || throw(ArgumentError("駒数が 3 対 3 でない (黒 $nb, 白 $nw): \"$s\""))
    return Pos(board, side)
end

function format_pos(p::Pos)
    io = IOBuffer()
    print(io, p.side == BLACK ? 'B' : 'W', ':')
    for v in p.board
        print(io, v == EMPTY ? '.' : v == BLACK ? 'B' : 'W')
    end
    return String(take!(io))
end

const INITIAL_POS_STR = let
    cells = fill('.', 25)
    for n in ("b1", "d1", "c4")
        cells[sqname_to_sq(n)+1] = 'B'
    end
    for n in ("b5", "d5", "c2")
        cells[sqname_to_sq(n)+1] = 'W'
    end
    string("B:", String(cells))
end

# ---------------------------------------------------------------------------
# 並び判定: 3 駒の座標を (行, 列) の辞書順に整列し、
#   p2 - p1 == p3 - p2 かつ その差が (0,1) (1,0) (1,1) (1,-1) のいずれか
# なら一直線に連続している。
# ---------------------------------------------------------------------------

function is_lined(board::AbstractVector{Int8}, side::Int8)
    r1 = c1 = r2 = c2 = r3 = c3 = 0
    n = 0
    for i in 1:25
        if board[i] == side
            n += 1
            r, c = sq_row(i - 1), sq_col(i - 1)
            if n == 1
                r1, c1 = r, c
            elseif n == 2
                r2, c2 = r, c
            else
                r3, c3 = r, c
            end
        end
    end
    n == 3 || return false
    # sq の昇順に走査しているので (行, 列) の辞書順に既に整列している
    dr1, dc1 = r2 - r1, c2 - c1
    dr2, dc2 = r3 - r2, c3 - c2
    (dr1 == dr2 && dc1 == dc2) || return false
    return (dr1, dc1) in ((0, 1), (1, 0), (1, 1), (1, -1))
end

# ---------------------------------------------------------------------------
# 合法手: 自駒 1 つを 8 方向のどれかへ、盤の端か他の駒の直前まで滑らせる
# ---------------------------------------------------------------------------

const DIRS = ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1))

# 手は (from_sq, to_sq)（どちらも 0 起点のマス番号）
function gen_moves!(out::Vector{Tuple{Int,Int}}, board::AbstractVector{Int8}, side::Int8)
    empty!(out)
    for i in 1:25
        board[i] == side || continue
        r, c = sq_row(i - 1), sq_col(i - 1)
        for (dr, dc) in DIRS
            nr, nc = r + dr, c + dc
            lr, lc = 0, 0   # 最後に通過できた空きマス
            while on_board(nr, nc) && board[rc_to_sq(nr, nc)+1] == EMPTY
                lr, lc = nr, nc
                nr += dr
                nc += dc
            end
            lr == 0 && continue   # 1 マスも進めない方向は不可
            push!(out, (i - 1, rc_to_sq(lr, lc)))
        end
    end
    return out
end

legal_moves(p::Pos) = gen_moves!(Tuple{Int,Int}[], p.board, p.side)

function apply_move(p::Pos, m::Tuple{Int,Int})
    b = copy(p.board)
    b[m[2]+1] = b[m[1]+1]
    b[m[1]+1] = EMPTY
    return Pos(b, opponent(p.side))
end

# 盤上で直接指す／戻す（探索用）
@inline function do_move!(board, m)
    board[m[2]+1] = board[m[1]+1]
    board[m[1]+1] = EMPTY
end
@inline function undo_move!(board, m)
    board[m[1]+1] = board[m[2]+1]
    board[m[2]+1] = EMPTY
end

# ---------------------------------------------------------------------------
# 盤の 8 対称: k = 0..7。k >= 4 なら先に転置し、その後 90° 回転を k%4 回
# ---------------------------------------------------------------------------

function transform_rc(r::Int, c::Int, k::Int)
    if k >= 4
        r, c = c, r
    end
    for _ in 1:(k%4)
        r, c = c, 6 - r
    end
    return r, c
end

function transform_pos(p::Pos, k::Int)
    b = fill(EMPTY, 25)
    for i in 1:25
        r, c = transform_rc(sq_row(i - 1), sq_col(i - 1), k)
        b[rc_to_sq(r, c)+1] = p.board[i]
    end
    return Pos(b, p.side)
end

# ---------------------------------------------------------------------------
# 合法手 0 の局面の総数（3 対 3 の全配置 × 手番 2 通り）。(合法手 0 の数, 調べた局面数) を返す
# ---------------------------------------------------------------------------

function count_nomove_placements()
    board = fill(EMPTY, 25)
    buf = Tuple{Int,Int}[]
    total = 0
    examined = 0
    for a in 1:25, b in a+1:25, c in b+1:25
        board[a] = board[b] = board[c] = BLACK
        rest = [i for i in 1:25 if board[i] == EMPTY]
        n = length(rest)
        for x in 1:n, y in x+1:n, z in y+1:n
            board[rest[x]] = board[rest[y]] = board[rest[z]] = WHITE
            for side in (BLACK, WHITE)
                examined += 1
                isempty(gen_moves!(buf, board, side)) && (total += 1)
            end
            board[rest[x]] = board[rest[y]] = board[rest[z]] = EMPTY
        end
        board[a] = board[b] = board[c] = EMPTY
    end
    return (total, examined)
end

# ---------------------------------------------------------------------------
# 局面の鍵（置換表用）: 盤を 3 進 25 桁の整数とみなし、手番を最上位に足す
# ---------------------------------------------------------------------------

const POW3_25 = Int64(3)^25

function pos_key(board::AbstractVector{Int8}, side::Int8)
    k = Int64(0)
    for i in 25:-1:1
        k = k * 3 + board[i]
    end
    return side == BLACK ? k : k + POW3_25
end

# ---------------------------------------------------------------------------
# 素朴ミニマックス（枝刈り・置換表なし）。αβ の正しさを確かめる基準。
# 値は (:win|:loss|:unknown, 手数) をそのまま再帰で組み立てる（評価値の算術を使わない）。
# ---------------------------------------------------------------------------

struct NoMove <: Exception end

function naive_value(board::Vector{Int8}, side::Int8, r::Int)
    opp = opponent(side)
    is_lined(board, opp) && return (:loss, 0)
    r == 0 && return (:unknown, 0)
    ms = gen_moves!(Tuple{Int,Int}[], board, side)
    isempty(ms) && throw(NoMove())
    best_win = typemax(Int)   # 勝てる手のうち最短
    all_lose = true
    worst_loss = 0            # 全手が負けのときの最長
    for m in ms
        do_move!(board, m)
        v, d = naive_value(board, opp, r - 1)
        undo_move!(board, m)
        if v == :loss
            best_win = min(best_win, d + 1)
        end
        if v == :win
            worst_loss = max(worst_loss, d + 1)
        else
            all_lose = false
        end
    end
    best_win != typemax(Int) && return (:win, best_win)
    all_lose && return (:loss, worst_loss)
    return (:unknown, 0)
end

function root_status(p::Pos)
    is_lined(p.board, opponent(p.side)) && return (:loss, 0)
    is_lined(p.board, p.side) && return (:invalid, 0)   # 手番側だけが並んでいる（到達不能）
    return nothing
end

"""
    oracle_naive(pos; maxdepth) -> (value, plies)

素朴な深さ制限付きミニマックス。`oracle` と同じ値を返すはず（テスト用の基準）。
"""
function oracle_naive(pos_str::AbstractString; maxdepth::Integer)
    p = parse_pos(pos_str)
    st = root_status(p)
    st === nothing || return st
    try
        v, d = naive_value(copy(p.board), p.side, Int(maxdepth))
        return v == :unknown ? (:unknown, Int(maxdepth)) : (v, d)
    catch e
        e isa NoMove && return (:nomove, 0)
        rethrow()
    end
end

# ---------------------------------------------------------------------------
# αβ 探索（negamax、反復深化、深さを考慮した置換表）
#
# 評価値（根からの手数 ply を使う通常の詰み点数）:
#   手番側の勝ち（根から ply 手目で並ぶ）  →  MATE - ply
#   手番側の負け                          → -(MATE - ply)
#   決着せず                              →  0
#
# 置換表には「その節点から見た」値（節点相対）を入れる。節点相対の勝ち k 手は MATE - k。
# 深さ d0 で得た値を残り深さ r (<= d0) の節点で使うときは、
#   k > r の勝ち・負けを 0（未決着）に落とす写像 f_r
# を通す。深さ r の純粋なミニマックス値は f_r(深さ d0 の値) に等しく、f_r は単調なので
# 下界・上界もそのまま f_r で写せる。これで置換表を使っても素朴ミニマックスと一致する。
# ---------------------------------------------------------------------------

const MATE = 1000
const INF = 10_000

const EXACT = Int8(0)
const LOWER = Int8(1)   # 真の値 >= 格納値
const UPPER = Int8(2)   # 真の値 <= 格納値

struct TTEntry
    depth::Int8
    value::Int16     # 節点相対
    flag::Int8
    best::Int8       # 最善手の添字（手生成順、0 は無し）
end

mutable struct Searcher
    tt::Dict{Int64,TTEntry}
    movebuf::Vector{Vector{Tuple{Int,Int}}}
    nodes::Int
    nomove::Bool
end

# 置換表は oracle の呼び出し間で共有してよい（値は深さつきで格納し、使うときに f_r で落とす）
const MAX_PLY = 64
Searcher() = Searcher(Dict{Int64,TTEntry}(), [Tuple{Int,Int}[] for _ in 1:MAX_PLY+1], 0, false)

ismate(v::Integer) = abs(v) > MATE - 200

# 根相対 → 節点相対
to_node(v::Int, ply::Int) = v > 0 && ismate(v) ? v + ply : v < 0 && ismate(v) ? v - ply : v
# 節点相対 → 根相対
to_root(v::Int, ply::Int) = v > 0 && ismate(v) ? v - ply : v < 0 && ismate(v) ? v + ply : v
# 節点相対の値を残り深さ r に落とす（f_r）
function clamp_depth(v::Int, r::Int)
    ismate(v) || return v
    k = MATE - abs(v)
    return k > r ? 0 : v
end

function search!(s::Searcher, board::Vector{Int8}, side::Int8, r::Int, ply::Int,
                 α::Int, β::Int)
    s.nodes += 1
    opp = opponent(side)
    is_lined(board, opp) && return -(MATE - ply)
    r == 0 && return 0

    key = pos_key(board, side)
    hint = 0
    e = get(s.tt, key, nothing)
    if e !== nothing
        hint = Int(e.best)
        if e.depth >= r
            v = to_root(clamp_depth(Int(e.value), r), ply)
            if e.flag == EXACT
                return v
            elseif e.flag == LOWER
                α = max(α, v)
            else
                β = min(β, v)
            end
            α >= β && return v
        end
    end

    ms = gen_moves!(s.movebuf[ply+1], board, side)
    if isempty(ms)
        s.nomove = true
        return 0
    end

    # 1 手で並べられるなら最短の勝ちで、これ以上良い値は無い
    for m in ms
        do_move!(board, m)
        w = is_lined(board, side)
        undo_move!(board, m)
        w && return MATE - (ply + 1)
    end

    α0 = α
    best = -INF
    bestidx = 0
    n = length(ms)
    for j in 0:n
        # j == 0 は置換表の最善手、以降は生成順（最善手は飛ばす）
        idx = j == 0 ? hint : j
        (idx == 0 || (j > 0 && idx == hint)) && continue
        m = ms[idx]
        do_move!(board, m)
        v = -search!(s, board, opp, r - 1, ply + 1, -β, -α)
        undo_move!(board, m)
        if v > best
            best = v
            bestidx = idx
        end
        if v > α
            α = v
        end
        α >= β && break
    end

    flag = best <= α0 ? UPPER : best >= β ? LOWER : EXACT
    s.tt[key] = TTEntry(Int8(r), Int16(to_node(best, ply)), flag, Int8(bestidx))
    return best
end

"""
    oracle(pos_str; maxdepth) -> (value::Symbol, plies::Int)

深さ制限付き αβ（反復深化）で局面を判定する。

- `(:win, d)`     手番側が最短 d 手で勝てる（d <= maxdepth）
- `(:loss, d)`    手番側がどう指しても d 手で負ける（最長抵抗、d <= maxdepth）。`(:loss, 0)` は既に相手が並んでいる
- `(:unknown, maxdepth)` maxdepth 手以内に決着しない
- `(:nomove, 0)`  探索中に合法手 0 の局面に出会った（3 対 3 では起こらないことを全数検査で確認済み）
- `(:invalid, 0)` 手番側だけが既に並んでいる到達不能局面

`searcher` に `Searcher()` を渡すと置換表を呼び出し間で共有する（省略時は毎回新しく作る）。
"""
function oracle(pos_str::AbstractString; maxdepth::Integer,
                searcher::Union{Nothing,Searcher}=nothing, stats::Union{Nothing,Dict}=nothing)
    p = parse_pos(pos_str)
    st = root_status(p)
    st === nothing || return st
    D = Int(maxdepth)
    D <= MAX_PLY || throw(ArgumentError("maxdepth は $MAX_PLY 以下"))
    D <= 0 && return (:unknown, max(D, 0))
    s = searcher === nothing ? Searcher() : searcher
    s.nomove = false
    board = copy(p.board)
    result = (:unknown, D)
    for depth in 1:D
        v = search!(s, board, p.side, depth, 0, -INF, INF)
        if s.nomove
            result = (:nomove, 0)
            break
        end
        if ismate(v)
            result = v > 0 ? (:win, MATE - v) : (:loss, MATE + v)
            break
        end
    end
    if stats !== nothing
        stats[:nodes] = s.nodes
        stats[:tt_entries] = length(s.tt)
    end
    return result
end

end # module
