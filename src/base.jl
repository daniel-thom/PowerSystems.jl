
const SKIP_PM_VALIDATION = false

const SYSTEM_KWARGS = Set((
    :branch_name_formatter,
    :bus_name_formatter,
    :config_path,
    :frequency,
    :gen_name_formatter,
    :genmap_file,
    :internal,
    :load_name_formatter,
    :load_zone_formatter,
    :runchecks,
    :shunt_name_formatter,
    :time_series_directory,
    :time_series_in_memory,
    :time_series_read_only,
    :timeseries_metadata_file,
    :unit_system,
))

"""
System

A power system defined by fields for base_power, components, and forecasts.

```julia
System(base_power)
System(base_power, buses, components...)
System(base_power, buses, generators, loads, branches, storage, services; kwargs...)
System(base_power, buses, generators, loads; kwargs...)
System(file; kwargs...)
System(; buses, generators, loads, branches, storage, base_power, services, kwargs...)
System(; kwargs...)
```

# Arguments
- `base_power::Float64`: the base power value for the system
- `buses::Vector{Bus}`: an array of buses
- `components...`: Each element must be an iterable containing subtypes of Component.

# Keyword arguments
- `ext::Dict`: Contains user-defined parameters. Should only contain standard types.
- `runchecks::Bool`: Run available checks on input fields and when add_component! is called.
  Throws InvalidRange if an error is found.
- `time_series_in_memory::Bool=false`: Store time series data in memory instead of HDF5.
- `config_path::String`: specify path to validation config file
"""
struct System <: IS.InfrastructureSystemsType
    data::IS.SystemData
    frequency::Float64 # [Hz]
    bus_numbers::Set{Int}
    runchecks::Bool
    units_settings::SystemUnitsSettings
    internal::IS.InfrastructureSystemsInternal

    function System(
        data,
        units_settings::SystemUnitsSettings,
        internal::IS.InfrastructureSystemsInternal;
        kwargs...,
    )
        # Note to devs: if you add parameters to kwargs then consider whether they need
        # special handling in the deserialization function in this file.
        # See deserialize read for System.

        # Implement a strict check here to make sure that SYSTEM_KWARGS can be used
        # elsewhere.
        unsupported = setdiff(keys(kwargs), SYSTEM_KWARGS)
        !isempty(unsupported) && error("Unsupported kwargs = $unsupported")
        if !isnothing(get(kwargs, :unit_system, nothing))
            @warn("unit_system kwarg ignored. The value in SystemUnitsSetting takes precedence")
        end
        bus_numbers = Set{Int}()
        frequency = get(kwargs, :frequency, DEFAULT_SYSTEM_FREQUENCY)
        runchecks = get(kwargs, :runchecks, true)
        sys = new(data, frequency, bus_numbers, runchecks, units_settings, internal)
        return sys
    end
end

function System(data, base_power, internal; kwargs...)
    unit_system_ = get(kwargs, :unit_system, "SYSTEM_BASE")
    unit_system = UNIT_SYSTEM_MAPPING[unit_system_]
    units_settings = SystemUnitsSettings(base_power, unit_system)
    return System(data, units_settings, internal; kwargs...)
end

"""Construct an empty `System`. Useful for building a System while parsing raw data."""
function System(base_power; kwargs...)
    return System(_create_system_data_from_kwargs(; kwargs...), base_power; kwargs...)
end

"""Construct a `System` from `InfrastructureSystems.SystemData`"""
function System(data, base_power; internal = IS.InfrastructureSystemsInternal(), kwargs...)
    return System(data, base_power, internal; kwargs...)
end

"""
System constructor when components are constructed externally.
"""
function System(base_power::Float64, buses::Vector{Bus}, components...; kwargs...)
    data = _create_system_data_from_kwargs(; kwargs...)
    sys = System(data, base_power; kwargs...)

    for bus in buses
        add_component!(sys, bus)
    end

    for component in Iterators.flatten(components)
        add_component!(sys, component)
    end

    if get(kwargs, :runchecks, true)
        check!(sys)
    end

    return sys
end

"""Constructs a non-functional System for demo purposes."""
function System(
    ::Nothing;
    buses = [
        Bus(;
            number = 0,
            name = "init",
            bustype = BusTypes.REF,
            angle = 0.0,
            magnitude = 0.0,
            voltage_limits = (min = 0.0, max = 0.0),
            base_voltage = nothing,
            area = nothing,
            load_zone = nothing,
            ext = Dict{String, Any}(),
        ),
    ],
    generators = [ThermalStandard(nothing), RenewableFix(nothing)],
    loads = [PowerLoad(nothing)],
    branches = nothing,
    storage = nothing,
    base_power = 100.0,
    services = nothing,
    kwargs...,
)
    _services = isnothing(services) ? [] : services
    return System(base_power, buses, generators, loads, _services; kwargs...)
end

"""Constructs a System from a file path ending with .m, .RAW, or .json"""
function System(file_path::AbstractString; kwargs...)
    ext = splitext(file_path)[2]
    if lowercase(ext) in [".m", ".raw"]
        pm_kwargs = Dict(k => v for (k, v) in kwargs if !in(k, SYSTEM_KWARGS))
        return System(PowerModelsData(file_path; pm_kwargs...); kwargs...)
    elseif lowercase(ext) == ".json"
        # File paths in the JSON are relative. Temporarily change to this directory in order
        # to find all dependent files.
        orig_dir = pwd()
        new_dir = dirname(file_path)
        if isempty(new_dir)
            new_dir = "."
        end
        cd(new_dir)
        try
            time_series_read_only = get(kwargs, :time_series_read_only, false)
            sys = deserialize(
                System,
                basename(file_path);
                time_series_read_only = time_series_read_only,
            )
            check!(sys)
            return sys
        finally
            cd(orig_dir)
        end
    else
        throw(DataFormatError("$file_path is not a supported file type"))
    end
end

"""
Serializes a system to a JSON string.
"""
function IS.to_json(sys::System, filename::AbstractString; force = false)
    IS.prepare_for_serialization!(sys.data, filename; force = force)
    data = to_json(sys)
    open(filename, "w") do io
        write(io, data)
    end
    @info "Serialized System to $filename"
end

function Base.deepcopy(sys::System)
    # We store forecast data in an HDF5 file that would not be copied as part of deepcopy.
    # The HDF5 file could have data buffered in memory, so we would have to close it, make
    # a copy, and attach it to a new system.
    # A simpler solution is to serialize to a tmp dir and deserialize.
    path = mktempdir()
    filename = joinpath(path, "sys.json")
    IS.to_json(sys, filename)
    return System(filename)
end

"""
Return a user-modifiable dictionary to store extra information.
"""
get_ext(sys::System) = IS.get_ext(sys.internal)

"""
Return the system's base power.
"""
get_base_power(sys::System) = sys.units_settings.base_value

"""
Return the system's frequency.
"""
get_frequency(sys::System) = sys.frequency

"""
Clear any value stored in ext.
"""
clear_ext!(sys::System) = IS.clear_ext!(sys.internal)

function set_unit_system!(component::Component, settings::SystemUnitsSettings)
    component.internal.units_info = settings
    return
end

"""
Sets the units base for the getter functions on the devices. It modifies the behavior of all getter functions
"""
function set_units_base_system!(system::System, settings::String)
    system.units_settings.unit_system = UNIT_SYSTEM_MAPPING[settings]
    @info "Unit System changed to $(UNIT_SYSTEM_MAPPING[settings])"
    return
end

function set_units_base_system!(system::System, settings::UnitSystem)
    system.units_settings.unit_system = settings
    @info "Unit System changed to $settings"
    return
end

function get_units_base(system::System)
    return string(system.units_settings.unit_system)
end

function get_units_setting(component::T) where {T <: Component}
    return component.internal.units_info
end

function has_units_setting(component::T) where {T <: Component}
    return !isnothing(get_units_setting(component))
end

"""
Add a component to the system.

Throws ArgumentError if the component's name is already stored for its concrete type.
Throws ArgumentError if any Component-specific rule is violated.
Throws InvalidRange if any of the component's field values are outside of defined valid
range.

# Examples
```julia
sys = System(100.0)

# Add a single component.
add_component!(sys, bus)

# Add many at once.
buses = [bus1, bus2, bus3]
generators = [gen1, gen2, gen3]
foreach(x -> add_component!(sys, x), Iterators.flatten((buses, generators)))
```
"""
function add_component!(sys::System, component::T; kwargs...) where {T <: Component}
    set_unit_system!(component, sys.units_settings)
    @assert has_units_setting(component)
    if !_is_deserialization_in_progress(sys)
        check_component_addition(sys, component)
        check_attached_buses(sys, component)
        check_for_services_on_addition(sys, component)
    end

    if sys.runchecks && !validate_struct(sys, component)
        throw(IS.InvalidValue("Invalid value for $(component)"))
    end

    IS.add_component!(sys.data, component; kwargs...)

    if !_is_deserialization_in_progress(sys)
        # Whatever this may change should have been validated above in
        # check_component_addition, so this should not fail.
        handle_component_addition!(sys, component)
    end
    return
end

"""
Similar to [`add_component!`](@ref) but for services.

# Arguments
- `sys::System`: system
- `service::Service`: service to add
- `contributing_devices`: Must be an iterable of type Device
"""
function add_service!(sys::System, service::Service, contributing_devices; kwargs...)
    if sys.runchecks && !validate_struct(sys, service)
        throw(InvalidValue("Invalid value for $service"))
    end

    for device in contributing_devices
        device_type = typeof(device)
        if !(device_type <: Device)
            throw(ArgumentError("contributing_devices must be of type Device"))
        end
        throw_if_not_attached(device, sys)
    end

    set_unit_system!(service, sys.units_settings)
    # Since this isn't atomic, order is important. Add to system before adding to devices.
    IS.add_component!(sys.data, service; kwargs...)

    for device in contributing_devices
        add_service_internal!(device, service)
    end
end

"""
Similar to [`add_component!`](@ref) but for StaticReserveGroup.

# Arguments
- `sys::System`: system
- `service::StaticReserveGroup`: service to add
"""
function add_service!(sys::System, service::StaticReserveGroup; kwargs...)
    if sys.runchecks && !validate_struct(sys, service)
        throw(InvalidValue("Invalid value for $service"))
    end

    for _service in get_contributing_services(service)
        throw_if_not_attached(_service, sys)
    end

    set_unit_system!(service, sys.units_settings)
    IS.add_component!(sys.data, service; kwargs...)
end

"""Set StaticReserveGroup contributing_services with check"""
function set_contributing_services!(
    sys::System,
    service::StaticReserveGroup,
    val::Vector{Service},
)
    for _service in val
        throw_if_not_attached(_service, sys)
    end
    service.contributing_services = val
end

"""
Similar to [`add_component!`](@ref) but for StaticReserveGroup.

# Arguments
- `sys::System`: system
- `service::StaticReserveGroup`: service to add
- `contributing_services`: contributing services to the group
"""
function add_service!(
    sys::System,
    service::StaticReserveGroup,
    contributing_services::Vector{Service};
    kwargs...,
)
    if sys.runchecks && !validate_struct(sys, service)
        throw(InvalidValue("Invalid value for $service"))
    end

    set_contributing_services!(sys, service, contributing_services)

    set_unit_system!(service, sys.units_settings)
    IS.add_component!(sys.data, service; kwargs...)
end

"""
Adds forecasts from a metadata file or metadata descriptors.

# Arguments
- `sys::System`: system
- `metadata_file::AbstractString`: metadata file for timeseries
  that includes an array of IS.TimeseriesFileMetadata instances or a vector.
- `resolution::DateTime.Period=nothing`: skip forecast that don't match this resolution.
"""
function add_forecasts!(sys::System, metadata_file::AbstractString; resolution = nothing)
    return IS.add_forecasts!(Component, sys.data, metadata_file; resolution = resolution)
end

"""
Adds forecasts from a metadata file or metadata descriptors.

# Arguments
- `sys::System`: system
- `timeseries_metadata::Vector{IS.TimeseriesFileMetadata}`: metadata for timeseries
- `resolution::DateTime.Period=nothing`: skip forecast that don't match this resolution.
"""
function add_forecasts!(
    sys::System,
    timeseries_metadata::Vector{IS.TimeseriesFileMetadata};
    resolution = nothing,
)
    return IS.add_forecasts!(
        Component,
        sys.data,
        timeseries_metadata;
        resolution = resolution,
    )
end

function IS.add_forecast!(
    ::Type{<:Component},
    data::IS.SystemData,
    forecast_cache::IS.ForecastCache,
    metadata::IS.TimeseriesFileMetadata;
    resolution = nothing,
)
    IS.set_component!(metadata, data, PowerSystems)
    component = metadata.component
    if isnothing(component)
        return
    end

    forecast, ts_data = IS.make_forecast!(forecast_cache, metadata; resolution = resolution)
    if isnothing(forecast)
        return
    end

    if component isa Area
        uuids = Set{UUIDs.UUID}()
        for bus in _get_buses(data, component)
            push!(uuids, IS.get_uuid(bus))
        end
        for component_ in (
            load for
            load in IS.get_components(ElectricLoad, data) if
            IS.get_uuid(get_bus(load)) in uuids
        )
            IS.add_forecast!(data, component_, forecast, ts_data, skip_if_present = true)
        end
    else
        IS.add_forecast!(data, component, forecast, ts_data)
    end
end

"""
Iterates over all components.

# Examples
```julia
for component in iterate_components(sys)
    @show component
end
```

See also: [`get_components`](@ref)
"""
function iterate_components(sys::System)
    return IS.iterate_components(sys.data)
end

"""
Remove all components from the system.
"""
function clear_components!(sys::System)
    return IS.clear_components!(sys.data)
end

"""
Remove all components of type T from the system.

Throws ArgumentError if the type is not stored.
"""
function remove_components!(::Type{T}, sys::System) where {T <: Component}
    for component in IS.remove_components!(T, sys.data)
        handle_component_removal!(sys, component)
    end
end

function clear_units!(component::Component)
    get_internal(component).units_info = nothing
    return
end

"""
Remove a component from the system by its value.

Throws ArgumentError if the component is not stored.
"""
function remove_component!(sys::System, component::T) where {T <: Component}
    check_component_removal(sys, component)
    IS.remove_component!(sys.data, component)
    handle_component_removal!(sys, component)
    clear_units!(component)
end

"""
Throws ArgumentError if a PowerSystems rule blocks removal from the system.
"""
function check_component_removal(sys::System, service::T) where {T <: Service}
    if T == StaticReserveGroup
        return
    end
    groupservices = get_components(StaticReserveGroup, sys)
    for groupservice in groupservices
        if service ∈ get_contributing_services(groupservice)
            throw(ArgumentError("service $(get_name(service)) cannot be removed with an attached StaticReserveGroup"))
            return
        end
    end
end

"""
Remove a component from the system by its name.

Throws ArgumentError if the component is not stored.
"""
function remove_component!(
    ::Type{T},
    sys::System,
    name::AbstractString,
) where {T <: Component}
    component = IS.remove_component!(T, sys.data, name)
    handle_component_removal!(sys, component)
end

"""
Get the component of type T with name. Returns nothing if no component matches. If T is an abstract
type then the names of components across all subtypes of T must be unique.

See [`get_components_by_name`](@ref) for abstract types with non-unique names across subtypes.

Throws ArgumentError if T is not a concrete type and there is more than one component with
    requested name
"""
function get_component(::Type{T}, sys::System, name::AbstractString) where {T <: Component}
    return IS.get_component(T, sys.data, name)
end

"""
Returns an iterator of components. T can be concrete or abstract.
Call collect on the result if an array is desired.

# Examples
```julia
iter = PowerSystems.get_components(ThermalStandard, sys)
iter = PowerSystems.get_components(Generator, sys)
iter = PowerSystems.get_components(Generator, sys, x->(PowerSystems.get_available(x)))
generators = collect(PowerSystems.get_components(Generator, sys))
```

See also: [`iterate_components`](@ref)
"""
function get_components(::Type{T}, sys::System) where {T <: Component}
    return IS.get_components(T, sys.data, nothing)
end

# These two methods are defined independently instead of  filter_func::Union{Function, Nothing} = nothing
# because of a documenter error
# that has no relation with the code https://github.com/JuliaDocs/Documenter.jl/issues/1296
#
function get_components(
    ::Type{T},
    sys::System,
    filter_func::Function,
) where {T <: Component}
    return IS.get_components(T, sys.data, filter_func)
end

# These are helper functions for debugging problems.
# Searches components linearly, and so is slow compared to the other get_component functions
get_component(sys::System, uuid::Base.UUID) = IS.get_component(sys.data, uuid)
get_component(sys::System, uuid::String) = IS.get_component(sys.data, Base.UUID(uuid))

function _get_components_by_name(abstract_types, data::IS.SystemData, name::AbstractString)
    _components = []
    for subtype in abstract_types
        component = IS.get_component(subtype, data, name)
        if !isnothing(component)
            push!(_components, component)
        end
    end

    return _components
end

"""
Get the components of abstract type T with name. Note that PowerSystems enforces unique
names on each concrete type but not across concrete types.

See [`get_component`](@ref) if the concrete type is known.

Throws ArgumentError if T is not an abstract type.
"""
function get_components_by_name(
    ::Type{T},
    sys::System,
    name::AbstractString,
) where {T <: Component}
    return IS.get_components_by_name(T, sys.data, name)
end

"""
Gets components availability. Requires type T to have the method get_available implemented.
"""

function get_available_components(::Type{T}, sys::System) where {T <: Component}
    return get_components(T, sys, x -> get_available(x))
end

"""
Return true if the component is attached to the system.
"""
function is_attached(component::T, sys::System) where {T <: Component}
    return is_attached(T, get_name(component), sys)
end

function is_attached(::Type{T}, name, sys::System) where {T <: Component}
    return !isnothing(get_component(T, sys, name))
end

"""
Throws ArgumentError if the component is not attached to the system.
"""
function throw_if_not_attached(component::Component, sys::System)
    if !is_attached(component, sys)
        throw(ArgumentError("$(summary(component)) is not attached to the system"))
    end
end

"""
Return a vector of devices contributing to the service.
"""
function get_contributing_devices(sys::System, service::T) where {T <: Service}
    throw_if_not_attached(service, sys)
    return [x for x in get_components(Device, sys) if has_service(x, service)]
end

struct ServiceContributingDevices
    service::Service
    contributing_devices::Vector{Device}
end

const ServiceContributingDevicesKey = NamedTuple{(:type, :name), Tuple{DataType, String}}
const ServiceContributingDevicesMapping =
    Dict{ServiceContributingDevicesKey, ServiceContributingDevices}

"""
Returns a ServiceContributingDevices object.
"""
function _get_contributing_devices(sys::System, service::T) where {T <: Service}
    uuid = IS.get_uuid(service)
    devices = ServiceContributingDevices(service, Vector{Device}())
    for device in get_components(Device, sys)
        for _service in get_services(device)
            if IS.get_uuid(_service) == uuid
                push!(devices.contributing_devices, device)
                break
            end
        end
    end
    return devices
end

"""
Return an instance of ServiceContributingDevicesMapping.
"""
function get_contributing_device_mapping(sys::System)
    services = ServiceContributingDevicesMapping()
    for service in get_components(Service, sys)
        key = ServiceContributingDevicesKey((typeof(service), get_name(service)))
        services[key] = _get_contributing_devices(sys, service)
    end

    return services
end

"""
Return a vector of components with buses in the AggregationTopology.
"""
function get_components_in_aggregation_topology(
    ::Type{T},
    sys::System,
    aggregator::AggregationTopology,
) where {T <: StaticInjection}
    buses = Set{String}((get_name(x) for x in get_buses(sys, aggregator)))
    components = Vector{T}()
    for component in get_components(T, sys)
        bus = get_bus(component)
        bus_name = get_name(bus)
        if bus_name in buses
            push!(components, component)
        end
    end

    return components
end

"""
Return a mapping of AggregationTopology name to vector of buses within it.
"""
function get_aggregation_topology_mapping(
    ::Type{T},
    sys::System,
) where {T <: AggregationTopology}
    mapping = Dict{String, Vector{Bus}}()
    accessor_func = get_aggregation_topology_accessor(T)
    for bus in get_components(Bus, sys)
        aggregator = accessor_func(bus)
        name = get_name(aggregator)
        buses = get(mapping, name, nothing)
        if isnothing(buses)
            mapping[name] = Vector{Bus}([bus])
        else
            push!(buses, bus)
        end
    end

    return mapping
end

"""
Return a vector of buses contained within the AggregationTopology.
"""
function get_buses(sys::System, aggregator::AggregationTopology)
    return _get_buses(sys.data, aggregator)
end

function _get_buses(data::IS.SystemData, aggregator::T) where {T <: AggregationTopology}
    accessor_func = get_aggregation_topology_accessor(T)
    buses = Vector{Bus}()
    for bus in IS.get_components(Bus, data)
        _aggregator = accessor_func(bus)
        if IS.get_uuid(_aggregator) == IS.get_uuid(aggregator)
            push!(buses, bus)
        end
    end

    return buses
end

"""
Add forecast to the system.

Throws ArgumentError if the component is not stored in the system.

"""
function add_forecast!(sys::System, component::Component, forecast::Forecast)
    return IS.add_forecast!(sys.data, component, forecast)
end

"""
Add a forecast to a system from a CSV file.

See InfrastructureSystems.TimeseriesFileMetadata for description of
scaling_factor.
"""
function add_forecast!(
    sys::System,
    filename::AbstractString,
    component::Component,
    label::AbstractString,
    scaling_factor::Union{String, Float64} = 1.0,
)
    return IS.add_forecast!(sys.data, filename, component, label, scaling_factor)
end

"""
Add a forecast to a system from a TimeSeries.TimeArray.

See InfrastructureSystems.TimeseriesFileMetadata for description of
scaling_factor.
"""
function add_forecast!(
    sys::System,
    ta::TimeSeries.TimeArray,
    component,
    label,
    scaling_factor::Union{String, Float64} = 1.0,
)
    return IS.add_forecast!(sys.data, ta, component, label, scaling_factor)
end

"""
Add a forecast to a system from a DataFrames.DataFrame.

See InfrastructureSystems.TimeseriesFileMetadata for description of
scaling_factor.
"""
function add_forecast!(
    sys::System,
    df::DataFrames.DataFrame,
    component,
    label,
    scaling_factor::Union{String, Float64} = 1.0,
)
    return IS.add_forecast!(sys.data, df, component, label, scaling_factor)
end

"""
Efficiently add all forecasts in one component to another by copying the underlying
references.

# Arguments
- `src::Component`: Source component
- `dst::Component`: Destination component
- `label_mapping::Dict = nothing`: Optionally map src labels to different dst labels.
  If provided and src has a forecast with a label not present in label_mapping, that
  forecast will not copied. If label_mapping is nothing then all forecasts will be copied
  with src's labels.
"""
function copy_forecasts!(
    src::Component,
    dst::Component,
    label_mapping::Union{Nothing, Dict{String, String}} = nothing,
)
    IS.copy_forecasts!(src, dst, label_mapping)
end

"""
Return a vector of forecasts from a metadata file.

# Arguments
- `data::SystemData`: system
- `metadata_file::AbstractString`: path to metadata file
- `resolution::{Nothing, Dates.Period}`: skip any forecasts that don't match this resolution

See InfrastructureSystems.TimeseriesFileMetadata for description of what the file
should contain.
"""
function make_forecasts(sys::System, metadata_file::AbstractString; resolution = nothing)
    return IS.make_forecasts(sys.data, metadata_file, PowerSystems; resolution = resolution)
end

"""
Return a vector of forecasts from a vector of TimeseriesFileMetadata values.

# Arguments
- `data::SystemData`: system
- `timeseries_metadata::Vector{TimeseriesFileMetadata}`: metadata values
- `resolution::{Nothing, Dates.Period}`: skip any forecasts that don't match this resolution
"""
function make_forecasts(
    sys::System,
    metadata::Vector{IS.TimeseriesFileMetadata};
    resolution = nothing,
)
    return IS.make_forecasts(sys.data, metadata, PowerSystems; resolution = resolution)
end

"""
Return true if forecasts are stored contiguously.

Throws ArgumentError if there are no forecasts stored.
"""
function are_forecasts_contiguous(sys::System)
    return IS.are_forecasts_contiguous(sys.data)
end

"""
"""
function are_forecasts_contiguous(component::Component)
    return IS.are_forecasts_contiguous(component)
end

"""
result regardless of whether the forecasts have been stored as one contiguous array or
chunks of contiguous arrays, such as one 365-day forecast vs 365 one-day forecasts.

Throws ArgumentError if there are no forecasts stored, interval is not a multiple of the
system's forecast resolution, or if the stored forecasts have overlapping timestamps.

# Arguments
- `sys::System`: System.
- `interval::Dates.Period`: Amount of time in between each initial time.
- `horizon::Int`: Length of each forecast array.
- `initial_time::Union{Nothing, Dates.DateTime}=nothing`: Start with this time. If nothing,
  use the first initial time.
"""
function generate_initial_times(
    sys::System,
    interval::Dates.Period,
    horizon::Int;
    initial_time::Union{Nothing, Dates.DateTime} = nothing,
)
    return IS.generate_initial_times(
        sys.data,
        interval,
        horizon;
        initial_time = initial_time,
    )
end

"""
Generate initial times for a component.
"""
function generate_initial_times(
    component::Component,
    interval::Dates.Period,
    horizon::Int;
    initial_time::Union{Nothing, Dates.DateTime} = nothing,
)
    return IS.generate_initial_times(
        component,
        interval,
        horizon;
        initial_time = initial_time,
    )
end

"""
Return a forecast for the entire time series range stored for these parameters.
"""
function get_forecast(
    ::Type{T},
    component::Component,
    initial_time::Dates.DateTime,
    label::AbstractString,
) where {T <: Forecast}
    return IS.get_forecast(T, component, initial_time, label)
end

"""
Return a forecast for a subset of the time series range stored for these parameters.
"""
function get_forecast(
    ::Type{T},
    component::Component,
    initial_time::Dates.DateTime,
    label::AbstractString,
    horizon::Int,
) where {T <: Forecast}
    return IS.get_forecast(T, component, initial_time, label, horizon)
end

function get_forecast_initial_times(::Type{T}, component::Component) where {T <: Forecast}
    return IS.get_forecast_initial_times(T, component)
end

function get_forecast_initial_times(
    ::Type{T},
    component::Component,
    label::AbstractString,
) where {T <: Forecast}
    return IS.get_forecast_initial_times(T, component, label)
end

function get_forecast_labels(
    ::Type{T},
    component::Component,
    initial_time::Dates.DateTime,
) where {T <: Forecast}
    return IS.get_forecast_labels(T, component, initial_time)
end

"""
Return a TimeSeries.TimeArray where the forecast data has been multiplied by the forecasted
component field.
"""
function get_forecast_values(
    ::Type{T},
    component::Component,
    initial_time::Dates.DateTime,
    label::AbstractString,
) where {T <: Forecast}
    return IS.get_forecast_values(T, PowerSystems, component, initial_time, label)
end

function get_forecast_values(
    ::Type{T},
    component::Component,
    initial_time::Dates.DateTime,
    label::AbstractString,
    horizon::Int,
) where {T <: Forecast}
    forecast = get_forecast(T, component, initial_time, label, horizon)
    return IS.get_forecast_values(PowerSystems, component, forecast)
end

function get_forecast_values(component::Component, forecast::Forecast)
    return IS.get_forecast_values(PowerSystems, component, forecast)
end

"""
Return sorted forecast initial times.
"""
function get_forecast_initial_times(sys::System)
    return IS.get_forecast_initial_times(sys.data)
end

"""
Return an iterable of NamedTuple keys for forecasts stored for this component.
"""
function get_forecast_keys(component::Component)
    return IS.get_forecast_keys(component)
end

"""
Return the horizon for all forecasts.
"""
function get_forecasts_horizon(sys::System)
    return IS.get_forecasts_horizon(sys.data)
end

"""
Return the earliest initial_time for a forecast.
"""
function get_forecasts_initial_time(sys::System)
    return IS.get_forecasts_initial_time(sys.data)
end

"""
Return the interval for all forecasts.
"""
function get_forecasts_interval(sys::System)
    return IS.get_forecasts_interval(sys.data)
end

"""
Return the resolution for all forecasts.
"""
function get_forecasts_resolution(sys::System)
    return IS.get_forecasts_resolution(sys.data)
end

"""
Return an iterator of forecasts in order of initial time.

Note that passing a filter function can be much slower than the other filtering parameters
because it reads time series data from media.

Call `collect` on the result to get an array.

# Arguments
- `data::SystemData`: system
- `filter_func = nothing`: Only return forecasts for which this returns true.
- `type = nothing`: Only return forecasts with this type.
- `initial_time = nothing`: Only return forecasts matching this value.
- `label = nothing`: Only return forecasts matching this value.

# Examples
```julia
for forecast in iterate_forecasts(sys)
    @show forecast
end

forecasts = collect(iterate_forecasts(sys; initial_time = DateTime("2020-01-01T00:00:00"))
```
"""
function iterate_forecasts(
    sys::System,
    filter_func = nothing;
    type = nothing,
    initial_time = nothing,
    label = nothing,
)
    return iterate_forecasts(
        sys.data,
        filter_func;
        type = type,
        initial_time = initial_time,
        label = label,
    )
end

"""
Remove all forecasts from the system.
"""
function clear_forecasts!(sys::System)
    return IS.clear_forecasts!(sys.data)
end

"""
Throws DataFormatError if forecasts have inconsistent parameters.
"""
function check_forecast_consistency(sys::System)
    IS.check_forecast_consistency(sys.data)
end

"""
Return true if all forecasts have consistent parameters.
"""
function validate_forecast_consistency(sys::System)
    return IS.validate_forecast_consistency(sys.data)
end

"""
Remove the time series data for a component.
"""
function remove_forecast!(
    ::Type{T},
    sys::System,
    component::Component,
    initial_time::Dates.DateTime,
    label::String,
) where {T <: Forecast}
    return IS.remove_forecast!(T, sys.data, component, initial_time, label)
end

"""
Validate an instance of a InfrastructureSystemsType against System data.
Returns true if the instance is valid.

Users implementing this function for custom types should consider implementing
InfrastructureSystems.validate_struct instead if the validation logic only requires data
contained within the instance.
"""
function validate_struct(sys::System, value::IS.InfrastructureSystemsType)
    return true
end

function check!(sys::System)
    buses = get_components(Bus, sys)
    slack_bus_check(buses)
    buscheck(buses)
    critical_components_check(sys)
    adequacy_check(sys)
end

function IS.serialize(sys::T) where {T <: System}
    data = Dict{String, Any}()
    for field in fieldnames(T)
        # Exclude bus_numbers because they will get rebuilt during deserialization.
        if field != :bus_numbers
            data[string(field)] = serialize(getfield(sys, field))
        end
    end

    return data
end

function IS.deserialize(
    ::Type{System},
    filename::AbstractString;
    time_series_read_only = false,
)
    raw = open(filename) do io
        JSON3.read(io, Dict)
    end

    # Read any field that is defined in System but optional for the constructors and not
    # already handled here.
    handled = ("data", "units_settings", "bus_numbers", "internal")
    kwargs = Dict{String, Any}()
    for field in setdiff(keys(raw), handled)
        kwargs[field] = raw[field]
    end

    units_settings = IS.deserialize(SystemUnitsSettings, raw["units_settings"])
    data = IS.deserialize(
        IS.SystemData,
        raw["data"];
        time_series_read_only = time_series_read_only,
    )
    internal = IS.deserialize(InfrastructureSystemsInternal, raw["internal"])
    sys = System(data, units_settings; internal = internal)
    ext = get_ext(sys)
    ext["deserialization_in_progress"] = true
    deserialize_components!(sys, raw["data"]["components"])
    pop!(ext, "deserialization_in_progress")
    isempty(ext) && clear_ext!(sys)

    return sys
end

function deserialize_components!(sys::System, raw)
    # Maintain a lookup of UUID to component because some component types encode
    # composed types as UUIDs instead of actual types.
    component_cache = Dict{Base.UUID, Component}()

    # Add each type to this as we parse.
    parsed_types = Set()

    function is_matching_type(x, types)
        for t in types
            x <: t && return true
        end
        return false
    end

    function deserialize_and_add!(;
        skip_types = nothing,
        include_types = nothing,
        post_add_func = nothing,
    )
        for (c_type_str, components) in raw
            c_type = get_component_type(c_type_str)
            c_type in parsed_types && continue
            if !isnothing(skip_types) && is_matching_type(c_type, skip_types)
                continue
            end
            if !isnothing(include_types) && !is_matching_type(c_type, include_types)
                continue
            end
            for component in components
                comp = deserialize(c_type, component, component_cache)
                add_component!(sys, comp)
                component_cache[IS.get_uuid(comp)] = comp
                if !isnothing(post_add_func)
                    post_add_func(comp)
                end
            end
            push!(parsed_types, c_type)
        end
    end

    # Run in order based on type composition.
    deserialize_and_add!(; include_types = [Area, LoadZone])
    deserialize_and_add!(; include_types = [AGC])
    deserialize_and_add!(; include_types = [Bus])
    deserialize_and_add!(;
        include_types = [Arc, Service],
        skip_types = [StaticReserveGroup],
    )
    # Devices and StaticReserveGroup have services, skip one round.
    deserialize_and_add!(; include_types = [DynamicInjection, StaticReserveGroup])
    # StaticInjection has to follow DynamicInjection.
    deserialize_and_add!(; include_types = [Device])
    deserialize_and_add!(; include_types = [RegulationDevice, DynamicBranch])
end

"""
Return bus with name.
"""
function get_bus(sys::System, name::String)
    return get_component(Bus, sys, name)
end

"""
Return bus with bus_number.
"""
function get_bus(sys::System, bus_number::Int)
    for bus in get_components(Bus, sys)
        if bus.number == bus_number
            return bus
        end
    end

    return nothing
end

"""
Return all buses values with bus_numbers.
"""
function get_buses(sys::System, bus_numbers::Set{Int})
    buses = Vector{Bus}()
    for bus in get_components(Bus, sys)
        if bus.number in bus_numbers
            push!(buses, bus)
        end
    end

    return buses
end

function _is_deserialization_in_progress(sys::System)
    ext = get_ext(sys)
    return get(ext, "deserialization_in_progress", false)
end

check_for_services_on_addition(sys::System, component::Component) = nothing

function check_for_services_on_addition(sys::System, component::Device)
    if supports_services(component) && length(get_services(component)) > 0
        throw(ArgumentError("type Device cannot be added with services"))
    end
    return
end

# Needed because get_services returns the services of the underlying struct
function check_for_services_on_addition(sys::System, component::RegulationDevice)
    for d in get_services(component)
        isa(d, AGC) && throw(ArgumentError("type Device cannot be added with services"))
    end
    return
end

"""
Throws ArgumentError if any bus attached to the component is invalid.
"""
check_attached_buses(sys::System, component::Component) = nothing

function check_attached_buses(sys::System, component::StaticInjection)
    throw_if_not_attached(get_bus(component), sys)
end

function check_attached_buses(sys::System, component::Branch)
    throw_if_not_attached(get_from_bus(component), sys)
    throw_if_not_attached(get_to_bus(component), sys)
end

function check_attached_buses(sys::System, component::DynamicBranch)
    check_attached_buses(sys, get_branch(component))
end

function check_attached_buses(sys::System, component::Arc)
    throw_if_not_attached(get_from(component), sys)
    throw_if_not_attached(get_to(component), sys)
end

"""
Throws ArgumentError if a PowerSystems rule blocks addition to the system.

This method is tied with handle_component_addition!. If the methods are re-implemented for
a subtype then whatever is added in handle_component_addition! must be checked here.
"""
check_component_addition(sys::System, component::Component) = nothing

"""
Throws ArgumentError if a PowerSystems rule blocks removal from the system.
"""
check_component_removal(sys::System, component::Component) = nothing

"""
Refer to docstring for check_component_addition!
"""
handle_component_addition!(sys::System, component::Component) = nothing

handle_component_removal!(sys::System, component::Component) = nothing

function check_component_addition(sys::System, dyn_branch::DynamicBranch)
    throw_if_not_attached(dyn_branch.branch, sys)
end

function check_component_addition(sys::System, bus::Bus)
    number = get_number(bus)
    if number in sys.bus_numbers
        throw(ArgumentError("bus number $number is already stored in the system"))
    end

    area = get_area(bus)
    if !isnothing(area)
        throw_if_not_attached(area, sys)
    end

    load_zone = get_load_zone(bus)
    if !isnothing(load_zone)
        throw_if_not_attached(load_zone, sys)
    end
end

function handle_component_addition!(sys::System, bus::Bus)
    number = get_number(bus)
    @assert !(number in sys.bus_numbers) "bus number $number is already stored"
    push!(sys.bus_numbers, number)
end

function handle_component_addition!(sys::System, component::RegulationDevice)
    copy_forecasts!(component.device, component)
    if !isnothing(get_component(typeof(component.device), sys, get_name(component.device)))
        # This will not be true during deserialization.
        remove_component!(sys, component.device)
        # The line above removed the component setting so needs to be added back
        set_unit_system!(component.device, component.internal.units_info)
    end
    return
end

function handle_component_addition!(sys::System, component::Branch)
    handle_component_addition_common!(sys, component)
end

function handle_component_addition!(sys::System, component::DynamicBranch)
    handle_component_addition_common!(sys, component)
    remove_component!(sys, component.branch)
end

function handle_component_addition_common!(sys::System, component::Branch)
    # If this arc is already attached to the system, assign it to the branch.
    # Else, add it to the system.
    arc = get_arc(component)
    _arc = get_component(Arc, sys, get_name(arc))
    if isnothing(_arc)
        add_component!(sys, arc)
    else
        set_arc!(component, _arc)
    end
end

"""
Throws ArgumentError if the bus number is not stored in the system.
"""
function handle_component_removal!(sys::System, bus::Bus)
    number = get_number(bus)
    @assert number in sys.bus_numbers "bus number $number is not stored"
    pop!(sys.bus_numbers, number)
end

function handle_component_removal!(sys::System, device::Device)
    # This may have to be refactored if handle_component_removal! needs to be implemented
    # for a subtype.
    clear_services!(device)
end

function handle_component_removal!(sys::System, service::Service)
    for device in get_components(Device, sys)
        _remove_service!(device, service)
    end
end

function handle_component_removal!(sys::System, value::T) where {T <: AggregationTopology}
    for device in get_components(Bus, sys)
        if get_aggregation_topology_accessor(T)(device) == value
            _remove_aggregration_topology!(device, value)
        end
    end
end

"""
Return a sorted vector of bus numbers in the system.
"""
function get_bus_numbers(sys::System)
    return sort(collect(sys.bus_numbers))
end

function IS.compare_values(x::System, y::System)
    match = true

    if x.units_settings.unit_system != x.units_settings.unit_system
        @debug "unit system does not match" x.units_settings.unit_system y.units_settings.unit_system
        match = false
    end

    if get_base_power(x) != get_base_power(y)
        @debug "base_power does not match" get_base_power(x) get_base_power(y)
        match = false
    end

    if !IS.compare_values(x.data, y.data)
        @debug "SystemData values do not match"
        match = false
    end

    return match
end

function IS.compare_values(x::T, y::T) where {T <: Union{StaticInjection, DynamicInjection}}
    # Must implement this method because a device of one of these subtypes might have a
    # reference to its counterpart, and vice versa, and so infinite recursion will occur
    # in the default function.
    match = true
    for (fieldname, fieldtype) in zip(fieldnames(T), fieldtypes(T))
        val1 = getfield(x, fieldname)
        val2 = getfield(y, fieldname)
        if val1 isa StaticInjection || val2 isa DynamicInjection
            uuid1 = IS.get_uuid(val1)
            uuid2 = IS.get_uuid(val2)
            if uuid1 != uuid2
                @debug "values do not match" T fieldname uuid1 uuid2
                match = false
                break
            end
        elseif !isempty(fieldnames(typeof(val1)))
            if !IS.compare_values(val1, val2)
                @debug "values do not match" T fieldname val1 val2
                match = false
                break
            end
        elseif val1 isa AbstractArray
            if !IS.compare_values(val1, val2)
                match = false
            end
        else
            if val1 != val2
                @debug "values do not match" T fieldname val1 val2
                match = false
                break
            end
        end
    end

    return match
end

function _create_system_data_from_kwargs(; kwargs...)
    validation_descriptor_file = nothing
    runchecks = get(kwargs, :runchecks, true)
    time_series_in_memory = get(kwargs, :time_series_in_memory, false)
    time_series_directory = get(kwargs, :time_series_directory, nothing)
    if runchecks
        validation_descriptor_file =
            get(kwargs, :config_path, POWER_SYSTEM_STRUCT_DESCRIPTOR_FILE)
    end

    return IS.SystemData(;
        validation_descriptor_file = validation_descriptor_file,
        time_series_in_memory = time_series_in_memory,
        time_series_directory = time_series_directory,
    )
end

"""
Converts a Line component to a MonitoredLine component and replaces the original in the
system
"""
function convert_component!(
    linetype::Type{MonitoredLine},
    line::Line,
    sys::System;
    kwargs...,
)
    new_line = linetype(
        line.name,
        line.available,
        line.active_power_flow,
        line.reactive_power_flow,
        line.arc,
        line.r,
        line.x,
        line.b,
        (from_to = line.rate, to_from = line.rate),
        line.rate,
        line.angle_limits,
        line.services,
        line.ext,
        InfrastructureSystems.Forecasts(),
        line.internal,
    )
    IS.assign_new_uuid!(line)
    add_component!(sys, new_line)
    copy_forecasts!(line, new_line)
    remove_component!(sys, line)
end

"""
Converts a MonitoredLine component to a Line component and replaces the original in the
system
"""
function convert_component!(
    linetype::Type{Line},
    line::MonitoredLine,
    sys::System;
    kwargs...,
)
    force = get(kwargs, :force, false)
    if force
        @warn("Possible data loss converting from $(typeof(line)) to $linetype")
    else
        error("Possible data loss converting from $(typeof(line)) to $linetype, add `force = true` to convert anyway.")
    end

    new_line = linetype(
        line.name,
        line.available,
        line.active_power_flow,
        line.reactive_power_flow,
        line.arc,
        line.r,
        line.x,
        line.b,
        line.rate,
        line.angle_limits,
        line.services,
        line.ext,
        InfrastructureSystems.Forecasts(),
        line.internal,
    )
    IS.assign_new_uuid!(line)
    add_component!(sys, new_line)
    copy_forecasts!(line, new_line)
    remove_component!(sys, line)
end
