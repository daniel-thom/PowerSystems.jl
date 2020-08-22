"""
    mutable struct DynamicGenerator{
        M <: Machine,
        S <: Shaft,
        A <: AVR,
        TG <: TurbineGov,
        P <: PSS,
    } <: DynamicInjection
        name::String
        ω_ref::Float64
        machine::M
        shaft::S
        avr::A
        prime_mover::TG
        pss::P
        n_states::Int64
        states::Vector{Symbol}
        ext::Dict{String, Any}
        internal::InfrastructureSystemsInternal
    end

A dynamic generator is composed by 5 components, namely a Machine, a Shaft, an Automatic Voltage Regulator (AVR),
a Prime Mover (o Turbine Governor) and Power System Stabilizer (PSS). It requires a Static Injection device that is attached to it.

# Arguments
- `name::String`: Name of generator.
- `ω_ref::Float64`: Frequency reference set-point in pu.
- `machine <: Machine`: Machine model for modeling the electro-magnetic phenomena.
- `shaft <: Shaft`: Shaft model for modeling the electro-mechanical phenomena.
- `avr <: AVR`: AVR model of the excitacion system.
- `prime_mover <: TurbineGov`: Prime Mover and Turbine Governor model for mechanical power.
- `pss <: PSS`: Power System Stabilizer model.
- `n_states::Int64`: Number of states (will depend on the components).
- `states::Vector{Symbol}`: Vector of states (will depend on the components).
- `ext::Dict{String, Any}`
- `internal::InfrastructureSystemsInternal`: power system internal reference, do not modify
"""
mutable struct DynamicGenerator{
    M <: Machine,
    S <: Shaft,
    A <: AVR,
    TG <: TurbineGov,
    P <: PSS,
} <: DynamicInjection
    name::String
    ω_ref::Float64
    machine::M
    shaft::S
    avr::A
    prime_mover::TG
    pss::P
    n_states::Int64
    states::Vector{Symbol}
    ext::Dict{String, Any}
    internal::InfrastructureSystemsInternal
end

function DynamicGenerator(
    static_injector::Generator,
    ω_ref::Float64,
    machine::M,
    shaft::S,
    avr::A,
    prime_mover::TG,
    pss::P,
    ext::Dict{String, Any} = Dict{String, Any}(),
) where {M <: Machine, S <: Shaft, A <: AVR, TG <: TurbineGov, P <: PSS}
    n_states = (
        get_n_states(machine) +
        get_n_states(shaft) +
        get_n_states(avr) +
        get_n_states(prime_mover) +
        get_n_states(pss)
    )
    states = vcat(
        get_states(machine),
        get_states(shaft),
        get_states(avr),
        get_states(prime_mover),
        get_states(pss),
    )

    return DynamicGenerator{M, S, A, TG, P}(
        get_name(static_injector),
        ω_ref,
        machine,
        shaft,
        avr,
        prime_mover,
        pss,
        n_states,
        states,
        ext,
        InfrastructureSystemsInternal(),
    )
end

function DynamicGenerator(;
    name::Union{String, Generator},
    ω_ref::Float64,
    machine::M,
    shaft::S,
    avr::A,
    prime_mover::TG,
    pss::P,
    n_states = nothing,
    states = nothing,
    ext::Dict{String, Any} = Dict{String, Any}(),
    internal = InfrastructureSystemsInternal(),
) where {M <: Machine, S <: Shaft, A <: AVR, TG <: TurbineGov, P <: PSS}
    if name isa StaticInjection
        name = get_name(name)
    end
    if isnothing(n_states)
        @assert isnothing(states)
        # TODO DT: make helper function
        n_states = (
            get_n_states(machine) +
            get_n_states(shaft) +
            get_n_states(avr) +
            get_n_states(prime_mover) +
            get_n_states(pss)
        )
        states = vcat(
            get_states(machine),
            get_states(shaft),
            get_states(avr),
            get_states(prime_mover),
            get_states(pss),
        )
    else
        @assert !isnothing(states)
    end
    DynamicGenerator(
        name,
        ω_ref,
        machine,
        shaft,
        avr,
        prime_mover,
        pss,
        n_states,
        states,
        ext,
        internal,
    )
end

get_name(device::DynamicGenerator) = device.name
get_Sbase(device::DynamicGenerator) = device.machine.s_rated
get_states(device::DynamicGenerator) = device.states
get_n_states(device::DynamicGenerator) = device.n_states
get_ω_ref(device::DynamicGenerator) = device.ω_ref
get_machine(device::DynamicGenerator) = device.machine
get_shaft(device::DynamicGenerator) = device.shaft
get_avr(device::DynamicGenerator) = device.avr
get_prime_mover(device::DynamicGenerator) = device.prime_mover
get_pss(device::DynamicGenerator) = device.pss
get_ext(device::DynamicGenerator) = device.ext
get_internal(device::DynamicGenerator) = device.internal
get_V_ref(value::DynamicGenerator) = get_V_ref(get_avr(value))
get_P_ref(value::DynamicGenerator) = get_P_ref(get_prime_mover(value))
