# log posterior = log likelihood + log prior
# log Pr(Θ|YY)  = log Pr(YY|Θ)   + log Pr(Θ)
function posterior{T<:FloatingPoint}(model::AbstractModel, YY::Matrix{T}; mh::Bool = false)
    if mh
        like, out = likelihood(model, YY; mh=mh)
        post = like + prior(model.Θ)
        return post, like, out
    else
        return likelihood(model, YY; mh=mh) + prior(model.Θ)
    end
end

# Evaluate posterior at `parameters`
function posterior!{T<:FloatingPoint}(parameters::Vector{T}, model::AbstractModel, YY::Matrix{T}; mh::Bool = false)
    update!(model.Θ, parameters)
    return posterior(model, YY; mh=mh)
end



# This is a dsge likelihood function that can handle 2-part estimation where
# there is a model switch.
# If there is no model switch, then we filter over the main sample all at once.
function likelihood{T<:FloatingPoint}(model::AbstractModel, YY::Matrix{T}; mh::Bool = false)
    
    # During Metropolis-Hastings, return -∞ if any parameters are not within their bounds
    if mh
        for α in model.Θ
            (left, right) = α.bounds
            if !α.fixed && !(left <= α.value <= right)
                return -Inf, Dict{String, Any}()
            end
        end
    end
    
    spec = model.spec

    # Partition sample into presample, normal, and zero lower bound periods
    presample = Dict{String, Any}()
    normal = Dict{String, Any}()
    zlb = Dict{String, Any}()
    mt = [presample, normal, zlb]

    presample["n_observables"] = spec["n_observables"] - spec["nant"]
    normal["n_observables"] = spec["n_observables"] - spec["nant"]
    zlb["n_observables"] = spec["n_observables"]

    presample["n_states"] = spec["n_states_aug"] - spec["nant"]
    normal["n_states"] = spec["n_states_aug"] - spec["nant"]
    zlb["n_states"] = spec["n_states_aug"]

    presample["YY"] = YY[1:spec["n_presample_periods"], 1:presample["n_observables"]]
    normal["YY"] = YY[(spec["n_presample_periods"]+1):(end-spec["antlags"]-1), 1:normal["n_observables"]]
    zlb["YY"] = YY[(end-spec["antlags"]):end, :]


    
    ## step 1: solution to DSGE model - delivers transition equation for the state variables  S_t
    ## transition equation: S_t = TC+TTT S_{t-1} +RRR eps_t, where var(eps_t) = QQ
    zlb["TTT"], zlb["RRR"], zlb["CCC"] = solve(model::AbstractModel)

    # Get normal, no ZLB model matrices
    state_inds = [1:(spec["n_states"]-spec["nant"]); (spec["n_states"]+1):spec["n_states_aug"]]
    shock_inds = 1:(spec["n_exoshocks"]-spec["nant"])

    normal["TTT"] = zlb["TTT"][state_inds, state_inds]
    normal["RRR"] = zlb["RRR"][state_inds, shock_inds]
    normal["CCC"] = zlb["CCC"][state_inds, :]


    
    ## step 2: define the measurement equation: X_t = ZZ*S_t + D + u_t
    ## where u_t = eta_t+MM* eps_t with var(eta_t) = EE
    ## where var(u_t) = HH = EE+MM QQ MM', cov(eps_t,u_t) = VV = QQ*MM'

    # Get measurement equation matrices set up for all periods that aren't the presample
    for p = 2:3
        #try
            shocks = (p == 3)
            mt[p]["ZZ"], mt[p]["DD"], mt[p]["QQ"], mt[p]["EE"], mt[p]["MM"] = measurement(model, mt[p]["TTT"], mt[p]["RRR"], mt[p]["CCC"]; shocks=shocks)
        #catch 
            # Error thrown during gensys
            #    return -Inf
        #end

        mt[p]["HH"] = mt[p]["EE"] + mt[p]["MM"]*mt[p]["QQ"]*mt[p]["MM"]'
        mt[p]["VV"] = mt[p]["QQ"]*mt[p]["MM"]'
        mt[p]["VVall"] = [[mt[p]["RRR"]*mt[p]["QQ"]*mt[p]["RRR"]'   mt[p]["RRR"]*mt[p]["VV"]];
                          [mt[p]["VV"]'*mt[p]["RRR"]'               mt[p]["HH"]]]
    end

    # TODO: Incorporate this into measurement equation (why is this only done for normal period?)
    # Adjustment to DD because measurement equation assumes CCC is the zero vector
    if any(normal["CCC"] != 0)
        normal["DD"] += normal["ZZ"]*((UniformScaling(1) - normal["TTT"])\normal["CCC"])
    end

    # Presample measurement & transition equation matrices are same as normal period
    presample["TTT"], presample["RRR"], presample["QQ"] = normal["TTT"], normal["RRR"], normal["QQ"]
    presample["ZZ"], presample["DD"], presample["VVall"] = normal["ZZ"], normal["DD"], normal["VVall"]

    
    
    ## step 3: compute log-likelihood using Kalman filter - written by Iskander
    ##         note that Iskander's program assumes a transition equation written as:
    ##         S_t = TTT S_{t-1} +eps2_t, where eps2_t = RRReps_t
    ##         therefore redefine QQ2 = var(eps2_t) = RRR*QQ*RRR'
    ##         and  VV2 = cov(eps2_t,u_u) = RRR*VV
    ##         define VVall as the joint variance of the two shocks VVall = var([eps2_tu_t])

    # Run Kalman filter on presample
    presample["A0"] = zeros(presample["n_states"], 1)
    presample["P0"] = dlyap!(copy(presample["TTT"]), copy(presample["RRR"]*presample["QQ"]*presample["RRR"]'))
    presample["pyt"], presample["zend"], presample["Pend"] = kalcvf2NaN(presample["YY"]', 1, zeros(presample["n_states"], 1), presample["TTT"], presample["DD"], presample["ZZ"], presample["VVall"], presample["A0"], presample["P0"])

    # Run Kalman filter on normal and ZLB periods
    for p = 2:3
        if p == 2
            zprev = presample["zend"]
            Pprev = presample["Pend"]
        else
            # This section expands the number of states to accomodate extra states for the
            # anticipated policy shocks. It does so by taking the zend and Pend for the
            # state space without anticipated policy shocks, then shoves in nant
            # zeros in the middle of zend and Pend in the location of
            # the anticipated shock entries.
            before_shocks = 1:(spec["n_states"]-spec["nant"])
            after_shocks_old = (spec["n_states"]-spec["nant"]+1):(spec["n_states_aug"]-spec["nant"])
            after_shocks_new = (spec["n_states"]+1):spec["n_states_aug"]
            
            zprev = [normal["zend"][before_shocks, :];
                     zeros(spec["nant"], 1);
                     normal["zend"][after_shocks_old, :]]

            Pprev = zeros(spec["n_states_aug"], spec["n_states_aug"])
            Pprev[before_shocks, before_shocks] = normal["Pend"][before_shocks, before_shocks]
            Pprev[before_shocks, after_shocks_new] = normal["Pend"][before_shocks, after_shocks_old]
            Pprev[after_shocks_new, before_shocks] = normal["Pend"][after_shocks_old, before_shocks]
            Pprev[after_shocks_new, after_shocks_new] = normal["Pend"][after_shocks_old, after_shocks_old]
        end
        
        mt[p]["pyt"], mt[p]["zend"], mt[p]["Pend"] = kalcvf2NaN(mt[p]["YY"]', 1, zeros(mt[p]["n_states"], 1), mt[p]["TTT"], mt[p]["DD"], mt[p]["ZZ"], mt[p]["VVall"], zprev, Pprev)
    end

    # Return total log-likelihood, excluding the presample
    like = normal["pyt"] + zlb["pyt"]
    if mh
        return like, zlb
    else
        return like
    end
end





# DLYAP   Discrete Lyapunov equation solver.
#
#    X = DLYAP(A,Q) solves the discrete Lyapunov equation:
#
#     A*X*A' - X + Q = 0
#
#    See also  LYAP.

#  J.N. Little 2-1-86, AFP 7-28-94
#  Copyright 1986-2001 The MathWorks, Inc.
#  $Revision: 1.11 $  $Date: 2001/01/18 19:50:01 $

#LYAP  Solve continuous-time Lyapunov equations.
#
#   x = LYAP(a,c) solves the special form of the Lyapunov matrix
#   equation:
#
#           a*x + x*a' = -c
#
#   See also  DLYAP.

#  S.N. Bangert 1-10-86
#  Copyright 1986-2001 The MathWorks, Inc.
#  $Revision: 1.10 $  $Date: 2001/01/18 19:50:23 $
#  Last revised JNL 3-24-88, AFP 9-3-95

# How to prove the following conversion is true.  Re: show that if
#         (1) Ad X Ad' + Cd = X             Discrete lyaponuv eqn
#         (2) Ac = inv(Ad + I) (Ad - I)     From dlyap
#         (3) Cc = (I - Ac) Cd (I - Ac')/2  From dlyap
# Then
#         (4) Ac X + X Ac' + Cc = 0         Continuous lyapunov
#
# Step 1) Substitute (2) into (3)
#         Use identity 2*inv(M+I) = I - inv(M+I)*(M-I)
#                                 = I - (M-I)*inv(M+I) to show
#         (5) Cc = 4*inv(Ad + I)*Cd*inv(Ad' + I)
# Step 2) Substitute (2) and (5) into (4)
# Step 3) Replace (Ad - I) with (Ad + I -2I)
#         Replace (Ad' - I) with (Ad' + I -2I)
# Step 4) Multiply through and simplify to get
#         X -inv(Ad+I)*X -X*inv(Ad'+I) +inv(Ad+I)*Cd*inv(Ad'+I) = 0
# Step 5) Left multiply by (Ad + I) and right multiply by (Ad' + I)
# Step 6) Simplify to (1)
function dlyap!(a, c)
    m, n = size(a)
    a = (a + UniformScaling(1))\(a - UniformScaling(1))
    c = (UniformScaling(1)-a)*c*(UniformScaling(1)-a')/2

    mc, nc = size(c)

    # a and c must be square and the same size
    if (m != n) || (m != mc) || (n != nc)
        error("Dimensions do not agree.")
    elseif m == 0
        x = zeros(m, m)
        return x
    end

    # Perform schur decomposition on a (and convert to complex form)
    ta, ua, _ = schur(complex(a)) # matlab code converts to complex - come back to
    # ua, ta = rsf2csf(ua, ta)
    # Schur decomposition of a' can be calculated from that of a.
    j = m:-1:1
    ub = ua[:, j]
    tb = ta[j ,j]'
    
    # Check all combinations of ta(i, i)+tb(j, j) for zero
    p1 = diag(ta).' # Use .' instead of ' in case a and a' are not real
    p2 = diag(tb)
    p_sum = abs(p1) .+ abs(p2)
    if any(p_sum .== 0) || any(abs(p1 .+ p2) .< 1000*eps()*p_sum)
        error("Solution does not exist or is not unique.")
    end

    # Transform c
    ucu = -ua'*c*ub

    # Solve for first column of transformed solution
    y = complex(zeros(n, n))
    y[:, 1] = (ta + UniformScaling(tb[1, 1]))\ucu[:, 1]

    # Solve for remaining columns of transformed solution
    for k=1:n-1
        km1 = 1:k
        y[:, k+1] = (ta + UniformScaling(tb[k+1, k+1]))\(ucu[:, k+1] - y[:, km1]*tb[km1, k+1])
    end

    # Find untransformed solution
    x = ua*y*ub'

    # Ignore complex part if real inputs (better be small)
    if isreal(a) && isreal(c)
        x = real(x)
    end

    # Force x to be symmetric if c is symmetric
    if issym(c)
        x = (x+x')/2
    end

    return x
end