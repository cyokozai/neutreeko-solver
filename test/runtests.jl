using Test
using Random
using Neutreeko

const NT = Neutreeko

@testset verbose = true "Neutreeko" begin
    include("test_board.jl")
    include("test_export.jl")
    include("test_position.jl")
    include("test_index.jl")
    include("test_solve.jl")
    include("test_stats.jl")
    include("test_agent.jl")
end
