# 解の表を、独立検証器（verify/compare.jl）の TSV 形式で書き出す。
#
# 1 行 = <局面文字列>\t<win|loss|draw>\t<距離>
#   局面文字列は本体の format_position そのもの（"<手番>:<25文字>"、sq = 0..24 = a1..e5）。
#   距離は lookup の値そのもの（勝ちは最短・負けは最長の ply、引分けは -1）。
#   無効局面（手番側が並び済み。両者並びを含む）は書かない。
#
# 実行（リポジトリ直下で）:
#   docker run --rm -v "$PWD":/work -w /work julia:1.11 julia --project=. scripts/export_tsv.jl [オプション]
#
# オプション:
#   --table PATH      表のファイル（既定 data/neutreeko_table.bin。無ければその場で solve() する）
#   --out PATH        出力先（既定は標準出力）
#   --sample N        条件に合う局面から無作為に N 件（既定は全件）
#   --seed S          無作為抽出と --side random の乱数の種（既定 20260924）
#   --max-dist D      距離 D 以下の勝ち・負けだけ（引分けは含めない）
#   --draws           引分けだけ
#   --positions FILE  局面文字列の列挙（1 行 1 局面、先頭列だけ読む。空行・# 行は無視）から
#   --side S          正規化局面をどちらの手番の色で書くか: black（既定）/ white / both / random
#
# 表は手番側視点に正規化してあるので、1 つの番号に黒番と白番（色を入れ替えた同じ配置）の
# 2 通りの絶対表現が対応する。--side で選ぶ（--positions では入力のまま）。

module NeutreekoExport

using Neutreeko
using Random

const NT = Neutreeko

const DEFAULT_TABLE = joinpath(@__DIR__, "..", "data", "neutreeko_table.bin")
const DEFAULT_SEED = 20260924
const SIDES = (:black, :white, :both, :random)

"""
    tsv_row(t, p) -> Union{String,Nothing}

局面 `p` の 1 行。無効局面なら `nothing`。
"""
function tsv_row(t::NT.SolveTable, p::Position)
    v, d = lookup(t, p)
    v === :invalid && return nothing
    return string(format_position(p), '\t', v, '\t', d)
end

"""
    select_indices(t; maxdist = nothing, draws_only = false) -> Vector{Int}

無効でない正規化局面の番号（昇順）。`maxdist` なら距離 ≤ maxdist の勝ち・負けだけ、
`draws_only` なら引分けだけ。両方の指定はできない。
"""
function select_indices(t::NT.SolveTable; maxdist::Union{Nothing,Integer} = nothing,
                        draws_only::Bool = false)
    (maxdist !== nothing && draws_only) &&
        throw(ArgumentError("--max-dist と --draws は同時に指定できない"))
    out = Int[]
    @inbounds for i in eachindex(t.value)
        v = t.value[i]
        v == NT.VAL_INVALID && continue
        if draws_only
            v == NT.VAL_DRAW || continue
        elseif maxdist !== nothing
            (v != NT.VAL_DRAW && t.dist[i] <= maxdist) || continue
        end
        push!(out, i)
    end
    return out
end

"""
    sample_indices(idx, n; seed) -> Vector{Int}

`idx` から重複なく `n` 件を無作為に選び、昇順に並べて返す（`n` ≥ 件数なら全件）。
同じ `seed` なら同じ結果（Julia の版が同じ限り）。
"""
function sample_indices(idx::AbstractVector{<:Integer}, n::Integer; seed::Integer = DEFAULT_SEED)
    n >= length(idx) && return collect(Int, idx)
    rng = Xoshiro(seed)
    pick = randperm(rng, length(idx))[1:n]
    return sort!(Int[idx[k] for k in pick])
end

"""
    index_positions(idx; side = :black, seed) -> Vector{Position}

正規化局面の番号を絶対表現の局面にする。`side` は `:black` / `:white` / `:both`（番号ごとに
黒番・白番の順に 2 局面）/ `:random`（番号ごとに `seed` の乱数で選ぶ）。
"""
function index_positions(idx::AbstractVector{<:Integer}; side::Symbol = :black,
                         seed::Integer = DEFAULT_SEED)
    side in SIDES || throw(ArgumentError("side は $(SIDES) のいずれか: $(repr(side))"))
    side === :black && return [NT.position_from_index(i, true) for i in idx]
    side === :white && return [NT.position_from_index(i, false) for i in idx]
    side === :both &&
        return [NT.position_from_index(i, b) for i in idx for b in (true, false)]
    rng = Xoshiro(seed)
    return [NT.position_from_index(i, rand(rng, Bool)) for i in idx]
end

"""
    read_positions(path) -> Vector{Position}

1 行 1 局面の列挙を読む。先頭のタブ区切り列だけを使い、空行と `#` 行は飛ばす。
"""
function read_positions(path::AbstractString)
    out = Position[]
    for raw in eachline(path)
        line = strip(raw)
        (isempty(line) || startswith(line, "#")) && continue
        push!(out, parse_position(strip(first(split(line, '\t')))))
    end
    return out
end

"""
    write_tsv(io, t, positions) -> (written, skipped_invalid)
"""
function write_tsv(io::IO, t::NT.SolveTable, positions)
    written = 0
    skipped = 0
    for p in positions
        row = tsv_row(t, p)
        if row === nothing
            skipped += 1
        else
            println(io, row)
            written += 1
        end
    end
    return written, skipped
end

"表を読む。ファイルが無ければ solve() する（数秒）"
function load_or_solve(path::AbstractString)
    isfile(path) && return load_table(path)
    println(stderr, "表 $(path) が無いので solve() する")
    return solve()
end

const USAGE = """
使い方: julia --project=. scripts/export_tsv.jl [--table PATH] [--out PATH]
          [--sample N] [--seed S] [--max-dist D | --draws] [--positions FILE]
          [--side black|white|both|random]"""

function parse_args(args::AbstractVector{<:AbstractString})
    o = Dict{Symbol,Any}(:table => DEFAULT_TABLE, :out => nothing, :sample => nothing,
                         :seed => DEFAULT_SEED, :maxdist => nothing, :draws => false,
                         :positions => nothing, :side => :black)
    i = 1
    needval(k) = i < length(args) ? args[i+1] : throw(ArgumentError("$k に値が無い\n$USAGE"))
    while i <= length(args)
        a = args[i]
        if a == "--draws"
            o[:draws] = true
            i += 1
            continue
        end
        a in ("--table", "--out", "--sample", "--seed", "--max-dist", "--positions", "--side") ||
            throw(ArgumentError("知らないオプション: $a\n$USAGE"))
        v = needval(a)
        if a == "--table"
            o[:table] = v
        elseif a == "--out"
            o[:out] = v
        elseif a == "--sample"
            o[:sample] = parse(Int, v)
        elseif a == "--seed"
            o[:seed] = parse(Int, v)
        elseif a == "--max-dist"
            o[:maxdist] = parse(Int, v)
        elseif a == "--positions"
            o[:positions] = v
        else
            s = Symbol(v)
            s in SIDES || throw(ArgumentError("--side は black / white / both / random: $v"))
            o[:side] = s
        end
        i += 2
    end
    (o[:maxdist] !== nothing && o[:draws]) &&
        throw(ArgumentError("--max-dist と --draws は同時に指定できない"))
    (o[:positions] !== nothing && (o[:maxdist] !== nothing || o[:draws])) &&
        throw(ArgumentError("--positions と --max-dist / --draws は同時に指定できない"))
    return (; (k => v for (k, v) in o)...)
end

function main(args::AbstractVector{<:AbstractString})
    o = parse_args(args)
    t = load_or_solve(o.table)
    if o.positions !== nothing
        positions = read_positions(o.positions)
        o.sample === nothing ||
            (positions = positions[sample_indices(eachindex(positions), o.sample; seed = o.seed)])
        what = "positions=$(o.positions)"
    else
        idx = select_indices(t; maxdist = o.maxdist, draws_only = o.draws)
        o.sample === nothing || (idx = sample_indices(idx, o.sample; seed = o.seed))
        positions = index_positions(idx; side = o.side, seed = o.seed)
        what = o.draws ? "draws" : o.maxdist !== nothing ? "max-dist=$(o.maxdist)" : "all"
    end
    header = "# scripts/export_tsv.jl $(what) sample=$(something(o.sample, "all")) " *
             "seed=$(o.seed) side=$(o.side) no_move_rule=$(t.no_move_rule)"
    written, skipped = if o.out === nothing
        println(stdout, header)
        write_tsv(stdout, t, positions)
    else
        mkpath(dirname(abspath(o.out)))
        open(o.out, "w") do io
            println(io, header)
            write_tsv(io, t, positions)
        end
    end
    println(stderr, "written=$(written) skipped_invalid=$(skipped)")
    return written
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    NeutreekoExport.main(ARGS)
end
