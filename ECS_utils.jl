# Clear a component of all entities and data 
# Mostly useful for testing
function clear!(component::Component)::Nothing
    deleteat!(component, ones{Bool, 1}(size(component)[1]))
    
    return nothing
end

function clear!(components::AbstractArray{Component})::Nothing
    for component in components
        clear!(component)
    end
        
    return nothing
end

# Join components on the intersection of their common entities
# This is often the first processing step of systems that take more than one component
function join(components::Dict{Symbol, Component})::Component
    # Join dataframes based on the intersection of the entities that are in them
    # You can change the on parameter in order to merge on a different field
    merged_component = reduce((A,B) -> join(A, B, kind = :inner), components)

    return merged_component
end