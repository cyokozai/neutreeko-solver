# 組合せ数体系による局面番号と、状態分類・後ろ向き生成の整合のテスト

@testset "局面数" begin
    @test NT.N_ME == binomial(25, 3) == 2300
    @test NT.N_OPP == binomial(22, 3) == 1540
    @test NT.NSTATES == 3_542_000
end

@testset "rank/unrank の往復（全数）" begin
    ok = true
    seen_bad = 0
    for i in 1:NT.NSTATES
        me, opp = NT.unrank_state(i)
        good = count_ones(me) == 3 && count_ones(opp) == 3 && (me & opp) == 0 &&
               (me | opp) & ~NT.FULL_MASK == 0 && NT.rank_state(me, opp) == i
        if !good
            ok = false
            seen_bad += 1
            seen_bad <= 3 && @info "往復失敗" i me opp
        end
    end
    @test ok
    # 番号は 1 始まりで連続（全単射であることは往復と個数の一致から従う）
    @test NT.rank_state(NT.unrank_state(1)...) == 1
    @test NT.rank_state(NT.unrank_state(NT.NSTATES)...) == NT.NSTATES
end

@testset "Position と番号の対応" begin
    p0 = initial_position()
    i = NT.state_index(p0)
    @test 1 <= i <= NT.NSTATES
    @test NT.position_from_index(i, true) == p0
    # 白番の同じ配置は、色を入れ替えた黒番局面と同じ番号（手番側視点の正規化）
    pw = Position(p0.white, p0.black, false)
    @test NT.state_index(pw) == i
end

@testset "状態分類（手番側視点）" begin
    counts = Dict(:interior => 0, :loss0 => 0, :invalid => 0)
    me_only = 0
    both = 0
    for i in 1:NT.NSTATES
        me, opp = NT.unrank_state(i)
        k = NT.state_kind(me, opp)
        counts[k] += 1
        if k == :invalid
            is_win_line(opp) ? (both += 1) : (me_only += 1)
        end
    end
    # 両者とも並びなし / 相手のみ並び / 手番側のみ並び / 両者並び
    @test counts[:interior] == 3_395_644
    @test counts[:loss0] == 72_436
    @test me_only == 72_436
    @test both == 1_484
    @test counts[:invalid] == me_only + both
end

@testset "predecessors と子の整合（無作為抽出）" begin
    rng = MersenneTwister(1)
    nsample = 100_000
    bad_down = 0   # q が p の子なのに p が q の親に無い
    bad_up = 0     # p が q の親なのに q が p の子に無い
    nedges = 0
    for _ in 1:nsample
        i = rand(rng, 1:NT.NSTATES)
        me, opp = NT.unrank_state(i)
        # count_moves は子の列挙数と一致する
        nchild = 0
        # 下向き: 子 c の親集合に i がある
        NT.foreach_child(me, opp) do cme, copp
            nedges += 1
            nchild += 1
            found = false
            NT.foreach_predecessor(cme, copp) do pme, popp
                found |= NT.rank_state(pme, popp) == i
            end
            found || (bad_down += 1)
        end
        nchild == NT.count_moves(me, opp) || (bad_down += 1)
        # 上向き: 親 r の子集合に i がある
        NT.foreach_predecessor(me, opp) do pme, popp
            found = false
            NT.foreach_child(pme, popp) do cme, copp
                found |= NT.rank_state(cme, copp) == i
            end
            found || (bad_up += 1)
        end
    end
    @test nedges > 10 * nsample
    @test bad_down == 0
    @test bad_up == 0
    # 親の個数の総和と子の個数の総和は全体では等しい（辺の数）。抽出でなく全数で確かめる
    total_children = 0
    total_parents = 0
    for i in 1:NT.NSTATES
        me, opp = NT.unrank_state(i)
        total_children += NT.count_moves(me, opp)
        NT.foreach_predecessor((_, _) -> (total_parents += 1), me, opp)
    end
    @test total_children == total_parents
end
