#=
This file is auto-generated. Do not edit.
=#
"""
    mutable struct MultiStartCost <: OperationalCost
        variable::VariableCost
        no_load::Float64
        fixed::Float64
        startup::NamedTuple{(:hot, :warm, :cold), NTuple{3, Float64}}
        shutdn::Float64
    end

Data Structure Operational Cost Data which includes fixed, variable cost, multiple start up cost and stop costs.

# Arguments
- `variable::VariableCost`: variable cost
- `no_load::Float64`: no load cost
- `fixed::Float64`: fixed cost
- `startup::NamedTuple{(:hot, :warm, :cold), NTuple{3, Float64}}`: startup cost
- `shutdn::Float64`: shutdown cost, validation range: `(0, nothing)`, action if invalid: `warn`
"""
mutable struct MultiStartCost <: OperationalCost
    "variable cost"
    variable::VariableCost
    "no load cost"
    no_load::Float64
    "fixed cost"
    fixed::Float64
    "startup cost"
    startup::NamedTuple{(:hot, :warm, :cold), NTuple{3, Float64}}
    "shutdown cost"
    shutdn::Float64
end


function MultiStartCost(; variable, no_load, fixed, startup, shutdn, )
    MultiStartCost(variable, no_load, fixed, startup, shutdn, )
end

# Constructor for demo purposes; non-functional.
function MultiStartCost(::Nothing)
    MultiStartCost(;
        variable=VariableCost((0.0, 0.0)),
        no_load=0.0,
        fixed=0.0,
        startup=(hot = START_COST, warm = START_COST,cold = START_COST),
        shutdn=0.0,
    )
end

"""Get [`MultiStartCost`](@ref) `variable`."""
get_variable(value::MultiStartCost) = value.variable
"""Get [`MultiStartCost`](@ref) `no_load`."""
get_no_load(value::MultiStartCost) = value.no_load
"""Get [`MultiStartCost`](@ref) `fixed`."""
get_fixed(value::MultiStartCost) = value.fixed
"""Get [`MultiStartCost`](@ref) `startup`."""
get_startup(value::MultiStartCost) = value.startup
"""Get [`MultiStartCost`](@ref) `shutdn`."""
get_shutdn(value::MultiStartCost) = value.shutdn

"""Set [`MultiStartCost`](@ref) `variable`."""
set_variable!(value::MultiStartCost, val) = value.variable = val
"""Set [`MultiStartCost`](@ref) `no_load`."""
set_no_load!(value::MultiStartCost, val) = value.no_load = val
"""Set [`MultiStartCost`](@ref) `fixed`."""
set_fixed!(value::MultiStartCost, val) = value.fixed = val
"""Set [`MultiStartCost`](@ref) `startup`."""
set_startup!(value::MultiStartCost, val) = value.startup = val
"""Set [`MultiStartCost`](@ref) `shutdn`."""
set_shutdn!(value::MultiStartCost, val) = value.shutdn = val

