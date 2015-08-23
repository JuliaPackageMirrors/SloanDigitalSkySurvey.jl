# written by Jeffrey Regier
# jeff [at] stat [dot] berkeley [dot] edu

module OptimizeElbo

VERSION < v"0.4.0-dev" && using Docile

using NLopt
using CelesteTypes
using Transform

import ElboDeriv
import DataFrames
import ForwardDiff

export ObjectiveWrapperFunctions, WrapperState

#TODO: use Lumberjack.jl for logging
const debug = false


# The main reason we need this is to have a mutable type to keep
# track of function evaluations, but we can keep other metadata
# in it as well.
type WrapperState
    f_evals::Int64
    verbose::Bool
    print_every_n::Int64
end


type ObjectiveWrapperFunctions

    f_objective::Function
    f_value_grad::Function
    f_value_grad!::Function
    f_value::Function
    f_grad::Function
    f_ad_grad::Function
    f_ad_hessian::Function

    state::WrapperState
    transform::DataTransform
    mp::ModelParams{Float64}
    kept_ids::Array{Int64}
    omitted_ids::Array{Int64}

    ObjectiveWrapperFunctions(f::Function, mp::ModelParams{Float64}, transform::DataTransform,
                              kept_ids::Array{Int64, 1}, omitted_ids::Array{Int64, 1}) = begin

        mp_dual = CelesteTypes.convert(ModelParams{ForwardDiff.Dual}, mp);
        x_length = length(kept_ids) * mp.S

        state = WrapperState(0, false, 10)
        function print_status{T <: Number}(
          iter_vp::VariationalParams{T}, value::T, grad::Array{T})
            if state.verbose || (state.f_evals % state.print_every_n == 0)
                println("f_evals: $(state.f_evals) value: $(value)")
            end
            if state.verbose
              S = length(iter_vp)
              if length(iter_vp[1]) == length(ids_names)
                state_df = DataFrames.DataFrame(names=ids_names)
              elseif length(iter_vp[1]) == length(ids_free_names)
                state_df = DataFrames.DataFrame(names=ids_free_names)
              else
                state_df = DataFrames.DataFrame(names=[ "x$i" for i=1:length(iter_vp[1, :])])
              end
              for s=1:S
                state_df[symbol(string("val", s))] = iter_vp[s]
              end
              for s=1:mp.S
                state_df[symbol(string("grad", s))] = grad[:, s]
              end
              println(state_df)
              println("\n=======================================\n")
            end
        end

        function f_objective(x_dual::Array{ForwardDiff.Dual{Float64}})
            state.f_evals += 1
            # Evaluate in the constrained space and then unconstrain again.
            transform.vector_to_vp!(x_dual, mp_dual.vp, omitted_ids)
            f_res = f(mp_dual)
            f_res_trans = transform.transform_sensitive_float(f_res, mp_dual)
        end

        function f_objective(x::Array{Float64})
            state.f_evals += 1
            # Evaluate in the constrained space and then unconstrain again.
            transform.vector_to_vp!(x, mp.vp, omitted_ids)
            f_res = f(mp)

            # TODO: Add an option to print either the transformed or
            # free parameterizations.
            #print_status(mp.vp, f_res.v, f_res.d)
            f_res_trans = transform.transform_sensitive_float(f_res, mp)
            print_status(transform.from_vp(mp.vp), f_res_trans.v, f_res_trans.d)
            f_res_trans
        end

        function f_value_grad{T <: Number}(x::Array{T, 1})
            @assert length(x) == x_length
            res = f_objective(x)
            grad = zeros(T, length(x))
            if length(grad) > 0
                svs = [res.d[kept_ids, s] for s in 1:mp.S]
                grad[:] = reduce(vcat, svs)
            end
            res.v, grad
        end

        function f_value_grad!(x, grad)
            @assert length(x) == x_length
            @assert length(x) == length(grad)
            value, grad[:] = f_value_grad(x)
            value
        end

        # TODO: Add caching.
        function f_value(x)
            @assert length(x) == x_length
            f_objective(x).v
       end

        function f_grad(x)
            @assert length(x) == x_length
            f_value_grad(x)[2]
        end

        # Forward diff versions of the gradient and Hessian.
        f_ad_grad = ForwardDiff.forwarddiff_gradient(f_value, Float64, fadtype=:dual; n=x_length);

        function f_ad_hessian(x::Array{Float64})
            @assert length(x) == x_length
            k = x_length
            hess = zeros(Float64, k, k);
            x_dual = ForwardDiff.Dual{Float64}[ ForwardDiff.Dual{Float64}(x[i], 0.) for i = 1:k ]
            print("Getting Hessian ($k components): ")
            for index in 1:k
                print(".")
                x_dual[index] = ForwardDiff.Dual(x[index], 1.)
                deriv = f_grad(x_dual)
                hess[:, index] = Float64[ ForwardDiff.epsilon(x_val) for x_val in deriv ]
                x_dual[index] = ForwardDiff.Dual(x[index], 0.)
            end
            print("Done.\n")
            hess
        end

        new(f_objective, f_value_grad, f_value_grad!, f_value, f_grad, f_ad_grad, f_ad_hessian,
            state, transform, mp, kept_ids, omitted_ids)
    end
end


function get_nlopt_unconstrained_bounds(vp::Vector{Vector{Float64}},
                                        omitted_ids::Vector{Int64},
                                        transform::DataTransform)
    # Set reasonable bounds for unconstrained parameters.
    #
    # vp: Variational parameters.
    # omitted_ids: Ids of _unconstrained_ variational parameters to be omitted.
    # transform: A DataTransform object.

    kept_ids = setdiff(1:length(UnconstrainedParams), omitted_ids)
    lbs = fill(-15.0, length(ids_free), length(vp))
    ubs = fill(15.0, length(ids_free), length(vp))

    # Change the bounds to match the scaling
    for s=1:length(vp)
      for (param, bounds) in transform.bounds[s]
        lbs[collect(ids_free.(param)), s] *= bounds[3]
        ubs[collect(ids_free.(param)), s] *= bounds[3]
      end
    end
    reduce(vcat, lbs[kept_ids, :]), reduce(vcat, ubs[kept_ids, :])
end


function maximize_f(f::Function, blob::Blob, mp::ModelParams, transform::DataTransform,
                    lbs::Union(Float64, Vector{Float64}), ubs::Union(Float64, Vector{Float64});
                    omitted_ids=Int64[], xtol_rel = 1e-7, ftol_abs = 1e-6, verbose = false)
    # Maximize using NLOpt and unconstrained coordinates.
    #
    # Args:
    #   - f: A function that takes a blob and constrianed coordinates (e.g. ElboDeriv.elbo)
    #   - blob: Input for f
    #   - mp: Constrained initial ModelParams
    #   - transform: The data transform to be applied before optimizing.
    #   - lbs: An array of lower bounds (in the transformed space)
    #   - ubs: An array of upper bounds (in the transformed space)
    #   - omitted_ids: Omitted ids from the _unconstrained_ parameterization (i.e. elements
    #       of free_ids).
    #   - xtol_rel: X convergence
    #   - ftol_abs: F convergence
    #   - verbose: Print detailed output

    kept_ids = setdiff(1:length(UnconstrainedParams), omitted_ids)
    x0 = transform.vp_to_vector(mp.vp, omitted_ids)
    iter_count = 0

    obj_wrapper = ObjectiveWrapperFunctions(
      mp -> f(blob, mp), mp, transform, kept_ids, omitted_ids);
    obj_wrapper.state.verbose = verbose

    opt = Opt(:LD_LBFGS, length(x0))
    for i in 1:length(x0)
        if !(lbs[i] <= x0[i] <= ubs[i])
            println("coordinate $i falsity: $(lbs[i]) <= $(x0[i]) <= $(ubs[i])")
        end
    end
    lower_bounds!(opt, lbs)
    upper_bounds!(opt, ubs)
    max_objective!(opt, obj_wrapper.f_value_grad!)
    xtol_rel!(opt, xtol_rel)
    ftol_abs!(opt, ftol_abs)
    (max_f, max_x, ret) = optimize(opt, x0)

    println("got $max_f at $max_x after $iter_count iters (returned $ret)\n")
    iter_count, max_f, max_x, ret
end

function maximize_f(f::Function, blob::Blob, mp::ModelParams, transform::DataTransform;
    omitted_ids=Int64[], xtol_rel = 1e-7, ftol_abs = 1e-6, verbose = false)
    # Default to the bounds given in get_nlopt_unconstrained_bounds.

    lbs, ubs = get_nlopt_unconstrained_bounds(mp.vp, omitted_ids, transform)
    maximize_f(f, blob, mp, transform, lbs, ubs;
      omitted_ids=omitted_ids, xtol_rel=xtol_rel, ftol_abs=ftol_abs, verbose = verbose)
end

function maximize_f(f::Function, blob::Blob, mp::ModelParams;
    omitted_ids=Int64[], xtol_rel = 1e-7, ftol_abs = 1e-6, verbose = false)
    # Use the default transform.

    transform = get_mp_transform(mp);
    maximize_f(f, blob, mp, transform,
      omitted_ids=omitted_ids, xtol_rel=xtol_rel, ftol_abs=ftol_abs, verbose=verbose)
end

function maximize_elbo(blob::Blob, mp::ModelParams, trans::DataTransform;
    xtol_rel = 1e-7, ftol_abs=1e-6, verbose = false)
    omitted_ids = setdiff(1:length(UnconstrainedParams),
                          [ids_free.r1, ids_free.r2,
                           ids_free.k[:], ids_free.c1[:]])
    maximize_f(ElboDeriv.elbo, blob, mp, trans, omitted_ids=omitted_ids,
        ftol_abs=ftol_abs, xtol_rel=xtol_rel, verbose=verbose)

    maximize_f(ElboDeriv.elbo, blob, mp, trans,
        ftol_abs=ftol_abs, xtol_rel=xtol_rel, verbose=verbose)
end

function maximize_elbo(blob::Blob, mp::ModelParams; verbose = false)
    trans = get_mp_transform(mp)
    maximize_elbo(blob, mp, trans, verbose=verbose)
end

function maximize_likelihood(
  blob::Blob, mp::ModelParams, trans::DataTransform;
  xtol_rel = 1e-7, ftol_abs=1e-6, verbose = false)
    omitted_ids = [ids_free.k[:], ids_free.c2[:], ids_free.r2]
    maximize_f(ElboDeriv.elbo_likelihood, blob, mp, trans,
               omitted_ids=omitted_ids, xtol_rel=xtol_rel,
               ftol_abs=ftol_abs, verbose=verbose)
end

function maximize_likelihood(blob::Blob, mp::ModelParams)
    # Default to the rectangular transform.
    maximize_likelihood(blob, mp, world_rect_transform)
end

end
