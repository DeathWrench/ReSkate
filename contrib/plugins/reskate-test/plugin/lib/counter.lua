-- For the require checks: counts how many times this module ran.
ptest_counter_loads = (ptest_counter_loads or 0) + 1
return {
    loads = function() return ptest_counter_loads end,
}
