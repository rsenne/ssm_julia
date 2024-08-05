export HiddenMarkovModel, fit!

mutable struct HiddenMarkovModel <: Model
    A::Matrix{<:Real} # transition matrix
    B::Vector{Model} # Vector of emission Models
    πₖ::Vector{Float64} # initial state distribution
    K::Int # number of states
end

function validate_model(model::HiddenMarkovModel)
    # check that the transition matrix is the proper shape
    @assert size(model.A) == (model.K, model.K)
    # check that the initial state distribution is the same length as the number of states
    @assert model.K == length(model.πₖ)
    # check that the number of states is equal to the number of emission models
    @assert model.K == length(model.B)
    # check that all emission model are the same type
    @assert all([model.B[1] isa typeof(model.B[i]) for i in 2:length(model.B)])

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

function HiddenMarkovModel(; 
    K::Int,
    emission::Model,
    A::Matrix{<:Real} = initialize_transition_matrix(K), 
    πₖ::Vector{Float64} = initialize_state_distribution(K))

    B = [deepcopy(emission) for _ in 1:K]

    model = HiddenMarkovModel(A, B, πₖ, K)

    validate_model(model)
    
    return model
end

# not most efficient method. in future, could set up a more direct mapping by emission type.
function number_of_observations(model::HiddenMarkovModel, data)
    return length(loglikelihood(model.B[1], data..., observation_wise=true))
end


function sample(model::HiddenMarkovModel, data...; n::Int=number_of_observations(model, data))
    T = n

    # confirm model is valid
    validate_model(model)

    # confirm data is in the correct format
    validate_data(model, data...)


    # sample all observations for every state
    # not most efficient, but allows for general "data" object
    possible_observations = Vector{Matrix{Float64}}()

    for k in 1:model.K
        push!(possible_observations, sample(model.B[k], data...; n=n))
    end


    # Initialize the state sequence
    state_sequence = zeros(Int, T)
    # Initialize the observation sequence
    observation_sequence = zeros(Float64, T, size(possible_observations[1], 2))

    # Sample the initial state
    state_sequence[1] = rand(Categorical(model.πₖ))
    observation_sequence[1, :] = sample(model.B[state_sequence[1]], data...)

    # Sample the rest of the states and observations
    for t in 2:T
        state_sequence[t] = rand(Categorical(model.A[state_sequence[t-1], :]))
        observation_sequence[t, :] = possible_observations[state_sequence[t]][t, :]
    end

    return state_sequence, observation_sequence
end



function forward(model::HiddenMarkovModel, data, loglikelihoods::Matrix{<:Real}, T::Int)
    # Initialize an α-matrix 
    α = zeros(T, model.K)

    # Calculate α₁
    @threads for k in 1:model.K
        α[1, k] = log(model.πₖ[k]) + loglikelihoods[k, 1]
    end
    # Now perform the rest of the forward algorithm for t=2 to T
    for t in 2:T
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

function backward(model::HiddenMarkovModel, data, loglikelihoods::Matrix{<:Real}, T::Int)
    # Initialize a β matrix
    β = zeros(Float64, T, model.K)

    # Set last β values. In log-space, 0 corresponds to a value of 1 in the original space.
    β[T, :] .= 0  # log(1) = 0

    # Calculate β, starting from T-1 and going backward to 1
    for t in T-1:-1:1
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
    T = size(α, 1)
    γ = α .+ β
    @threads for t in 1:T
        γ[t, :] .-= logsumexp(γ[t, :])
    end
    return γ
end

function calculate_ξ(model::HiddenMarkovModel, α::Matrix{<:Real}, β::Matrix{<:Real}, loglikelihoods::Matrix{<:Real})
    T = size(α, 1)
    ξ = zeros(Float64, T-1, model.K, model.K)
    for t in 1:T-1
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


function E_step(model::HiddenMarkovModel, data, T::Int)
    # run forward-backward algorithm

    # Calculate observation wise likelihoods for all states
    loglikelihoods = zeros(model.K, T)
    @threads for k in 1:K
        loglikelihoods[k, :] = loglikelihood(model.B[k], data..., observation_wise=true)
    end

    α = forward(model, data, loglikelihoods, T)
    β = backward(model, data, loglikelihoods, T)
    γ = calculate_γ(model, α, β)
    ξ = calculate_ξ(model, α, β, loglikelihoods)
    return γ, ξ, α, β
end

function update_initial_state_distribution!(model::HiddenMarkovModel, γ::Matrix{<:Real})
    # Update initial state probabilities
    model.πₖ .= exp.(γ[1, :])
end

function update_transition_matrix!(model::HiddenMarkovModel, γ::Matrix{<:Real}, ξ::Array{Float64, 3})
    T = size(γ, 1)
    # Update transition probabilities
    @threads for i in 1:model.K
        for j in 1:model.K
            model.A[i, j] = exp(logsumexp(ξ[:, i, j]) - logsumexp(γ[1:T-1, i]))
        end
    end
end

function update_emissions!(model::HiddenMarkovModel, data, w::Matrix{<:Real})
    # update regression models 
 
     @threads for k in 1:model.K
         fit!(model.B[k], data..., weights=w[:, k])
     end
 
 end

function M_step!(model::HiddenMarkovModel, γ::Matrix{<:Real}, ξ::Array{Float64, 3}, data, T::Int)
    # update initial state distribution
    update_initial_state_distribution!(model, γ)   
    # update transition matrix
    update_transition_matrix!(model, γ, ξ)
    # update regression models
    update_emissions!(model, data, exp.(γ)) 
end


function fit!(model::HiddenMarkovModel, data...; max_iters::Int=100, tol::Float64=1e-6)
    # confirm model is valid
    validate_model(model)

    # confirm data is in the correct format
    validate_data(model, data...)

    T = number_of_observations(model, data)

    log_likelihood = -Inf
    # Initialize progress bar
    p = Progress(max_iters; dt=1, desc="Computing Baum-Welch...",)
    for iter in 1:max_iters
        # Update the progress bar
        next!(p; showvalues = [(:iteration, iter), (:log_likelihood, log_likelihood)])
        # E-Step
        γ, ξ, α, β = E_step(model, data, T)
        # Compute and update the log-likelihood
        log_likelihood_current = logsumexp(α[T, :])
        println(log_likelihood_current)
        if abs(log_likelihood_current - log_likelihood) < tol
            finish!(p)
            break
        else
            log_likelihood = log_likelihood_current
        end
        # M-Step
        M_step!(model, γ, ξ, data, T)
    end


    # confirm model is valid
    validate_model(model)
end