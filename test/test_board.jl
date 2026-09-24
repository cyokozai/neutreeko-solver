# 盤・勝ち筋・局面表記のテスト

"テスト側で独立に作る勝ち筋判定: 3 マスが 8 方向のどれかに等間隔 1 で並ぶか"
function _independent_is_line(a::Int, b::Int, c::Int)
    pts = sort([(s ÷ 5, s % 5) for s in (a, b, c)])   # (row, col) で整列
    (r1, c1), (r2, c2), (r3, c3) = pts
    dr, dc = r2 - r1, c2 - c1
    (dr, dc) in ((0, 1), (1, 0), (1, 1), (1, -1)) || return false
    return (r3 - r2, c3 - c2) == (dr, dc)
end

@testset "盤とマス番号" begin
    @test NT.square_name(0) == "a1"
    @test NT.square_name(4) == "e1"
    @test NT.square_name(20) == "a5"
    @test NT.square_name(24) == "e5"
    @test NT.square_name(17) == "c4"
    for s in 0:24
        @test NT.parse_square(NT.square_name(s)) == s
    end
    @test_throws ArgumentError NT.parse_square("f1")
    @test_throws ArgumentError NT.parse_square("a6")
    @test_throws ArgumentError NT.parse_square("a")
end

@testset "勝ち筋 48 本" begin
    lines = NT.WIN_LINES
    @test length(lines) == 48
    @test length(unique(lines)) == 48
    # 各筋は 3 ビットで、幾何的にも一直線に連続している
    @test all(count_ones(l) == 3 for l in lines)
    sqs(l) = [s for s in 0:24 if (l >> s) & 1 == 1]
    @test all(_independent_is_line(sqs(l)...) for l in lines)
    # 向きごとの本数: 横 15・縦 15・斜め 9+9
    function dir(l)
        a, b, _ = sqs(l)
        (b ÷ 5 - a ÷ 5, b % 5 - a % 5)
    end
    ds = map(dir, lines)
    @test count(==((0, 1)), ds) == 15
    @test count(==((1, 0)), ds) == 15
    @test count(==((1, 1)), ds) == 9
    @test count(==((1, -1)), ds) == 9
end

@testset "is_win_line" begin
    bit(ss...) = reduce(|, (UInt32(1) << s for s in ss))
    @test NT.is_win_line(bit(0, 1, 2))      # a1 b1 c1
    @test NT.is_win_line(bit(0, 6, 12))     # a1 b2 c3
    @test NT.is_win_line(bit(2, 6, 10))     # c1 b2 a3
    @test NT.is_win_line(bit(4, 9, 14))     # e1 e2 e3
    @test !NT.is_win_line(bit(0, 1, 3))     # 隙間あり
    @test !NT.is_win_line(bit(3, 4, 5))     # 行の折り返し（d1 e1 a2）は並びではない
    @test NT.is_win_line(bit(4, 8, 12))     # e1 d2 c3（右下がりの斜め）
    @test !NT.is_win_line(bit(8, 9, 10))    # d2 e2 a3（折り返し）
    @test !NT.is_win_line(bit(4, 10, 16))   # e1 a3 b4（斜めの折り返し）
    @test NT.is_win_line(bit(0, 1, 2, 20))  # 4 駒以上でも筋を含めば真
    # 全 C(25,3) 組を独立判定と照合し、真になる組がちょうど 48
    n = 0
    for a in 0:22, b in a+1:23, c in b+1:24
        expected = _independent_is_line(a, b, c)
        got = NT.is_win_line(bit(a, b, c))
        got == expected || (@test got == expected)
        n += got
    end
    @test n == 48
end
