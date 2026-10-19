import Foundation

/// Where a token number came from. Totals never mix sources silently (Bible Part 10 §13).
public enum MeasurementSource: String, Codable, Hashable, Sendable, CaseIterable {
    /// Read from the provider's own local records (Claude Code transcripts via `ClaudeTranscriptReader`).
    /// Labelled "provider-reported": C2D read it, the provider did not send it (ADR-023).
    case providerConfirmed
    case locallyTokenized
    case heuristicEstimate
    case unavailable

    public var label: String {
        switch self {
        case .providerConfirmed: "provider-reported"
        case .locallyTokenized: "locally tokenized"
        case .heuristicEstimate: "heuristic estimate"
        case .unavailable: "unavailable"
        }
    }
}

public struct TokenEstimate: Hashable, Sendable {
    public let tokens: Int
    public let source: MeasurementSource
    public let confidence: String
}

/// Deterministic, local, provider-agnostic token estimate. Never presented as billed usage.
public enum TokenEstimator {
    /// Formula (per character class, summed, then rounded):
    /// - ASCII letters/digits: 1 token per 4 characters (prose), 1 per 3.5 when the text looks like code
    ///   (≥ 15 % of non-space chars are `{}()[];=<>` or lines start with indentation);
    /// - ASCII punctuation and symbols: 1 token each (`.,;:(){}[]<>=+-*/` …);
    /// - whitespace: free (it is absorbed into neighbouring tokens);
    /// - CJK ideographs/kana/hangul: 1 token per character;
    /// - emoji and other astral-plane scalars: 2 tokens each;
    /// - other non-ASCII (accented Latin, Cyrillic, …): 1 token per 2 characters.
    /// Calibrated by hand against the "~4 chars/token for English, ~1 char/token for CJK" rule of thumb.
    /// ponytail: heuristic with ±25 % expected error; swap in a real tokenizer when a provider ships one.
    public static func estimate(_ text: String) -> TokenEstimate {
        if text.isEmpty { return TokenEstimate(tokens: 0, source: .heuristicEstimate, confidence: "empty input") }
        var ascii = 0, punct = 0, cjk = 0, astral = 0, otherNonASCII = 0, nonSpace = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if scalar.properties.isWhitespace { continue }
            nonSpace += 1
            if v < 0x80 {
                if scalar.properties.isAlphabetic || (0x30...0x39).contains(v) { ascii += 1 } else { punct += 1 }
            } else if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v) {
                cjk += 1
            } else if v > 0xFFFF {
                astral += 1
            } else {
                otherNonASCII += 1
            }
        }
        let looksLikeCode = nonSpace > 0 && Double(punct) / Double(nonSpace) >= 0.15
        let asciiDivisor = looksLikeCode ? 3.5 : 4.0
        let total = Double(ascii) / asciiDivisor + Double(punct) + Double(cjk) + Double(astral) * 2 + Double(otherNonASCII) / 2
        let tokens = max(1, Int(total.rounded()))
        let confidence = looksLikeCode ? "heuristic (code-like text, ±25 %)" : "heuristic (±25 %)"
        return TokenEstimate(tokens: tokens, source: .heuristicEstimate, confidence: confidence)
    }
}
