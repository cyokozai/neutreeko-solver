# 局面・指し手・文字列表記のテスト

@testset "初期局面と文字列表記" begin
    # b1=1, d1=3, c4=17 が黒 / c2=7, b5=21, d5=23 が白、黒番
    expected = "B:" * ".B.B." * "..W.." * "....." * "..B.." * ".W.W."
    @test expected == "B:.B.B...W.........B...W.W."
    @test NT.INITIAL_POSITION_STRING == expected
    p0 = initial_position()
    @test format_position(p0) == expected
    @test parse_position(expected) == p0
    @test NT.side_to_move(p0) == :black
    @test p0.black == (UInt32(1) << 1) | (UInt32(1) << 3) | (UInt32(1) << 17)
    @test p0.white == (UInt32(1) << 7) | (UInt32(1) << 21) | (UInt32(1) << 23)

    w = "W:" * expected[3:end]
    pw = parse_position(w)
    @test NT.side_to_move(pw) == :white
    @test format_position(pw) == w

    @test_throws ArgumentError parse_position("B:" * "."^24)            # 長さ不足
    @test_throws ArgumentError parse_position("X:" * expected[3:end])   # 手番の文字が不正
    @test_throws ArgumentError parse_position("B;" * expected[3:end])   # 区切りが不正
    @test_throws ArgumentError parse_position("B:" * "BBBB" * "."^18 * "WWW") # 駒数が不正
    @test_throws ArgumentError parse_position("B:" * "BBBx" * "."^18 * "WWW") # 文字が不正
end

@testset "指し手の表記" begin
    m = Move(1, 16)
    @test m.from == 1 && m.to == 16
    @test NT.format_move(m) == "b1-b4"
    @test NT.parse_move("b1-b4") == m
    @test NT.parse_move("e5-a1") == Move(24, 0)
    @test string(m) == "b1-b4"
    @test_throws ArgumentError NT.parse_move("b1b4")
    @test_throws ArgumentError NT.parse_move("b1-b9")
end

@testset "初期局面の合法手（手で数えた 14 手）" begin
    p0 = initial_position()
    ms = legal_moves(p0)
    @test length(ms) == 14
    @test Set(NT.format_move.(ms)) == Set([
        "b1-b4", "b1-c1", "b1-a1", "b1-a2",
        "d1-d4", "d1-c1", "d1-e1", "d1-e2",
        "c4-c5", "c4-c3", "c4-e4", "c4-a4", "c4-e2", "c4-a2",
    ])
end

@testset "apply_move" begin
    p0 = initial_position()
    p1 = apply_move(p0, NT.parse_move("b1-b4"))
    @test NT.side_to_move(p1) == :white
    @test format_position(p1) == "W:" * "...B." * "..W.." * "....." * ".BB.." * ".W.W."
    # 白の応手: b5 は下に b4 の黒があるので S へ動けない
    @test !any(m -> m.from == 21 && m.to == 16, legal_moves(p1))
    @test_throws ArgumentError apply_move(p0, NT.parse_move("b1-b3"))  # 途中停止は不可
    @test_throws ArgumentError apply_move(p0, NT.parse_move("b5-b4"))  # 相手の駒
    @test_throws ArgumentError apply_move(p0, NT.parse_move("b1-c3"))  # 方向が直線でない
end

@testset "勝ち判定" begin
    p = parse_position("W:" * "BBB.." * "....." * "....." * "....." * "WW.W.")
    @test NT.winner(p) == :black
    @test NT.is_terminal(p)
    @test NT.winner(initial_position()) === nothing
    @test !NT.is_terminal(initial_position())
    # 黒が c1 へ滑って横一列を作る
    q = parse_position("B:" * "BB..B" * "....." * "....." * "....." * "WW.W.")
    q2 = apply_move(q, NT.parse_move("e1-c1"))
    @test NT.winner(q2) == :black
end

@testset "局面の前向き・後ろ向き（Position 版）" begin
    rng = MersenneTwister(20260924)
    p = initial_position()
    # 無作為な対局を数本たどり、子の親集合に元局面が含まれることを確かめる
    for game in 1:20
        p = initial_position()
        for ply in 1:30
            NT.is_terminal(p) && break
            ms = legal_moves(p)
            isempty(ms) && break
            q = apply_move(p, ms[rand(rng, 1:length(ms))])
            @test p in NT.predecessors(q)
            p = q
        end
    end
end
