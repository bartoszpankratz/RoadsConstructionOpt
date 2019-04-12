### USING OSMDES FRAMEWORK
#Simple single_simulation

using OpenStreetMapX
using OpenStreetMapXPlot
using LightGraphs
using Plots
using SparseArrays
using DataStructures
using Statistics

mutable struct Agent
    start_node::Int64
    end_node::Int64
    route::Array{Tuple{Int64,Int64},1}
    current_edge::Int64
    travel_times::SparseArrays.SparseMatrixCSC{Float64,Int64}
	time::Float64 #1.Added time of final route
end

mutable struct SimData
    map_data::MapData
	driving_times::SparseArrays.SparseMatrixCSC{Float64,Int64}
	velocities::SparseArrays.SparseMatrixCSC{Float64,Int64}
	max_densities::SparseArrays.SparseMatrixCSC{Float64,Int64}
	population::Array{Agent,1}
end

mutable struct Stats
	routes_changed::Int
	delays::Array{Float64,1}
    cars_count::SparseArrays.SparseMatrixCSC{Float64,Int64}
    avg_driving_times::SparseArrays.SparseMatrixCSC{Float64,Int64}
	total_time::Float64 #2. Added total of all final route. Total output of the system
end

#3. change
Stats(m::Int,n::Int) = Stats(0, Float64[], SparseArrays.spzeros(m, n), SparseArrays.spzeros(m, n),0.0)

function get_route(m::MapData, w::AbstractMatrix{Float64}, node0::Int64,  node1::Int64)
    f(x, B = agent.end_node, nodes = m.nodes, vertices = m.n) = OpenStreetMapX.get_distance(x,B,nodes,vertices)/(maximum(values(OpenStreetMapX.SPEED_ROADS_URBAN))/3.6)
    route_indices, route_values = OpenStreetMapX.a_star_algorithm(m.g, node0, node1, w, f)
    [(route_indices[j - 1],route_indices[j]) for j = 2:length(route_indices)]
end

function get_max_densities(m::MapData,
	l::Float64)
			roadways_lanes = Dict{Int64,Int64}()
    for roadway in m.roadways
        if !OpenStreetMapX.haslanes(roadway)
            lanes = 1
        else
            lanes = OpenStreetMapX.getlanes(roadway)
        end
        roadways_lanes[roadway.id] = lanes
    end
    segments = OpenStreetMapX.find_segments(m.nodes,m.roadways,m.intersections)
    segments = Dict((m.v[segment.node0],m.v[segment.node1]) => roadways_lanes[segment.parent] for segment in segments)
    lanes_matrix = SparseArrays.sparse(map(x->getfield.(collect(keys(segments)), x), fieldnames(eltype(collect(keys(segments)))))...,
	collect(values(segments)),
	length(m.v),length(m.v))
    return m.w .* lanes_matrix / l
end

#setting random
import Random
function get_nodes(m::MapData)
	start_node, end_node = 0, 0
    while start_node == end_node
Random.seed!(0)
        start_node = m.v[OpenStreetMapX.point_to_nodes(OpenStreetMapX.generate_point_in_bounds(m), m)]
        end_node = m.v[OpenStreetMapX.point_to_nodes(OpenStreetMapX.generate_point_in_bounds(m), m)]
    end
    return start_node,end_node
end

function create_agents(m::MapData,
                        w::SparseArrays.SparseMatrixCSC{Float64,Int64},
                        N::Int64)
    buffer = Dict{Tuple{Int64,Int64}, Vector{Agent}}()
    nodes_list = Tuple{Int64,Int64}[]
    for i = 1:N
        nodes = get_nodes(m)
        if i % 2000 == 0
            @info "$i agents created"
        end
        if !haskey(buffer,nodes)
            route = get_route(m, w, nodes[1], nodes[2])
            travel_times = SparseArrays.spzeros(size(w)[1], size(w)[2])
            agent = Agent(nodes[1], nodes[2],
                            route,
                            1,
                            travel_times,0) ###Added Time
            buffer[nodes] = [agent]
            push!(nodes_list,nodes)
        else
            push!(buffer[nodes],deepcopy(buffer[nodes][1]))
        end
    end
    return reduce(vcat,[buffer[k] for k in nodes_list])
end

function get_sim_data(m::MapData,
                    N::Int64,
					l::Float64,
                    speeds = OpenStreetMapX.SPEED_ROADS_URBAN)::SimData
    driving_times = OpenStreetMapX.create_weights_matrix(m, OpenStreetMapX.network_travel_times(m, speeds))
    velocities = OpenStreetMapX.get_velocities(m, speeds)
	max_densities = get_max_densities(m, l)
    agents = create_agents(m, driving_times, N)
    return SimData(m, driving_times, velocities, max_densities, agents)
end

N = 100;
iter = 5;
l = 5.0;

pth = "C:/RoadsConstructionOpt/Roboczy/"
name = "mapatest2.osm"

map_data =  OpenStreetMapX.get_map_data(pth,name,use_cache = false);
#@time plotmap(map_data; width = 1000, height = 1000)
@time sim_data=get_sim_data(map_data,N,l)

function update_travels!(agent::Agent,
                        driving_time::SparseArrays.SparseMatrixCSC{Float64,Int64})
    agent.travel_times += (driving_time - agent.travel_times)
end

function update_travels!(agent::Agent, edge0::Int, edge1::Int,
                        driving_time::Float64)
    agent.travel_times[edge0, edge1] +=(driving_time - agent.travel_times[edge0, edge1])
end


function calculate_driving_time(ρ::Float64,
                                ρ_max::Float64,
                                d::Float64,
                                v_max::Float64,
                                V_min::Float64 = 1.0)
    v = (v_max - V_min)* max((1 - ρ/ρ_max),0.0) + V_min
    return d/v
end


#
function departure_time(w::AbstractMatrix{Float64}, route::Array{Tuple{Int64,Int64},1})
    isempty(route) ? (driving_time = 0) : (driving_time = sum(w[edge[1],edge[2]] for edge in route))
    return -driving_time
end

function update_stats!(stats::Stats, edge0::Int, edge1::Int, driving_time::Float64)
    stats.cars_count[edge0, edge1] += 1.0
    stats.avg_driving_times[edge0, edge1] += (driving_time - stats.avg_driving_times[edge0, edge1])/stats.cars_count[edge0, edge1]
end
#
function update_routes!(sim_data::SimData, stats::Stats)
     for agent in sim_data.population
		  update_travels!(agent, stats.avg_driving_times)
		old_route = agent.route
        agent.route = get_route(sim_data.map_data,
                                sim_data.driving_times + agent.travel_times,
                                agent.start_node, agent.end_node)
		(agent.route != old_route) && (stats.routes_changed += 1)
    end
end
###Total time of agents travel
function update_time!(agent::Agent, edge0::Int, edge1::Int,
						driving_time::Float64)
	agent.time += driving_time
end
###Total time of all agents travel
function update_total_time!(stats::Stats, agent::Agent)
		stats.total_time += agent.time
	end


	function run_single_iteration!(sim_data::SimData)
	    sim_clock = DataStructures.PriorityQueue{Int, Float64}()
	    for i = 1:length(sim_data.population)
	        sim_clock[i] = departure_time(sim_data.driving_times + sim_data.population[i].travel_times, sim_data.population[i].route)
	    end
	    m, n = size(sim_data.map_data.w)
	    stats = Stats(m, n)
	    traffic_densities = SparseArrays.spzeros(m, n)
	    while !isempty(sim_clock)
	        id, current_time = DataStructures.peek(sim_clock)
	        agent = sim_data.population[id]
	        (agent.current_edge != 1) && (traffic_densities[agent.route[agent.current_edge - 1][1], agent.route[agent.current_edge - 1][2]] -= 1.0)
	        if agent.current_edge > length(agent.route)
				push!(stats.delays, current_time)
	            DataStructures.dequeue!(sim_clock)
	            agent.current_edge = 1
	        else
	            edge0, edge1 = agent.route[agent.current_edge]
	            driving_time = calculate_driving_time(traffic_densities[edge0, edge1],
	                                                sim_data.max_densities[edge0, edge1],
	                                                sim_data.map_data.w[edge0, edge1],
	                                                sim_data.velocities[edge0, edge1])
				update_travels!(agent,edge0, edge1, driving_time)
	            update_stats!(stats, edge0, edge1, driving_time)
	            traffic_densities[edge0, edge1] += 1.0
	            agent.current_edge += 1
	            sim_clock[id] += driving_time
	        end
	    end
	    update_routes!(sim_data, stats)
		#For each agent
		for agent in sim_data.population
		##For each agent's edge
		for i=1:length(agent.route)
			edge0, edge1 = agent.route[i][1],agent.route[i][2]
			driving_time = calculate_driving_time(traffic_densities[edge0, edge1],
												sim_data.max_densities[edge0, edge1],
												sim_data.map_data.w[edge0, edge1],
												sim_data.velocities[edge0, edge1])
			update_time!(agent,edge0,edge1,driving_time) ### time of final route
		end
		update_total_time!(stats,agent) ##Total time of the system
		end
		return stats.total_time
	end
	run_single_iteration!(sim_data)

@time run_single_iteration!(sim_data)