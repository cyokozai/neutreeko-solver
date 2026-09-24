using Test
using Random
using Neutreeko

const NT = Neutreeko

@testset "Neutreeko" begin
    include("test_board.jl")
    include("test_position.jl")
    include("test_index.jl")
end
