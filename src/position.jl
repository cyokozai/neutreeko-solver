# 局面・指し手・前向き生成・後ろ向き生成

"駒の数（片側）"
const NPIECES = 3

"""
    Position(black, white, black_to_move)

色の絶対表現による局面。`black` / `white` は各色の 3 駒のビットボード、
`black_to_move` は黒の手番なら `true`。解の表は手番側視点に正規化した
（手番側の 3 マス, 相手の 3 マス）で引くので、`lookup` の内部で変換する。
"""
struct Position
    black::Bits
    white::Bits
    black_to_move::Bool
end

"""
    Move(from, to)

指し手。駒を `from` のマスから `to` のマスへ滑らせる（マス番号 0〜24）。
表記は `"b1-b4"` 形式（`format_move` / `parse_move`）。
"""
struct Move
    from::Int8
    to::Int8
end

"""
初期局面の文字列表記。黒 b1, d1, c4 / 白 b5, d5, c2、黒番。
"""
const INITIAL_POSITION_STRING = "B:.B.B...W.........B...W.W."

"""
    initial_position() -> Position

初期局面（黒 b1, d1, c4 / 白 b5, d5, c2、黒が先手）。
"""
initial_position() = Position(bit(1) | bit(3) | bit(17), bit(7) | bit(21) | bit(23), true)

"手番の色（`:black` か `:white`）"
side_to_move(p::Position) = p.black_to_move ? :black : :white

"手番側の駒と相手の駒のビットボードを返す（手番側視点への正規化）"
@inline mover_bits(p::Position) = p.black_to_move ? (p.black, p.white) : (p.white, p.black)

"手番側視点の (me, opp) と手番の色から絶対表現の局面を作る"
@inline from_mover_bits(me::Bits, opp::Bits, black_to_move::Bool) =
    black_to_move ? Position(me, opp, true) : Position(opp, me, false)

# ---------------------------------------------------------------------------
# 文字列表記
# ---------------------------------------------------------------------------

"""
    format_position(p) -> String

局面を `"<手番>:<25文字>"` 形式に変換する。手番は `B` か `W`、25 文字は
sq = 0..24 の順（a1, b1, …, e1, a2, …, e5）で `B` / `W` / `.`。
独立検証器と共有する取り決めなので、形式を変えないこと。
"""
function format_position(p::Position)
    buf = Vector{Char}(undef, NSQUARES)
    for sq in 0:NSQUARES-1
        buf[sq+1] = (p.black >> sq) & 1 == 1 ? 'B' : (p.white >> sq) & 1 == 1 ? 'W' : '.'
    end
    return string(p.black_to_move ? 'B' : 'W', ':', String(buf))
end

"""
    parse_position(str) -> Position

`format_position` の逆変換。形式が不正、または各色の駒が 3 つでなければ `ArgumentError`。
"""
function parse_position(str::AbstractString)
    s = collect(str)
    length(s) == NSQUARES + 2 || throw(ArgumentError("局面表記は 27 文字: $(repr(str))"))
    s[1] in ('B', 'W') || throw(ArgumentError("手番は B か W: $(repr(str))"))
    s[2] == ':' || throw(ArgumentError("手番の後は ':' : $(repr(str))"))
    black = Bits(0)
    white = Bits(0)
    for sq in 0:NSQUARES-1
        c = s[sq+3]
        if c == 'B'
            black |= bit(sq)
        elseif c == 'W'
            white |= bit(sq)
        elseif c != '.'
            throw(ArgumentError("盤の文字は B/W/. のみ: $(repr(str))"))
        end
    end
    (count_ones(black) == NPIECES && count_ones(white) == NPIECES) ||
        throw(ArgumentError("各色の駒は 3 つ: $(repr(str))"))
    return Position(black, white, s[1] == 'B')
end

Base.show(io::IO, p::Position) = print(io, "parse_position(\"", format_position(p), "\")")

"""
    format_move(m) -> String

指し手を `"b1-b4"` 形式に変換する。
"""
format_move(m::Move) = string(square_name(m.from), '-', square_name(m.to))

"""
    parse_move(str) -> Move

`"b1-b4"` 形式の指し手を読む。
"""
function parse_move(str::AbstractString)
    parts = split(str, '-')
    length(parts) == 2 || throw(ArgumentError("指し手は \"b1-b4\" 形式: $(repr(str))"))
    return Move(parse_square(parts[1]), parse_square(parts[2]))
end

Base.show(io::IO, m::Move) = print(io, format_move(m))

# ---------------------------------------------------------------------------
# 勝ち判定
# ---------------------------------------------------------------------------

"""
    winner(p) -> Union{Symbol,Nothing}

既に 3 つ並んでいる側を返す（`:black` / `:white`）。どちらも並んでいなければ `nothing`、
両者とも並んでいれば `:both`（合法な手順では到達しない）。
"""
function winner(p::Position)
    b = is_win_line(p.black)
    w = is_win_line(p.white)
    return b && w ? :both : b ? :black : w ? :white : nothing
end

"終局しているか（どちらかが並んでいる）"
is_terminal(p::Position) = winner(p) !== nothing

# ---------------------------------------------------------------------------
# 前向き生成（ビットボード版）
# ---------------------------------------------------------------------------

"""
    foreach_move(f, me, opp)

手番側 `me` の各駒について、8 方向それぞれへ盤の端か他の駒の直前まで滑らせた
着地点を求め、`f(from, to)` を呼ぶ。1 マスも動けない方向は飛ばす。
終局しているかどうかは見ない（呼び出し側の責務）。
"""
@inline function foreach_move(f::F, me::Bits, opp::Bits) where {F}
    occ = me | opp
    m = me
    while m != 0
        s = trailing_zeros(m)
        m &= m - Bits(1)
        @inbounds rays = RAYS[s+1]
        for d in 1:8
            to = -1
            @inbounds for x in rays[d]
                (occ >> x) & 1 == 1 && break
                to = x
            end
            to >= 0 && f(s, to)
        end
    end
    return nothing
end

"手番側視点の局面 (me, opp) の合法手の数"
function count_moves(me::Bits, opp::Bits)
    occ = me | opp
    n = 0
    m = me
    while m != 0
        s = trailing_zeros(m)
        m &= m - Bits(1)
        @inbounds rays = RAYS[s+1]
        for d in 1:8
            ray = @inbounds rays[d]
            # 隣のマスが空いていれば、その方向に少なくとも 1 マス動ける
            (!isempty(ray) && (occ >> @inbounds(ray[1])) & 1 == 0) && (n += 1)
        end
    end
    return n
end

"""
    foreach_child(f, me, opp)

手番側視点の局面 (me, opp) から 1 手指した子局面を、子の手番側視点
`f(child_me, child_opp)` で列挙する（手番が交代するので `child_me` は元の相手）。
"""
@inline function foreach_child(f::F, me::Bits, opp::Bits) where {F}
    foreach_move(me, opp) do s, t
        f(opp, me ⊻ bit(s) ⊻ bit(t))
    end
end

# ---------------------------------------------------------------------------
# 後ろ向き生成（ビットボード版）
# ---------------------------------------------------------------------------

"""
    foreach_predecessor(f, me, opp)

手番側視点の局面 q = (me, opp) の直前局面をすべて列挙し、直前局面の手番側視点
`f(pred_me, pred_opp)` を呼ぶ。

直前に指したのは q の相手側（`opp`）である。相手の駒が s に止まっていて、方向 d へ
滑ってきたのなら:

- s から d へ 1 マス進んだ先は盤外か駒で塞がっている（そこで止まったのだから）。
- 元の位置 t は、s から −d 方向に連続する空きマスのどれか（途中に駒があれば滑れない）。

直前局面では相手側が手番なので、手番側視点は (opp − s + t, me) になる。
直前局面が終局済みかどうかは見ない。`foreach_child` の厳密な逆であり、
「p が q の親 ⇔ q が p の子」がテストで確かめてある。
"""
@inline function foreach_predecessor(f::F, me::Bits, opp::Bits) where {F}
    occ = me | opp
    m = opp
    while m != 0
        s = trailing_zeros(m)
        m &= m - Bits(1)
        @inbounds rays = RAYS[s+1]
        for d in 1:8
            fwd = @inbounds rays[d]
            # d 方向の次のマスが空いていれば、s で止まれない
            (!isempty(fwd) && (occ >> @inbounds(fwd[1])) & 1 == 0) && continue
            @inbounds for t in rays[OPPOSITE_DIR[d]]
                (occ >> t) & 1 == 1 && break
                f(opp ⊻ bit(s) ⊻ bit(t), me)
            end
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Position 版の公開 API
# ---------------------------------------------------------------------------

"""
    legal_moves(p) -> Vector{Move}

手番側の合法手の一覧。終局しているかどうかは見ない（`is_terminal` を別に確かめること）。
"""
function legal_moves(p::Position)
    me, opp = mover_bits(p)
    out = Move[]
    foreach_move((s, t) -> push!(out, Move(s, t)), me, opp)
    return out
end

"""
    apply_move(p, m) -> Position

指し手 `m` を適用した局面（手番が交代する）。`m` が合法手でなければ `ArgumentError`。
"""
function apply_move(p::Position, m::Move)
    m in legal_moves(p) || throw(ArgumentError("合法手ではない: $(format_move(m)) in $(format_position(p))"))
    me, opp = mover_bits(p)
    newme = me ⊻ bit(m.from) ⊻ bit(m.to)
    # 子局面では相手が手番になる
    return from_mover_bits(opp, newme, !p.black_to_move)
end

"""
    predecessors(p) -> Vector{Position}

局面 `p` の直前局面（1 手前にありえた局面）の一覧。手番は `p` と逆になる。
直前局面が終局済みかどうかは見ない。
"""
function predecessors(p::Position)
    me, opp = mover_bits(p)
    out = Position[]
    prev_black = !p.black_to_move
    foreach_predecessor(me, opp) do pm, po
        push!(out, from_mover_bits(pm, po, prev_black))
    end
    return out
end
