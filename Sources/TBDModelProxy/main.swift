// TBDModelProxy's entry point: one call into `Proxy.swift`, which holds every
// decision this process makes — argument parsing, the exit-code taxonomy, the
// signal handling — so all of it can be exercised from `TBDModelProxyTests`
// without spawning a binary. Same division as `TBDHolder`/`Holder.swift`.
//
// Deliberately no diagnostics here: `run()` is `-> Never` and reports its own
// failures on stderr with the usage line.

TBDModelProxyMain.run()
