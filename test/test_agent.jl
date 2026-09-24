# 対戦エージェント・対局進行・CLI のテスト。TABLE は test_solve.jl で計算済み

# CLI（scripts/play.jl）は `PlayCLI` モジュールとして読み込み、入出力を IOBuffer で差し替えて試す
include(joinpath(@__DIR__, "..", "scripts", "play.jl"))
include(joinpath(@__DIR__, "..", "scripts", "tournament.jl"))

"局面文字列を行ごとに書くための補助（a1..e1 / a2..e2 / … / a5..e5 の順に 5 文字ずつ）"
pos(side, rows...) = parse_position(string(side, ":", rows...))

"手番側が 1 手で並べる手の一覧"
winning_moves(p) = [m for m in legal_moves(p) if NT.winner(apply_move(p, m)) !== nothing]

"手番を相手に渡した局面（相手の 1 手勝ちを調べるため）"
pass(p) = Position(p.black, p.white, !p.black_to_move)

"決められた手順を順に指すだけのエージェント（反復の試験用）"
mutable struct ScriptedAgent <: NT.AbstractAgent
    moves::Vector{Move}
    k::Int
end
ScriptedAgent(strs::AbstractString...) = ScriptedAgent([NT.parse_move(s) for s in strs], 0)
function NT.choose_move(a::ScriptedAgent, p::Position, history)
    a.k += 1
    return a.moves[mod1(a.k, length(a.moves))]
end

# 1 手勝ちがある局面（黒番、e1-c1 で a1-b1-c1 が並ぶ）
const P_WIN1 = pos('B', "BB..B", ".....", ".....", ".....", "WW.W.")

# 往復で同一局面を繰り返せる局面: 黒 a1 は c1 に止められて b1 と往復、白 a5 も c5 で同様
const P_SHUFFLE = pos('B', "B.B..", ".....", "....B", ".....", "W.W.W")

@testset "game_outcome: 並び・3 回反復・継続" begin
    p0 = initial_position()
    @test NT.game_outcome([p0]) === nothing
    # 白が並んだ直後（黒番）なら白の勝ち
    pl = pos('B', "BB...", "....B", ".....", ".....", "WWW..")
    @test NT.game_outcome([pl]) == (:white, :line)
    # 同一局面（手番込み）が 3 回現れたら引分け。2 回では続行
    a = apply_move(P_SHUFFLE, NT.parse_move("a1-b1"))
    @test NT.game_outcome([P_SHUFFLE, a, P_SHUFFLE]) === nothing
    @test NT.game_outcome([P_SHUFFLE, a, P_SHUFFLE, a, P_SHUFFLE]) == (:draw, :repetition)
    # 配置が同じでも手番が違えば別の局面として数える
    q = pass(P_SHUFFLE)
    @test NT.game_outcome([P_SHUFFLE, q, P_SHUFFLE, q]) === nothing
end

@testset "play_game: 同一局面 3 回で引分け" begin
    b = ScriptedAgent("a1-b1", "b1-a1")
    w = ScriptedAgent("a5-b5", "b5-a5")
    r = NT.play_game(b, w; start = P_SHUFFLE, max_plies = 100)
    # 開始局面が 4 手目・8 手目に再現し、8 手目で 3 回目
    @test r.winner === :draw
    @test r.reason === :repetition
    @test r.plies == 8
    @test length(r.moves) == 8
    @test NT.format_move.(r.moves[1:4]) == ["a1-b1", "a5-b5", "b1-a1", "b5-a5"]
    @test r.start == P_SHUFFLE
    @test r.final == P_SHUFFLE
    # record=false でも結果は同じで、棋譜だけ残さない
    r2 = NT.play_game(ScriptedAgent("a1-b1", "b1-a1"), ScriptedAgent("a5-b5", "b5-a5");
                      start = P_SHUFFLE, record = false)
    @test (r2.winner, r2.reason, r2.plies) == (:draw, :repetition, 8)
    @test isempty(r2.moves)
end

@testset "play_game: 手数上限と並び" begin
    r = NT.play_game(RandomAgent(MersenneTwister(1)), RandomAgent(MersenneTwister(2)); max_plies = 0)
    @test (r.winner, r.reason, r.plies) == (:draw, :max_plies, 0)
    # 1 手勝ちの局面から黒が並べて終わる
    r = NT.play_game(ScriptedAgent("e1-c1"), RandomAgent(MersenneTwister(3)); start = P_WIN1)
    @test (r.winner, r.reason, r.plies) == (:black, :line, 1)
    # 既に終局している局面から始めれば 0 手で終わる
    pl = pos('B', "BB...", "....B", ".....", ".....", "WWW..")
    r = NT.play_game(RandomAgent(), RandomAgent(); start = pl)
    @test (r.winner, r.reason, r.plies) == (:white, :line, 0)
    # エージェントが非合法手を返したら対局を進めない
    @test_throws ArgumentError NT.play_game(ScriptedAgent("a1-a5"), RandomAgent(); start = P_WIN1)
end

@testset "RandomAgent: 合法手から選ぶ・seed で再現する" begin
    p0 = initial_position()
    rng = MersenneTwister(11)
    a = RandomAgent(rng)
    picks = [choose_move(a, p0, [p0]) for _ in 1:500]
    @test all(in(legal_moves(p0)), picks)
    @test length(unique(picks)) == length(legal_moves(p0))   # 14 手すべてが出る
    r1 = NT.play_game(RandomAgent(MersenneTwister(5)), RandomAgent(MersenneTwister(6)))
    r2 = NT.play_game(RandomAgent(MersenneTwister(5)), RandomAgent(MersenneTwister(6)))
    @test r1.moves == r2.moves
end

@testset "PerfectAgent: 表の最善手を選ぶ" begin
    rng = MersenneTwister(21)
    a = PerfectAgent(TABLE)
    ar = PerfectAgent(TABLE; rng = MersenneTwister(22))
    for _ in 1:2_000
        p = NT.position_from_index(rand(rng, 1:NT.NSTATES), rand(rng, Bool))
        NT.is_terminal(p) && continue
        bm = best_moves(TABLE, p)
        isempty(bm) && continue
        @test choose_move(a, p, [p]) == bm[1]        # 乱数なしなら先頭（決定的）
        @test choose_move(ar, p, [p]) in bm
    end
    # 乱数ありなら同点手の中からばらける
    p0 = initial_position()
    @test length(best_moves(TABLE, p0)) > 1
    @test length(unique(choose_move(ar, p0, [p0]) for _ in 1:200)) > 1
    # seed を同じにすれば同じ選び方になる
    a1, a2 = PerfectAgent(TABLE; rng = MersenneTwister(9)), PerfectAgent(TABLE; rng = MersenneTwister(9))
    @test [choose_move(a1, p0, [p0]) for _ in 1:20] == [choose_move(a2, p0, [p0]) for _ in 1:20]
    # 終局済みの局面では指せない
    pl = pos('B', "BB...", "....B", ".....", ".....", "WWW..")
    @test_throws ArgumentError choose_move(a, pl, [pl])
end

@testset "PerfectAgent 同士: 初期局面から反復で引分け" begin
    r = NT.play_game(PerfectAgent(TABLE), PerfectAgent(TABLE); max_plies = 1_000)
    @test (r.winner, r.reason) == (:draw, :repetition)
    # 途中の局面はすべて表の上で引分け（どちらも一度も誤らない）
    p = r.start
    for m in r.moves
        @test lookup(TABLE, p)[1] === :draw
        p = apply_move(p, m)
    end
    # 同点手を乱数で選んでも引分けのまま（反復か手数上限）
    for s in 1:5
        r = NT.play_game(PerfectAgent(TABLE; rng = MersenneTwister(s)),
                         PerfectAgent(TABLE; rng = MersenneTwister(100 + s)); max_plies = 2_000)
        @test r.winner === :draw
    end
end

@testset "PerfectAgent は RandomAgent に負けない（多数対局）" begin
    results = Symbol[]
    for s in 1:40
        rb = NT.play_game(PerfectAgent(TABLE; rng = MersenneTwister(s)), RandomAgent(MersenneTwister(1000 + s));
                          max_plies = 400, record = false)
        rw = NT.play_game(RandomAgent(MersenneTwister(2000 + s)), PerfectAgent(TABLE; rng = MersenneTwister(s));
                          max_plies = 400, record = false)
        @test rb.winner !== :white
        @test rw.winner !== :black
        push!(results, rb.winner, rw.winner === :white ? :black : rw.winner === :black ? :white : :draw)
    end
    # 完全なエージェントは無作為な相手を実際に倒す（引分けばかりではない）
    @test count(==(:black), results) >= 70
end

@testset "PerfectAgent: 勝ちの局面から表の距離どおりに勝つ" begin
    # 最長の勝ち局面を含め、距離の違う勝ち局面をいくつか試す
    imax = argmax(i -> TABLE.value[i] == NT.VAL_WIN ? Int(TABLE.dist[i]) : -1, 1:NT.NSTATES)
    rng = MersenneTwister(31)
    allwins = findall(==(NT.VAL_WIN), TABLE.value)
    cands = [imax; rand(rng, allwins, 30)]
    for i in cands, black in (true, false)
        p = NT.position_from_index(i, black)
        v, d = lookup(TABLE, p)
        @test v === :win
        me = black ? :black : :white
        pa, pb = PerfectAgent(TABLE), PerfectAgent(TABLE)
        r = black ? NT.play_game(pa, pb; start = p) : NT.play_game(pb, pa; start = p)
        @test (r.winner, r.reason, r.plies) == (me, :line, d)
        # 相手が無作為でも勝ち、距離より長くはかからない
        ra = black ? NT.play_game(pa, RandomAgent(MersenneTwister(i)); start = p) :
                     NT.play_game(RandomAgent(MersenneTwister(i)), pa; start = p)
        @test ra.winner === me
        @test ra.plies <= d
    end
end

@testset "AlphaBetaAgent: 1 手勝ちを逃さない" begin
    for depth in (1, 2, 4)
        a = AlphaBetaAgent(depth)
        m = choose_move(a, P_WIN1, [P_WIN1])
        @test NT.winner(apply_move(P_WIN1, m)) === :black
    end
    # 表で 1 手勝ちの局面を無作為に拾い、深さ 2 で必ず並べる
    rng = MersenneTwister(41)
    wins1 = findall(i -> TABLE.value[i] == NT.VAL_WIN && TABLE.dist[i] == 1, 1:NT.NSTATES)
    a = AlphaBetaAgent(2)
    for _ in 1:300
        p = NT.position_from_index(rand(rng, wins1), rand(rng, Bool))
        @test NT.is_terminal(apply_move(p, choose_move(a, p, [p])))
    end
end

@testset "AlphaBetaAgent: 相手の 1 手勝ちを防ぐ" begin
    # 黒番。白は c3-c5 で a5-b5-c5 が並ぶ。黒に 1 手勝ちは無く、防ぐ手は限られる
    p = pos('B', "B...B", "....B", "..W..", ".....", "WW...")
    @test isempty(winning_moves(p))
    @test !isempty(winning_moves(pass(p)))
    blocks = [m for m in legal_moves(p) if isempty(winning_moves(apply_move(p, m)))]
    @test 0 < length(blocks) < length(legal_moves(p))
    for depth in (2, 3, 4)
        m = choose_move(AlphaBetaAgent(depth), p, [p])
        @test m in blocks
    end
    # 表の上で「防げる」局面（負け 1 手でない子が残る局面）を無作為に拾い、深さ 2 で 1 手負けの手を指さない
    rng = MersenneTwister(51)
    a = AlphaBetaAgent(2)
    tested = 0
    while tested < 200
        q = NT.position_from_index(rand(rng, 1:NT.NSTATES), rand(rng, Bool))
        NT.state_kind(NT.mover_bits(q)...) === :interior || continue
        isempty(winning_moves(q)) || continue
        threat = !isempty(winning_moves(pass(q)))
        safe = [m for m in legal_moves(q) if isempty(winning_moves(apply_move(q, m)))]
        (threat && !isempty(safe)) || continue
        tested += 1
        @test choose_move(a, q, [q]) in safe
    end
end

@testset "AlphaBetaAgent: 引数と探索の統計" begin
    @test_throws ArgumentError AlphaBetaAgent(0)
    a = AlphaBetaAgent(3)
    p0 = initial_position()
    @test choose_move(a, p0, [p0]) in legal_moves(p0)
    @test a.nodes > 0
    # 評価関数を差し替えられる（常に 0 なら先頭の手 = 決定的）
    z = AlphaBetaAgent(1; eval = (me, opp) -> 0)
    @test choose_move(z, p0, [p0]) == legal_moves(p0)[1]
    # 深いほうが強い: 深さ 4 は無作為に負けない（seed 固定の少数対局）
    for s in 1:5
        r = NT.play_game(AlphaBetaAgent(4; rng = MersenneTwister(s)), RandomAgent(MersenneTwister(s));
                         max_plies = 200, record = false)
        @test r.winner !== :white
    end
end

# ---------------------------------------------------------------------------
# CLI（scripts/play.jl）
# ---------------------------------------------------------------------------

@testset "CLI: 引数の解釈" begin
    o = PlayCLI.parse_args(String[])
    @test o.black == "human" && o.white == "perfect"
    @test o.games == 0 && o.seed === nothing && o.position === nothing && o.analyze === nothing
    o = PlayCLI.parse_args(["--black", "alphabeta:6", "--white", "random", "--games", "20", "--seed", "7",
                            "--table", "x.bin", "--position", NT.INITIAL_POSITION_STRING, "--max-plies", "50"])
    @test (o.black, o.white, o.games, o.seed, o.table, o.max_plies) == ("alphabeta:6", "random", 20, 7, "x.bin", 50)
    @test o.position == NT.INITIAL_POSITION_STRING
    o = PlayCLI.parse_args(["--analyze", NT.INITIAL_POSITION_STRING])
    @test o.analyze == NT.INITIAL_POSITION_STRING
    @test_throws ArgumentError PlayCLI.parse_args(["--games"])
    @test_throws ArgumentError PlayCLI.parse_args(["--bogus"])
    @test_throws ArgumentError PlayCLI.parse_args(["--black", "genius"])
    @test_throws ArgumentError PlayCLI.parse_args(["--games", "5", "--black", "human"])
end

@testset "CLI: エージェント指定の解釈" begin
    @test PlayCLI.make_agent("random", nothing, 1) isa RandomAgent
    @test PlayCLI.make_agent("perfect", TABLE, 1) isa PerfectAgent
    a = PlayCLI.make_agent("alphabeta", nothing, 1)
    @test a isa AlphaBetaAgent && a.depth == 4
    @test PlayCLI.make_agent("alphabeta:6", nothing, 1).depth == 6
    @test PlayCLI.make_agent("human", nothing, 1) === :human
    @test_throws ArgumentError PlayCLI.make_agent("alphabeta:x", nothing, 1)
    @test_throws ArgumentError PlayCLI.make_agent("perfect", nothing, 1)   # 表が要る
    @test PlayCLI.needs_table("perfect") && PlayCLI.needs_table("human")
    @test !PlayCLI.needs_table("random") && !PlayCLI.needs_table("alphabeta:2")
end

@testset "CLI: 盤の表示" begin
    s = PlayCLI.render_board(initial_position())
    lines = split(chomp(s), '\n')
    # 行 5 が上、列 a〜e が下
    @test startswith(lines[1], "5")
    @test occursin(". W . W .", lines[1])
    @test occursin(". . B . .", lines[2])
    @test occursin(". . W . .", lines[4])
    @test occursin(". B . B .", lines[5])
    @test occursin("a b c d e", lines[end])
end

@testset "CLI: 指し手の評価（hint / analyze）" begin
    ev = PlayCLI.evaluate_moves(TABLE, P_WIN1)
    @test length(ev) == length(legal_moves(P_WIN1))
    e = only(filter(x -> x.move == NT.parse_move("e1-c1"), ev))
    @test (e.value, e.plies) == (:win, 1)
    # 並びは 勝ち（短い順）→ 引分け → 負け（長い順）
    order = Dict(:win => 0, :draw => 1, :loss => 2)
    @test issorted(ev; by = x -> (order[x.value], x.value === :loss ? -x.plies : x.plies))
    @test PlayCLI.describe(:win, 1) == "勝ち（1 手）"
    @test PlayCLI.describe(:draw, -1) == "引分け"

    io = IOBuffer()
    PlayCLI.analyze(io, TABLE, format_position(P_WIN1))
    out = String(take!(io))
    @test occursin("勝ち（1 手）", out)
    @test occursin("e1-c1", out)
    @test occursin("黒番", out)
end

@testset "CLI: 人間の対局（標準入力をモック）" begin
    # hint・不正入力・undo を経て e1-c1 で勝つ。白は乱数だが、黒の最初の手の前に undo しても戻れない
    input = IOBuffer("hint\nfoo\na1-a5\nundo\ne1-c1\n")
    output = IOBuffer()
    r = PlayCLI.run_interactive(:human, RandomAgent(MersenneTwister(1)); start = P_WIN1, table = TABLE,
                                input = input, output = output)
    out = String(take!(output))
    @test (r.winner, r.reason, r.plies) == (:black, :line, 1)
    @test occursin("勝ち（1 手）", out)            # hint の一覧
    @test occursin("読めません", out)             # foo
    @test occursin("合法手ではありません", out)   # a1-a5
    @test occursin("戻せません", out)             # 最初の局面での undo
    @test occursin("黒の勝ち", out)

    # undo は相手の応手ごと戻す（人間 vs エージェント）
    input = IOBuffer("a1-a4\nundo\ne1-c1\n")
    output = IOBuffer()
    r = PlayCLI.run_interactive(:human, ScriptedAgent("b5-b2"); start = P_WIN1, table = TABLE,
                                input = input, output = output)
    @test (r.winner, r.plies) == (:black, 1)
    @test NT.format_move.(r.moves) == ["e1-c1"]

    # quit と入力の終わり（EOF）は中断
    r = PlayCLI.run_interactive(:human, :human; start = P_WIN1, table = TABLE,
                                input = IOBuffer("quit\n"), output = IOBuffer())
    @test r.reason === :quit
    r = PlayCLI.run_interactive(:human, :human; start = P_WIN1, table = TABLE,
                                input = IOBuffer(""), output = IOBuffer())
    @test r.reason === :quit

    # エージェント同士でも同じループで最後まで進む
    output = IOBuffer()
    r = PlayCLI.run_interactive(PerfectAgent(TABLE), PerfectAgent(TABLE); start = P_WIN1, table = TABLE,
                                input = IOBuffer(""), output = output)
    @test (r.winner, r.reason) == (:black, :line)
    @test occursin("e1-c1", String(take!(output)))
end

@testset "CLI: 多数対局の集計" begin
    io = IOBuffer()
    s = PlayCLI.run_matches(io, PerfectAgent(TABLE; rng = MersenneTwister(2)), RandomAgent(MersenneTwister(3)), 6;
                            start = initial_position(), max_plies = 400)
    @test s.black + s.white + s.draw == 6
    @test s.white == 0
    out = String(take!(io))
    @test occursin("黒の勝ち", out)
end

@testset "総当たり（scripts/tournament.jl）" begin
    specs = ["perfect", "alphabeta:2", "random"]
    res = Tournament.round_robin(specs, TABLE, 3; seed = 1, max_plies = 200)
    n = length(specs)
    @test size(res.win) == size(res.draw) == size(res.loss) == (n, n)
    for i in 1:n, j in 1:n
        i == j && continue
        @test res.win[i, j] + res.draw[i, j] + res.loss[i, j] == 6   # 先手 3 局 + 後手 3 局
        @test res.win[i, j] == res.loss[j, i]
        @test res.draw[i, j] == res.draw[j, i]
    end
    @test all(res.loss[1, j] == 0 for j in 2:n)   # 完全なエージェントは負けない
    # 同じ種なら同じ結果
    res2 = Tournament.round_robin(specs, TABLE, 3; seed = 1, max_plies = 200)
    @test res2.win == res.win && res2.draw == res.draw
    io = IOBuffer()
    Tournament.print_table(io, res)
    out = String(take!(io))
    @test occursin("| perfect", out)
    @test occursin("alphabeta:2", out)
end
