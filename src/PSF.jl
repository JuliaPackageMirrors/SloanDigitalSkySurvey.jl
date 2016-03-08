module PSF

import ForwardDiff
import Optim
import GaussianMixtures


"""
All the information form a psField file needed to compute a raw PSF for a point.
Attributes:
 - rrows: A matrix of flattened eigenimages.
 - rnrow: The number of rows in an eigenimage.
 - rncol: The number of columns in an eigenimage.
 - cmat: The coefficients of the weight polynomial (see get_psf_at_point()).
"""
immutable RawPSFComponents
    rrows::Array{Float64,2}
    rnrow::Int32
    rncol::Int32
    cmat::Array{Float64,3}
end


# Constants to keep the optimization stable.
const sigma_min = diagm([0.25, 0.25])
const weight_min = 0.05


"""
Convert the parameters of a mixture of 2d Gaussians
sum_k weight_vec[k] * N(mu_vec[k], sigma_vec[k])
to an unconstrained vector that can be passed to an optimizer.
"""
function wrap_parameters(
    mu_vec::Vector{Vector{Float64}},
    sigma_vec::Vector{Matrix{Float64}},
    weight_vec::Vector{Float64})

  @assert length(mu_vec) == length(sigma_vec) == length(weight_vec)
  local K = length(mu_vec)

  # Two mean parameters, three covariance parameters,
  # and one weight per component.
  local par = zeros(K * 6)
  for k = 1:K
    offset = (k - 1) * 6
    par[offset + (1:2)] = mu_vec[k]
    sigma_chol = chol(sigma_vec[k] - sigma_min)
    par[offset + 3] = log(sigma_chol[1, 1])
    par[offset + 4] = sigma_chol[1, 2]
    par[offset + 5] = log(sigma_chol[2, 2])
    par[offset + 6] = log(weight_vec[k] - weight_min)
  end

  par
end


"""
Reverse wrap_parameters().
"""
function unwrap_parameters{T <: Number}(par::Vector{T})
  local K = round(Int, length(par) / 6)
  @assert K == length(par) / 6

  local mu_vec = Array(Vector{T}, K)
  local sigma_vec = Array(Matrix{T}, K)
  local weight_vec = zeros(T, K)

  for k = 1:K
    offset = (k - 1) * 6
    mu_vec[k] = par[offset + (1:2)]
    sigma_chol_vec = par[offset + (3:5)]
    sigma_chol = T[exp(sigma_chol_vec[1]) sigma_chol_vec[2];
                   0.0                    exp(sigma_chol_vec[3])]
    sigma_vec[k] = sigma_chol' * sigma_chol + sigma_min
    weight_vec[k] = exp(par[offset + 6]) + weight_min
  end

  mu_vec, sigma_vec, weight_vec
end


"""
Using a vector of mu, sigma, and weights, get the value of the GMM at x.

Args:
  - x: A length 2 vector to evaluate the GMM at.
  - mu_vec: A vector of location vectors.
  - sigma_vec: A vector of covariance matrices.
  - weight_vec: A vector of weights.

Returns:
  - The weighted sum of the component densities at x.
"""
function evaluate_psf_at_point{T <: Number}(
    x::Vector{Float64},
    mu_vec::Vector{Vector{T}},
    sigma_vec::Vector{Matrix{T}},
    weight_vec::Vector{T})

  @assert length(mu_vec) == length(sigma_vec) == length(weight_vec)
  local K = length(mu_vec)

  @assert length(x) == 2
  local pdf = 0.0
  for k = 1:K
    z = x - mu_vec[k]
    log_pdf = -0.5 * dot(z, sigma_vec[k] \ z) -
               0.5 * logdet(sigma_vec[k]) - log(2 * pi)
    pdf += weight_vec[k] * exp(log_pdf)
  end

  pdf
end


"""
Given a psf matrix, return a matrix of the same size, where each element of
the matrix is a 2-length vector of the [x1, x2] location of that matrix cell.
The locations are chosen so that the scale is pixels, but the center of the
psf is [0, 0].
"""
function get_x_matrix_from_psf(psf::Matrix{Float64})
  psf_center = Float64[ (size(psf, i) - 1) / 2 + 1 for i=1:2 ]
  Vector{Float64}[ Float64[i, j] - psf_center for i=1:size(psf, 1), j=1:size(psf, 2) ]
end


"""
Evaluate a GMM expressed in its unconstrained form.
"""
function render_psf{T <: Number}(par::Vector{T}, x_mat::Matrix{Vector{Float64}})
  local mu_vec, sigma_vec, weight_vec
  mu_vec, sigma_vec, weight_vec = unwrap_parameters(par)
  gmm_psf =
    T[ evaluate_psf_at_point(x_mat[i, j], mu_vec, sigma_vec, weight_vec)
       for i=1:size(x_mat, 1), j=1:size(x_mat, 2) ]
  gmm_psf
end


"""
Fit a mixture of 2d Gaussians to a PSF image (evaluated at a single point).

Args:
 - psf: An matrix image of the point spread function, e.g. as returned by
        get_psf_at_point.

"""
function fit_psf_gaussians_least_squares(
    psf::Array{Float64, 2}; initial_par=Float64[],
    grtol = 1e-9, iterations = 5000, verbose=false,
    K=2, optim_method=:nelder_mead)

  if (any(psf .< 0))
      if verbose
          warn("Some psf values are negative.")
      end
      psf[ psf .< 0 ] = 0
  end

  x_mat = get_x_matrix_from_psf(psf);

  if length(initial_par) == 0
    if verbose
      println("Using default initialization.")
    else
      println("Using user-specified initialization.")
    end
    psf_starting_mean  =
      sum([ psf[i, j]  * x_mat[i, j] for
          i in 1:size(psf, 1), j=1:size(psf, 2) ]) / sum(psf)

    mu_vec = Array(Vector{Float64}, K)
    sigma_vec = Array(Matrix{Float64}, K)
    weight_vec = zeros(Float64, K)

    for k=1:K
      mu_vec[k] = psf_starting_mean
      sigma_vec[k] = Float64[ sqrt(2 * k) 0; 0 sqrt(2 * k)]
      weight_vec[k] = 1 / K
    end
    initial_par = wrap_parameters(mu_vec, sigma_vec, weight_vec)
  end

  @assert length(initial_par) == K * 6

  function evaluate_fit{T <: Number}(par::Vector{T})
    gmm_psf = render_psf(par, x_mat)
    local fit = sum((psf .- gmm_psf) .^ 2)
    if verbose && T == Float64
      println("-------------------")
      println("Fit: $fit")
      mu_vec, sigma_vec, weight_vec = unwrap_parameters(par)
      println(mu_vec)
      println(sigma_vec)
      println(weight_vec)
    end
    fit
  end

  optim_result =
    Optim.optimize(evaluate_fit, initial_par, method=optim_method,
                   iterations=iterations, grtol=grtol)

  optim_result, unwrap_parameters(optim_result.minimum)...
end


"""
Using data from a psField file, evaluate the PSF for a source at given point.

Args:
 - row: The row of the point source (may be a float).
 - col: The column of the point source (may be a float).
 - raw_psf_comp: Raw PSF components (e.g. as read from a psField file)

Returns:
 - An rnrow x rncol image of the PSF at (row, col)

The PSF is represented as a weighted combination of "eigenimages" (stored
in rrows), where the weights vary smoothly across points (row, col) in the image
as a polynomial of the form
weight[k](row, col) = sum_{i,j} cmat[i, j, k] * (rcs * row) ^ i (rcs * col) ^ j
...where row and col are zero-indexed.

This function is based on the function sdss_psf_at_points in astrometry.net:
https://github.com/dstndstn/astrometry.net/blob/master/util/sdss_psf.py
"""
function get_psf_at_point(row::Float64, col::Float64,
                          raw_psf_comp::RawPSFComponents)

    # This is a coordinate transform to keep the polynomial coefficients
    # to a reasonable size.
    const rcs = 0.001

    # rrows' image data is in the first column a flattened form.
    # The second dimension is the number of eigen images, which should
    # match the number of coefficient arrays.
    cmat = raw_psf_comp.cmat

    k_tot = size(raw_psf_comp.rrows)[2]
    @assert k_tot == size(cmat)[3]

    nrow_b = size(cmat)[1]
    ncol_b = size(cmat)[2]

    # Get the weights.  The row and column are intended to be
    # zero-indexed.
    coeffs_mat = [ ((row - 1) * rcs) ^ i * ((col - 1) * rcs) ^ j for
                    i=0:(nrow_b - 1), j=0:(ncol_b - 1)]
    weight_mat = zeros(k_tot)
    for k = 1:k_tot, i = 1:nrow_b, j = 1:ncol_b
        weight_mat[k] += cmat[i, j, k] * coeffs_mat[i, j]
    end

    # Weight the images in rrows and reshape them into matrix form.
    # It seems I need to convert for reshape to work.  :(
    psf = reshape(sum([ raw_psf_comp.rrows[:, i] * weight_mat[i] for i=1:k_tot]),
                  (convert(Int64, raw_psf_comp.rnrow),
                   convert(Int64, raw_psf_comp.rncol)))

    psf
end



###################
# Methods for EM.  EM is faster, but optimizes the wrong loss function --
# we want a least squares fit, not a log likelihood fit.

"""
Evaluate a gmm object at the data points x_mat.
"""
function evaluate_gmm(gmm::GaussianMixtures.GMM, x_mat::Array{Float64, 2})
    post = GaussianMixtures.gmmposterior(gmm, x_mat)
    exp(post[2]) * gmm.w;
end


"""
Fit a mixture of 2d Gaussians to a PSF image (evaluated at a single point).

Args:
 - psf: An matrix image of the point spread function, e.g. as returned by get_psf_at_point.
 - tol: The target mean sum of squared errors between the MVN fit and the raw psf.
 - max_iter: The maximum number of EM steps to take.

 Returns:
  - A GaussianMixtures.GMM object containing the fit
  - A scaling that minimized the least squares error.

 Use an EM algorithm to fit a mixture of three multivariate normals to the
 point spread function.  Although the psf is continuous-valued, we use EM by
 fitting as if we had gotten psf[x, y] data points at the image location [x, y].
 As of writing weighted data matrices of this form were not supported in GaussianMixtures.

 Note that this is a little incoherent -- we use something like log loss
 to fit the mixture and squared error loss to fit the scale.
"""
function fit_psf_gaussians(
  psf::Array{Float64, 2}; tol = 1e-9, max_iter = 500, verbose=false)

    function sigma_for_gmm(sigma_mat)
        # Returns a matrix suitable for storage in the field gmm.Σ
        GaussianMixtures.cholinv(sigma_mat)
    end

    # TODO: Is it ok that it is coming up negative in some points?
    if (any(psf .< 0))
        if verbose
            warn("Some psf values are negative.")
        end
        psf[ psf .< 0 ] = 0
    end

    # Data points at which the psf is evaluated in matrix form.
    psf_center = Float64[ (size(psf, i) - 1) / 2 + 1 for i=1:2 ]
    x_prod = [ Float64[i, j] for i=1:size(psf, 1), j=1:size(psf, 2) ]
    x_mat = Float64[ x_row[col] for x_row=x_prod, col=1:2 ]
    x_mat = broadcast(-, x_mat, psf_center')

    # The function we're trying to match.
    psf_scale = sum(psf)
    psf_mat = Float64[psf[round(Int, x_row[1]), round(Int, x_row[2])] /
                      psf_scale for x_row=x_prod ];

    # Use the GaussianMixtures package to evaluate our likelihoods.  In order to
    # avoid automatically choosing an initialization point, hard-code three
    # gaussians for now.  Ignore their initialization, which would not be
    # weighted by the psf.
    gmm = GaussianMixtures.GMM(3, x_mat; kind=:full, nInit=0)

    # Get the scale for the starting point from the whole image.
    psf_starting_var = x_mat' * (x_mat .* psf_mat)

    # Hard-coded initialization.
    gmm.μ[1, :] = Float64[0, 0]
    gmm.Σ[1] = sigma_for_gmm(Float64[ sqrt(2) 0; 0 sqrt(2)])

    gmm.μ[2, :] = -Float64[0, 0]
    gmm.Σ[2] = sigma_for_gmm(Float64[ 2 0; 0 2])

    gmm.μ[3, :] = Float64[0.2, 0.2]
    gmm.Σ[3] = sigma_for_gmm(psf_starting_var)

    gmm.w = ones(gmm.n) / gmm.n

    iter = 1
    err_diff = Inf
    last_err = Inf
    fit_done = false

    # post contains the posterior information about the values of the
    # mixture as well as the probabilities of each component.
    post = GaussianMixtures.gmmposterior(gmm, x_mat)

    while !fit_done
        # Update gmm using last value of post.  post[1] contains
        # posterior probabilities of the indicators.
        z = post[1] .* psf_mat
        z_sum = collect(sum(z, 1))
        new_w = z_sum / sum(z_sum)
        gmm.w = new_w
        for d=1:gmm.n
            if new_w[d] > 1e-6
                new_mean = sum(x_mat .* z[:, d], 1) / z_sum[d]
                x_centered = broadcast(-, x_mat, new_mean)
                x_cov = x_centered' * (x_centered .* z[:, d]) / z_sum[d]

                gmm.μ[d, :] = new_mean
                gmm.Σ[d] = sigma_for_gmm(x_cov)
            else
                warn("Component $d has very small probability.")
            end
        end

        # Get next posterior and check for convergence.  post[2] contains
        # the log densities at each point.
        post = GaussianMixtures.gmmposterior(gmm, x_mat)
        gmm_fit = exp(post[2]) * gmm.w;
        err = mean((gmm_fit - psf_mat) .^ 2)
        err_diff = abs(last_err - err)
        if verbose
            println("$iter: err=$err err_diff=$err_diff")
        end

        last_err = err
        if isnan(err)
            error("NaN in MVN PSF fit.")
        end

        iter = iter + 1
        if err_diff < tol
            println("Tolerance reached ($err_diff < $tol)")
            fit_done = true
        elseif iter >= max_iter
            warn("PSF MVN fit: max_iter exceeded")
            fit_done = true
        end

        if verbose
          println("Fitting psf: $iter: $err_diff")
        end
    end

    # Get the scaling constant that minimizes the squared error.
    post = GaussianMixtures.gmmposterior(gmm, x_mat)
    gmm_fit = exp(post[2]) * gmm.w;
    scale = sum(gmm_fit .* psf_mat) / sum(gmm_fit .* gmm_fit)

    gmm, scale
end


end
