# 集計: 合法手 0 の局面、初期局面からの到達可能性

"""
    no_move_states() -> Vector{Int}

どちらも並んでいない（未確定の）局面のうち、手番側に合法手が 1 つも無い局面の番号の一覧。
"""
no_move_states() =
    [i for i in 1:NSTATES if (let (me, opp) = unrank_state(i)
        state_kind(me, opp) === :interior && count_moves(me, opp) == 0
    end)]

"絶対表現（正規化番号 i, 手番の色）の通し番号。黒番は 2i−1、白番は 2i"
@inline abs_index(i::Integer, black_to_move::Bool) = 2 * Int(i) - (black_to_move ? 1 : 0)

"""
    reachable_from(p = initial_position()) -> BitVector

局面 `p` から合法手順（どちらかが並んだら終局）で到達できる局面の集合を、
絶対表現の通し番号（`abs_index`、長さ 2×NSTATES）で返す。
"""
function reachable_from(p::Position = initial_position())
    seen = falses(2 * NSTATES)
    queue = Int[]
    i0 = state_index(p)
    seen[abs_index(i0, p.black_to_move)] = true
    push!(queue, abs_index(i0, p.black_to_move))
    head = 1
    while head <= length(queue)
        a = queue[head]
        head += 1
        i = (a + 1) >> 1
        btm = isodd(a)
        me, opp = unrank_state(i)
        state_kind(me, opp) === :interior || continue   # 終局した局面からは指さない
        foreach_child(me, opp) do cme, copp
            c = abs_index(rank_state(cme, copp), !btm)
            if !seen[c]
                seen[c] = true
                push!(queue, c)
            end
        end
    end
    return seen
end

"絶対表現の到達集合を、色を入れ替えて同一視した正規化局面の集合に畳む"
normalize_reachable(seen::BitVector) = BitVector(seen[2i-1] | seen[2i] for i in 1:NSTATES)

"""
    count_with_interior_predecessor() -> Int

無効でない局面のうち、どちらも並んでいない直前局面を少なくとも 1 つ持つもの
（＝どこかから 1 手で到達しうる局面）の数。
"""
function count_with_interior_predecessor()
    n = 0
    for i in 1:NSTATES
        me, opp = unrank_state(i)
        state_kind(me, opp) === :invalid && continue
        found = Ref(false)
        foreach_predecessor(me, opp) do pm, po
            found[] |= state_kind(pm, po) === :interior
        end
        n += found[]
    end
    return n
end
