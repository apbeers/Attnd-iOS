// AttestationManager.swift
// Attnd
//
// Handles Apple App Attest: generates a device key, fetches a server nonce,
// attests the key, and exchanges it for a short-lived JWT that is then
// stored in the Keychain and used as the Authorization token for all API calls.
//
// The manager is an `actor` so concurrent token() calls are naturally serialised —
// only one attestation flow runs at a time even if the first API calls race.
//
// Simulator / macOS support: DCAppAttestService.isSupported returns false on
// simulators and macOS targets. In that case, token() returns nil and APIClient
// falls back to the static ATTND_API_KEY from Info.plist.

import CryptoKit
import DeviceCheck
import Foundation

// MARK: - Errors

enum AttestationManagerError: LocalizedError {
    case notSupported
    case keyGenerationFailed(String)
    case attestationFailed(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "App Attest is not supported on this device."
        case .keyGenerationFailed(let msg):
            return "Key generation failed: \(msg)"
        case .attestationFailed(let msg):
            return "Attestation failed: \(msg)"
        case .networkError(let msg):
            return "Network error during attestation: \(msg)"
        }
    }
}

// MARK: - AttestationManager

actor AttestationManager {

    static let shared = AttestationManager()

    // MARK: Private constants

    private let attestBaseURL = "https://\(APIClient.serverHost)/api/v1/attest"

    // UserDefaults key for the persisted App Attest key ID
    private let keyIdDefaultsKey = "com.arcu.attnd.attest.keyId"

    // Keychain key for the JWT
    private let jwtKeychainKey = "com.arcu.attnd.attest.jwt"

    // Re-use inflight attestation instead of starting a second one in parallel
    private var inflightTask: Task<String, Error>?

    // MARK: - Public API

    /// Whether this device supports App Attest. False on simulators and macOS.
    nonisolated var isSupported: Bool { DCAppAttestService.shared.isSupported }

    /// Returns a valid JWT.
    /// - If a non-expired token is already stored, returns it immediately.
    /// - Otherwise runs the full attestation flow (once, even if called concurrently).
    /// - Returns nil if App Attest is not supported on this device.
    func token() async throws -> String? {
        guard isSupported else { return nil }

        // Fast path — cached, non-expired token
        if let cached = cachedToken() { return cached }

        // Coalesce concurrent callers onto the same task
        if let existing = inflightTask {
            return try await existing.value
        }

        let task = Task<String, Error> {
            let started = ContinuousClock.now
            AppLog.info(.auth, "auth.attest.started", "App Attest", ["kind": "app_attest"])
            do {
                let t = try await self.attest()
                self.inflightTask = nil
                let ms = (ContinuousClock.now - started).wholeMilliseconds
                AppLog.info(.auth, "auth.attest.finished", "App Attest token in \(ms) ms", ["kind": "app_attest", "ms": .int(ms), "ok": true])
                return t
            } catch {
                // The failed task stays in place (callers fall back to the static key) until a
                // 401 invalidates it, as before.
                let ns = error as NSError
                AppLog.warning(.auth, "auth.attest.failed", "App Attest failed", [
                    "kind": "app_attest", "error": .string(String(describing: error).prefix(120).description),
                    "domain": .string(ns.domain), "code": .int(ns.code),
                ])
                throw error
            }
        }
        inflightTask = task
        return try await task.value
    }

    /// Force-clears the stored JWT and re-attests.
    /// Call this after receiving a 401 from the API so a fresh token is fetched.
    func invalidateToken() {
        AppLog.info(.auth, "auth.token.expired", "401: attestation token cleared", ["reason": "401"])
        KeychainHelper.delete(key: jwtKeychainKey)
        inflightTask = nil
    }

    /// Eagerly start attestation in the background so the first API call is instant.
    /// Errors are silently ignored — the API call will retry.
    nonisolated func warmup() {
        Task { _ = try? await self.token() }
    }

    // MARK: - Attestation Flow

    private func attest() async throws -> String {
        // Step 1 — get or generate key
        let keyId = try await resolvedKeyId()

        // Step 2 — fetch a server nonce
        let nonce = try await fetchNonce()

        // Step 3 — compute clientDataHash = SHA-256(nonce)
        let nonceData = Data(nonce.utf8)
        let clientDataHash = Data(SHA256.hash(data: nonceData))

        // Step 4 — call DCAppAttestService.attestKey
        let attestationData: Data
        do {
            attestationData = try await DCAppAttestService.shared.attestKey(
                keyId, clientDataHash: clientDataHash
            )
        } catch {
            // Invalid key — clear so a new one is generated next time
            UserDefaults.standard.removeObject(forKey: keyIdDefaultsKey)
            throw AttestationManagerError.attestationFailed(error.localizedDescription)
        }

        // Step 5 — exchange with our backend for a JWT
        let jwt = try await sendAttestation(
            keyId: keyId,
            attestation: attestationData.base64EncodedString(),
            nonce: nonce
        )

        KeychainHelper.save(key: jwtKeychainKey, value: jwt)
        return jwt
    }

    private func resolvedKeyId() async throws -> String {
        if let stored = UserDefaults.standard.string(forKey: keyIdDefaultsKey) {
            return stored
        }
        do {
            let newKeyId = try await DCAppAttestService.shared.generateKey()
            UserDefaults.standard.set(newKeyId, forKey: keyIdDefaultsKey)
            return newKeyId
        } catch {
            throw AttestationManagerError.keyGenerationFailed(error.localizedDescription)
        }
    }

    // MARK: - Network helpers

    private func fetchNonce() async throws -> String {
        guard let url = URL(string: "\(attestBaseURL)/nonce/") else {
            throw AttestationManagerError.networkError("Invalid nonce URL")
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard
                let json = try? JSONDecoder().decode([String: String].self, from: data),
                let nonce = json["nonce"]
            else {
                throw AttestationManagerError.networkError("Malformed nonce response")
            }
            return nonce
        } catch let error as AttestationManagerError {
            throw error
        } catch {
            throw AttestationManagerError.networkError(error.localizedDescription)
        }
    }

    private func sendAttestation(keyId: String, attestation: String, nonce: String) async throws -> String {
        guard let url = URL(string: "\(attestBaseURL)/ios/") else {
            throw AttestationManagerError.networkError("Invalid attestation URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "key_id": keyId,
            "attestation": attestation,
            "nonce": nonce,
        ]
        req.httpBody = try? JSONEncoder().encode(body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard
                let http = response as? HTTPURLResponse,
                http.statusCode == 200
            else {
                let serverMsg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                    ?? "Attestation rejected"
                throw AttestationManagerError.attestationFailed(serverMsg)
            }
            guard
                let json = try? JSONDecoder().decode([String: String].self, from: data),
                let jwt = json["token"]
            else {
                throw AttestationManagerError.attestationFailed("No token in server response")
            }
            return jwt
        } catch let error as AttestationManagerError {
            throw error
        } catch {
            throw AttestationManagerError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Token expiry

    /// Returns the stored JWT if it is valid and not within 60 s of expiry.
    private func cachedToken() -> String? {
        guard let jwt = KeychainHelper.read(key: jwtKeychainKey) else { return nil }
        return isJWTValid(jwt) ? jwt : nil
    }

    /// Decode the JWT payload (without signature verification) and check `exp`.
    private func isJWTValid(_ jwt: String) -> Bool {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return false }

        // Base64url → base64 padding
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem != 0 { b64 += String(repeating: "=", count: 4 - rem) }

        guard
            let data = Data(base64Encoded: b64),
            let payload = try? JSONDecoder().decode(JWTPayloadPeek.self, from: data)
        else { return false }

        // Treat as expired 60 s early to handle clock skew and propagation lag
        return Date().timeIntervalSince1970 < Double(payload.exp) - 60
    }
}

// MARK: - Helpers

private struct JWTPayloadPeek: Decodable {
    let exp: Int
}
