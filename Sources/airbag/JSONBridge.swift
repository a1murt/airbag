import AirbagCore

enum JSONOutputBridge {
    static func string(_ value: Any) -> String { JSONOutput.string(value, pretty: true) }
}
