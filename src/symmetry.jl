# 盤面の 8 通りの対称（回転 4 × 鏡映 2 の二面体群 D4）

"""
    SYMMETRIES :: Vector{Vector{Int}}

盤の対称変換をマスの置換として表したもの。`SYMMETRIES[k][sq+1]` が変換後のマス番号。
1 番目は恒等変換。Neutreeko のルール（8 方向の滑りと 3 並び）はこの 8 変換で不変なので、
値と距離も不変になるはず（テストで全数確認）。
"""
const SYMMETRIES = let
    n = BOARD_SIZE - 1
    maps = [
        (r, c) -> (r, c),          # 恒等
        (r, c) -> (c, n - r),      # 90° 回転
        (r, c) -> (n - r, n - c),  # 180° 回転
        (r, c) -> (n - c, r),      # 270° 回転
        (r, c) -> (r, n - c),      # 左右鏡映
        (r, c) -> (n - r, c),      # 上下鏡映
        (r, c) -> (c, r),          # 主対角線での鏡映
        (r, c) -> (n - c, n - r),  # 副対角線での鏡映
    ]
    [[make_sq(f(sq_row(sq), sq_col(sq))...) for sq in 0:NSQUARES-1] for f in maps]
end

"ビットボードにマスの置換 `perm` を適用する"
@inline function transform_bits(x::Bits, perm::Vector{Int})
    y = Bits(0)
    while x != 0
        s = trailing_zeros(x)
        x &= x - Bits(1)
        y |= bit(@inbounds perm[s+1])
    end
    return y
end

"局面番号 `i` に対称変換 `perm` を施した局面の番号"
@inline function transform_index(i::Integer, perm::Vector{Int})
    me, opp = unrank_state(i)
    return rank_state(transform_bits(me, perm), transform_bits(opp, perm))
end

"""
    is_canonical(i) -> Bool

局面番号 `i` が、その対称類（8 変換で移り合う局面の集合）の中で最小の番号か。
"""
function is_canonical(i::Integer)
    for k in 2:length(SYMMETRIES)
        transform_index(i, SYMMETRIES[k]) < i && return false
    end
    return true
end

"""
    symmetry_class_count(pred = i -> true) -> Int

条件 `pred(i)` を満たす局面の対称類の数（代表元＝類内最小番号の個数）。
`pred` は対称変換で不変な条件（値など）であること。
"""
symmetry_class_count(pred = i -> true) = count(i -> pred(i) && is_canonical(i), 1:NSTATES)

"""
    count_symmetry_violations(t::SolveTable) -> Int

全局面 × 恒等以外の 7 変換について、変換先の値または距離が元と異なる組の数（正しければ 0）。
"""
function count_symmetry_violations(t::SolveTable)
    bad = 0
    @inbounds for i in 1:NSTATES, k in 2:length(SYMMETRIES)
        j = transform_index(i, SYMMETRIES[k])
        (t.value[j] == t.value[i] && t.dist[j] == t.dist[i]) || (bad += 1)
    end
    return bad
end

"対称変換 `perm` で動かない局面の数（Burnside の補題による検算用）"
count_fixed_states(perm::Vector{Int}) = count(i -> transform_index(i, perm) == i, 1:NSTATES)
