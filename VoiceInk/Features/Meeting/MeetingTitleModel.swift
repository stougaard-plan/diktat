import Foundation

/// Indstillinger for automatisk mødetitel. FRA som standard: så hedder mødet «Møde» og vises med dato og tid,
/// og der sendes ingenting nogen steder. Slås det til, sendes et uddrag af transskriptet (højst ca. 3000 tegn,
/// uden tidsstempler) til brugerens EGEN Ollama. Adressen er som standard denne Mac (127.0.0.1:11434).
/// Adresser uden for denne Mac accepteres kun, hvis brugeren har slået «Tillad anden maskine på mit netværk» til
/// (OllamaHostPolicy), og de skal være på lokalnettet.
enum MeetingTitleSettings {
    static let enabledKey = "MeetingTitleEnabled"
    static let urlKey = "MeetingTitleOllamaURL"
    static let modelKey = "MeetingTitleOllamaModel"
    static let defaultURL = "http://127.0.0.1:11434"

    static func modelName(_ defaults: UserDefaults = .standard) -> String {
        (defaults.string(forKey: modelKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func urlString(_ defaults: UserDefaults = .standard) -> String {
        let raw = (defaults.string(forKey: urlKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? defaultURL : raw
    }

    static func baseURL(_ defaults: UserDefaults = .standard) -> URL? { URL(string: urlString(defaults)) }

    /// Sand kun hvis brugeren selv har slået titel til OG har skrevet et modelnavn.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey) && !modelName(defaults).isEmpty
    }
}

/// Kobler mødetitlen til en Ollama-model, som brugeren selv har sat op (valgfrit, FRA som standard).
///
/// Transskriptets tekst (højst ca. 3000 tegn pr. møde, uden tidsstempler) sendes kun til den adresse, brugeren har
/// skrevet, og kun hvis OllamaHostPolicy tillader den. Omdirigeringer følges ikke. Teksten går over HTTP uden
/// kryptering, så en adresse uden for denne Mac bør kun være et netværk, brugeren selv stoler på.
/// Kan modellen ikke nås, bliver titlen «Møde» og prøves igen senere (se MeetingTitler).
enum MeetingTitleModel {
    /// Lidt over MeetingTitle.defaultTimeout, så den egentlige timeout er MeetingTitles og ikke URLSessions.
    static let requestTimeout: TimeInterval = 100

    enum ModelError: LocalizedError {
        case notConfigured
        case addressNotAllowed
        case unreachable(String)
        case server(Int)
        case badResponse
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Titelmodellen er ikke sat op."
            case .addressNotAllowed: return "Adressen til titelmodellen er ikke tilladt (kun denne Mac, eller lokalnettet hvis det er slået til)."
            case .unreachable(let why): return "Titelmodellen kunne ikke nås (\(why))."
            case .server(let code): return "Titelmodellen svarede med fejl (\(code))."
            case .badResponse: return "Titelmodellen svarede med noget, der ikke kunne læses."
            }
        }
    }

    /// Stopper omdirigeringer: et svar kan aldrig sende transskriptet videre til en anden adresse.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) { completionHandler(nil) }
    }

    /// Fjerner «tænke»-blokke, hvis Ollama alligevel sender dem med.
    static func stripThinking(_ text: String) -> String {
        guard let open = text.range(of: "<think>") else { return text }
        if let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
            return (String(text[..<open.lowerBound]) + String(text[close.upperBound...]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Generator med faste værdier (bruges af tests og af `makeConfiguredGenerator`).
    ///
    /// `isStillEnabled` tjekkes FØR hvert HTTP-forsøg (også forsøget uden «think»). Er titlen slået fra, sendes
    /// intet, og kaldet afsluttes med `CancellationError`. En afbrudt opgave afbryder også selve forespørgslen.
    static func makeGenerator(
        baseURL: URL, model: String, allowRemote: Bool = false,
        isStillEnabled: @escaping @Sendable () -> Bool = { true }
    ) -> @Sendable (_ system: String, _ input: String) async throws -> String {
        return { system, input in
            guard await OllamaHostPolicy.validate(baseURL, allowRemote: allowRemote),
                let url = URL(string: "/api/generate", relativeTo: baseURL)
            else { throw ModelError.addressNotAllowed }
            func send(withThinkFlag: Bool) async throws -> (Data, HTTPURLResponse) {
                guard isStillEnabled(), !Task.isCancelled else { throw CancellationError() }
                var request = URLRequest(url: url, timeoutInterval: requestTimeout)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                var body: [String: Any] = [
                    "model": model, "system": system, "prompt": input, "stream": false,
                    "options": ["temperature": 0, "num_predict": 64],
                ]
                if withThinkFlag { body["think"] = false }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = requestTimeout
                config.waitsForConnectivity = false
                config.connectionProxyDictionary = [:]  // aldrig via en systemproxy
                let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
                defer { session.finishTasksAndInvalidate() }
                do {
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ModelError.badResponse }
                    return (data, http)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let e as URLError where e.code == .cancelled {
                    throw CancellationError()
                } catch let e as ModelError {
                    throw e
                } catch {
                    throw ModelError.unreachable((error as NSError).localizedDescription)
                }
            }
            var (data, http) = try await send(withThinkFlag: true)
            // Nogle modeller kender ikke «think». Ét forsøg uden, hvis serveren afviser forespørgslen.
            if http.statusCode == 400 { (data, http) = try await send(withThinkFlag: false) }
            guard http.statusCode == 200 else { throw ModelError.server(http.statusCode) }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = obj["response"] as? String
            else { throw ModelError.badResponse }
            // Ufuldstændigt svar (done:false) bruges ikke.
            if let done = obj["done"] as? Bool, !done { throw ModelError.badResponse }
            return stripThinking(text)
        }
    }

    /// Læser indstillingerne HVER gang titlen laves, så en ændring virker uden genstart.
    static func makeConfiguredGenerator(defaults: UserDefaults = .standard)
        -> @Sendable (_ system: String, _ input: String) async throws -> String
    {
        return { system, input in
            guard MeetingTitleSettings.isEnabled(defaults), let url = MeetingTitleSettings.baseURL(defaults) else {
                throw ModelError.notConfigured
            }
            let allowRemote = defaults.bool(forKey: OllamaHostPolicy.allowRemoteKey)
            let g = makeGenerator(
                baseURL: url, model: MeetingTitleSettings.modelName(defaults), allowRemote: allowRemote,
                isStillEnabled: { MeetingTitleSettings.isEnabled(defaults) })
            return try await g(system, input)
        }
    }

    @MainActor
    static func install(into titler: MeetingTitler, defaults: UserDefaults = .standard) {
        titler.isEnabled = { MeetingTitleSettings.isEnabled(defaults) }
        titler.generate = makeConfiguredGenerator(defaults: defaults)
        // Slås titlen fra, mens et kald er i gang, afbrydes kaldet, og køen tømmes.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak titler] _ in
            Task { @MainActor in
                if !MeetingTitleSettings.isEnabled(defaults) { titler?.cancelInFlight() }
            }
        }
    }
}
