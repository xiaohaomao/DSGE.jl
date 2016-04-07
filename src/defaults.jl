"""
```
default_settings!(m::AbstractModel)
```

Default Settings are constructed, initialized and added to `m.settings`.
"""
function default_settings!(m::AbstractModel)

    # I/O File locations
    saveroot = normpath(joinpath(dirname(@__FILE__), "..","save"))
    datapath = normpath(joinpath(dirname(@__FILE__), "..","save","input_data"))

    m <= Setting(:saveroot, saveroot, "Root of data directory structure")
    m <= Setting(:dataroot, datapath, "Input data directory path")

    # Data settings for released and conditional data. Default behavior is to set vintage
    # of data to today's date.
    vint = Dates.format(now(), DSGE_DATE_FORMAT)
    m <= Setting(:data_vintage, vint, true, "vint", "Vintage of data")
    m <= Setting(:cond_vintage, vint, "Vintage of conditional data")
    m <= Setting(:cond_id, "0000", "Identifier of conditional dataset")
    m <= Setting(:use_population_forecast, false, "Whether to use population forecasts as data")

    # Dates
    ffq = lastdayofquarter(Date(data_vintage(m), DSGE_DATE_FORMAT) + Year(2000))
    m <= Setting(:first_forecast_quarter, ffq, "First quarter for which to produce forecasts.")

    # Anticipated shocks
    zlb_start = Date("2008-12-31","y-m-d")
    m <= Setting(:zlb_start_date,  zlb_start, "First period to incorporate zero bound expectation")
    m <= Setting(:n_presample_periods, 2, "Number of periods in the presample")
    m <= Setting(:n_anticipated_shocks, 0, "Number of anticipated policy shocks")
    m <= Setting(:n_anticipated_shocks_padding, 20, "Padding for anticipated policy shocks")
    m <= Setting(:zlb_start_index, 198, "Index of first period to incorporate zero bound expectation")

    # General computation
    m <= Setting(:use_parallel_workers, true, "Use available parallel workers in computations")

    # Estimation
    m <= Setting(:reoptimize, true, "Optimize the posterior mode. If false, reads in mode from a file.")
    m <= Setting(:calculate_hessian, true, "Calculate the hessian at the mode")
    m <= Setting(:n_hessian_test_params, typemax(Int), "Max number of free params for which to calculate Hessian")

    # Metropolis-Hastings
    m <= Setting(:n_mh_simulations, 10000, "Number of draws per block in Metropolis-Hastings")
    m <= Setting(:n_mh_blocks, 22, "Number of blocks for Metropolis-Hastings")
    m <= Setting(:n_mh_burn, 2, "Number of blocks to use as burn-in in Metropolis-Hastings")
    m <= Setting(:mh_thin, 5, "Metropolis-Hastings thinning step")

    # Forecast
    m <= Setting(:use_expected_rate_data, (n_anticipated_shocks(m) > 0), "Use data on expected future interest rates")
    m <= Setting(:forecast_horizons, 60, "Forecast horizons")
    m <= Setting(:forecast_observables, :all, "Observables to forecast")
    m <= Setting(:forecast_kill_shocks, false, "Kill (set to 0) all shocks in forecast")
    m <= Setting(:forecast_tdist_shocks, false, "Draw Students-t distributed shocks in forecast")
    m <= Setting(:forecast_tdist_draw_df, false, "Draw Students-t degrees of freedom parameter")
    m <= Setting(:forecast_tdist_df_val, 15, "Students-t degrees of freedom fixed value")
    m <= Setting(:forecast_use_simulation_smoother, true, "Use Durbin-Koopman (2002) simulation smoother")
    m <= Setting(:forecast_jstep, 5, "Forecast thinning step (in addition to MH thinning step")
    m <= Setting(:forecast_enforce_zlb, true, "Enforce zero lower bound in forecast periods")
    m <= Setting(:shockdec_startindex, 190, "Index of start of shock decomposition output period")
    m <= Setting(:shockdec_endindex, 50000, "Index of end of shock decomposition output period")
    m <= Setting(:shockdec_whichshocks, :all, "Sets of shocks for which to conduct shock decomposition")

end
