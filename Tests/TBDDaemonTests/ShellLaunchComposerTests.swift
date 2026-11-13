import Foundation
import Testing
@testable import TBDDaemonLib

@Test func testShellFlagsPerShellFamily() {
    // Each branch of the flag choice, with hardcoded expectations: csh and
    // tcsh reject -l when combined with -c (measured: "Unknown option: `-l'"),
    // so they keep the pre-login-shell -i -c. Every other shell gets the
    // interactive login -i -l -c. Flags are separate argv elements, never
    // clustered, because some shells (e.g. nushell) reject GNU-style
    // clustering while accepting the individual flags.
    #expect(ShellLaunchComposer.shellFlags(forShell: "/bin/tcsh") == ["-i", "-c"])
    #expect(ShellLaunchComposer.shellFlags(forShell: "/bin/csh") == ["-i", "-c"])
    // The lowercased basename decides, not the full path or its case.
    #expect(ShellLaunchComposer.shellFlags(forShell: "/usr/local/bin/tcsh") == ["-i", "-c"])
    #expect(ShellLaunchComposer.shellFlags(forShell: "/bin/TCSH") == ["-i", "-c"])
    #expect(ShellLaunchComposer.shellFlags(forShell: "/opt/weird/wrappers/deep/path/csh") == ["-i", "-c"])
    #expect(ShellLaunchComposer.shellFlags(forShell: "/bin/zsh") == ["-i", "-l", "-c"])
    #expect(ShellLaunchComposer.shellFlags(forShell: "/bin/bash") == ["-i", "-l", "-c"])
    #expect(ShellLaunchComposer.shellFlags(forShell: "/opt/homebrew/bin/fish") == ["-i", "-l", "-c"])
    // Degenerate paths fall into the default branch rather than crashing.
    #expect(ShellLaunchComposer.shellFlags(forShell: "") == ["-i", "-l", "-c"])
    #expect(ShellLaunchComposer.shellFlags(forShell: "/") == ["-i", "-l", "-c"])
    #expect(ShellLaunchComposer.shellFlags(forShell: "/bin/") == ["-i", "-l", "-c"])
}
