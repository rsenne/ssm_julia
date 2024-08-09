export HiddenMarkovModel, valid_emission, fit!, sample, loglikelihood, viterbi
export weighted_initialization

# for unit tests
export E_step, validate_model, validate_data, valid_emission_models
export class_probabilities



# Please ensure all criteria are met for any new emission model:
# 1. fit!(model, data..., <weights here>) must fit the model using the weights provided (by maximizing the weighted loglikelihood).
# 2. loglikelihood(model, data...; observation_wise=true) must return a Vector{Float64} of the loglikelihood of each observation.
# 3. TimeSeries(model, sample(model, data...; n=<number of samples>)) must return a TimeSeries object of n samples.
# 4. revert_TimeSeries(model, time_series) must return the time_series data converted back to the original sample() format (the inverse of TimeSeries(model, samples)).



"""
    HiddenMarkovModel

A Hidden Markov Model (HMM) with custom emissions.

# Fields
- `K::Int`: Number of states.
- `B::Vector=Vector()`: Vector of emission models.
- `emission=nothing`: If B is missing emissions, clones of this model will be used to fill in the rest.
- `A::Matrix{<:Real}`: Transition matrix.
- `πₖ::Vector{Float64}`: Initial state distribution.

# Examples
```jldoctest; output = false, filter = r"(?s).*" => s""
emission_1 = Gaussian(output_dim=2)
emission_2 = Gaussian(output_dim=2)
model = HiddenMarkovModel(K=2, B=[emission_1, emission_2])

model = HiddenMarkovModel(K=2, emission=Gaussian(output_dim=2))
# output
```
"""
mutable struct HiddenMarkovModel <: Model
    A::Matrix{<:Real} # transition matrix
    B::Vector{EmissionModel} # Vector of emission Models
    πₖ::Vector{Float64} # initial state distribution
    K::Int # number of states
end

function validate_model(model::HiddenMarkovModel)
    # check that the transition matrix is the proper shape
    @assert size(model.A) == (model.K, model.K)
    @assert isapprox(sum(model.A, dims=2), ones(model.K))
    # check that the initial state distribution is the same length as the number of states
    @assert model.K == length(model.πₖ)
    @assert sum(model.πₖ) ≈ 1.0
    # check that the number of states is equal to the number of emission models
    @assert model.K == length(model.B)
    # check that all emission model are the same type
    @assert all([model.B[i] isa EmissionModel for i in 1:length(model.B)])


    # check that all emission models are valid
    for i in 1:length(model.B)
        validate_model(model.B[i])
    end
end

function validate_data(model::HiddenMarkovModel, data...)
    # check that the data is the correct length
    validate_data(model.B[1], data...)
end

function initialize_transition_matrix(K::Int)
    # initialize a transition matrix
    A = zeros(Float64, K, K)
    @threads for i in 1:K
        A[i, :] = rand(Dirichlet(ones(K)))
    end
    return A
end

function initialize_state_distribution(K::Int)
    # initialize a state distribution
    return rand(Dirichlet(ones(K)))
end


"""
    weighted_initialization(model::HiddenMarkovModel, data...)

Initialize the matrix with our custom weighted initialization method. Assigns responsibilities randomly, fits the emission models, and sets the transition matrix and initial state distribution to uniform priors.

# Arguments
- `model::HiddenMarkovModel`: The HiddenMarkovModel to initialize.
- `data...`: The data to fit the emission models.

# Examples
```jldoctest; output = true
μ = [3.0, 4.0]
emission_1 = Gaussian(output_dim=2, μ=μ)
μ = [-5.0, 2.0]
emission_2 = Gaussian(output_dim=2, μ=μ)

true_model = HiddenMarkovModel(K=2, B=[emission_1, emission_2])
states, Y = sample(true_model, n=1000)

est_model = HiddenMarkovModel(K=2, emission=Gaussian(output_dim=2))
weighted_initialization(est_model, Y)
fit!(est_model, Y)

loglikelihood(est_model, Y) > loglikelihood(true_model, Y)
# output
true
```
"""
function weighted_initialization(model::HiddenMarkovModel, data...)
    validate_model(model)
    validate_data(model, data...)

    # get the proper shape for class probabilities
    responsibilities = class_probabilities(model, data...)

    # replace each row in responsibilities with rand(Dirichlet(ones(K)))
    for i in 1:size(responsibilities, 1)
        responsibilities[i, :] = rand(Dirichlet(ones(model.K)))
    end

    # train each emission model with their randomized responsibilities
    for i in 1:model.K
        emission_fit!(model.B[i], data..., responsibilities[:, i])
    end

    # set the transition matrix to a uniform prior
    model.A = ones(Float64, model.K, model.K) / model.K

    # set the initial state distribution to a uniform prior
    model.πₖ = ones(Float64, model.K) / model.K
end


function HiddenMarkovModel(; 
    K::Int,
    B::Vector=Vector(),
    emission=nothing,
    A::Matrix{<:Real} = initialize_transition_matrix(K), 
    πₖ::Vector{Float64} = initialize_state_distribution(K))

    # if B does not have all K emission models, then fill in the rest with deep copies of "emission"
    if !isnothing(emission) && length(B) < K
        for i in length(B)+1:K
            push!(B, deepcopy(emission))
        end
    end


    emission_models = Emission.(B)

    model = HiddenMarkovModel(A, emission_models, πₖ, K)

    validate_model(model)
    
    return model
end

"""
    sample(model::HiddenMarkovModel, data...; n::Int)

Generate `n` samples from a Hidden Markov Model. Returns a tuple of the state sequence and the observation sequence.

# Arguments
- `model::HiddenMarkovModel`: The Hidden Markov Model to sample from.
- `data...`: The data to fit the Hidden Markov Model. Requires the same format as the emission model.
- `n::Int`: The number of samples to generate.

# Returns
- `state_sequence::Vector{Int}`: The state sequence, where each element is an integer 1:K.
- `observation_sequence::Matrix{Float64}`: The observation sequence. This takes the form of the emission model's output.

# Examples
```jldoctest; output = false, filter = r"(?s).*" => s""
model = HiddenMarkovModel(K=2, emission=Gaussian(output_dim=2))
states, Y = sample(model, n=1000)

model = HiddenMarkovModel(K=2, emission=GaussianRegression(input_dim=2, output_dim=2))
Φ = randn(100, 2)
states, Y = sample(model, Φ, n=10)
# output
```
"""
function sample(model::HiddenMarkovModel, data...; n::Int)
    # confirm model is valid
    validate_model(model)

    # confirm data is in the correct format
    validate_data(model, data...)


    state_sequence = [rand(Categorical(model.πₖ))]
    observation_sequence = emission_sample(model.B[state_sequence[1]], data...)

    for i in 2:n
        # sample the next state
        push!(state_sequence, rand(Categorical(model.A[state_sequence[end], :])))
        observation_sequence = emission_sample(model.B[state_sequence[i]], data...; observation_sequence=observation_sequence)
    end

    return state_sequence, observation_sequence
end

"""
    loglikelihood(model::HiddenMarkovModel, data...)

Calculate the log likelihood of the data given the Hidden Markov Model.

# Arguments
- `model::HiddenMarkovModel`: The Hidden Markov Model to calculate the log likelihood for.
- `data...`: The data to calculate the log likelihood for. Requires the same format as the emission model.

# Returns
- `loglikelihood::Float64`: The log likelihood of the data given the Hidden Markov Model.

# Examples
```jldoctest; output = false, filter = r"(?s).*" => s""
model = HiddenMarkovModel(K=2, emission=Gaussian(output_dim=2))
states, Y = sample(model, n=10)
loglikelihood(model, Y)
# output
```
"""
function loglikelihood(model::HiddenMarkovModel, data...)
    # confirm model is valid
    validate_model(model)

    # confirm data is in the correct format
    validate_data(model, data...)

    # Calculate observation wise likelihoods for all states
    loglikelihoods_state_1 = emission_loglikelihood(model.B[1], data...)
    loglikelihoods = zeros(model.K, length(loglikelihoods_state_1))
    loglikelihoods[1, :] = loglikelihoods_state_1

    @threads for k in 2:model.K
        loglikelihoods[k, :] = emission_loglikelihood(model.B[k], data...)
    end

    α = forward(model, loglikelihoods)
    return logsumexp(α[end, :])
end



function forward(model::HiddenMarkovModel, loglikelihoods::Matrix{<:Real})
    time_steps = size(loglikelihoods, 2)

    # Initialize an α-matrix 
    α = zeros(time_steps, model.K)

    # Calculate α₁
    @threads for k in 1:model.K
        α[1, k] = log(model.πₖ[k]) + loglikelihoods[k, 1]
    end
    # Now perform the rest of the forward algorithm for t=2 to time_steps
    for t in 2:time_steps
        @threads for k in 1:model.K
            values_to_sum = Float64[]
            for i in 1:model.K
                push!(values_to_sum, log(model.A[i, k]) + α[t-1, i])
            end
            log_sum_alpha_a = logsumexp(values_to_sum)
            α[t, k] = log_sum_alpha_a + loglikelihoods[k, t]
        end
    end
    return α
end

function backward(model::HiddenMarkovModel, loglikelihoods::Matrix{<:Real})
    time_steps = size(loglikelihoods, 2)

    # Initialize a β matrix
    β = zeros(Float64, time_steps, model.K)

    # Set last β values. In log-space, 0 corresponds to a value of 1 in the original space.
    β[end, :] .= 0  # log(1) = 0

    # Calculate β, starting from time_steps-1 and going backward to 1
    for t in time_steps-1:-1:1
        @threads for i in 1:model.K
            values_to_sum = Float64[]
            for j in 1:model.K
                push!(values_to_sum, log(model.A[i, j]) + loglikelihoods[j, t+1] + β[t+1, j])
            end
            β[t, i] = logsumexp(values_to_sum)
        end
    end
    return β
end

function calculate_γ(model::HiddenMarkovModel, α::Matrix{<:Real}, β::Matrix{<:Real})
    time_steps = size(α, 1)
    γ = α .+ β
    @threads for t in 1:time_steps
        γ[t, :] .-= logsumexp(γ[t, :])
    end
    return γ
end

function calculate_ξ(model::HiddenMarkovModel, α::Matrix{<:Real}, β::Matrix{<:Real}, loglikelihoods::Matrix{<:Real})
    time_steps = size(α, 1)
    ξ = zeros(Float64, time_steps-1, model.K, model.K)
    for t in 1:time_steps-1
        # Array to store the unnormalized ξ values
        log_ξ_unnormalized = zeros(Float64, model.K, model.K)
        @threads for i in 1:model.K
            for j in 1:model.K
                log_ξ_unnormalized[i, j] = α[t, i] + log(model.A[i, j]) + loglikelihoods[j, t+1] + β[t+1, j]
            end
        end
        # Normalize the ξ values using log-sum-exp operation
        ξ[t, :, :] .= log_ξ_unnormalized .- logsumexp(log_ξ_unnormalized)
    end
    return ξ
end


function E_step(model::HiddenMarkovModel, data)
    # run forward-backward algorithm

    # Calculate observation wise likelihoods for all states
    loglikelihoods_state_1 = emission_loglikelihood(model.B[1], data...)
    loglikelihoods = zeros(model.K, length(loglikelihoods_state_1))
    loglikelihoods[1, :] = loglikelihoods_state_1

    @threads for k in 2:model.K
        loglikelihoods[k, :] = emission_loglikelihood(model.B[k], data...)
    end

    α = forward(model, loglikelihoods)
    β = backward(model, loglikelihoods)
    γ = calculate_γ(model, α, β)
    ξ = calculate_ξ(model, α, β, loglikelihoods)
    return γ, ξ, α, β
end

function update_initial_state_distribution!(model::HiddenMarkovModel, γ::Matrix{<:Real})
    # Update initial state probabilities
    model.πₖ .= exp.(γ[1, :])
end

function update_transition_matrix!(model::HiddenMarkovModel, γ::Matrix{<:Real}, ξ::Array{Float64, 3})
    # Update transition probabilities
    @threads for i in 1:model.K
        for j in 1:model.K
            model.A[i, j] = exp(logsumexp(ξ[:, i, j]) - logsumexp(γ[1:end-1, i]))
        end
    end
end

function update_emissions!(model::HiddenMarkovModel, data, w::Matrix{<:Real})
    # update regression models 
 
     @threads for k in 1:model.K
         emission_fit!(model.B[k], data..., w[:, k])
     end
 
 end

function M_step!(model::HiddenMarkovModel, γ::Matrix{<:Real}, ξ::Array{Float64, 3}, data)
    # update initial state distribution
    update_initial_state_distribution!(model, γ)   
    # update transition matrix
    update_transition_matrix!(model, γ, ξ)
    # update regression models
    update_emissions!(model, data, exp.(γ)) 
end

"""
    fit!(model::HiddenMarkovModel, data...; max_iters::Int=100, tol::Float64=1e-6)

Fit the Hidden Markov Model using the EM algorithm.

# Arguments
- `model::HiddenMarkovModel`: The Hidden Markov Model to fit.
- `data...`: The data to fit the Hidden Markov Model. Requires the same format as the emission model.
- `max_iters::Int=100`: The maximum number of iterations to run the EM algorithm.
- `tol::Float64=1e-6`: When the log likelihood is improving by less than this value, the algorithm will stop.

# Examples
```jldoctest; output = true
μ = [3.0, 4.0]
emission_1 = Gaussian(output_dim=2, μ=μ)
μ = [-5.0, 2.0]
emission_2 = Gaussian(output_dim=2, μ=μ)

true_model = HiddenMarkovModel(K=2, B=[emission_1, emission_2])
states, Y = sample(true_model, n=1000)

est_model = HiddenMarkovModel(K=2, emission=Gaussian(output_dim=2))
weighted_initialization(est_model, Y)
fit!(est_model, Y)

loglikelihood(est_model, Y) > loglikelihood(true_model, Y)
# output
true
```
"""
function fit!(model::HiddenMarkovModel, data...; max_iters::Int=100, tol::Float64=1e-6)
    # confirm model is valid
    validate_model(model)

    # confirm data is in the correct format
    validate_data(model, data...)

    log_likelihood = -Inf
    # Initialize progress bar
    p = Progress(max_iters; dt=1, desc="Running EM algorithm...",)
    for iter in 1:max_iters
        # Update the progress bar
        next!(p; showvalues = [(:iteration, iter), (:log_likelihood, log_likelihood)])
        # E-Step
        γ, ξ, α, β = E_step(model, data)
        # Compute and update the log-likelihood
        log_likelihood_current = logsumexp(α[end, :])
        #println("iter $(iter) loglikelihood: ", log_likelihood_current)
        if abs(log_likelihood_current - log_likelihood) < tol
            finish!(p)
            break
        else
            log_likelihood = log_likelihood_current
        end
        # M-Step
        M_step!(model, γ, ξ, data)
    end


    # confirm model is valid
    validate_model(model)
end

"""
    class_probabilities(model::HiddenMarkovModel, data...)

Calculate the class probabilities for each observation. Returns a matrix of size `(T, K)` where `K` is the number of states and `T` is the number of observations.

# Arguments
- `model::HiddenMarkovModel`: The Hidden Markov Model to calculate the class probabilities for.
- `data...`: The data to calculate the class probabilities for. Requires the same format as the emission model loglikelihood() function.

# Returns
- `class_probabilities::Matrix{Float64}`: The class probabilities for each observation. Of shape `(T, K)`. Each row of the Matrix sums to 1.

# Examples
```jldoctest; output = false, filter = r"(?s).*" => s""

model = HiddenMarkovModel(K=2, emission=Gaussian(output_dim=2))
states, Y = sample(model, n=10)
class_probabilities(model, Y)
# output
```
"""
function class_probabilities(model::HiddenMarkovModel, data...)
    γ, ξ, α, β = E_step(model, data)
    return exp.(γ)
end




"""
    viterbi(model::HiddenMarkovModel, data...)

Calculate the most likely sequence of states given the data.

# Arguments
- `model::HiddenMarkovModel`: The Hidden Markov Model to calculate the most likely sequence of states for.
- `data...`: The data to calculate the most likely sequence of states for. Requires the same format as the emission model's loglikelihood() function.

# Returns
- `best_path::Vector{Int}`: The most likely sequence of states.

# Examples
```jldoctest; output = false, filter = r"(?s).*" => s""
emission_1 = Gaussian(output_dim=2, μ=[3.0, 4.0])
emission_2 = Gaussian(output_dim=2, μ=[-5.0, 2.0])
model = HiddenMarkovModel(K=2, B=[emission_1, emission_2])
states, Y = sample(model, n=100)
state_sequence = viterbi(model, Y)
# output
```
"""
function viterbi(model::HiddenMarkovModel, data...)
    # Calculate observation wise likelihoods for all states
    loglikelihoods_state_1 = emission_loglikelihood(model.B[1], data...)
    loglikelihoods = zeros(model.K, length(loglikelihoods_state_1))
    loglikelihoods[1, :] = loglikelihoods_state_1

    @threads for k in 2:model.K
        loglikelihoods[k, :] = emission_loglikelihood(model.B[k], data...)
    end

    T = length(loglikelihoods_state_1)
    K = size(model.A, 1)  # Number of states

    # Step 1: Initialization
    viterbi = zeros(Float64, T, K)
    backpointer = zeros(Int, T, K)
    for i in 1:K
        viterbi[1, i] = log(model.πₖ[i]) + loglikelihoods[i, 1]
        backpointer[1, i] = 0
    end

    # Step 2: Recursion
    for t in 2:T
        for j in 1:K
            max_prob, max_state = -Inf, 0
            for i in 1:K
                prob = viterbi[t-1, i] + log(model.A[i, j]) + loglikelihoods[j, t]
                if prob > max_prob
                    max_prob = prob
                    max_state = i
                end
            end
            viterbi[t, j] = max_prob
            backpointer[t, j] = max_state
        end
    end

    # Step 3: Termination
    best_path_prob, best_last_state = findmax(viterbi[T, :])
    best_path = [best_last_state]
    for t in T:-1:2
        push!(best_path, backpointer[t, best_path[end]])
    end
    return reverse(best_path)
end