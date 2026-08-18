import AppctlCore
import ArgumentParser

/// Lives in the CLI target (not AppctlCore) because generating the script needs
/// the root `Appctl` type — completions cover the whole command tree.
struct CompletionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "completions",
        abstract: "Print a shell completion script for zsh, bash, or fish.",
        discussion: """
            Install:
              zsh:  appctl completions zsh > ~/.zsh/completions/_appctl
              bash: appctl completions bash > /usr/local/etc/bash_completion.d/appctl
              fish: appctl completions fish > ~/.config/fish/completions/appctl.fish
            """)

    @Argument(help: "The shell to generate a script for: zsh, bash, or fish.")
    var shell: String

    func run() throws {
        try Self.execute(shell: shell)
    }

    static func execute(shell: String) throws {
        guard let target = CompletionShell(rawValue: shell.lowercased()) else {
            throw AppctlError.invalidInput(
                field: "shell", value: shell,
                expected: CompletionShell.allCases.map(\.rawValue).joined(separator: ", "))
        }
        print(Appctl.completionScript(for: target))
    }
}
