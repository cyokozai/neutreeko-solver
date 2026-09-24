# Neutreeko を強解決して data/ に表を保存し、統計を標準出力へ出す。
#
# 実行（リポジトリ直下で）:
#   docker run --rm -v "$PWD":/work -w /work julia:1.11 julia --project=. scripts/solve.jl
#
# 引数 --no-move=loss を付けると、合法手 0 の局面を手番側の負けとして解く（既定は :draw）。

using Neutreeko

const NT = Neutreeko

function main(args)
    rule = any(==("--no-move=loss"), args) ? :loss : :draw
    outdir = joinpath(@__DIR__, "..", "data")
    outpath = joinpath(outdir, rule === :draw ? "neutreeko_table.bin" : "neutreeko_table_nomove_loss.bin")

    # 1 回目は JIT コンパイルを含むので、計時は 2 回目で取る
    NT.solve(no_move_rule = rule)
    t0 = time()
    t = NT.solve(no_move_rule = rule)
    elapsed = time() - t0
    save_table(outpath, t)

    n = NT.NSTATES
    cnt(v) = count(==(v), t.value)
    nwin, nloss, ndraw, ninv = cnt(NT.VAL_WIN), cnt(NT.VAL_LOSS), cnt(NT.VAL_DRAW), cnt(NT.VAL_INVALID)
    nvalid = n - ninv
    pct(a, b) = string(round(100a / b, digits = 3), "%")

    println("== Neutreeko 強解決（後退解析） ==")
    println("合法手 0 の扱い          : ", rule)
    println("全局面数（手番側視点）   : ", n, "  （手番込みの絶対表現では ", 2n, "）")
    println("有効局面数               : ", nvalid, "  （全局面 − 無効）")
    println("  勝ち                   : ", nwin, "  (", pct(nwin, nvalid), ")")
    println("  負け                   : ", nloss, "  (", pct(nloss, nvalid), ")  うち終局（0 手）", count(==(0x00), t.dist[t.value.==NT.VAL_LOSS]))
    println("  引分け                 : ", ndraw, "  (", pct(ndraw, nvalid), ")")
    println("無効（手番側が並び済み） : ", ninv)

    maxwin = maximum(t.dist[i] for i in 1:n if t.value[i] == NT.VAL_WIN)
    maxloss = maximum(t.dist[i] for i in 1:n if t.value[i] == NT.VAL_LOSS)
    iwin = findfirst(i -> t.value[i] == NT.VAL_WIN && t.dist[i] == maxwin, 1:n)
    nmaxwin = count(i -> t.value[i] == NT.VAL_WIN && t.dist[i] == maxwin, 1:n)
    pwin = NT.position_from_index(iwin, true)
    println("最長の勝ち距離           : ", Int(maxwin), " ply（該当 ", nmaxwin, " 局面）")
    println("  例                     : ", format_position(pwin))
    println("  最善手順               : ", join(NT.format_move.(NT.principal_variation(t, pwin)), " "))
    println("最長の負け距離           : ", Int(maxloss), " ply")

    nm = NT.no_move_states()
    println("合法手 0 の局面数        : ", length(nm), "  （どちらも並んでいない局面のうち）")

    p0 = initial_position()
    v0, d0 = lookup(t, p0)
    println("初期局面                 : ", format_position(p0))
    println("初期局面のゲーム値       : ", v0, "  距離 ", d0, "  （", v0 === :draw ? "引分け。距離は定義しない" : "ply", "）")
    println("  引分けを保つ初手       : ", join(NT.format_move.(best_moves(t, p0)), " "))
    # 初手ごとの結果（黒から見た値に直す: 子の手番側＝白の負けは黒の勝ち）
    flip = Dict(:win => :loss, :loss => :win, :draw => :draw, :invalid => :invalid)
    firsts = map(legal_moves(p0)) do m
        v, d = lookup(t, apply_move(p0, m))
        string(NT.format_move(m), "=", flip[v], d >= 0 ? "($(d + 1))" : "")
    end
    println("  初手 14 手の黒の値     : ", join(firsts, " "), "  （括弧内は初期局面から決着までの ply）")

    # 対称類
    println("対称類の数（8 変換）     : 全局面 ", NT.symmetry_class_count(),
        " / 有効 ", NT.symmetry_class_count(i -> t.value[i] != NT.VAL_INVALID),
        " / 引分け ", NT.symmetry_class_count(i -> t.value[i] == NT.VAL_DRAW))
    println("対称性の違反             : ", NT.count_symmetry_violations(t))

    # 初期局面からの到達可能性
    seen = NT.reachable_from(p0)
    norm = NT.normalize_reachable(seen)
    nreach = count(norm)
    println("初期局面から到達可能     : 絶対表現 ", count(seen), " / 手番側視点 ", nreach,
        "（黒番 ", count(i -> seen[2i-1], 1:n), "・白番 ", count(i -> seen[2i], 1:n), "）")
    println("  うち終局（負け 0 手）  : ", count(i -> norm[i] && t.value[i] == NT.VAL_LOSS && t.dist[i] == 0, 1:n))
    println("  有効だが到達不能       : ", nvalid - nreach)
    ndraw_r = count(i -> norm[i] && t.value[i] == NT.VAL_DRAW, 1:n)
    println("  到達可能な引分け       : ", ndraw_r, "  (", pct(ndraw_r, nreach), ")")
    # 手番を無視した駒配置の数（公開値との照合用）
    nboth = count(i -> (let (me, opp) = NT.unrank_state(i); NT.has_line3(me) && NT.has_line3(opp) end), 1:n)
    println("駒配置（手番を無視）     : ", n, "  うち両者並び ", nboth, "  → 両者並び以外 ", n - nboth)

    println("所要時間（後退解析）     : ", round(elapsed, digits = 2), " 秒")
    println("保存先                   : ", normpath(outpath), "  (", filesize(outpath), " バイト)")
end

main(ARGS)
