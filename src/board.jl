# 盤の幾何: マス番号、方向、勝ち筋（長さ 3 の直線）

"盤の一辺の長さ"
const BOARD_SIZE = 5
"マス数"
const NSQUARES = BOARD_SIZE * BOARD_SIZE

"""
    Bits

3 マス集合などを表す 25 ビットのビットボード。ビット `sq` が立っていれば、マス `sq` に駒がある。
"""
const Bits = UInt32

"全マスが立ったマスク"
const FULL_MASK = (Bits(1) << NSQUARES) - Bits(1)

@inline sq_row(sq::Integer) = sq ÷ BOARD_SIZE          # 0 始まりの行（0 が 1 段目）
@inline sq_col(sq::Integer) = sq % BOARD_SIZE          # 0 始まりの列（0 が a 列）
@inline make_sq(row::Integer, col::Integer) = row * BOARD_SIZE + col
@inline on_board(row::Integer, col::Integer) = 0 <= row < BOARD_SIZE && 0 <= col < BOARD_SIZE
@inline bit(sq::Integer) = Bits(1) << sq

"""
    square_name(sq) -> String

マス番号（0〜24）を `"a1"` 形式の名前に変換する。`sq = (row-1)*5 + (col-1)`。
"""
function square_name(sq::Integer)
    0 <= sq < NSQUARES || throw(ArgumentError("マス番号が範囲外: $sq"))
    return string(Char('a' + sq_col(sq)), sq_row(sq) + 1)
end

"""
    parse_square(name) -> Int

`"a1"` 形式のマス名をマス番号に変換する。
"""
function parse_square(name::AbstractString)
    length(name) == 2 || throw(ArgumentError("マス名は 2 文字: $(repr(name))"))
    c, r = name[1], name[2]
    ('a' <= c <= 'e' && '1' <= r <= '5') || throw(ArgumentError("マス名が不正: $(repr(name))"))
    return make_sq(r - '1', c - 'a')
end

"""
8 方向 `(drow, dcol)`。順序は N, NE, E, SE, S, SW, W, NW（N が行番号の増える向き）。
"""
const DIRECTIONS = ((1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1))

"""
    RAYS[sq+1][d]

マス `sq` から方向 `d` へ進んだときに通るマスの列（`sq` 自身は含まない。盤の端で打ち切り）。
前向きの滑り（`legal_moves`）と後ろ向きの滑り（`predecessors`）の両方がこの表を使う。
"""
const RAYS = let
    rays = Vector{NTuple{8,Vector{Int}}}(undef, NSQUARES)
    for sq in 0:NSQUARES-1
        r0, c0 = sq_row(sq), sq_col(sq)
        rays[sq+1] = ntuple(8) do d
            dr, dc = DIRECTIONS[d]
            out = Int[]
            r, c = r0 + dr, c0 + dc
            while on_board(r, c)
                push!(out, make_sq(r, c))
                r += dr
                c += dc
            end
            out
        end
    end
    rays
end

"逆向きの方向番号（N↔S など）"
const OPPOSITE_DIR = ntuple(d -> mod1(d + 4, 8), 8)

"""
    WIN_LINES :: Vector{Bits}

5×5 盤上の長さ 3 の直線（縦・横・斜め）をすべて列挙したもの。横 15・縦 15・斜め 9+9 の計 48 本。
各筋の起点マスから N, NE, E, SE の 4 方向だけに伸ばすことで重複なく数える。
"""
const WIN_LINES = let
    lines = Bits[]
    for sq in 0:NSQUARES-1, d in (1, 2, 3, 4)   # N, NE, E, SE
        ray = RAYS[sq+1][d]
        length(ray) >= 2 || continue
        push!(lines, bit(sq) | bit(ray[1]) | bit(ray[2]))
    end
    lines
end

"""
    is_win_line(bits::Bits) -> Bool

ビットボード `bits` の駒の中に、縦・横・斜めに連続した 3 つの並びが含まれていれば `true`。
"""
@inline function is_win_line(bits::Bits)
    @inbounds for l in WIN_LINES
        (bits & l) == l && return true
    end
    return false
end
is_win_line(bits::Integer) = is_win_line(Bits(bits))
