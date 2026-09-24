# Neutreeko の対局 CLI（人間・完全なエージェント・αβ探索・無作為の任意の組み合わせ）
#
# 実行（リポジトリ直下で）:
#   docker run --rm -it -v "$PWD":/work -w /work julia:1.11 julia --project=. scripts/play.jl [オプション]
#
# 例:
#   scripts/play.jl                                     # 人間（黒）対 完全なエージェント（白）
#   scripts/play.jl --black perfect --white human       # 人間が後手
#   scripts/play.jl --black alphabeta:4 --white random --games 100 --seed 1
#   scripts/play.jl --analyze "B:.B.B...W.........B...W.W."
#
# 人間の入力: `b1-b4` 形式の指し手、`hint`（各合法手の値）、`undo`（1 手戻す）、`help`、`quit`。
# 入出力は関数の引数に分けてあり、test/test_agent.jl から IOBuffer を差し込んで試験する。

module PlayCLI

using Neutreeko
using Random

const NT = Neutreeko

"既定の表のパス（scripts/solve.jl の保存先と同じ）"
const DEFAULT_TABLE = normpath(joinpath(@__DIR__, "..", "data", "neutreeko_table.bin"))

const USAGE = """
使い方: julia --project=. scripts/play.jl [オプション]

  --black SPEC        黒の指し手（既定 human）
  --white SPEC        白の指し手（既定 perfect）
                        SPEC = human | perfect | random | alphabeta[:深さ]（深さの既定 4）
  --table PATH        強解決の表（既定 data/neutreeko_table.bin。無ければ解いて保存する）
  --seed N            乱数の種（同点手の選択・無作為の手）。省くと毎回変わる
  --games N           エージェント同士で N 局指して勝率を集計する（human は不可）
  --position STR      途中局面から始める（例 "B:.B.B...W.........B...W.W."）
  --max-plies N       手数の上限（既定 1000。超えたら引分け）
  --analyze STR       局面の値と全合法手の評価を出して終了する
  --help              この説明

局面文字列は "<手番 B|W>:<25 文字>"。25 文字は a1, b1, …, e1, a2, …, e5 の順に B / W / .。
"""

const AGENT_NAMES = ("human", "perfect", "random", "alphabeta")

"CLI の設定"
Base.@kwdef mutable struct Options
    black::String = "human"
    white::String = "perfect"
    table::String = DEFAULT_TABLE
    seed::Union{Nothing,Int} = nothing
    games::Int = 0
    position::Union{Nothing,String} = nothing
    analyze::Union{Nothing,String} = nothing
    max_plies::Int = 1000
    help::Bool = false
end

"""
    split_spec(spec) -> (name, depth)

`"alphabeta:6"` を `("alphabeta", 6)` に分ける。深さを持たない指定では `depth == nothing`。
不正なら `ArgumentError`。
"""
function split_spec(spec::AbstractString)
    parts = split(spec, ':')
    name = String(parts[1])
    name in AGENT_NAMES || throw(ArgumentError("エージェントは $(join(AGENT_NAMES, " / ")) のいずれか: $(repr(spec))"))
    length(parts) == 1 && return name, (name == "alphabeta" ? 4 : nothing)
    (length(parts) == 2 && name == "alphabeta") ||
        throw(ArgumentError("深さを指定できるのは alphabeta だけ: $(repr(spec))"))
    depth = tryparse(Int, parts[2])
    (depth === nothing || depth < 1) && throw(ArgumentError("深さは 1 以上の整数: $(repr(spec))"))
    return name, depth
end

"指定のエージェントが強解決の表を要するか（human は hint のために使う）"
needs_table(spec::AbstractString) = first(split_spec(spec)) in ("perfect", "human")

"""
    parse_args(args) -> Options

コマンドライン引数を解釈する。不正なら `ArgumentError`。
"""
function parse_args(args::AbstractVector{<:AbstractString})
    o = Options()
    i = 1
    value() = (i < length(args) || throw(ArgumentError("$(args[i]) には値が要る")); args[i+1])
    function int(s)
        x = tryparse(Int, s)
        x === nothing && throw(ArgumentError("整数が要る: $(repr(s))"))
        return x
    end
    while i <= length(args)
        a = args[i]
        if a == "--help" || a == "-h"
            o.help = true
            i += 1
            continue
        end
        a == "--black" ? (o.black = value()) :
        a == "--white" ? (o.white = value()) :
        a == "--table" ? (o.table = value()) :
        a == "--seed" ? (o.seed = int(value())) :
        a == "--games" ? (o.games = int(value())) :
        a == "--position" ? (o.position = value()) :
        a == "--max-plies" ? (o.max_plies = int(value())) :
        a == "--analyze" ? (o.analyze = value()) :
        throw(ArgumentError("不明なオプション: $(repr(a))"))
        i += 2
    end
    split_spec(o.black)
    split_spec(o.white)
    o.games >= 0 || throw(ArgumentError("--games は 0 以上"))
    o.max_plies >= 0 || throw(ArgumentError("--max-plies は 0 以上"))
    o.games > 0 && "human" in (o.black, o.white) &&
        throw(ArgumentError("--games では human を指定できない（--black と --white にエージェントを指定する）"))
    return o
end

"""
    make_agent(spec, table, seed) -> Union{AbstractAgent,Symbol}

指定からエージェントを作る。人間は `:human`。`seed` が `nothing` なら大域の乱数を使う。
"""
function make_agent(spec::AbstractString, table, seed::Union{Nothing,Integer})
    name, depth = split_spec(spec)
    name == "human" && return :human
    rng = seed === nothing ? Random.default_rng() : MersenneTwister(seed)
    name == "random" && return RandomAgent(rng)
    name == "alphabeta" && return AlphaBetaAgent(depth; rng = rng)
    table === nothing && throw(ArgumentError("perfect には強解決の表が要る"))
    return PerfectAgent(table; rng = rng)
end

"""
    obtain_table(path, io) -> SolveTable

`path` の表を読む。無ければ、その旨を表示して `solve()` で解き、`path` に保存する。
"""
function obtain_table(path::AbstractString, io::IO = stdout)
    isfile(path) && return load_table(path)
    println(io, "表 $path が見つからないので、強解決します（数秒〜数十秒）…")
    t = solve()
    save_table(path, t)
    println(io, "保存しました: $path")
    return t
end

# ---------------------------------------------------------------------------
# 表示
# ---------------------------------------------------------------------------

"""
    render_board(p) -> String

盤を ASCII で描く。行 5 を上に、列 a〜e を下に置く。黒 `B`、白 `W`、空き `.`。
"""
function render_board(p::Position)
    io = IOBuffer()
    for r in 5:-1:1
        cells = map(1:5) do c
            sq = (r - 1) * 5 + (c - 1)
            (p.black >> sq) & 1 == 1 ? 'B' : (p.white >> sq) & 1 == 1 ? 'W' : '.'
        end
        println(io, r, " | ", join(cells, ' '), " |")
    end
    println(io, "    a b c d e")
    return String(take!(io))
end

color_name(c::Symbol) = c === :black ? "黒" : c === :white ? "白" : string(c)
side_name(p::Position) = p.black_to_move ? "黒番" : "白番"

"値と手数の日本語表記（手番側から見た値）"
function describe(v::Symbol, d::Integer)
    v === :win && return "勝ち（$d 手）"
    v === :loss && return "負け（$d 手）"
    v === :draw && return "引分け"
    return "無効"
end

const FLIP = Dict(:win => :loss, :loss => :win, :draw => :draw, :invalid => :invalid)

"""
    evaluate_moves(table, p) -> Vector{NamedTuple{(:move, :value, :plies)}}

局面 `p` の各合法手を、指した側から見た値（`:win` / `:loss` / `:draw`）と決着までの手数
（`p` から数えた ply。引分けは −1）で評価する。並びは 勝ち（短い順）→ 引分け → 負け（長い順）。
"""
function evaluate_moves(table, p::Position)
    ev = map(legal_moves(p)) do m
        v, d = lookup(table, apply_move(p, m))
        (move = m, value = FLIP[v], plies = d >= 0 ? d + 1 : -1)
    end
    order = Dict(:win => 0, :draw => 1, :loss => 2, :invalid => 3)
    return sort(ev; by = x -> (order[x.value], x.value === :loss ? -x.plies : x.plies))
end

"hint / analyze の一覧を書く。最善手には印を付ける"
function print_evaluations(io::IO, table, p::Position)
    best = Set(best_moves(table, p))
    for e in evaluate_moves(table, p)
        println(io, "  ", rpad(format_move(e.move), 7), rpad(describe(e.value, e.plies), 12),
                e.move in best ? "  ← 最善" : "")
    end
end

"""
    analyze(io, table, str)

局面文字列 `str` の値・距離と、全合法手の評価を `io` に書く。
"""
function analyze(io::IO, table, str::AbstractString)
    p = parse_position(str)
    println(io, "局面: ", format_position(p))
    print(io, render_board(p))
    w = NT.winner(p)
    if w !== nothing
        println(io, side_name(p), "。既に", color_name(w), "が並んでいる（終局）")
        return
    end
    v, d = lookup(table, p)
    println(io, side_name(p), "。手番側から見た値: ", describe(v, d))
    println(io, "合法手 ", length(legal_moves(p)), " 手（指した側から見た値、手数はこの局面から数えた ply）:")
    print_evaluations(io, table, p)
end

"棋譜を `1. b1-b4 b5-b2  2. …` の形にする（開始局面の手番から数える）"
function format_record(start::Position, moves::Vector{Move})
    parts = String[]
    white_first = !start.black_to_move
    white_first && !isempty(moves) && push!(parts, "1. … " * format_move(moves[1]))
    i = white_first ? 2 : 1
    k = white_first ? 2 : 1
    while i <= length(moves)
        s = "$k. " * format_move(moves[i])
        i + 1 <= length(moves) && (s *= " " * format_move(moves[i+1]))
        push!(parts, s)
        i += 2
        k += 1
    end
    return join(parts, "  ")
end

const REASON_TEXT = Dict(:line => "3 つ並んだ", :repetition => "同一局面 3 回", :max_plies => "手数上限",
                         :no_moves => "合法手なし", :quit => "中断")

function result_text(winner::Symbol, reason::Symbol)
    reason === :quit && return "中断しました"
    winner in (:black, :white) && return "$(color_name(winner))の勝ち（$(REASON_TEXT[reason])）"
    return "引分け（$(REASON_TEXT[reason])）"
end

# ---------------------------------------------------------------------------
# 対局
# ---------------------------------------------------------------------------

"""
    run_interactive(black, white; start, table, input, output, max_plies = 1000) -> GameResult

1 局を進める。`black` / `white` は `AbstractAgent` か `:human`。人間の手は `input` から 1 行ずつ読む:

- `b1-b4` 形式の指し手
- `hint` — 各合法手の値（勝ち/負け/引分けと手数）の一覧（`table` が要る）
- `undo` — 直前の自分の手まで戻す（相手がエージェントならその応手ごと）
- `help` — 入力の説明
- `quit`（または入力の終わり）— 中断（結果の `reason == :quit`、`winner == :none`）
"""
function run_interactive(black, white; start::Position = initial_position(), table = nothing,
                         input::IO = stdin, output::IO = stdout, max_plies::Integer = 1000)
    history = Position[start]
    moves = Move[]
    is_human(p) = (p.black_to_move ? black : white) === :human
    finish(w, r) = begin
        println(output, "結果: ", result_text(w, r))
        isempty(moves) || println(output, "棋譜: ", format_record(start, moves))
        GameResult(w, r, length(moves), copy(moves), start, history[end])
    end
    shown = 0   # 最後に盤を表示したときの履歴の長さ（同じ局面を何度も描かない）
    while true
        p = history[end]
        if shown != length(history)
            println(output)
            print(output, render_board(p))
            shown = length(history)
        end
        o = game_outcome(history)
        o === nothing || return finish(o[1], o[2])
        length(moves) >= max_plies && return finish(:draw, :max_plies)
        agent = p.black_to_move ? black : white
        if agent !== :human
            m = choose_move(agent, p, history)
            println(output, side_name(p), ": ", format_move(m))
            push!(moves, m)
            push!(history, apply_move(p, m))
            continue
        end
        print(output, side_name(p), " の手（例 b1-b4 / hint / undo / quit）> ")
        if eof(input)
            println(output)
            return finish(:none, :quit)
        end
        cmd = strip(readline(input))
        println(output, cmd)   # 入力をそのまま残す（モックした入力でも記録が読めるように）
        if isempty(cmd)
            continue
        elseif cmd in ("quit", "q", "exit")
            return finish(:none, :quit)
        elseif cmd in ("help", "?")
            println(output, "指し手は b1-b4 のように「元のマス-止まるマス」で入力する。駒は止まるまで滑る。")
            println(output, "hint: 各合法手の値 / undo: 1 手戻す / quit: 中断")
        elseif cmd == "hint"
            if table === nothing
                println(output, "hint には強解決の表が要ります")
            else
                v, d = lookup(table, p)
                println(output, "この局面は", side_name(p), "から見て ", describe(v, d))
                print_evaluations(output, table, p)
            end
        elseif cmd == "undo"
            if length(history) == 1
                println(output, "これ以上戻せません")
                continue
            end
            pop!(history); pop!(moves)
            while length(history) > 1 && !is_human(history[end])
                pop!(history); pop!(moves)
            end
            shown = 0
            println(output, "戻しました（", length(moves), " 手目の後）")
        else
            m = try
                parse_move(cmd)
            catch e
                e isa ArgumentError || rethrow()
                println(output, "読めません: ", repr(cmd), "（b1-b4 の形式で入力）")
                continue
            end
            if !(m in legal_moves(p))
                println(output, "合法手ではありません: ", format_move(m), "（駒は止まるまで滑る。hint で一覧）")
                continue
            end
            push!(moves, m)
            push!(history, apply_move(p, m))
        end
    end
end

"""
    run_matches(io, black, white, n; start, max_plies = 1000) -> NamedTuple

エージェント同士で `n` 局指し、黒勝ち・白勝ち・引分けの数と終局理由の内訳を `io` に書いて返す。
"""
function run_matches(io::IO, black::AbstractAgent, white::AbstractAgent, n::Integer;
                     start::Position = initial_position(), max_plies::Integer = 1000)
    nb = nw = nd = 0
    reasons = Dict{Symbol,Int}()
    total_plies = 0
    t0 = time()
    for _ in 1:n
        r = play_game(black, white; start = start, max_plies = max_plies, record = false)
        r.winner === :black ? (nb += 1) : r.winner === :white ? (nw += 1) : (nd += 1)
        reasons[r.reason] = get(reasons, r.reason, 0) + 1
        total_plies += r.plies
    end
    elapsed = time() - t0
    pct(k) = string(round(100k / max(n, 1), digits = 1), "%")
    println(io, "黒 ", black, " 対 白 ", white, "（", n, " 局、開始 ", format_position(start), "）")
    println(io, "  黒の勝ち: ", nb, "（", pct(nb), "）")
    println(io, "  白の勝ち: ", nw, "（", pct(nw), "）")
    println(io, "  引分け  : ", nd, "（", pct(nd), "）")
    println(io, "  終局理由: ", join(["$(REASON_TEXT[k]) $v" for (k, v) in sort(collect(reasons))], " / "))
    println(io, "  平均手数: ", round(total_plies / max(n, 1), digits = 1), " ply、所要 ",
            round(elapsed, digits = 1), " 秒")
    return (black = nb, white = nw, draw = nd, reasons = reasons, mean_plies = total_plies / max(n, 1))
end

"黒と白に別の種を配る"
side_seed(seed, k) = seed === nothing ? nothing : seed + k

function main(args = ARGS; input::IO = stdin, output::IO = stdout)
    o = try
        parse_args(args)
    catch e
        e isa ArgumentError || rethrow()
        println(stderr, "エラー: ", e.msg)
        print(stderr, USAGE)
        return 1
    end
    if o.help
        print(output, USAGE)
        return 0
    end
    if o.analyze !== nothing
        analyze(output, obtain_table(o.table, output), o.analyze)
        return 0
    end
    table = (needs_table(o.black) || needs_table(o.white)) ? obtain_table(o.table, output) : nothing
    start = o.position === nothing ? initial_position() : parse_position(o.position)
    black = make_agent(o.black, table, side_seed(o.seed, 0))
    white = make_agent(o.white, table, side_seed(o.seed, 1))
    if o.games > 0
        run_matches(output, black, white, o.games; start = start, max_plies = o.max_plies)
    else
        println(output, "黒 ", black === :human ? "人間" : black, " 対 白 ", white === :human ? "人間" : white)
        run_interactive(black, white; start = start, table = table, input = input, output = output,
                        max_plies = o.max_plies)
    end
    return 0
end

end # module PlayCLI

if abspath(PROGRAM_FILE) == @__FILE__
    exit(PlayCLI.main(ARGS))
end
