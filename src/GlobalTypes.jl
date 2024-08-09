"""
The purpose of this file is to provide a common place for all global types to be defined. This is to avoid circular dependencies between files.
"""

export Model, RegressionModel, BasicModel, MixtureModel, EmissionsModel, AbstractHMM, DynamicalSystem, EmissionModel


# Create abstract types here 

"""
Abstract type for all Models. 
"""

abstract type Model end

"""
Abstract type for Mixture Models. I.e. GMM's, etc.
"""

abstract type MixtureModel <: Model end

"""
Abstract type for Basic Models. I.e. Poisson, Gaussian, etc.
"""

abstract type BasicModel <: Model end

"""
Abstract type for Regression Models. I.e. GaussianRegression, BernoulliRegression, etc.
"""

abstract type RegressionModel <: Model end


"""
Abstract type for Dynamical Systems. I.e. LDS, etc.
"""
abstract type DynamicalSystem <: Model end

"""
Abstract type for emission models. I.e. Gaussian, Poisson, Regressions, etc.
"""

abstract type EmissionModel <: Model end