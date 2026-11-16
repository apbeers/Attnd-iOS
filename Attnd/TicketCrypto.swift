// TicketCrypto.swift
// Attnd
//
// The two primitives door mode needs (API-017): Ed25519 signature checks for QR tokens
// (`ATK1.<payload>.<signature>`, the event's public keys from the door manifest) and SHA-256
// for searching the manifest by email (`email_hash`). CryptoKit on Apple platforms; the Linux
// test harness builds the same file against swift-crypto, which has the same API.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

enum TicketCrypto {
    /// True when `signature` (64 bytes) is a valid Ed25519 signature of `message` by the raw
    /// 32-byte `publicKey`. Malformed keys or signatures are simply invalid.
    static func isValidSignature(_ signature: Data, of message: Data, publicKey: Data) -> Bool {
        guard publicKey.count == 32, signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }

    /// Lower-case hex SHA-256 of the UTF-8 bytes of `text`.
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
