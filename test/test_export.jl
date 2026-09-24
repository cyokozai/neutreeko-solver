# scripts/export_tsv.jl（表を独立検証器の TSV 形式で書き出す）のテスト
#
# runtests.jl では test_solve.jl より前に読まれるので、全体解 TABLE は使わず、
# 数局面だけに値を置いた小さな表を手で組んで確かめる。

include(joinpath(@__DIR__, "..", "scripts", "export_tsv.jl"))

const EX = NeutreekoExport

"指定した局面だけに値を置き、残りを無効にした表"
function tiny_table(entries)
    value = fill(NT.VAL_INVALID, NT.NSTATES)
    dist = zeros(UInt8, NT.NSTATES)
    for (s, v, d) in entries
        i = NT.state_index(parse_position(s))
        value[i] = v
        dist[i] = d
    end
    return NT.SolveTable(value, dist, :draw)
end

# 値の組は tiny_table の中だけの取り決め（実際の値かどうかは問わない）
const EX_ENTRIES = [
    ("B:.B.B...W.........B...W.W.", NT.VAL_DRAW, 0x00),   # 初期局面
    ("W:BBB...........W.....W.W..", NT.VAL_LOSS, 0x00),   # 相手が並び済み
    ("B:.BB.B.........W.....W.W..", NT.VAL_WIN, 0x01),
    ("W:.BB.B.........W.....W.W..", NT.VAL_LOSS, 0x02),
    ("W:W...............BB.WB...W", NT.VAL_WIN, 0x03),
    ("W:.................BB.WWB.W", NT.VAL_LOSS, 0x04),
    ("W:B.B..W........WB....W....", NT.VAL_WIN, 0x07),
]

@testset "export_tsv: 1 行の書式" begin
    t = tiny_table(EX_ENTRIES)
    @test EX.tsv_row(t, parse_position("B:.BB.B.........W.....W.W..")) == "B:.BB.B.........W.....W.W..\twin\t1"
    @test EX.tsv_row(t, parse_position("W:BBB...........W.....W.W..")) == "W:BBB...........W.....W.W..\tloss\t0"
    # 引分けの距離は lookup と同じく -1
    @test EX.tsv_row(t, initial_position()) == "B:.B.B...W.........B...W.W.\tdraw\t-1"
    # 無効局面は書かない
    @test EX.tsv_row(t, parse_position("B:BBB...........W.....W.W..")) === nothing
    # 局面文字列は本体の format_position そのもの
    p = parse_position("W:W...............BB.WB...W")
    @test split(EX.tsv_row(t, p), '\t')[1] == format_position(p)
end

@testset "export_tsv: 局面の選び方" begin
    t = tiny_table(EX_ENTRIES)
    all_idx = EX.select_indices(t)
    @test length(all_idx) == length(EX_ENTRIES)
    @test issorted(all_idx)
    @test all(t.value[i] != NT.VAL_INVALID for i in all_idx)

    near = EX.select_indices(t; maxdist = 3)
    @test sort([t.dist[i] for i in near]) == [0x00, 0x01, 0x02, 0x03]
    @test all(t.value[i] != NT.VAL_DRAW for i in near)   # 距離で絞るときは引分けを含めない

    draws = EX.select_indices(t; draws_only = true)
    @test draws == [NT.state_index(initial_position())]
    @test_throws ArgumentError EX.select_indices(t; maxdist = 3, draws_only = true)
end

@testset "export_tsv: 無作為抽出は seed で再現し、元の集合の部分集合" begin
    idx = collect(1:1000)
    a = EX.sample_indices(idx, 10; seed = 42)
    b = EX.sample_indices(idx, 10; seed = 42)
    c = EX.sample_indices(idx, 10; seed = 43)
    @test a == b
    @test a != c
    @test length(a) == 10 && allunique(a) && issorted(a) && issubset(a, idx)
    # 件数が集合より多ければ全件
    @test EX.sample_indices(idx[1:5], 10; seed = 1) == idx[1:5]
end

@testset "export_tsv: 手番の色の展開" begin
    i = NT.state_index(parse_position("B:.BB.B.........W.....W.W.."))
    pb = EX.index_positions([i]; side = :black)
    pw = EX.index_positions([i]; side = :white)
    @test format_position(only(pb)) == "B:.BB.B.........W.....W.W.."
    @test format_position(only(pw)) == "W:.WW.W.........B.....B.B.."   # 色を入れ替えた同じ局面
    @test length(EX.index_positions([i, i + 1]; side = :both)) == 4
    r1 = EX.index_positions(collect(1:50); side = :random, seed = 7)
    r2 = EX.index_positions(collect(1:50); side = :random, seed = 7)
    @test r1 == r2
    @test any(p -> p.black_to_move, r1) && any(p -> !p.black_to_move, r1)
    @test all(NT.state_index(p) == j for (p, j) in zip(r1, 1:50))
end

@testset "export_tsv: main の出力（全件・距離・列挙）" begin
    t = tiny_table(EX_ENTRIES)
    mktempdir() do dir
        tbl = joinpath(dir, "t.bin")
        save_table(tbl, t)
        datalines(path) = [l for l in eachline(path) if !isempty(l) && !startswith(l, "#")]

        out = joinpath(dir, "all.tsv")
        EX.main(["--table", tbl, "--out", out])
        rows = datalines(out)
        @test length(rows) == length(EX_ENTRIES)
        @test all(length(split(r, '\t')) == 3 for r in rows)
        # 書いた行は表と同じ値に読み戻せる
        for r in rows
            s, v, d = split(r, '\t')
            @test lookup(t, parse_position(s)) == (Symbol(v), parse(Int, d))
        end
        @test startswith(first(eachline(out)), "#")

        out2 = joinpath(dir, "near.tsv")
        EX.main(["--table", tbl, "--out", out2, "--max-dist", "2"])
        @test length(datalines(out2)) == 3

        out3 = joinpath(dir, "sample.tsv")
        EX.main(["--table", tbl, "--out", out3, "--sample", "3", "--seed", "5"])
        out4 = joinpath(dir, "sample2.tsv")
        EX.main(["--table", tbl, "--out", out4, "--sample", "3", "--seed", "5"])
        @test length(datalines(out3)) == 3
        @test datalines(out3) == datalines(out4)

        # 局面文字列の列挙から。無効局面は書かず、空行・# 行・2 列目以降は無視する
        lst = joinpath(dir, "list.txt")
        write(lst, """
        # comment
        B:.BB.B.........W.....W.W..\tanything

        B:BBB...........W.....W.W..
        W:.................BB.WWB.W
        """)
        out5 = joinpath(dir, "list.tsv")
        EX.main(["--table", tbl, "--out", out5, "--positions", lst])
        @test datalines(out5) == ["B:.BB.B.........W.....W.W..\twin\t1", "W:.................BB.WWB.W\tloss\t4"]

        @test_throws ArgumentError EX.parse_args(["--sample"])
        @test_throws ArgumentError EX.parse_args(["--side", "red"])
        @test_throws ArgumentError EX.parse_args(["--bogus"])
    end
end
