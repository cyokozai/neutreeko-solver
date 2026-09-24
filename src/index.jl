# 組合せ数体系（combinatorial number system）による局面の番号付けと状態分類

"手番側 3 駒の置き方の数 C(25,3)"
const N_ME = binomial(NSQUARES, NPIECES)
"残り 22 マスへの相手 3 駒の置き方の数 C(22,3)"
const N_OPP = binomial(NSQUARES - NPIECES, NPIECES)
"""
手番側視点に正規化した局面の総数 C(25,3)×C(22,3) = 3,542,000。
手番を含めた色の絶対表現ではこの 2 倍（7,084,000）になるが、
盤上の配置と手番の組は色を入れ替えれば必ずどれかの正規化局面に対応するので、この数で足りる。
"""
const NSTATES = N_ME * N_OPP

"小さい二項係数の表 BINOM[n+1, k+1] = C(n, k)（n ≤ 25, k ≤ 3）"
const BINOM = [binomial(n, k) for n in 0:NSQUARES, k in 0:NPIECES]

"""
    rank3(a, b, c) -> Int

0 ≤ a < b < c の 3 点集合の組合せ数体系による番号 C(a,1)+C(b,2)+C(c,3)（0 始まり）。
"""
@inline rank3(a::Int, b::Int, c::Int) = @inbounds BINOM[a+1, 2] + BINOM[b+1, 3] + BINOM[c+1, 4]

"3 ビットのビットボードの番号（25 マス中の 3 点集合、0 始まり）"
@inline function rank_bits3(x::Bits)
    a = trailing_zeros(x); x &= x - Bits(1)
    b = trailing_zeros(x); x &= x - Bits(1)
    c = trailing_zeros(x)
    return rank3(a, b, c)
end

"番号順（0 始まりの番号 + 1 が添字）に並べた n 点中の 3 点集合"
function _combos3(n::Int)
    out = Vector{NTuple{3,Int}}(undef, binomial(n, 3))
    for c in 2:n-1, b in 1:c-1, a in 0:b-1
        out[rank3(a, b, c)+1] = (a, b, c)
    end
    return out
end

"手番側の 3 駒の番号 → ビットボード"
const ME_BITS = [bit(a) | bit(b) | bit(c) for (a, b, c) in _combos3(NSQUARES)]

"22 マス中の 3 点集合（相手駒を、手番側の駒を除いて詰めた座標で表したもの）"
const OPP_COMBOS22 = [(UInt8(a), UInt8(b), UInt8(c)) for (a, b, c) in _combos3(NSQUARES - NPIECES)]

"FREE_SQUARES[k+1, r+1]: 手番側の駒が番号 r の配置のとき、k 番目（0 始まり）の空きマス"
const FREE_SQUARES = let
    t = Matrix{UInt8}(undef, NSQUARES - NPIECES, N_ME)
    for r in 0:N_ME-1
        k = 0
        for sq in 0:NSQUARES-1
            if (ME_BITS[r+1] >> sq) & 1 == 0
                t[k+1, r+1] = sq
                k += 1
            end
        end
    end
    t
end

"番号 r の 3 駒配置が並びを含むか（is_win_line の表引き版）"
const LINE_BY_RANK = BitVector([is_win_line(b) for b in ME_BITS])

"3 駒のビットボードが並びを含むか（表引きで速い）"
@inline has_line3(x::Bits) = @inbounds LINE_BY_RANK[rank_bits3(x)+1]

"""
    rank_state(me, opp) -> Int

手番側視点の局面 (me, opp) の番号（1 始まり、1〜NSTATES）。
手番側の 3 駒を 25 マス中の組合せとして番号 r_me、相手の 3 駒を「手番側の駒を除いた
22 マス」に詰めた座標で番号 r_opp とし、r_me × 1540 + r_opp + 1 とする。
"""
@inline function rank_state(me::Bits, opp::Bits)
    rme = rank_bits3(me)
    x = opp
    a = trailing_zeros(x); x &= x - Bits(1)
    b = trailing_zeros(x); x &= x - Bits(1)
    c = trailing_zeros(x)
    # 自分より下にある手番側の駒の数だけ詰める
    a -= count_ones(me & (bit(a) - Bits(1)))
    b -= count_ones(me & (bit(b) - Bits(1)))
    c -= count_ones(me & (bit(c) - Bits(1)))
    return rme * N_OPP + rank3(a, b, c) + 1
end

"""
    unrank_state(i) -> (me, opp)

`rank_state` の逆変換。
"""
@inline function unrank_state(i::Integer)
    i0 = i - 1
    rme = i0 ÷ N_OPP
    ro = i0 - rme * N_OPP
    @inbounds begin
        me = ME_BITS[rme+1]
        a, b, c = OPP_COMBOS22[ro+1]
        opp = bit(FREE_SQUARES[a+1, rme+1]) | bit(FREE_SQUARES[b+1, rme+1]) | bit(FREE_SQUARES[c+1, rme+1])
    end
    return me, opp
end

"""
    state_index(p::Position) -> Int

局面を手番側視点に正規化した番号。黒番の局面と、色を入れ替えた白番の局面は同じ番号になる。
"""
state_index(p::Position) = rank_state(mover_bits(p)...)

"""
    position_from_index(i, black_to_move) -> Position

番号 `i` の正規化局面を、手番の色 `black_to_move` の絶対表現に戻す。
"""
function position_from_index(i::Integer, black_to_move::Bool)
    me, opp = unrank_state(i)
    return from_mover_bits(me, opp, black_to_move)
end

"""
    state_kind(me, opp) -> Symbol

手番側視点の局面の分類。

- `:loss0`   — 相手が既に並んでいて手番側は並んでいない。手番側の負け（0 手）。
- `:invalid` — 手番側が並んでいる（相手の並びは問わない）。直前に手番側が並べた時点で
               終局しているはずなので、合法な手順では到達しない。両者並びも同様に到達しない。
- `:interior` — どちらも並んでいない。値は子局面から決まる。
"""
@inline function state_kind(me::Bits, opp::Bits)
    has_line3(me) && return :invalid
    has_line3(opp) && return :loss0
    return :interior
end
