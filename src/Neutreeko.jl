"""
    Neutreeko

5×5 盤の Neutreeko を後退解析で強解決するモジュール。
"""
module Neutreeko

export Position, Move, initial_position, legal_moves, apply_move, is_win_line,
       parse_position, format_position, format_move, parse_move, predecessors,
       solve, save_table, load_table, lookup, best_moves

include("board.jl")
include("position.jl")

end # module
