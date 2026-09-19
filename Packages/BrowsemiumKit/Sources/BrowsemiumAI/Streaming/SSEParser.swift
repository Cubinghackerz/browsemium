import Foundation

public struct SSEParser: Sendable {
    public struct Event: Sendable, Equatable {
        public let type: String?
        public let data: String

        public init(type: String? = nil, data: String) {
            self.type = type
            self.data = data
        }
    }

    private var buffer: [UInt8] = []
    private var dataLines: [String] = []
    private var eventType: String?

    public init() {}

    public mutating func consume(_ chunk: String) -> [Event] {
        buffer.append(contentsOf: chunk.utf8)
        return drain(consumingTrailingCarriageReturn: true)
    }

    public mutating func finish() -> [Event] {
        var events = drain(consumingTrailingCarriageReturn: false)
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            if let event = process(line) {
                events.append(event)
            }
        }
        if let event = flush() {
            events.append(event)
        }
        return events
    }

    private mutating func drain(consumingTrailingCarriageReturn: Bool) -> [Event] {
        var events: [Event] = []
        var lineStart = 0
        var index = 0

        while index < buffer.count {
            let byte = buffer[index]
            guard byte == 0x0A || byte == 0x0D else {
                index += 1
                continue
            }

            if byte == 0x0D, index == buffer.count - 1, consumingTrailingCarriageReturn {
                break
            }

            let line = String(decoding: buffer[lineStart..<index], as: UTF8.self)
            if byte == 0x0D, index + 1 < buffer.count, buffer[index + 1] == 0x0A {
                index += 1
            }
            if let event = process(line) {
                events.append(event)
            }
            lineStart = index + 1
            index += 1
        }

        if lineStart > 0 {
            buffer.removeFirst(lineStart)
        }
        return events
    }

    private mutating func process(_ line: String) -> Event? {
        if line.isEmpty {
            return flush()
        }
        if line.hasPrefix(":") {
            return nil
        }

        let field: String
        var value: String
        if let colonIndex = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colonIndex])
            let afterColon = line.index(after: colonIndex)
            value = String(line[afterColon...])
            if value.hasPrefix(" ") {
                value.removeFirst()
            }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "data":
            dataLines.append(value)
        case "event":
            eventType = value
        default:
            break
        }
        return nil
    }

    private mutating func flush() -> Event? {
        guard !dataLines.isEmpty else {
            eventType = nil
            return nil
        }
        let data = dataLines.joined(separator: "\n")
        let event = Event(type: eventType, data: data)
        dataLines.removeAll()
        eventType = nil
        return event
    }
}
