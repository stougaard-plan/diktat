import Foundation
import SwiftUI

/// En model i en lokal Ollama-installation.
struct OllamaModel: Identifiable, Hashable, Decodable {
    let name: String
    var id: String { name }
}

/// Hvilke Ollama-adresser appen vil tale med.
/// Standard: kun denne Mac (localhost, 127.0.0.1, ::1). Slår brugeren «Tillad anden maskine på mit netværk» til,
/// accepteres også adresser på det lokale netværk (private IP-intervaller, .local, .lan, .ts.net og navne uden punktum).
/// Offentlige adresser afvises altid, også når et navn peger på en offentlig adresse (navnet slås op og alle svar
/// tjekkes, se `validate`), og omdirigeringer afvises, så tekst ikke ender uden for brugerens egne maskiner.
enum OllamaHostPolicy {
    static let allowRemoteKey = "ollamaAllowRemoteHost"
    /// Særskilt tilvalg: må ordlisten (dine egne ord og navne) sendes med, når Ollama kører på en anden maskine?
    static let sendVocabularyRemoteKey = "ollamaSendVocabularyToRemoteHost"

    static var sendVocabularyToRemote: Bool { UserDefaults.standard.bool(forKey: sendVocabularyRemoteKey) }

    /// Navneopslag. Kan udskiftes i tests.
    nonisolated(unsafe) static var resolver: @Sendable (String) -> [String] = systemResolve

    /// Kører Ollama på en anden maskine end denne Mac?
    static func isRemote(_ url: URL) -> Bool { !isLoopback(url) }

    static var allowRemote: Bool { UserDefaults.standard.bool(forKey: allowRemoteKey) }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// Første, hurtige tjek af selve adressen (uden netværk). Bruges alene er det IKKE nok for navne:
    /// brug `validate`, som også slår navnet op.
    static func isAllowed(_ url: URL, allowRemote: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        if isLoopback(url) { return true }
        guard allowRemote, let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return isPrivateNetworkHost(host)
    }

    /// Fuldt tjek: adressen skal passe til politikken, og et NAVN skal slås op, så alle svar er private adresser
    /// (eller denne Mac). Et navn, der peger på en offentlig adresse, afvises. Ingen svar afvises også.
    /// Rest-risiko: navnet slås op igen, når forespørgslen sendes. Ændrer svaret sig mellem de to opslag
    /// (DNS rebinding), kan det ikke fanges her. Se NETVAERK.md.
    static func validate(_ url: URL, allowRemote: Bool) async -> Bool {
        guard isAllowed(url, allowRemote: allowRemote) else { return false }
        if isLoopback(url) { return true }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        // En IP-adresse er allerede afgjort af isAllowed. Kun navne slås op.
        if isIPLiteral(bare) { return true }
        let resolve = resolver
        let addresses = await Task.detached { resolve(bare) }.value
        return !addresses.isEmpty && addresses.allSatisfy(isPrivateOrLoopbackAddress)
    }

    static func isIPLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// Er det en privat adresse, en adresse i lokalnettet eller denne Mac? Tager kun numeriske adresser.
    static func isPrivateOrLoopbackAddress(_ raw: String) -> Bool {
        var ip = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
        let lower = ip.lowercased()
        if lower.hasPrefix("::ffff:"), lower.contains(".") { return isPrivateOrLoopbackAddress(String(lower.dropFirst(7))) }
        if lower == "::1" { return true }
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) {
            if parts[0] == "127" { return true }
            return isPrivateNetworkHost(lower)
        }
        if lower.contains(":") { return lower.hasPrefix("fe80:") || lower.hasPrefix("fc") || lower.hasPrefix("fd") }
        return false
    }

    /// Slår et navn op med systemets resolver og returnerer numeriske adresser.
    static func systemResolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buffer))
            }
            cursor = info.pointee.ai_next
        }
        return out
    }

    static func isPrivateNetworkHost(_ rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) {
            let o = parts.compactMap { Int($0) }
            if o[0] == 10 { return true }
            if o[0] == 172, (16...31).contains(o[1]) { return true }
            if o[0] == 192, o[1] == 168 { return true }
            if o[0] == 169, o[1] == 254 { return true }
            if o[0] == 100, (64...127).contains(o[1]) { return true }  // Tailscale / CGNAT
            return false
        }
        if host.contains(":") {  // IPv6
            return host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
        if !host.contains(".") {  // enkeltnavn på lokalnet, fx «hjemmeserver». Rene tal og 0x-former er IP-skrivemåder, ikke navne.
            let numericLike = host.allSatisfy { $0.isNumber } || host.hasPrefix("0x")
            return !numericLike
        }
        return host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa")
            || host.hasSuffix(".ts.net")
    }
}

/// Minimal Ollama-klient. Taler kun med adresser, som OllamaHostPolicy tillader.
enum OllamaLocalClient {
    static func isLoopback(_ url: URL) -> Bool { OllamaHostPolicy.isLoopback(url) }

    private static func request(_ baseURL: URL, path: String, timeout: TimeInterval) async throws -> URLRequest {
        guard await OllamaHostPolicy.validate(baseURL, allowRemote: OllamaHostPolicy.allowRemote) else {
            throw LocalAIError.invalidURL
        }
        guard let url = URL(string: path, relativeTo: baseURL) else { throw LocalAIError.invalidURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        return req
    }

    static func checkConnection(baseURL: URL) async -> Bool {
        guard let req = try? await request(baseURL, path: "/api/tags", timeout: 3) else { return false }
        guard let (_, response) = try? await NoRedirectSession.session.data(for: req) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    static func fetchModels(baseURL: URL) async throws -> [OllamaModel] {
        let req = try await request(baseURL, path: "/api/tags", timeout: 5)
        let (data, response) = try await NoRedirectSession.session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LocalAIError.serviceUnavailable }
        struct Tags: Decodable { let models: [OllamaModel] }
        return try JSONDecoder().decode(Tags.self, from: data).models
    }

    static func generate(
        baseURL: URL, model: String, prompt: String, systemPrompt: String,
        temperature: Double, timeout: TimeInterval
    ) async throws -> String {
        var req = try await request(baseURL, path: "/api/generate", timeout: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model, "prompt": prompt, "system": systemPrompt, "stream": false, "think": false,
            "options": ["temperature": temperature],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await NoRedirectSession.session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw LocalAIError.modelNotFound }
        if status >= 500 { throw LocalAIError.serverError }
        guard status == 200 else { throw LocalAIError.invalidResponse }
        struct Reply: Decodable { let response: String }
        return try JSONDecoder().decode(Reply.self, from: data).response
    }
}

class OllamaService: ObservableObject {
    static let defaultBaseURL = "http://localhost:11434"

    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "ollamaBaseURL") }
    }
    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "ollamaSelectedModel") }
    }
    @Published var availableModels: [OllamaModel] = []
    @Published var isConnected: Bool = false
    @Published var isLoadingModels: Bool = false

    private let defaultTemperature: Double = 0.0

    init() {
        self.baseURL = UserDefaults.standard.string(forKey: "ollamaBaseURL") ?? Self.defaultBaseURL
        self.selectedModel = UserDefaults.standard.string(forKey: "ollamaSelectedModel") ?? "llama2"
    }

    private var baseURLValue: URL? { URL(string: baseURL) }

    @MainActor
    func checkConnection() async {
        guard let url = baseURLValue else { isConnected = false; return }
        isConnected = await OllamaLocalClient.checkConnection(baseURL: url)
    }

    @MainActor
    func refreshConnectionAndModels() async -> Result<[OllamaModel], Error> {
        isLoadingModels = true
        defer { isLoadingModels = false }
        guard let url = baseURLValue else {
            isConnected = false
            availableModels = []
            return .failure(LocalAIError.invalidURL)
        }
        do {
            let models = try await OllamaLocalClient.fetchModels(baseURL: url)
            isConnected = true
            availableModels = models
            if !models.contains(where: { $0.name == selectedModel }) && !models.isEmpty {
                selectedModel = models[0].name
            }
            return .success(models)
        } catch {
            isConnected = false
            availableModels = []
            return .failure(error)
        }
    }

    func enhance(
        _ text: String, withSystemPrompt systemPrompt: String? = nil, model: String? = nil,
        timeout: TimeInterval = 30
    ) async throws -> String {
        guard let systemPrompt else { throw LocalAIError.invalidRequest }
        guard let url = baseURLValue else { throw LocalAIError.invalidURL }
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestModel = (trimmed?.isEmpty == false ? trimmed : nil) ?? selectedModel
        return try await OllamaLocalClient.generate(
            baseURL: url, model: requestModel, prompt: text, systemPrompt: systemPrompt,
            temperature: defaultTemperature, timeout: timeout)
    }
}

enum LocalAIError: Error, LocalizedError {
    case invalidURL
    case serviceUnavailable
    case invalidResponse
    case modelNotFound
    case serverError
    case invalidRequest
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Ugyldig Ollama-adresse. Kun denne Mac er tilladt, medmindre «Tillad anden maskine på mit netværk» er slået til. Så kræves en adresse på det lokale netværk."
        case .serviceUnavailable: return String(localized: "Ollama kører ikke")
        case .invalidResponse: return String(localized: "Ugyldigt svar fra Ollama")
        case .modelNotFound: return String(localized: "Den valgte model findes ikke i Ollama")
        case .serverError: return String(localized: "Fejl i Ollama")
        case .invalidRequest: return String(localized: "Der mangler en systemprompt")
        case .timeout: return String(localized: "Ollama svarede ikke i tide")
        }
    }
}

/// Afviser alle omdirigeringer, så en forespørgsel til Ollama aldrig kan ende uden for den valgte adresse.
enum NoRedirectSession {
    private final class Delegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) { completionHandler(nil) }
    }
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]  // aldrig via en systemproxy
        return URLSession(configuration: config, delegate: Delegate(), delegateQueue: nil)
    }()
}
