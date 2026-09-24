# 集計（合法手 0 の局面、到達可能性）のテスト。TABLE は test_solve.jl で計算済み

@testset "合法手 0 の局面" begin
    nm = NT.no_move_states()
    # 全数で数えると 0 件（3 駒すべてが全方向に塞がる配置は、相手 3 駒では作れない）
    @test length(nm) == 0
    # 件数 0 なので、扱いを :loss に切り替えても表は変わらない
    tl = solve(no_move_rule = :loss)
    @test tl.no_move_rule == :loss
    @test tl.value == TABLE.value
    @test tl.dist == TABLE.dist
end

@testset "初期局面からの到達可能性" begin
    seen = NT.reachable_from()
    norm = NT.normalize_reachable(seen)
    # 無効局面（手番側が並んでいる）には到達しない
    @test !any(norm[i] && TABLE.value[i] == NT.VAL_INVALID for i in 1:NT.NSTATES)
    # 前向き探索の到達集合と、「どちらも並んでいない直前局面を持つ」局面の数が一致する
    @test count(norm) == NT.count_with_interior_predecessor()
    @test seen[NT.abs_index(NT.state_index(initial_position()), true)]
    # 件数の固定（scripts/solve.jl の出力と同じ値）
    @test count(norm) == 3_467_624
    @test count(seen) == 6_935_248
    # 到達集合は「どちらも並んでいない直前局面を持つ局面」全体と一致し（上の件数一致）、
    # その条件は色の入れ替えで不変なので、黒番と白番で同じ正規化局面の集合になる
    @test all(seen[2i-1] == seen[2i] for i in 1:NT.NSTATES)
end
