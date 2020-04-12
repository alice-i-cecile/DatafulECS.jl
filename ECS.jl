# ECS types ####

# Entities are just a global identifier for objects
# These are created using UUIDs in order to allow for non-blocking creation of new entities
const Entity = UUID

rng = MersenneTwister(1234)
Entity() = uuid4(rng)

# Components store data for a single aspect of objects
# Components store a list of entities, as well as a collection of data as a DataFrame
# Each column stores a different type of data, while each row reflects a different entity
# The first column is always the list of entities
# Add new entities with push!, and remove them with deleterows!
const Component = DataFrame

# Expand a component to a certain size using missing values
# Mostly useful when batch-creating new entities
function expand!(component::Component, new_size::Int64)::Nothing
    current_size = size(component)[1]
    if current_size >= new_size
        return nothing
    else 
        Δsize = new_size - current_size
        column_eltypes = [eltype(component[!, i]) for i in 1:size(component)[2]]
        new_data = DataFrame(column_eltypes::Vector, names(component), nrows=Δsize)
        push!(component, new_data)

        return nothing
    end
end

# Create an empty component
function Component(fields::Dict{Symbol, DataType} = Dict{Symbol, DataType}(), n::Int64=0)::Component
    entities = Vector{Entity}

    columns = Dict{Symbol, Any}()
    columns[:entity] = Entity[]
    for (K, V) in fields
        # Create an empty vector of the appropriate type to initialize dataframe
        columns[K] = V[]
    end

    component = DataFrame(columns...)
    if n != 0
        expand!(component, size)
        component.entity = [Entity() for _ in 1:n]
    end

    return component
end

function extract(components::Dict{Symbol, Component}, required_components::Set{Symbol})
    return filter((k,v) -> k ∈ required_components, components)
end

#= 
Systems perform actions on entities that have all of the specified components
Systems are structs which must have the following fields:
    read_components::Set{Symbol}
    write_components::Set{Symbol}

These should be disjoint: write_components are automatically readable as well.

Other system-level data (such as constants for game mechanics or initialization) should be stored here

Systems should be one of: initialization, main, or cleanup, depending on when they should be run
=#
abstract type System end

# Components are created during initialization by various systems that depend on them
# Overwrite this function for your specific system if you want it to do things during initialization
# Operates on an extracted and merged set of components
function initialize!(system::System, read_components::Dict{Symbol, Component}, write_components::Dict{Symbol, Component})::Nothing
    return Dict{Symbol, Component}()
end

# Performs the operations of a system, mutating objects in place
# The data used is a merged dataframe of all components used
# The return value denotes elements to delete; and should either nothing or Array{Element, 1}
# Systems should track elapsed time dynamically using the time_step parameter
# Operates on an extracted and merged set of components
function run!(system::System, read_components::Dict{Symbol, Component}, write_components::Dict{Symbol, Component}, time_step::Float64)::Dict{Symbol, Component}
    return Dict{Symbol, Component}()
end

# Gameplay loop ####

# Adds new components or new entities with a component to an existing dictionary of components
# Updates the first dictionary in place
function merge!(components::Dict{Symbol, Component}, new_components::Dict{Symbol, Component})::Nothing
    for (k, v) in new_components
        if k ∈ components.keys
            push!(components[k], v)
        else
            components[k] = v
        end
    end
    
    return nothing
end

# Updates the data of the game by applying each system to it once
function update!(time_step::Float64, components::Dict{Symbol, Component}, systems::Vector{System}, cleanup_systems::Vector{System})::Nothing
    # Most systems update their components in place
    # Some actions which touch on components outside of the relevant ones end up deferred until the end of the time step
    # Deferrment is effectively a way to pass messages between components
    # Use it when you only shallowly interact with a large system 
    # Or when the task is much better done in batches across systems
    # Defer things which have large side effects
    # Creating and deleting entities is the canonical example
    deferred = Dict{Symbol, Component}()

    for system in systems
        if length(system.deferred_components) == 0
            run!(system, extract(components, system.read_components), extract(components, system.write_components), time_step)
        else
            newly_deferred = run!(system, extract(components, system.read_components), extract(components, system.write_components), time_step)
            merge!(deferred, newly_deferred)
        end
    end

    # Repeatedly loop through cleanup_systems until everything is empty
    # This can eventually be changed to leave things waiting for extra time if needed for performance
    # This pattern allows cleanup systems to create new deferred components
    while length(deferred) > 0
        for cleanup_system in cleanup_systems
            # Check that all components needed are available before running the cleanup system
            required_components = union(cleanup_system.read_components, cleanup_system.write_components)
            if all([k ∈ union(keys(deferred), keys(components)) for k in required_components])
                required_components = Dict{Symbol, Component}()
                for k in required_components
                    if k ∈ keys(deferred)
                        required_components[k] = deferred[k]
                    else
                        required_components[k] = components[k]
                    end
                end

                newly_deferred = run!(cleanup_system, 
                                      extract(required_components, cleanup_system.read_components), 
                                      extract(required_components, cleanup_system.write_components), 
                                      time_step)

                merge!(deferred, newly_deferred)
            end
        end
    end

    return nothing
end

# Central game loop
# Time step is listed in seconds
# Systems initialize components
# Pass in a dictionary of empty components to be initialized
function game_loop(components::Dict{Symbol, Component}, 
                   initialization_systems::Vector{System},
                   main_systems::Vector{System}, 
                   cleanup_systems::Vector{System}, 
                   min_time_step::Float64=0.01)::Dict{Symbol, Component}

    for system in initialization_systems
        initialize!(system, extract(components, system.read_components), extract(components, system.write_components))
    end

    # FIXME: better solution needed to limit time
    steps = 1
    max_steps = 10

    #= Loosely sync wall and in game time by dynamically lengthening time steps if performance gets too poor.
    We have to decide on the length of a time step before computation occurs, 
    in order to ensure things get updated according to elapsed time.
    # Track computation time using a simple rolling average
    =#
    i = 1 # always starts at 1
    window_length = 5 # positive integer; increase to smooth more
    computation_time = repeat([0.0], window_length)
    time_step = min_time_step

    # Main loop for each time step
    while (steps <= max_steps)
        print("$steps steps out of $max_steps.\n")
        tick()
        average_computation_time = sum(computation_time) / window_length

        # Ensure that each time step takes at least the minimum time
        if average_computation_time < min_time_step
            sleep(min_time_step - average_computation_time)
            time_step = min_time_step
        else
            time_step = average_computation_time
        end

        # Run gameplay loop repeatedly by updating state
        update!(time_step, components, main_systems, cleanup_systems)

        # Record loop duration
        computation_time[i] = tok()
        i = i % window_length + 1
        steps += 1
    end

    return components
end