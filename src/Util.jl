# written by Jeffrey Regier
# jeff [at] stat [dot] berkeley [dot] edu

module Util

VERSION < v"0.4.0-dev" && using Docile

export matvec222, logit, inv_logit

function matvec222(mat::Matrix, vec::Vector)
    # x' A x in a slightly more efficient form.
    (mat[1,1] * vec[1] + mat[1,2] * vec[2]) * vec[1] +
            (mat[2,1] * vec[1] + mat[2,2] * vec[2]) * vec[2]
end

function get_bvn_cov(ab::Float64, angle::Float64, scale::Float64)
    # Unpack a rotation-parameterized BVN covariance matrix.
    #
    # Args:
    #   - ab: The ratio of the minor to the major axis.
    #   - angle: Rotation angle (in radians)
    #   - scale: The major axis.
    #
    #  Returns:
    #    The 2x2 covariance matrix parameterized by the inputs.

    #@assert -pi/2 <= angle < pi/2
    @assert 0 < scale
    @assert 0 < ab <= 1.
    cp, sp = cos(angle), sin(angle)
    R = [[cp -sp], [sp cp]]  # rotates
    D = diagm([1., ab])  # shrinks the minor axis
    W = scale * D * R'
    W' * W  # XiXi
end

function inv_logit(x)
    # TODO: bounds checking
    -log(1.0 ./ x - 1)
end

function logit(x)
    # TODO: bounds checking
    1.0 ./ (1.0 + exp(-x))
end

@doc """
Determine whether a ray in direction r from point p
intersects the edge from v1 to v2 in two dimensions.
""" ->
function ray_crossing(p::Array{Float64, 1}, r::Array{Float64, 1},
                      v1::Array{Float64, 1}, v2::Array{Float64, 1})
    @assert length(p) == length(r) == length(v1) == length(v2) == 2

    delta_v = v2 - v1
    int_mat = hcat(r, -delta_v)
    if det(int_mat) == 0
        # If the ray is parallel to an edge, consider it not to be
        # an intersection.
        return false
    else
        sol =  int_mat \ (v1 - p)
        return 0 <= sol[2] < 1 && sol[1] > 0
    end
end
 
@doc """
Use the ray crossing algorithm to determine whether the point p
is inside a convex polygon with corners v[i, :], i =1:number of edges,
using the ray-casting algorithm in direction r.
This assumes the polygon is not self-intersecting, and does not
handle the edge cases that might arise from non-convex shapes.
A point on the edge of a polygon is considered to be outside the polygon.
""" ->
function point_inside_polygon(p, r, v)

    n_edges = size(v, 1)
    @assert length(p) == length(r) == size(v, 2)
    @assert n_edges >= 3

    num_crossings = 0
    for edge=1:(n_edges - 1)
        crossing = ray_crossing(p, r, v[edge, :][:], v[edge + 1, :][:]) ? 1: 0
        num_crossings = num_crossings + crossing
    end

    # The final edge from the last vertex back to the first.
    crossing = ray_crossing(p, r, v[n_edges, :][:], v[1, :][:]) ? 1: 0
    num_crossings = num_crossings + crossing

    return num_crossings % 2 == 1
end


function point_near_polygon_corner(p, radius, v)
    n_vertices = size(v, 1)
    @assert length(p) == size(v, 2)
    @assert n_vertices >= 3

    r2 = radius ^ 2
    for vertex=1:n_vertices
        delta = p - v[vertex, :][:]
        if dot(delta, delta) < r2
            return true
        end
    end

    return false    
end

function point_near_line_segment(p, radius, v1, v2)
    delta = v2 - v1
    delta = delta / sqrt(dot(delta, delta))

    delta_vp1 = v1 - p
    delta_vp2 = v2 - p

    delta_along1 = dot(delta_vp1, delta) * delta
    delta_along2 = dot(delta_vp2, delta) * delta

    delta_perp = delta_vp2 - delta_along2

    # Check that the point is between the edges of the line segment
    # and no more than radius away.
    return (sqrt(dot(delta_perp, delta_perp)) < radius) &&
           (dot(delta_along1, delta_along2) < 0)
end


function point_within_radius_of_polygon(p, radius, v)

end


end
