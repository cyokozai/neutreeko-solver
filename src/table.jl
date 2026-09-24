# 解の表の保存・読込と、局面からの参照（値・最善手）

"保存ファイルの先頭の識別子"
const TABLE_MAGIC = b"NTRKTBL1"

"""
    save_table(path, t::SolveTable)

表をバイナリで保存する。形式（すべてリトルエンディアン）:
識別子 8 バイト `NTRKTBL1`、局面数 `UInt32`、合法手 0 の扱い `UInt8`（0=:draw, 1=:loss）、
続いて `value`（`Int8` × 局面数）、`dist`（`UInt8` × 局面数）。
"""
function save_table(path::AbstractString, t::SolveTable)
    length(t.value) == NSTATES == length(t.dist) || throw(ArgumentError("表の長さが不正"))
    mkpath(dirname(abspath(path)))
    open(path, "w") do io
        write(io, TABLE_MAGIC)
        write(io, htol(UInt32(NSTATES)))
        write(io, UInt8(findfirst(==(t.no_move_rule), NO_MOVE_RULES) - 1))
        write(io, t.value)
        write(io, t.dist)
    end
    return path
end

"""
    load_table(path) -> SolveTable

`save_table` で保存した表を読む。識別子・局面数・長さが合わなければ `ErrorException`。
"""
function load_table(path::AbstractString)
    open(path, "r") do io
        magic = read(io, length(TABLE_MAGIC))
        magic == TABLE_MAGIC || error("解の表のファイルではない: $path")
        n = ltoh(read(io, UInt32))
        n == NSTATES || error("局面数が一致しない: $n ≠ $NSTATES")
        r = read(io, UInt8)
        r < length(NO_MOVE_RULES) || error("合法手 0 の扱いの符号が不正: $r")
        value = Vector{Int8}(undef, NSTATES)
        dist = Vector{UInt8}(undef, NSTATES)
        try
            read!(io, value)
            read!(io, dist)
        catch e
            e isa EOFError && error("表が途中で切れている: $path")
            rethrow()
        end
        eof(io) || error("ファイル末尾に余分なデータがある")
        return SolveTable(value, dist, NO_MOVE_RULES[r+1])
    end
end

"値の符号を記号に変換する"
function value_symbol(v::Int8)
    v == VAL_WIN && return :win
    v == VAL_LOSS && return :loss
    v == VAL_DRAW && return :draw
    return :invalid
end

"""
    lookup(t, p) -> (value::Symbol, distance::Int)

局面 `p` の手番側から見た値（`:win` / `:loss` / `:draw` / `:invalid`）と、
決着までの手数（ply）を返す。勝ちは最短、負けは最長の手数。
引き分けと無効では `distance == -1`。終局済み（相手が並んでいる）局面は `(:loss, 0)`。
"""
function lookup(t::SolveTable, p::Position)
    i = state_index(p)
    v = t.value[i]
    s = value_symbol(v)
    return s, (s === :win || s === :loss) ? Int(t.dist[i]) : -1
end

"""
    best_moves(t, p) -> Vector{Move}

最善手の一覧。

- 勝ちの局面: 最短で勝てる手（子が「負け・距離 d−1」）
- 負けの局面: 最も長く粘れる手（子が「勝ち・距離 d−1」）
- 引き分けの局面: 引き分けを保つ手（子が引き分け）
- 終局済み・無効の局面: 空
"""
function best_moves(t::SolveTable, p::Position)
    v, d = lookup(t, p)
    out = Move[]
    (v === :invalid || (v === :loss && d == 0)) && return out
    want = v === :win ? (:loss, d - 1) : v === :loss ? (:win, d - 1) : (:draw, -1)
    for m in legal_moves(p)
        lookup(t, apply_move(p, m)) == want && push!(out, m)
    end
    return out
end

"""
    principal_variation(t, p; maxlen = 300) -> Vector{Move}

`best_moves` の先頭を選び続けた手順。勝ち・負けの局面では決着まで（長さは距離に等しい）、
引き分けでは `maxlen` 手で打ち切る。
"""
function principal_variation(t::SolveTable, p::Position; maxlen::Int = 300)
    out = Move[]
    while length(out) < maxlen
        bm = best_moves(t, p)
        isempty(bm) && break
        push!(out, bm[1])
        p = apply_move(p, bm[1])
    end
    return out
end
