### A Pluto.jl notebook ###
# v0.19.32

using Markdown
using InteractiveUtils

# ╔═╡ 371c7050-9bc4-11ee-205f-354baf99a94a
### import packages
begin
	# change this to your system path
	using Pkg

	# In the package manager, use "dev path\to\local\package\under\development"
	using SSM

	using LinearAlgebra
	using Distributions
	using Random
	using Plots
end

# ╔═╡ 278317f2-36fe-4632-96d2-7b1d71190c53
using PlutoUI

# ╔═╡ daaed62c-9700-4098-a6c8-c5bf56dc7fc6
md"hi"

# ╔═╡ dd7fc95b-70a7-402c-a921-da9c1105dac8
# Let's simulate observations from a Gaussian Mixture Model
begin
	Random.seed!(123)
	"""
	# set means and covs
	μ₁, μ₂ = [0.1, 0.3], [-1.2, 2.2]
	Σ₁, Σ₂ = [1 0.2; 0.2 1], [1 0.9; 0.9 1]
	# simulate data
	data1, data2 = rand(MvNormal(μ₁, Σ₁), 500), rand(MvNormal(μ₂, Σ₂), 500)
	combined_data = Matrix{Float64}(hcat(data1, data2)')
	# create model and visualize data points
	gmm = SSM.GMM(2, 2, combined_data)
	p = scatter(data1[1, :], data1[2, :], label="k₁")
	scatter!(data2[1, :], data2[2, :], label="k₂")
	plot!(title="Gaussian Mixture", xlabel="x₁", ylabel="x₂")"""

	k = 2
	data_dim = 2
	μ₁, μ₂ = [0.1, 0.3], [-1.2, 2.2]
	Σ₁, Σ₂ = [1 0.2; 0.2 1], [1 0.9; 0.9 1]
	

	gmmIdeal = SSM.GMM(k, data_dim)
	gmmIdeal.μₖ[:, 1] = μ₁
	gmmIdeal.μₖ[:, 2] = μ₂
	gmmIdeal.Σₖ[1] = Σ₁
	gmmIdeal.Σₖ[2] = Σ₂



	data = rand(gmmIdeal, 1000)
	# Transpose to match expected structure
	data = permutedims(data)

	gmmEstimate = SSM.GMM(k, data_dim)

	p = scatter(data[:, 1], data[:, 2], label="Samples")
	plot!(title="Gaussian Mixture", xlabel="x₁", ylabel="x₂")
end



# ╔═╡ 1466cf75-19a6-4835-a4d6-aaa57e6ad343
# now lets fit the model!
SSM.fit!(gmmEstimate, data)



# Component matching based on nearest mean vector, NOT using the Hungarian algorithm
function compare_gmms(gmmIdeal, gmmEstimate)
    k = gmmIdeal.k
    paired_j = Bool[false for _ in 1:k]  # Track which gmmEstimate components have been paired

    mean_diffs = zeros(Float64, k)
    cov_diffs = zeros(Float64, k)
    mixing_coeff_diffs = zeros(Float64, k)

    for i in 1:k
        best_match_idx = 0
        best_match_diff = Inf

        for j in 1:k
            if !paired_j[j]
                mean_diff = norm(gmmIdeal.μₖ[:,i] - gmmEstimate.μₖ[:,j])
                if mean_diff < best_match_diff
                    best_match_diff = mean_diff
                    best_match_idx = j
                end
            end
        end

        # Mark the best match as paired
        paired_j[best_match_idx] = true

        # Calculate differences for the best match
        mean_diffs[i] = best_match_diff
        cov_diffs[i] = norm(gmmIdeal.Σₖ[i] - gmmEstimate.Σₖ[best_match_idx])
        mixing_coeff_diffs[i] = abs(gmmIdeal.πₖ[i] - gmmEstimate.πₖ[best_match_idx])
    end

    return mean_diffs, cov_diffs, mixing_coeff_diffs
end



# ╔═╡ 2401f387-2e07-4180-ba15-c6afa204782e
begin
	# Define a function to evaluate the multivariate Gaussian
	function evaluate_mvg(x, y, μ, Σ)
    	pos = [x, y]
    	return pdf(MvNormal(μ, Σ), pos)
	end

	# Generate a grid for the contour
	xmin, xmax = extrema(data[:, 1])
	ymin, ymax = extrema(data[:, 2])
	xrange = range(xmin, stop=xmax, length=100)
	yrange = range(ymin, stop=ymax, length=100)

	# Plot each Gaussian in the GMM
	for k in 1:gmmEstimate.k
    	Z = [evaluate_mvg(x, y, gmmEstimate.μₖ[:, k], gmmEstimate.Σₖ[k]) for x in xrange, y in 			yrange]
    	contour!(xrange, yrange, Z', levels=10, linewidth=2, label="Gaussian Estimate $k")
	end
end

# Display the plot
display(p)




# Assuming gmmIdeal and gmmEstimate are defined and fit appropriately,
# you can compare them using:
mean_diffs, cov_diffs, mixing_coeff_diffs = compare_gmms(gmmIdeal, gmmEstimate)

println("Mean differences: ", mean_diffs)
println("Covariance differences: ", cov_diffs)
println("Mixing coefficient differences: ", mixing_coeff_diffs)



# Wait until 'enter' on command line
readline()

# ╔═╡ Cell order:
# ╠═278317f2-36fe-4632-96d2-7b1d71190c53
# ╠═daaed62c-9700-4098-a6c8-c5bf56dc7fc6
# ╠═371c7050-9bc4-11ee-205f-354baf99a94a
# ╠═dd7fc95b-70a7-402c-a921-da9c1105dac8
# ╠═1466cf75-19a6-4835-a4d6-aaa57e6ad343
# ╠═2401f387-2e07-4180-ba15-c6afa204782e
