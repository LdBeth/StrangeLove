import Foundation
import Testing

@testable import StrangeLove

/// Regression fixtures for `MessageParser`'s MIME walk. These guard the body
/// extraction paths that have bitten us — the parser only needs to surface a
/// text snippet, but it must not silently drop the body. Each fixture is a raw
/// RFC 822 message; we assert on the extracted `body`.
struct MessageParserTests {

    private func parse(_ raw: String) -> ParsedMessage {
        MessageParser.parse(Data(raw.utf8))
    }

    /// Same shape as a real nodemailer phishing message that produced an empty
    /// snippet: a `text/html` leaf nested inside `multipart/related` inside
    /// `multipart/mixed`, with mixed-case (`-Part_2`) boundaries and a folded
    /// Content-Type header. Before the fix the nested boundary was lowercased
    /// and the case-sensitive split matched nothing, so the body vanished.
    private let nestedMixedCase = """
        From: foxmail Support <sales@banburypostiche.co.uk>
        Subject: foxmail Email deativation Notice
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="--_NmP-15da1105b075d88b-Part_1"

        ----_NmP-15da1105b075d88b-Part_1
        Content-Type: multipart/related; type="text/html";
         boundary="--_NmP-15da1105b075d88b-Part_2"

        ----_NmP-15da1105b075d88b-Part_2
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        <html><body><div style=3D"color: =
        red;">Password Expiring Soon</div>
        <div>Your account password will expire=2E</div></body></html>
        ----_NmP-15da1105b075d88b-Part_2--

        ----_NmP-15da1105b075d88b-Part_1--
        """

    @Test func nestedMixedCaseMultipartKeepsBody() {
        let msg = parse(nestedMixedCase)
        #expect(msg.body.contains("Password Expiring Soon"))
        #expect(msg.body.contains("expire"))
        // HTML tags must be stripped.
        #expect(!msg.body.contains("<div>"))
    }

    /// The same message with CRLF line endings (as a real MTA delivers it),
    /// exercising the `\r\n` branch of the boundary/header split.
    @Test func nestedMixedCaseMultipartCRLF() {
        let crlf = nestedMixedCase.replacingOccurrences(of: "\n", with: "\r\n")
        let msg = parse(crlf)
        #expect(msg.body.contains("Password Expiring Soon"))
    }

    /// A single-part `text/html` message — HTML is the documented fallback when
    /// there is no `text/plain`.
    @Test func singlePartHTMLIsStripped() {
        let raw = """
            From: x
            Subject: Win
            Content-Type: text/html; charset=utf-8

            <html><body><h1>Win a prize</h1></body></html>
            """
        let msg = parse(raw)
        #expect(msg.body.contains("Win a prize"))
        #expect(!msg.body.contains("<h1>"))
    }

    /// `multipart/alternative`: the `text/plain` part must win over `text/html`.
    @Test func multipartAlternativePrefersPlainText() {
        let raw = """
            From: x
            Subject: s
            Content-Type: multipart/alternative; boundary="bnd"

            --bnd
            Content-Type: text/plain

            plain text wins
            --bnd
            Content-Type: text/html

            <p>html should lose</p>
            --bnd--
            """
        let msg = parse(raw)
        #expect(msg.body.contains("plain text wins"))
        #expect(!msg.body.contains("html should lose"))
    }

    /// `<style>`/`<script>` contents must not leak into the extracted text —
    /// CSS would otherwise crowd the real copy out of the snippet/embedding.
    @Test func styleAndScriptContentsAreDropped() {
        let raw = """
            From: x
            Subject: s
            Content-Type: text/html; charset=utf-8

            <html><head>
            <style>.email-body { margin: 0; color: #f0f2f5; }</style>
            <script>var tracking = 1; alert('x');</script>
            </head><body><p>Visible copy here</p></body></html>
            """
        let msg = parse(raw)
        #expect(msg.body.contains("Visible copy here"))
        #expect(!msg.body.contains("margin"))
        #expect(!msg.body.contains("#f0f2f5"))
        #expect(!msg.body.contains("tracking"))
        #expect(!msg.body.contains("alert"))
    }

    /// Base64 transfer-encoding on a `text/plain` part must be decoded.
    @Test func base64PartIsDecoded() {
        let raw = """
            From: x
            Subject: s
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: base64

            SGVsbG8gZnJvbSBhIGJhc2U2NCBib2R5
            """
        let msg = parse(raw)
        #expect(msg.body.contains("Hello from a base64 body"))
    }
}
