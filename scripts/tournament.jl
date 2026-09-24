# エージェントの総当たり戦。各組み合わせで先手・後手を N 局ずつ指し、勝ち-引分け-負けの表を出す。
#
# 実行（リポジトリ直下で）:
#   docker run --rm -v "$PWD":/work -w /work julia:1.11 julia --project=. scripts/tournament.jl [オプション]
#
#   --agents LIST     カンマ区切りのエージェント（既定 perfect,alphabeta:2,alphabeta:4,alphabeta:6,random）
#   --games N         1 組み合わせ・片方の色あたりの局数（既定 50。1 組で 2N 局）
#   --seed N          乱数の種（既定 1）
#   --max-plies N     手数の上限（既定 300。超えたら引分け）
#   --table PATH      強解決の表（既定 data/neutreeko_table.bin。無ければ解いて保存する）
#
# 対局はすべて初期局面から。同点手は各エージェントが種付きの乱数で選ぶので、同じ組でも棋譜はばらける。

isdefined(@__MODULE__, :PlayCLI) || include(joinpath(@__DIR__, "play.jl"))

module Tournament

using Neutreeko
using ..PlayCLI: make_agent, needs_table, obtain_table, split_spec, DEFAULT_TABLE

const DEFAULT_AGENTS = ["perfect", "alphabeta:2", "alphabeta:4", "alphabeta:6", "random"]

"組み合わせ (i, j)・色・局番号ごとに異なる種"
game_seed(seed, i, j, color, g) = seed * 1_000_000 + i * 100_000 + j * 10_000 + color * 5_000 + g

"""
    round_robin(specs, table, games_per_color; seed = 1, max_plies = 300) -> NamedTuple

`specs` の全組 (i ≠ j) で、i が黒・j が白の対局と、i が白・j が黒の対局を `games_per_color` 局ずつ行う。

返り値の `win[i, j]` / `draw[i, j]` / `loss[i, j]` は i から見た j との対戦成績（2 色の合計）。
`plies[i, j]` は i 対 j の総手数、`seconds[i]` は i が手を選ぶのに使った時間の合計、`moves[i]` は i が指した手数。
"""
function round_robin(specs::AbstractVector{<:AbstractString}, table, games_per_color::Integer;
                     seed::Integer = 1, max_plies::Integer = 300)
    n = length(specs)
    win = zeros(Int, n, n)
    draw = zeros(Int, n, n)
    loss = zeros(Int, n, n)
    plies = zeros(Int, n, n)
    seconds = zeros(n)
    moves = zeros(Int, n)
    for i in 1:n, j in 1:n
        i == j && continue
        # i が黒、j が白（i 対 j の成績は、j 対 i を数えるときに逆向きで足す）
        for g in 1:games_per_color
            b = Timed(make_agent(specs[i], table, game_seed(seed, i, j, 0, g)))
            w = Timed(make_agent(specs[j], table, game_seed(seed, i, j, 1, g)))
            r = play_game(b, w; max_plies = max_plies, record = false)
            if r.winner === :black
                win[i, j] += 1; loss[j, i] += 1
            elseif r.winner === :white
                loss[i, j] += 1; win[j, i] += 1
            else
                draw[i, j] += 1; draw[j, i] += 1
            end
            plies[i, j] += r.plies
            plies[j, i] += r.plies
            seconds[i] += b.seconds; moves[i] += b.moves
            seconds[j] += w.seconds; moves[j] += w.moves
        end
    end
    return (specs = collect(String, specs), games_per_color = games_per_color, win = win, draw = draw,
            loss = loss, plies = plies, seconds = seconds, moves = moves, seed = seed, max_plies = max_plies)
end

"手を選ぶ時間を計るための包み"
mutable struct Timed{A<:AbstractAgent} <: AbstractAgent
    agent::A
    seconds::Float64
    moves::Int
end
Timed(a::AbstractAgent) = Timed(a, 0.0, 0)

function Neutreeko.choose_move(t::Timed, p::Position, history)
    t0 = time_ns()
    m = choose_move(t.agent, p, history)
    t.seconds += (time_ns() - t0) / 1e9
    t.moves += 1
    return m
end

"""
    print_table(io, res)

`round_robin` の結果を Markdown の表で書く。セルは「勝-分-負」、右端は全対戦の合計と得点率
（勝ち 1・引分け 0.5）。続けて、1 手あたりの思考時間の表を書く。
"""
function print_table(io::IO, res)
    s = res.specs
    n = length(s)
    ng = 2 * res.games_per_color
    println(io, "各セルは行のエージェントから見た 勝-分-負（先手 ", res.games_per_color, " 局 + 後手 ",
            res.games_per_color, " 局 = ", ng, " 局）。初期局面から、手数上限 ", res.max_plies,
            " ply、seed ", res.seed, "。")
    println(io)
    println(io, "| 行 ＼ 列 | ", join(s, " | "), " | 合計 勝-分-負 | 得点率 |")
    println(io, "|---|", repeat("---|", n), "---|---|")
    for i in 1:n
        cells = [i == j ? "—" : "$(res.win[i, j])-$(res.draw[i, j])-$(res.loss[i, j])" for j in 1:n]
        w, d, l = sum(res.win[i, :]), sum(res.draw[i, :]), sum(res.loss[i, :])
        rate = (w + d / 2) / max(w + d + l, 1)
        println(io, "| ", s[i], " | ", join(cells, " | "), " | $w-$d-$l | ", round(100rate, digits = 1), "% |")
    end
    println(io)
    println(io, "| エージェント | 指した手数 | 1 手あたりの思考時間 |")
    println(io, "|---|---|---|")
    for i in 1:n
        per = res.moves[i] == 0 ? 0.0 : res.seconds[i] / res.moves[i]
        println(io, "| ", s[i], " | ", res.moves[i], " | ", round(per * 1e3, digits = 3), " ms |")
    end
end

function main(args = ARGS; io::IO = stdout)
    agents = DEFAULT_AGENTS
    games, seed, max_plies, table_path = 50, 1, 300, DEFAULT_TABLE
    i = 1
    while i <= length(args)
        a = args[i]
        i < length(args) || throw(ArgumentError("$a には値が要る"))
        v = args[i+1]
        a == "--agents" ? (agents = String.(split(v, ','))) :
        a == "--games" ? (games = parse(Int, v)) :
        a == "--seed" ? (seed = parse(Int, v)) :
        a == "--max-plies" ? (max_plies = parse(Int, v)) :
        a == "--table" ? (table_path = v) :
        throw(ArgumentError("不明なオプション: $(repr(a))"))
        i += 2
    end
    foreach(split_spec, agents)   # 指定の検査
    any(==("human"), agents) && throw(ArgumentError("総当たりに human は入れられない"))
    table = any(needs_table, agents) ? obtain_table(table_path, io) : nothing
    t0 = time()
    res = round_robin(agents, table, games; seed = seed, max_plies = max_plies)
    print_table(io, res)
    println(io)
    println(io, "所要 ", round(time() - t0, digits = 1), " 秒")
    return 0
end

end # module Tournament

if abspath(PROGRAM_FILE) == @__FILE__
    exit(Tournament.main(ARGS))
end
