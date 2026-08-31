import Foundation

// TBDHolder — one process per holder-transport session.
//
// PLACEHOLDER. The target exists now so the creation lock, the rendezvous
// paths and the wire protocol have a product to be built against, and so the
// daemon's test target can depend on a binary that will exist. The real entry
// point — adopt the inherited creation-lock fd, bind the rendezvous socket,
// `forkpty()` the job, serve `handOverPTY`, report exit — lands with the
// holder itself.
//
// It exits nonzero rather than succeeding silently: a spawner that reaches
// this build by mistake must fail loudly at spawn time, not hand back a
// session whose pty nobody owns.
//
// stderr, not `print()` — `no_print_in_sources` covers this target, and the
// daemon reads a holder's stderr as its diagnostic channel.

FileHandle.standardError.write(Data("TBDHolder: not implemented yet\n".utf8))
exit(1)
