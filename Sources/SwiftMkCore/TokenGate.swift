import Foundation

/// Confirmation gate for baseline mutations.
///
/// Port of `scripts/swift-mk-gate.sh`. A mutation is permitted only when the
/// caller sets a truthy confirm value and supplies a token whose slug matches
/// the slug of the token command's output.
public enum TokenGate {
    /// Lowercase ASCII slug: transliterate to ASCII, keep `[A-Za-z0-9_-]`, lowercase.
    public static func slugify(_ input: String) -> String {
        let latin = input.applyingTransform(.toLatin, reverse: false) ?? input
        let ascii = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        let kept = ascii.unicodeScalars.filter { scalar in
            (scalar >= "A" && scalar <= "Z")
                || (scalar >= "a" && scalar <= "z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "_" || scalar == "-"
        }
        return String(String.UnicodeScalarView(kept)).lowercased()
    }

    private static func confirmed(_ value: String) -> Bool {
        ["1", "y", "yes", "Y", "YES"].contains(value)
    }

    /// Evaluate the gate. Returns true when the mutation is permitted.
    public static func passes(
        confirmValue: String,
        tokenValue: String,
        tokenCommand: String
    ) -> Bool {
        guard confirmed(confirmValue) else { return false }
        guard !tokenCommand.isEmpty else { return false }
        let result = Shell.sh(tokenCommand)
        guard result.status == 0 else { return false }
        let expected = slugify(result.stdout)
        let actual = slugify(tokenValue)
        guard !expected.isEmpty, !actual.isEmpty else { return false }
        return expected == actual
    }
}
