import ArgumentParser
import Foundation
import MCP

// MARK: - MCP

struct MCP_Command: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Start an MCP server for speech transcription."
    )

    mutating func run() async throws {
        let server = Server(
            name: "yap",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [
                Tool(
                    name: "transcribe",
                    description: "Transcribe speech from an audio or video file using on-device speech recognition.",
                    inputSchema: .object([
                        "type": "object",
                        "properties": .object([
                            "file": .object([
                                "type": "string",
                                "description": "Absolute path to an audio or video file.",
                            ]),
                            "locale": .object([
                                "type": "string",
                                "description": "BCP 47 locale identifier (e.g. \"en-US\"). Defaults to the system locale.",
                            ]),
                            "format": .object([
                                "type": "string",
                                "description": "Output format: \"txt\", \"srt\", \"vtt\", or \"json\".",
                                "default": "txt",
                                "enum": .array(["txt", "srt", "vtt", "json"]),
                            ]),
                            "maxLength": .object([
                                "type": "integer",
                                "description": "Maximum sentence length in characters for timed output formats.",
                                "default": 40,
                            ]),
                            "censor": .object([
                                "type": "boolean",
                                "description": "Replace certain words with a redacted form.",
                                "default": false,
                            ]),
                            "wordTimestamps": .object([
                                "type": "boolean",
                                "description": "Include word-level timestamps in JSON output.",
                                "default": false,
                            ]),
                        ]),
                        "required": .array(["file"]),
                    ])
                ),
            ])
        }

        await server.withMethodHandler(CallTool.self) { request in
            guard request.name == "transcribe" else {
                return CallTool.Result(content: [.text("Unknown tool: \(request.name)")], isError: true)
            }

            guard let filePath = request.arguments?["file"]?.stringValue else {
                return CallTool.Result(content: [.text("Missing required parameter: file")], isError: true)
            }

            var options = TranscriptionEngine.Options()

            if let locale = request.arguments?["locale"]?.stringValue {
                options.locale = Locale(identifier: locale)
            }

            if let format = request.arguments?["format"]?.stringValue {
                switch format {
                case "srt": options.outputFormat = .srt
                case "vtt": options.outputFormat = .vtt
                case "json": options.outputFormat = .json
                default: options.outputFormat = .txt
                }
            }

            if let maxLength = request.arguments?["maxLength"]?.intValue {
                options.maxLength = maxLength
            }

            if let censor = request.arguments?["censor"]?.boolValue {
                options.censor = censor
            }

            if let wordTimestamps = request.arguments?["wordTimestamps"]?.boolValue {
                options.wordTimestamps = wordTimestamps
            }

            do {
                let result = try await TranscriptionEngine.transcribe(
                    file: URL(fileURLWithPath: filePath),
                    options: options
                )
                return CallTool.Result(content: [.text(result)])
            } catch {
                return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
            }
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}
