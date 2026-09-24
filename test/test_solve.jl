# 後退解析・不動点反復・表の保存・対称性・最善手のテスト
#
# 全体解は重いので 1 回だけ計算して以下のテストで共有する。

const TABLE = @time "後退解析 solve()" solve()

@testset "表の基本形" begin
    @test TABLE isa NT.SolveTable
    @test length(TABLE.value) == NT.NSTATES
    @test length(TABLE.dist) == NT.NSTATES
    @test TABLE.no_move_rule == :draw
    @test_throws ArgumentError solve(no_move_rule = :pass)
end

@testset "終局・無効局面の値" begin
    for i in 1:NT.NSTATES
        me, opp = NT.unrank_state(i)
        k = NT.state_kind(me, opp)
        v, d = TABLE.value[i], TABLE.dist[i]
        if k == :loss0
            (v == NT.VAL_LOSS && d == 0) || (@test (i, v, d) == (i, NT.VAL_LOSS, 0); break)
        elseif k == :invalid
            v == NT.VAL_INVALID || (@test (i, v) == (i, NT.VAL_INVALID); break)
        end
    end
    @test count(==(NT.VAL_INVALID), TABLE.value) == 72_436 + 1_484
end

@testset "距離の偶奇: 勝ち=奇数、負け=偶数" begin
    odd_win = all(isodd(TABLE.dist[i]) for i in 1:NT.NSTATES if TABLE.value[i] == NT.VAL_WIN)
    even_loss = all(iseven(TABLE.dist[i]) for i in 1:NT.NSTATES if TABLE.value[i] == NT.VAL_LOSS)
    @test odd_win
    @test even_loss
end

@testset "局所整合: 各局面の値と距離が子から再計算した値に一致（全数）" begin
    bad = 0
    for i in 1:NT.NSTATES
        me, opp = NT.unrank_state(i)
        NT.state_kind(me, opp) == :interior || continue
        v, d = NT.minimax_from_children(TABLE.value, TABLE.dist, me, opp, TABLE.no_move_rule)
        if (v, d) != (TABLE.value[i], TABLE.dist[i])
            bad += 1
            bad <= 3 && @info "局所整合の失敗" i v d TABLE.value[i] TABLE.dist[i]
        end
    end
    @test bad == 0
end

@testset "前向き不動点反復と全局面一致" begin
    t2 = @time "不動点反復 solve_fixpoint()" NT.solve_fixpoint()
    @test t2.value == TABLE.value
    @test t2.dist == TABLE.dist
end

@testset "8 通りの盤面対称で値と距離が不変" begin
    @test length(NT.SYMMETRIES) == 8
    # 対称変換はマスの置換で、恒等変換を含み、勝ち筋の集合を保つ
    @test NT.SYMMETRIES[1] == collect(0:24)
    @test all(sort(s) == collect(0:24) for s in NT.SYMMETRIES)
    @test length(unique(NT.SYMMETRIES)) == 8
    for s in NT.SYMMETRIES
        @test Set(NT.transform_bits(l, s) for l in NT.WIN_LINES) == Set(NT.WIN_LINES)
    end
    @test NT.count_symmetry_violations(TABLE) == 0
    # 検査関数そのものが違反を検出できること（1 局面だけ値を壊した表）
    broken = NT.SolveTable(copy(TABLE.value), copy(TABLE.dist), TABLE.no_move_rule)
    ibroken = findfirst(i -> broken.value[i] == NT.VAL_WIN &&
                             NT.transform_index(i, NT.SYMMETRIES[2]) != i, 1:NT.NSTATES)
    broken.dist[ibroken] += 0x02
    @test NT.count_symmetry_violations(broken) > 0
    # 対称類の数: Burnside の補題（固定点の平均）と、代表元を数える方法の一致
    classes = NT.symmetry_class_count()
    fixed = sum(NT.count_fixed_states(s) for s in NT.SYMMETRIES)
    @test fixed % 8 == 0
    @test classes == fixed ÷ 8
end

@testset "保存と読込" begin
    mktempdir() do dir
        path = joinpath(dir, "table.bin")
        save_table(path, TABLE)
        t = load_table(path)
        @test t.value == TABLE.value
        @test t.dist == TABLE.dist
        @test t.no_move_rule == TABLE.no_move_rule
        # 壊れたファイルは拒否する
        open(path, "w") do io
            write(io, "garbage")
        end
        @test_throws ErrorException load_table(path)
    end
end

@testset "lookup と best_moves" begin
    p0 = initial_position()
    v0, d0 = lookup(TABLE, p0)
    @test v0 in (:win, :loss, :draw)
    # 終局局面
    pl = parse_position("W:" * "BBB.." * "....." * "....." * "....." * "WW.W.")
    @test lookup(TABLE, pl) == (:loss, 0)
    @test isempty(best_moves(TABLE, pl))
    # 手番側がすでに並んでいる局面は無効
    pinv = parse_position("B:" * "BBB.." * "....." * "....." * "....." * "WW.W.")
    @test lookup(TABLE, pinv) == (:invalid, -1)
    # 1 手勝ち: e1 を c1 へ滑らせれば並ぶ
    q = parse_position("B:" * "BB..B" * "....." * "....." * "....." * "WW.W.")
    @test lookup(TABLE, q) == (:win, 1)
    @test NT.parse_move("e1-c1") in best_moves(TABLE, q)

    # 無作為な局面で best_moves の性質を確かめる
    rng = MersenneTwister(7)
    for _ in 1:20_000
        i = rand(rng, 1:NT.NSTATES)
        p = NT.position_from_index(i, rand(rng, Bool))
        v, d = lookup(TABLE, p)
        bm = best_moves(TABLE, p)
        childs = [lookup(TABLE, apply_move(p, m)) for m in bm]
        if v == :win
            @test !isempty(bm) && all(c -> c == (:loss, d - 1), childs)
        elseif v == :loss && d > 0
            @test !isempty(bm) && all(c -> c == (:win, d - 1), childs)
        elseif v == :draw
            @test all(c -> c[1] == :draw, childs)
            @test isempty(legal_moves(p)) || !isempty(bm)
        else
            @test isempty(bm)
        end
    end
end

@testset "最善手順（勝ちの局面から決着まで）" begin
    q = parse_position("B:" * "BB..B" * "....." * "....." * "....." * "WW.W.")
    pv = NT.principal_variation(TABLE, q)
    @test length(pv) == 1
    # 最長の勝ち局面から、表の距離どおりの手数で決着する
    imax = argmax(i -> TABLE.value[i] == NT.VAL_WIN ? Int(TABLE.dist[i]) : -1, 1:NT.NSTATES)
    p = NT.position_from_index(imax, true)
    pv = NT.principal_variation(TABLE, p)
    @test length(pv) == TABLE.dist[imax]
    for m in pv
        p = apply_move(p, m)
    end
    @test NT.winner(p) == :black
end
