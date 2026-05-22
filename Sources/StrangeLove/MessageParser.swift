import Foundation

/// A decoded, human-readable view of an RFC 822 / MIME message suitable for
/// feeding to the language model.
struct ParsedMessage {
    var sender: String
    var subject: String
    var body: String

    /// A single-line snippet stored with each learned example. Fed to the
    /// distiller (a large model) rather than the on-device prompt, so we keep a
    /// generous slice for better summarization.
    var snippet: String {
        let collapsed =
            body
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(500))
    }
}

enum MessageParser {
    /// Maximum number of body characters handed to the model.
    static let bodyLimit = 4000

    static func parse(_ data: Data) -> ParsedMessage {
        // RFC 822: headers and body are separated by a blank line. Be lenient
        // about CRLF vs LF.
        let text = decodeLatin1OrUTF8(data)
        let (headerText, bodyRaw) = splitHeadersAndBody(text)
        let headers = parseHeaders(headerText)

        let sender = decodeEncodedWords(headers["from"] ?? "")
        let subject = decodeEncodedWords(headers["subject"] ?? "")

        let contentType = headers["content-type"] ?? "text/plain"
        let encoding = (headers["content-transfer-encoding"] ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        let body = extractText(
            body: bodyRaw,
            contentType: contentType,
            encoding: encoding)

        return ParsedMessage(
            sender: sender,
            subject: subject,
            body: String(body.prefix(bodyLimit)))
    }

    // MARK: - Header / body split

    private static func splitHeadersAndBody(_ text: String) -> (String, String) {
        if let range = text.range(of: "\r\n\r\n") {
            return (
                String(text[..<range.lowerBound]),
                String(text[range.upperBound...])
            )
        }
        if let range = text.range(of: "\n\n") {
            return (
                String(text[..<range.lowerBound]),
                String(text[range.upperBound...])
            )
        }
        return (text, "")
    }

    /// Parse headers into a lowercase-keyed dictionary, unfolding continuation
    /// lines. Later duplicate headers overwrite earlier ones (good enough here).
    private static func parseHeaders(_ headerText: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String? = nil
        var currentValue = ""

        func flush() {
            if let key = currentKey {
                headers[key] = currentValue.trimmingCharacters(in: .whitespaces)
            }
        }

        for rawLine in headerText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.first == " " || line.first == "\t" {
                // Folded continuation of the previous header.
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            if let colon = line.firstIndex(of: ":") {
                flush()
                currentKey = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                currentValue = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return headers
    }

    // MARK: - MIME body extraction

    private static func extractText(
        body: String,
        contentType: String,
        encoding: String
    ) -> String {
        let lowerType = contentType.lowercased()

        if lowerType.contains("multipart"), let boundary = boundary(from: contentType) {
            return extractFromMultipart(body, boundary: boundary)
        }

        let decoded = decodeTransferEncoding(body, encoding: encoding)
        if lowerType.contains("text/html") {
            return stripHTML(decoded)
        }
        return decoded
    }

    private static func extractFromMultipart(_ body: String, boundary: String) -> String {
        let delimiter = "--\(boundary)"
        let parts = body.components(separatedBy: delimiter)
        var htmlFallback: String? = nil

        // `components(separatedBy:)` yields the preamble (text before the first
        // boundary) as parts[0] and the epilogue after the closing "--boundary--"
        // as the last element; neither is a real MIME part, so skip index 0 and
        // ignore any part that carries no headers.
        for part in parts.dropFirst() {
            let (headerText, partBody) = splitHeadersAndBody(part)
            let headers = parseHeaders(headerText)
            // A genuine MIME part begins with a header block; the closing
            // delimiter's trailing epilogue has none.
            guard !headers.isEmpty else { continue }
            let type = (headers["content-type"] ?? "text/plain").lowercased()
            let enc = (headers["content-transfer-encoding"] ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased()

            if type.contains("multipart"), let inner = self.boundary(from: type) {
                let nested = extractFromMultipart(partBody, boundary: inner)
                if !nested.isEmpty { return nested }
                continue
            }
            if type.contains("text/plain") {
                let decoded = decodeTransferEncoding(partBody, encoding: enc)
                if !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return decoded
                }
                continue
            }
            if type.contains("text/html"), htmlFallback == nil {
                htmlFallback = stripHTML(decodeTransferEncoding(partBody, encoding: enc))
            }
        }
        return htmlFallback ?? ""
    }

    private static func boundary(from contentType: String) -> String? {
        // Find boundary=... possibly quoted.
        guard let range = contentType.range(of: "boundary=", options: .caseInsensitive) else {
            return nil
        }
        var value = String(contentType[range.upperBound...])
        if value.first == "\"" {
            value.removeFirst()
            if let end = value.firstIndex(of: "\"") {
                return String(value[..<end])
            }
            return value
        }
        // Up to the next ';' or whitespace.
        if let end = value.firstIndex(where: { $0 == ";" || $0 == " " || $0 == "\r" || $0 == "\n" })
        {
            return String(value[..<end])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Transfer encodings

    private static func decodeTransferEncoding(_ text: String, encoding: String) -> String {
        switch encoding {
        case "base64":
            let stripped = text.components(separatedBy: .whitespacesAndNewlines).joined()
            if let data = Data(base64Encoded: stripped, options: .ignoreUnknownCharacters) {
                return decodeLatin1OrUTF8(data)
            }
            return text
        case "quoted-printable":
            return decodeQuotedPrintable(text)
        default:
            return text
        }
    }

    static func decodeQuotedPrintable(_ text: String) -> String {
        var output = Data()
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D {  // '='
                // Soft line break "=\r\n" or "=\n"
                if i + 1 < bytes.count && bytes[i + 1] == 0x0A {
                    i += 2
                    continue
                }
                if i + 2 < bytes.count && bytes[i + 1] == 0x0D && bytes[i + 2] == 0x0A {
                    i += 3
                    continue
                }
                if i + 2 < bytes.count,
                    let hi = hexValue(bytes[i + 1]),
                    let lo = hexValue(bytes[i + 2])
                {
                    output.append(UInt8(hi * 16 + lo))
                    i += 3
                    continue
                }
                output.append(b)
                i += 1
            } else {
                output.append(b)
                i += 1
            }
        }
        return decodeLatin1OrUTF8(output)
    }

    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: return Int(byte - 0x30)  // 0-9
        case 0x41...0x46: return Int(byte - 0x41 + 10)  // A-F
        case 0x61...0x66: return Int(byte - 0x61 + 10)  // a-f
        default: return nil
        }
    }

    // MARK: - RFC 2047 encoded words (=?charset?B/Q?text?=)

    static func decodeEncodedWords(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        var result = ""
        var remainder = Substring(input)

        while let start = remainder.range(of: "=?") {
            result += remainder[..<start.lowerBound]
            let afterStart = remainder[start.upperBound...]
            // charset?enc?text?=
            guard let end = afterStart.range(of: "?=") else {
                result += "=?"
                remainder = afterStart
                continue
            }
            let token = afterStart[..<end.lowerBound]
            let pieces = token.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
            if pieces.count == 3 {
                let charset = String(pieces[0])
                let enc = pieces[1].uppercased()
                let encoded = String(pieces[2])
                if let decoded = decodeWord(encoded, charset: charset, encoding: enc) {
                    result += decoded
                } else {
                    result += "=?\(token)?="
                }
            } else {
                result += "=?\(token)?="
            }
            remainder = afterStart[end.upperBound...]
        }
        result += remainder
        return result
    }

    private static func decodeWord(_ text: String, charset: String, encoding: String) -> String? {
        let data: Data?
        switch encoding {
        case "B":
            data = Data(base64Encoded: text, options: .ignoreUnknownCharacters)
        case "Q":
            // Q-encoding: like quoted-printable but '_' means space.
            let qp = text.replacingOccurrences(of: "_", with: " ")
            return decodeQuotedPrintable(qp)
        default:
            return nil
        }
        guard let data else { return nil }
        return decode(data, charset: charset)
    }

    // MARK: - Charset helpers

    private static func decode(_ data: Data, charset: String) -> String {
        let enc = encoding(forCharset: charset)
        if let s = String(data: data, encoding: enc) { return s }
        return decodeLatin1OrUTF8(data)
    }

    private static func encoding(forCharset charset: String) -> String.Encoding {
        switch charset.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
        case "us-ascii", "ascii": return .ascii
        case "iso-2022-jp": return .iso2022JP
        case "shift_jis", "shift-jis", "sjis": return .shiftJIS
        case "euc-jp", "eucjp": return .japaneseEUC
        default: return .utf8
        }
    }

    /// Try UTF-8, fall back to Latin-1 (which never fails) so we always get text.
    static func decodeLatin1OrUTF8(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - HTML

    static func stripHTML(_ html: String) -> String {
        var result = ""
        var insideTag = false
        for ch in html {
            switch ch {
            case "<": insideTag = true
            case ">": insideTag = false
            default:
                if !insideTag { result.append(ch) }
            }
        }
        return
            result
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
