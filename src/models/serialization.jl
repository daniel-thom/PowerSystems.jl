# Keep in sync with _ENCODE_AS_UUID_A.
const _ENCODE_AS_UUID_A = (
    Union{Nothing, Arc},
    Union{Nothing, Area},
    Union{Nothing, Bus},
    Union{Nothing, LoadZone},
    Union{Nothing, DynamicInjection},
    Vector{Service},
)

# Keep in sync with _ENCODE_AS_UUID_B.
const _ENCODE_AS_UUID_B = (Arc, Area, Bus, LoadZone, DynamicInjection, Vector{Service})

encode_as_uuid_type(::Type{T}) where {T} = mapreduce(x -> T <: x, |, _ENCODE_AS_UUID_A)
encode_as_uuid_val(val) = mapreduce(x -> val isa x, |, _ENCODE_AS_UUID_B)

function IS.serialize(component::T) where {T <: Component}
    data = Dict{String, Any}()
    for name in fieldnames(T)
        val = getfield(component, name)
        if encode_as_uuid_val(val)
            if val isa Array
                val = [IS.get_uuid(x) for x in val]
            elseif isnothing(val)
                val = nothing
            else
                val = IS.get_uuid(val)
            end
        end
        data[string(name)] = serialize(val)
    end

    return data
end

function IS.deserialize(::Type{T}, data::Dict, component_cache::Dict) where {T <: Component}
    @debug T data
    vals = Dict{Symbol, Any}()
    for (name, type) in zip(fieldnames(T), fieldtypes(T))
        vals[name] = deserialize_type(name, type, data[string(name)], component_cache)
    end

    if !isempty(T.parameters)
        return deserialize_parametric_type(T, PowerSystems, vals)
    end

    return T(; vals...)
end

function IS.deserialize(::Type{Device}, data::Any)
    error("This form of IS.deserialize is not supported for Devices")
end

function IS.deserialize_parametric_type(
    ::Type{T},
    mod::Module,
    data::Dict,
) where {T <: Service}
    return T(; data...)
end

function deserialize_type(field_name, field_type, val, component_cache)
    if isnothing(val)
        value = val
    elseif encode_as_uuid_type(field_type)
        if field_type <: Vector{Service}
            _vals = field_type()
            for _val in val
                uuid = deserialize(Base.UUID, _val)
                component = component_cache[uuid]
                push!(_vals, component)
            end
            value = _vals
        else
            uuid = deserialize(Base.UUID, val)
            component = component_cache[uuid]
            value = component
        end
    elseif field_type <: Component
        value = IS.deserialize(field_type, val, component_cache)
    elseif field_type <: Union{Nothing, Component}
        value = IS.deserialize(field_type.b, val, component_cache)
    elseif field_type <: InfrastructureSystemsType
        value = deserialize(field_type, val)
    elseif field_type <: Union{Nothing, InfrastructureSystemsType}
        value = deserialize(field_type.b, val)
    elseif field_type <: Enum
        value = get_enum_value(field_type, val)
    elseif field_type <: Union{Nothing, Enum}
        value = get_enum_value(field_type.b, val)
    else
        value = deserialize(field_type, val)
    end

    return value
end

function get_component_type(component_type::String)
    # This function will ensure that `component_type` contains a valid type expression,
    # so it should be safe to eval.
    return eval(IS.parse_serialized_type(component_type))
end
