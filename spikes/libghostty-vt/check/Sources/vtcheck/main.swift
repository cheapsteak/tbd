// vtcheck: headless engine check of libghostty-vt against the SwiftTerm fork TBD pins.
// See ../../RESULTS.md. THROWAWAY.
import Foundation
import GhosttyVt

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "corpus": runCorpus(arguments: Array(args.dropFirst()))
case "bench": runBench(arguments: Array(args.dropFirst()))
case "memory": runMemory(arguments: Array(args.dropFirst()))
case "memory-child": runMemoryChild(arguments: Array(args.dropFirst()))
case "diff": runDiff(arguments: Array(args.dropFirst()))
case "handover": runHandover(arguments: Array(args.dropFirst()))
case "signals": runSignals(arguments: Array(args.dropFirst()))
case "show": runShow(arguments: Array(args.dropFirst()))
case "sidecheck": runSideCheck(arguments: Array(args.dropFirst()))
case "tabs": runTabs(arguments: Array(args.dropFirst()))
default:
    print("usage: vtcheck corpus|bench|memory|diff|handover|signals|sidecheck|show|tabs")
    print("libghostty-vt \(String(cString: ghostty_version()))")
}
