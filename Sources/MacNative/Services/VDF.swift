import Foundation

/// Minimal parser for Valve's text KeyValues format (`.acf`, `.vdf`).
enum VDF {
    indirect enum Node {
        case value(String)
        case object([(String, Node)])

        subscript(key: String) -> Node? {
            guard case let .object(pairs) = self else { return nil }
            return pairs.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
        }

        var string: String? { if case let .value(s) = self { s } else { nil } }
        var children: [(String, Node)] { if case let .object(p) = self { p } else { [] } }
    }

    static func parse(_ text: String) -> Node {
        var tokens = tokenize(text)[...]
        return .object(parseObject(&tokens))
    }

    private enum Token { case string(String), open, close }

    private static func parseObject(_ tokens: inout ArraySlice<Token>) -> [(String, Node)] {
        var pairs: [(String, Node)] = []
        while let token = tokens.popFirst() {
            guard case let .string(key) = token else { break } // `}` closes this object
            switch tokens.popFirst() {
            case .open: pairs.append((key, .object(parseObject(&tokens))))
            case let .string(value): pairs.append((key, .value(value)))
            case .close, nil: return pairs
            }
        }
        return pairs
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" {
                var s = ""
                i = text.index(after: i)
                while i < text.endIndex, text[i] != "\"" {
                    if text[i] == "\\", text.index(after: i) < text.endIndex {
                        i = text.index(after: i)
                        let e = text[i]
                        s.append(e == "n" ? "\n" : e == "t" ? "\t" : e)
                    } else {
                        s.append(text[i])
                    }
                    i = text.index(after: i)
                }
                tokens.append(.string(s))
            } else if c == "{" {
                tokens.append(.open)
            } else if c == "}" {
                tokens.append(.close)
            } else if c == "/", text[text.index(after: i)...].hasPrefix("/") {
                while i < text.endIndex, text[i] != "\n" { i = text.index(after: i) }
                continue
            }
            if i < text.endIndex { i = text.index(after: i) }
        }
        return tokens
    }
}
