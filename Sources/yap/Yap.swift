import ArgumentParser

// MARK: - yap

@main struct Yap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A CLI for on-device speech transcription.",
        subcommands: [
            Transcribe.self,
            Listen.self,
            Dictate.self,
            MCP_Command.self,
        ],
        defaultSubcommand: Transcribe.self
    )
}
