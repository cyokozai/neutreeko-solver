# 後退解析の表（TSV）を oracle で突き合わせる。
#
# 使い方:
#   julia verify/compare.jl <table.tsv> [--maxdepth N] [--every K]
#     --maxdepth N  探索の深さ上限（既定 7）
#     --every K     データ行を K 行に 1 行だけ検証する（既定 1 = 全行）。1, K+1, 2K+1, ... 番目
#
# 置換表は全行で共有する（深さつきで格納し、浅い問い合わせでは f_r で落とすので共有しても
# 結果は行ごとに新しく探索した場合と同じ。runtests.jl の「深く探索 → 浅く問い合わせ」で確認）。
#
# 入力 1 行: <局面文字列>\t<win|loss|draw>\t<距離>
#   空行と '#' で始まる行は読み飛ばす。
#
# 判定規則:
#   - 表が win/loss で 距離 d <= maxdepth → oracle が同じ値・同じ距離を返すこと
#   - 表が draw、または 距離 d > maxdepth → oracle は maxdepth 内で決着しない（:unknown）こと
#   - 表の書式不正、oracle が :nomove を返した行も不一致として数える
#   - oracle が :invalid（手番側だけが並んでいる到達不能局面）の行は検証せず、件数だけ報告する
#
# 不一致があれば列挙して終了コード 1、無ければ 0。

if !isdefined(@__MODULE__, :NeutreekoOracle)
    include(joinpath(@__DIR__, "Oracle.jl"))
end

module NeutreekoCompare

using ..NeutreekoOracle: oracle, Searcher

export compare_table, Mismatch

struct Mismatch
    lineno::Int
    line::String
    reason::String
end

struct CompareResult
    checked::Int
    skipped_invalid::Int
    mismatches::Vector{Mismatch}
end

function check_line(lineno::Int, line::AbstractString, maxdepth::Int, searcher::Searcher)
    fields = split(line, '\t')
    length(fields) == 3 || return Mismatch(lineno, line, "列数が 3 でない")
    pos, val, dist = strip(fields[1]), strip(fields[2]), strip(fields[3])
    val in ("win", "loss", "draw") || return Mismatch(lineno, line, "値が win/loss/draw でない: $val")
    d = tryparse(Int, dist)
    d === nothing && return Mismatch(lineno, line, "距離が整数でない: $dist")
    got = try
        oracle(pos; maxdepth=maxdepth, searcher=searcher)
    catch e
        e isa ArgumentError || rethrow()
        return Mismatch(lineno, line, "局面文字列が不正: $(e.msg)")
    end
    got[1] == :invalid && return :invalid
    got[1] == :nomove && return Mismatch(lineno, line, "探索中に合法手 0 の局面が出た（扱い未確定）")
    if val != "draw" && d <= maxdepth
        want = (Symbol(val), d)
        got == want && return nothing
        return Mismatch(lineno, line, "表 $(want) / oracle $(got)")
    else
        got[1] == :unknown && return nothing
        why = val == "draw" ? "表は draw" : "表の距離 $d > maxdepth $maxdepth"
        return Mismatch(lineno, line, "$why なのに oracle は $(got) を返した")
    end
end

"""
    compare_table(path; maxdepth, every=1) -> CompareResult

TSV の各行を oracle で検証する。`every = K` なら K 行に 1 行だけ検証する。
"""
function compare_table(path::AbstractString; maxdepth::Integer, every::Integer=1)
    every >= 1 || throw(ArgumentError("every は 1 以上"))
    checked = 0
    skipped = 0
    ms = Mismatch[]
    searcher = Searcher()
    datarow = 0
    for (lineno, raw) in enumerate(eachline(path))
        line = rstrip(raw, ['\r', '\n'])
        (isempty(strip(line)) || startswith(line, "#")) && continue
        datarow += 1
        (datarow - 1) % every == 0 || continue
        r = check_line(lineno, line, Int(maxdepth), searcher)
        if r === :invalid
            skipped += 1
            continue
        end
        checked += 1
        r === nothing || push!(ms, r)
    end
    return CompareResult(checked, skipped, ms)
end

const USAGE = "使い方: julia verify/compare.jl <table.tsv> [--maxdepth N] [--every K]"

function main(args::Vector{String})
    path = nothing
    maxdepth = 7
    every = 1
    i = 1
    while i <= length(args)
        if args[i] == "--maxdepth" && i < length(args)
            maxdepth = parse(Int, args[i+1])
            i += 2
        elseif args[i] == "--every" && i < length(args)
            every = parse(Int, args[i+1])
            i += 2
        elseif path === nothing
            path = args[i]
            i += 1
        else
            println(stderr, USAGE)
            return 2
        end
    end
    if path === nothing
        println(stderr, USAGE)
        return 2
    end
    t0 = time()
    res = compare_table(path; maxdepth=maxdepth, every=every)
    el = round(time() - t0; digits=2)
    for m in res.mismatches
        println("MISMATCH line $(m.lineno): $(m.reason)\n    $(m.line)")
    end
    println("checked=$(res.checked) mismatches=$(length(res.mismatches)) " *
            "skipped_invalid=$(res.skipped_invalid) maxdepth=$maxdepth every=$every elapsed=$(el)s")
    return isempty(res.mismatches) ? 0 : 1
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    exit(NeutreekoCompare.main(ARGS))
end
