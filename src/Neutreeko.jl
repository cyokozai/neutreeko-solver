"""
    Neutreeko

5×5 盤の Neutreeko を後退解析で強解決するモジュール。
"""
module Neutreeko

export Position, Move, initial_position, legal_moves, apply_move, is_win_line,
       parse_position, format_position, format_move, parse_move, predecessors,
       solve, save_table, load_table, lookup, best_moves
export AbstractAgent, choose_move, PerfectAgent, RandomAgent, AlphaBetaAgent,
       play_game, game_outcome, GameResult

include("board.jl")
include("position.jl")
include("index.jl")
include("solve.jl")
include("table.jl")
include("symmetry.jl")
include("stats.jl")
include("agent.jl")

end # module
