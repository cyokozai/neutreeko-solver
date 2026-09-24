# Neutreeko 独立検証器（verify/）のテスト。
# 実行: docker run --rm -v "$PWD":/work -w /work julia:1.11 julia verify/runtests.jl
#
# 標準ライブラリ（Test, Random）のみを使う。src/ 以下のコードは一切読み込まない。

using Test
using Random

include(joinpath(@__DIR__, "Oracle.jl"))
include(joinpath(@__DIR__, "compare.jl"))
using .NeutreekoOracle
using .NeutreekoCompare

const O = NeutreekoOracle

# 盤面を「マス名 => 駒」で組み立てる補助。例: pos_from('W', ["b1","c1","e1"], ["a5","c5","e3"])
function pos_str_from(side::Char, blacks, whites)
    cells = fill('.', 25)
    for s in blacks
        cells[O.sqname_to_sq(s)+1] = 'B'
    end
    for s in whites
        cells[O.sqname_to_sq(s)+1] = 'W'
    end
    return string(side, ':', String(cells))
end

# 行 1（a1..e1）から行 5 の順に 5 文字ずつ
const INITIAL = "B:" * ".B.B." * "..W.." * "....." * "..B.." * ".W.W."

# 初期局面から無作為に指し進めた局面（到達可能な局面）を作る。
function random_playout_pos(rng, nply)
    p = O.parse_pos(O.INITIAL_POS_STR)
    for _ in 1:nply
        O.is_lined(p.board, O.opponent(p.side)) && break
        ms = O.legal_moves(p)
        isempty(ms) && break
        p = O.apply_move(p, rand(rng, ms))
    end
    return O.format_pos(p)
end

# 無作為な駒配置（3 対 3）。手番側だけが並んでいる到達不能局面は除く。
function random_placement_pos(rng)
    while true
        sqs = randperm(rng, 25)[1:6]
        cells = fill('.', 25)
        for s in sqs[1:3]
            cells[s] = 'B'
        end
        for s in sqs[4:6]
            cells[s] = 'W'
        end
        side = rand(rng, ('B', 'W'))
        str = string(side, ':', String(cells))
        p = O.parse_pos(str)
        if O.is_lined(p.board, p.side) && !O.is_lined(p.board, O.opponent(p.side))
            continue
        end
        return str
    end
end

@testset "NeutreekoOracle" begin

    @testset "表記: マス番号と文字列の往復" begin
        @test O.sqname_to_sq("a1") == 0
        @test O.sqname_to_sq("e1") == 4
        @test O.sqname_to_sq("a2") == 5
        @test O.sqname_to_sq("c4") == 17
        @test O.sqname_to_sq("e5") == 24
        for sq in 0:24
            @test O.sqname_to_sq(O.sq_to_sqname(sq)) == sq
        end

        # 初期配置: 黒 b1,d1,c4 / 白 b5,d5,c2、黒番
        @test O.INITIAL_POS_STR == INITIAL
        @test pos_str_from('B', ["b1", "d1", "c4"], ["b5", "d5", "c2"]) == INITIAL
        p = O.parse_pos(INITIAL)
        @test p.side == O.BLACK
        @test O.format_pos(p) == INITIAL

        rng = MersenneTwister(20260924)
        for _ in 1:200
            s = random_placement_pos(rng)
            @test O.format_pos(O.parse_pos(s)) == s
        end

        # 不正な表記は例外
        @test_throws ArgumentError O.parse_pos("X:" * "."^25)
        @test_throws ArgumentError O.parse_pos("B:" * "."^24)
        @test_throws ArgumentError O.parse_pos("B;" * "."^25)
        @test_throws ArgumentError O.parse_pos("B:" * "."^24 * "Q")
        @test_throws ArgumentError O.parse_pos("B:BBBB" * "."^21)   # 駒数が 3 対 3 でない
    end

    @testset "並び判定（座標差による直接判定）" begin
        lined(bl) = O.is_lined(O.parse_pos(pos_str_from('W', bl, ["a5", "c5", "e3"])).board, O.BLACK)
        @test lined(["a1", "b1", "c1"])        # 横
        @test lined(["c1", "b1", "d1"])        # 並べる順序に依存しない
        @test lined(["a1", "a2", "a3"])        # 縦
        @test lined(["b2", "c3", "d4"])        # 斜め（右上がり）
        @test lined(["c3", "b4", "d2"])        # 斜め（右下がり）
        @test !lined(["a1", "b1", "d1"])       # 一直線だが連続でない
        @test !lined(["a1", "c1", "e1"])       # 等間隔でも隣接していない
        @test !lined(["a1", "b2", "c1"])       # 折れ線
        @test !lined(["d1", "e1", "a2"])       # 行の折り返し（sq は 3,4,5 と連番）
        @test !lined(["e1", "a3", "b4"])       # 行の折り返し（sq は 4,10,16 と差 6）
        @test !lined(["a1", "e1", "d2"])       # 行の折り返し（sq は 0,4,8 と差 4）
    end

    @testset "初期局面の合法手数 = 14" begin
        # 手で数えた根拠（黒番。黒 b1,d1,c4 / 白 b5,d5,c2）:
        #   b1: 上→b4（b5 の白の手前）, 左→a1, 右→c1（d1 の黒の手前）, 左上→a2。
        #       右上は c2 の白に即座に塞がれ不可。下・左下・右下は盤の端で不可。 → 4 手
        #   d1: b1 と左右対称。上→d4, 右→e1, 左→c1, 右上→e2。左上は c2 で不可。 → 4 手
        #   c4: 上→c5, 下→c3（c2 の白の手前）, 左→a4, 右→e4, 左下→a2（b3 経由）,
        #       右下→e2（d3 経由）。左上は b5、右上は d5 の白に塞がれ不可。 → 6 手
        #   合計 4 + 4 + 6 = 14
        p = O.parse_pos(INITIAL)
        ms = O.legal_moves(p)
        @test length(ms) == 14
        dests = sort([O.sq_to_sqname(m[2]) for m in ms])
        @test dests == sort(["b4", "a1", "c1", "a2", "d4", "e1", "c1", "e2",
                             "c5", "c3", "a4", "e4", "a2", "e2"])
        # 白番に替えても白の合法手数は（上下対称なので）14
        pw = O.parse_pos("W:" * INITIAL[3:end])
        @test length(O.legal_moves(pw)) == 14
    end

    @testset "滑走の規則: 途中停止不可、盤の端か駒の直前まで" begin
        # 黒 a1 のみが動く状況で、上方向は a5 まで一気に滑る（途中の a2..a4 には止まれない）
        p = O.parse_pos(pos_str_from('B', ["a1", "c1", "e1"], ["b3", "d3", "c5"]))
        ms = [(O.sq_to_sqname(f), O.sq_to_sqname(t)) for (f, t) in O.legal_moves(p)]
        @test ("a1", "a5") in ms
        @test !(("a1", "a2") in ms)
        @test !(("a1", "a4") in ms)
        # a1 から右は b1 で止まる（c1 の黒の手前）
        @test ("a1", "b1") in ms
        # a1 の右上は b2 → c3 → d4 → e5（盤の端）
        @test ("a1", "e5") in ms
    end

    @testset "手組み局面" begin
        # (1) 既に相手が並んでいる → (:loss, 0)
        s0 = pos_str_from('W', ["a1", "b1", "c1"], ["a5", "c5", "e3"])
        @test oracle(s0; maxdepth=5) == (:loss, 0)
        @test oracle(s0; maxdepth=0) == (:loss, 0)

        # (2) 1 手勝ち: 黒 e1 が左へ滑ると d1 で止まり（c1 の黒の手前）b1-c1-d1 が並ぶ
        s1 = pos_str_from('B', ["b1", "c1", "e1"], ["a5", "c5", "e3"])
        @test oracle(s1; maxdepth=1) == (:win, 1)
        @test oracle(s1; maxdepth=6) == (:win, 1)
        @test oracle(s1; maxdepth=0) == (:unknown, 0)

        # (3) 2 手負け: (2) と同じ配置で白番。
        #   黒の脅威 e1→d1 を防ぐには白が d1 に入るしかない（e1 の左隣を塞ぐ）。
        #   d1 に滑り込めるのは d 列を下る駒・c2 から右下・e2 から左下だが、
        #   白 a5,c5,e3 の行き先は
        #     a5: 下→a1, 右→b5, 右下→d2（e1 の黒の手前）
        #     c5: 下→c2（c1 の手前）, 左→b5, 右→e5, 左下→a3, 右下→d4（e3 の手前）
        #     e3: 上→e5, 下→e2（e1 の手前）, 左→a3, 左上→d4（c5 の手前）, 左下→d2（c1 の手前）
        #   で d1 に届かない。白自身の 1 手勝ちも無い（a5-c5 には b5、c5-e3 には d4 が要るが、
        #   残りの駒でそこへ入れる手が無い）。よって白は何を指しても次に黒が並ぶ。
        s2 = pos_str_from('W', ["b1", "c1", "e1"], ["a5", "c5", "e3"])
        @test oracle(s2; maxdepth=1) == (:unknown, 1)
        @test oracle(s2; maxdepth=2) == (:loss, 2)
        @test oracle(s2; maxdepth=7) == (:loss, 2)
        @test oracle_naive(s2; maxdepth=2) == (:loss, 2)

        # (4) 初期局面は浅い深さでは決着しない
        @test oracle(INITIAL; maxdepth=4) == (:unknown, 4)
    end

    @testset "到達不能局面（手番側だけが並んでいる）は :invalid" begin
        s = pos_str_from('B', ["a1", "b1", "c1"], ["a5", "c5", "e3"])
        @test oracle(s; maxdepth=3)[1] == :invalid
    end

    @testset "合法手 0 の局面は 3 対 3 では存在しない（全配置を列挙）" begin
        # :nomove の扱いは未確定のため、そもそも起こり得るかを総当たりで確かめる。
        # 25C3 × 22C3 = 3,542,000 配置 × 手番 2 通り。
        @test O.count_nomove_placements() == (0, 2 * 2300 * 1540)
        # 検出器そのものの確認: 3 対 3 に限らない盤なら合法手 0 を作れる（黒 a1 を白 a2,b1,b2 で囲む）
        b = fill(O.EMPTY, 25)
        b[O.sqname_to_sq("a1")+1] = O.BLACK
        for n in ("a2", "b1", "b2")
            b[O.sqname_to_sq(n)+1] = O.WHITE
        end
        @test isempty(O.gen_moves!(Tuple{Int,Int}[], b, O.BLACK))
        @test !isempty(O.gen_moves!(Tuple{Int,Int}[], b, O.WHITE))
    end

    @testset "素朴ミニマックスと αβ（置換表・反復深化つき）の一致" begin
        rng = MersenneTwister(8)
        positions = String[]
        for _ in 1:250
            push!(positions, random_playout_pos(rng, rand(rng, 0:30)))
        end
        for _ in 1:250
            push!(positions, random_placement_pos(rng))
        end
        nwin = nloss = nunk = 0
        mismatches = Tuple{String,Int,Any,Any}[]
        for s in positions, d in 0:5
            a = oracle(s; maxdepth=d)
            b = oracle_naive(s; maxdepth=d)
            a == b || push!(mismatches, (s, d, a, b))
            if d == 5
                a[1] == :win && (nwin += 1)
                a[1] == :loss && (nloss += 1)
                a[1] == :unknown && (nunk += 1)
            end
        end
        @test isempty(mismatches)
        isempty(mismatches) || foreach(println, first(mismatches, 10))
        # 検査対象が偏っていないこと（勝ち・負け・未決着がそれぞれ含まれる）
        @test nwin > 0 && nloss > 0 && nunk > 0

        # 深さ 6 は件数を絞って確かめる（置換表の深さ依存が効き始める深さ）
        mism2 = Tuple{String,Int,Any,Any}[]
        deep = [(s, 6) for s in positions[1:5:end]]
        for (s, d) in deep
            a = oracle(s; maxdepth=d)
            b = oracle_naive(s; maxdepth=d)
            a == b || push!(mism2, (s, d, a, b))
        end
        @test isempty(mism2)
        isempty(mism2) || foreach(println, first(mism2, 10))

        # 置換表を共有したまま「深く探索 → 浅く問い合わせ」。深い値を浅い節点で使うとき
        # k > r の勝ち負けを未決着に落とす写像 f_r が無いと、ここで素朴ミニマックスと食い違う。
        mism3 = Tuple{String,Int,Any,Any}[]
        for s in positions[1:2:end]
            sh = O.Searcher()
            oracle(s; maxdepth=6, searcher=sh)
            for d in 5:-1:0
                a = oracle(s; maxdepth=d, searcher=sh)
                b = oracle_naive(s; maxdepth=d)
                a == b || push!(mism3, (s, d, a, b))
            end
        end
        @test isempty(mism3)
        isempty(mism3) || foreach(println, first(mism3, 10))

        # compare.jl と同じ使い方: 1 つの置換表を、異なる局面・異なる深さの問い合わせで使い回す
        shared = O.Searcher()
        mism4 = Tuple{String,Int,Any,Any}[]
        rng2 = MersenneTwister(81)
        for s in shuffle(rng2, positions)
            d = rand(rng2, 0:6)
            a = oracle(s; maxdepth=d, searcher=shared)
            b = oracle_naive(s; maxdepth=d)
            a == b || push!(mism4, (s, d, a, b))
        end
        @test isempty(mism4)
        isempty(mism4) || foreach(println, first(mism4, 10))
    end

    @testset "clamp_depth（f_r）の単体" begin
        M = O.MATE
        @test O.clamp_depth(M - 3, 3) == M - 3      # 3 手勝ちは残り 3 で見える
        @test O.clamp_depth(M - 5, 3) == 0          # 5 手勝ちは残り 3 では未決着
        @test O.clamp_depth(-(M - 2), 2) == -(M - 2)
        @test O.clamp_depth(-(M - 4), 3) == 0
        @test O.clamp_depth(0, 7) == 0
    end

    @testset "盤面 8 対称で oracle の結果が不変" begin
        rng = MersenneTwister(88)
        strs = [INITIAL,
                pos_str_from('B', ["b1", "c1", "e1"], ["a5", "c5", "e3"]),
                pos_str_from('W', ["b1", "c1", "e1"], ["a5", "c5", "e3"])]
        for _ in 1:60
            push!(strs, random_playout_pos(rng, rand(rng, 0:25)))
            push!(strs, random_placement_pos(rng))
        end
        # 対称変換そのものの健全性: 8 通りが互いに異なり、駒数と手番を保つ
        #   初期局面は左右対称なので像は 4 通り。非対称な局面では 8 通りになる。
        p0 = O.parse_pos(INITIAL)
        @test length(unique([O.format_pos(O.transform_pos(p0, k)) for k in 0:7])) == 4
        @test O.format_pos(O.transform_pos(p0, 0)) == INITIAL
        asym = O.parse_pos("W:....W..........B....WBWB.")
        @test length(unique([O.format_pos(O.transform_pos(asym, k)) for k in 0:7])) == 8
        for s in strs
            base = oracle(s; maxdepth=5)
            p = O.parse_pos(s)
            for k in 1:7
                t = O.transform_pos(p, k)
                @test count(==(O.BLACK), t.board) == count(==(O.BLACK), p.board)
                @test length(O.legal_moves(t)) == length(O.legal_moves(p))
                @test oracle(O.format_pos(t); maxdepth=5) == base
            end
        end
    end
end

@testset "compare.jl（表との突き合わせ）" begin
    fx = joinpath(@__DIR__, "fixtures")

    ok = compare_table(joinpath(fx, "table_ok.tsv"); maxdepth=5)
    @test ok.checked > 0
    @test isempty(ok.mismatches)

    bad = compare_table(joinpath(fx, "table_bad.tsv"); maxdepth=5)
    reasons = sort([m.lineno for m in bad.mismatches])
    # table_bad.tsv の 2〜7 行目が不一致（1 行目は正しい行、8 行目はコメント）
    @test reasons == [2, 3, 4, 5, 6, 7]

    # 間引き: every=2 なら 1,3,5,7 番目のデータ行だけを検証する（コメント行は数えない）
    thin = compare_table(joinpath(fx, "table_bad.tsv"); maxdepth=5, every=2)
    @test thin.checked == 4
    @test sort([m.lineno for m in thin.mismatches]) == [3, 5, 7]

    # 終了コード: 一致なら 0、不一致なら 1
    julia = Base.julia_cmd()
    script = joinpath(@__DIR__, "compare.jl")
    okrun = run(ignorestatus(`$julia --startup-file=no $script $(joinpath(fx, "table_ok.tsv")) --maxdepth 5`))
    @test okrun.exitcode == 0
    badrun = run(pipeline(ignorestatus(`$julia --startup-file=no $script $(joinpath(fx, "table_bad.tsv")) --maxdepth 5`);
                          stdout=devnull))
    @test badrun.exitcode == 1
end
