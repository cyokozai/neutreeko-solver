# 後退解析（retrograde analysis）による強解決と、検証用の前向き不動点反復

"値の符号（手番側視点）: 引き分け（後退解析で勝ち・負けに確定しなかった局面）"
const VAL_DRAW = Int8(0)
"値の符号: 手番側の勝ち"
const VAL_WIN = Int8(1)
"値の符号: 手番側の負け"
const VAL_LOSS = Int8(-1)
"値の符号: 合法な手順では到達しない局面（手番側が既に並んでいる）"
const VAL_INVALID = Int8(-2)

"合法手 0 の局面の扱いとして受け付ける値"
const NO_MOVE_RULES = (:draw, :loss)

"""
    SolveTable

強解決の結果。添字は `rank_state` の番号（手番側視点に正規化した局面）。

- `value[i]` — `VAL_WIN` / `VAL_LOSS` / `VAL_DRAW` / `VAL_INVALID`（手番側から見た値）
- `dist[i]`  — 勝ち・負けの局面で、最善の応酬のもとで決着するまでの手数（ply）。
               勝ちは最短、負けは最長。引き分け・無効では 0。
- `no_move_rule` — 合法手 0 の局面の扱い（`:draw` または `:loss`）
"""
struct SolveTable
    value::Vector{Int8}
    dist::Vector{UInt8}
    no_move_rule::Symbol
end

function _check_rule(no_move_rule::Symbol)
    no_move_rule in NO_MOVE_RULES ||
        throw(ArgumentError("no_move_rule は $(NO_MOVE_RULES) のいずれか: $(repr(no_move_rule))"))
end

"""
    initial_labels(no_move_rule) -> (value, dist, nmoves)

全局面を分類して初期値を置く。終局（相手が並んでいる）は負け 0 手、手番側が並んでいる局面は
無効、それ以外は未確定（`VAL_DRAW`）。`nmoves[i]` は未確定局面の合法手の数。
`no_move_rule == :loss` なら、合法手 0 の局面も負け 0 手として扱う。
"""
function initial_labels(no_move_rule::Symbol)
    _check_rule(no_move_rule)
    value = fill(VAL_DRAW, NSTATES)
    dist = zeros(UInt8, NSTATES)
    nmoves = zeros(UInt8, NSTATES)
    @inbounds for i in 1:NSTATES
        me, opp = unrank_state(i)
        k = state_kind(me, opp)
        if k === :invalid
            value[i] = VAL_INVALID
        elseif k === :loss0
            value[i] = VAL_LOSS
        else
            n = count_moves(me, opp)
            nmoves[i] = n
            if n == 0 && no_move_rule === :loss
                value[i] = VAL_LOSS
            end
        end
    end
    return value, dist, nmoves
end

"""
    solve(; no_move_rule = :draw) -> SolveTable

Neutreeko の全 3,542,000 局面（手番側視点）を後退解析で強解決する。

# アルゴリズム

1. 終局（相手が既に並んでいる局面）を「負け・0 手」としてキューに入れる。
   各未確定局面には「まだ勝ちと確定していない子の数」のカウンタ（初期値は合法手の数）を持たせる。
2. キューから局面 q（距離 d）を取り出し、`foreach_predecessor` で直前局面 p を列挙する。
   - q が負けなら、p には負けの子があるので p は「勝ち・d+1 手」に確定。
   - q が勝ちなら、p のカウンタを 1 減らす。0 になれば p の子は全部勝ちなので
     p は「負け・d+1 手」に確定。
   確定した p をキューの末尾に入れる。
3. キューは距離の順に処理される（幅優先）ので、勝ちは最初に見つかった負けの子で
   最短距離が、負けは最後に勝ちと確定した子で最長距離が付く。

# 引き分けの扱い

同一局面 3 回で引き分けというルールは局面の履歴に依存するが、強解決では
「後退解析で勝ち・負けに確定しなかった局面＝引き分け」とする。これで整合する理由:

- 確定した勝ち・負けの距離は、終局へ向かって毎手 1 ずつ減る手順が存在することを意味する。
  距離が真に減り続ける手順は同一局面を 2 度通らないので、3 回反復の規定に触れずに実現できる。
- 確定しなかった局面では、どちらの側も相手を終局へ追い込めない（勝ち側は負けへの手を持たず、
  負け側は常に未確定の子へ逃げられる）。両者がそうし続けると対局は有限の局面を巡回し、
  いずれ同一局面 3 回に達して引き分けになる。

# 合法手 0 の局面

ルールに規定が無いので `no_move_rule` で切り替える。既定の `:draw` ではカウンタが 0 から
減ることが無いので、そのまま未確定（引き分け）として残る。`:loss` では手番側の負け 0 手とする。
"""
function solve(; no_move_rule::Symbol = :draw)
    value, dist, cnt = initial_labels(no_move_rule)
    queue = Vector{Int32}(undef, NSTATES)
    tail = 0
    @inbounds for i in 1:NSTATES
        if value[i] == VAL_LOSS
            tail += 1
            queue[tail] = i
        end
    end
    head = 1
    @inbounds while head <= tail
        q = queue[head]
        head += 1
        vq = value[q]
        dnext = dist[q] + UInt8(1)
        dnext == 0 && error("距離が UInt8 を超えた")
        me, opp = unrank_state(q)
        # 直前局面の列挙（クロージャで tail を書き換えないよう、ここに展開する）
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
                    value[p] == VAL_DRAW || continue   # 確定済み・無効・終局は飛ばす
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
    return SolveTable(value, dist, no_move_rule)
end

"""
    minimax_from_children(value, dist, me, opp, no_move_rule) -> (v, d)

未確定でない子局面の値だけから、局面 (me, opp) の値と距離を 1 段の minimax で求める。

- 負けの子が 1 つでもあれば勝ち、距離は 1 + (負けの子の最小距離)
- 合法手があって子が全部勝ちなら負け、距離は 1 + (勝ちの子の最大距離)
- 合法手 0 なら `no_move_rule` に従う（`:loss` なら負け 0 手）
- それ以外は引き分け（未確定）
"""
function minimax_from_children(value::Vector{Int8}, dist::Vector{UInt8}, me::Bits, opp::Bits,
                               no_move_rule::Symbol)
    best_loss = typemax(Int)
    max_win = -1
    all_win = true
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
            to < 0 && continue
            n += 1
            c = rank_state(opp, me ⊻ bit(s) ⊻ bit(to))
            vc = value[c]
            if vc == VAL_LOSS
                best_loss = min(best_loss, Int(dist[c]))
            elseif vc == VAL_WIN
                max_win = max(max_win, Int(dist[c]))
            else
                all_win = false
            end
        end
    end
    n == 0 && return no_move_rule === :loss ? (VAL_LOSS, UInt8(0)) : (VAL_DRAW, UInt8(0))
    best_loss < typemax(Int) && return (VAL_WIN, UInt8(best_loss + 1))
    all_win && return (VAL_LOSS, UInt8(max_win + 1))
    return (VAL_DRAW, UInt8(0))
end

"""
    solve_fixpoint(; no_move_rule = :draw) -> SolveTable

検証用の別解。後退解析を使わず、前向きの 1 段 minimax を全局面に繰り返し適用して、
値が変わらなくなるまで更新する（Jacobi 型: 各反復は前の反復の値だけを読む）。

反復 j を終えた時点で確定している局面は、ちょうど真の距離が j 以下の局面である
（距離 j の勝ちは距離 j−1 の負けの子を、距離 j の負けは距離 j−1 以下の勝ちの子だけを持つ）。
そのため一度確定した値と距離は以後変わらず、確定済みの局面は再評価しない。
遅いが、後退解析とは独立な経路で同じ表を作るので、両者の全局面一致が正しさの検証になる。
"""
function solve_fixpoint(; no_move_rule::Symbol = :draw)
    value, dist, _ = initial_labels(no_move_rule)
    undecided = Int32[i for i in 1:NSTATES if value[i] == VAL_DRAW]
    newly = Tuple{Int32,Int8,UInt8}[]
    while true
        empty!(newly)
        for i in undecided
            me, opp = unrank_state(i)
            v, d = minimax_from_children(value, dist, me, opp, no_move_rule)
            v == VAL_DRAW || push!(newly, (i, v, d))
        end
        isempty(newly) && break
        for (i, v, d) in newly
            value[i] = v
            dist[i] = d
        end
        filter!(i -> value[i] == VAL_DRAW, undecided)
    end
    return SolveTable(value, dist, no_move_rule)
end
