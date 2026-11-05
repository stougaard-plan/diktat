import Foundation

// Stub for appens fejltype (testen kompilerer kun OllamaService.swift og CleanupFallback.swift).
enum EnhancementError: Error { case enhancementFailed }

var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "OK   " : "FEJL ", m); if !c { fails += 1 } }
func u(_ s: String) -> URL { URL(string: s)! }

func policyChecks() {
check(OllamaHostPolicy.isAllowed(u("http://localhost:11434"), allowRemote: false), "localhost tilladt som standard")
check(OllamaHostPolicy.isAllowed(u("http://127.0.0.1:11434"), allowRemote: false), "127.0.0.1 tilladt som standard")
check(!OllamaHostPolicy.isAllowed(u("http://192.168.1.20:11434"), allowRemote: false), "lokalnet-IP afvist, når fremmed maskine ikke er slået til")
check(OllamaHostPolicy.isAllowed(u("http://192.168.1.20:11434"), allowRemote: true), "192.168.x tilladt, når slået til")
check(OllamaHostPolicy.isAllowed(u("http://10.0.0.5:11434"), allowRemote: true), "10.x tilladt, når slået til")
check(OllamaHostPolicy.isAllowed(u("http://172.20.1.1:11434"), allowRemote: true), "172.16-31 tilladt, når slået til")
check(!OllamaHostPolicy.isAllowed(u("http://172.32.1.1:11434"), allowRemote: true), "172.32 (offentlig) afvist selv når slået til")
check(OllamaHostPolicy.isAllowed(u("http://100.101.2.3:11434"), allowRemote: true), "Tailscale 100.64/10 tilladt, når slået til")
check(OllamaHostPolicy.isAllowed(u("http://hjemmeserver.local:11434"), allowRemote: true), ".local-navn tilladt, når slået til")
check(OllamaHostPolicy.isAllowed(u("http://hjemmeserver:11434"), allowRemote: true), "enkeltnavn tilladt, når slået til")
check(!OllamaHostPolicy.isAllowed(u("http://8.8.8.8:11434"), allowRemote: true), "offentlig IP afvist selv når slået til")
check(!OllamaHostPolicy.isAllowed(u("http://example.com:11434"), allowRemote: true), "offentligt domæne afvist selv når slået til")
check(!OllamaHostPolicy.isAllowed(u("ftp://localhost:11434"), allowRemote: true), "andre protokoller end http/https afvist")
check(!OllamaHostPolicy.isAllowed(u("http://134744072:11434"), allowRemote: true), "ren tal (= 8.8.8.8 skrevet som ét tal) er ikke et lokalnet-navn")
check(!OllamaHostPolicy.isAllowed(u("http://0x08080808:11434"), allowRemote: true), "0x-skrivemåde af en IP er ikke et lokalnet-navn")
check(OllamaHostPolicy.isRemote(u("http://192.168.1.20:11434")) && !OllamaHostPolicy.isRemote(u("http://127.0.0.1:11434")), "isRemote: lokalnet er en anden maskine, loopback er ikke")

}

// 1b. B3: navne slås op, og alle svar skal være private adresser. Opslaget er udskiftet med en tabel i testen.
final class ResolveLog: @unchecked Sendable { var asked: [String] = [] }
func resolveChecks() async {
    let table: [String: [String]] = [
        "hjemmeserver.local": ["192.168.1.5"],
        "evil.local": ["8.8.8.8"],
        "blandet.lan": ["192.168.1.5", "8.8.8.8"],
        "tomt.lan": [],
        "hjemmeserver": ["fd00::1"],
        "offentlig-ipv6": ["2001:db8::1"],
        "min.ts.net": ["100.101.2.3"],
        "falsk.ts.net": ["8.8.4.4"],
        "mappet.lan": ["::ffff:8.8.8.8"],
        "mappet-privat.lan": ["::ffff:192.168.1.9"],
        "scope.lan": ["fe80::1%en0"],
    ]
    let log = ResolveLog()
    OllamaHostPolicy.resolver = { host in log.asked.append(host); return table[host] ?? [] }
    func ok(_ url: String) async -> Bool { await OllamaHostPolicy.validate(u(url), allowRemote: true) }
    check(await ok("http://hjemmeserver.local:11434"), "navn der peger på 192.168.x: tilladt")
    check(!(await ok("http://evil.local:11434")), "B3: .local-navn der peger på en offentlig IP: afvist")
    check(!(await ok("http://blandet.lan:11434")), "B3: navn med både privat og offentligt svar: afvist")
    check(!(await ok("http://tomt.lan:11434")), "B3: navn uden svar: afvist")
    check(await ok("http://hjemmeserver:11434"), "enkeltnavn der peger på fd00::1 (privat IPv6): tilladt")
    check(!(await ok("http://offentlig-ipv6:11434")), "B3: enkeltnavn med offentlig IPv6: afvist")
    check(await ok("http://min.ts.net:11434"), "ts.net-navn med 100.x: tilladt")
    check(!(await ok("http://falsk.ts.net:11434")), "B3: ts.net-navn der peger offentligt: afvist")
    check(!(await ok("http://mappet.lan:11434")), "B3: IPv4-mappet offentlig adresse (::ffff:8.8.8.8): afvist")
    check(await ok("http://mappet-privat.lan:11434"), "IPv4-mappet privat adresse: tilladt")
    check(await ok("http://scope.lan:11434"), "link-local IPv6 med zone-id: tilladt")
    let before = log.asked.count
    check(await OllamaHostPolicy.validate(u("http://localhost:11434"), allowRemote: false), "localhost uden at slå op: tilladt")
    check(await OllamaHostPolicy.validate(u("http://192.168.1.20:11434"), allowRemote: true), "privat IP-adresse uden at slå op: tilladt")
    check(log.asked.count == before, "loopback og IP-adresser slås ikke op")
    check(!(await OllamaHostPolicy.validate(u("http://hjemmeserver.local:11434"), allowRemote: false)), "navn uden «Tillad anden maskine»: afvist uden opslag")
    // Det rigtige systemopslag: «localhost» og et rent tal. Intet netværk (kun lokale opslag).
    OllamaHostPolicy.resolver = OllamaHostPolicy.systemResolve
    let lh = OllamaHostPolicy.systemResolve("localhost")
    check(!lh.isEmpty && lh.allSatisfy(OllamaHostPolicy.isPrivateOrLoopbackAddress), "systemopslag af localhost giver kun loopback (\(lh))")
    let numeric = OllamaHostPolicy.systemResolve("134744072")
    check(numeric.isEmpty || numeric.allSatisfy { !OllamaHostPolicy.isPrivateOrLoopbackAddress($0) }, "systemopslag af 134744072 giver en offentlig adresse eller intet (\(numeric))")
    check(!(await OllamaHostPolicy.validate(u("http://134744072:11434"), allowRemote: true)), "B3: 134744072 (= 8.8.8.8) afvist")
}

// 2. Fejlstier mod lokal testserver
let args = CommandLine.arguments
let lan = args.count > 1 ? args[1] : "127.0.0.1"
let portBase = Int(ProcessInfo.processInfo.environment["DIKTAT_TEST_PORT_BASE"] ?? "") ?? 18600
let ports = ["ok": portBase + 1, "hang": portBase + 2, "err500": portBase + 3, "empty": portBase + 4, "garbage": portBase + 5]
let raw = "Dette er det rå diktat."

func cleanup(_ base: String, timeout: TimeInterval) async -> (String, String) {
    let t0 = Date()
    let outcome = await CleanupFallback.run(raw: raw, text: { (s: String) in s }, emptyError: EnhancementError.enhancementFailed) {
        try await OllamaLocalClient.generate(baseURL: u(base), model: "test-model", prompt: raw, systemPrompt: "ryd op", temperature: 0, timeout: timeout)
    }
    let text = CleanupFallback.deliveredText(raw: raw, outcome: outcome, text: { $0 })
    var why = "ok"
    if case .fellBack(let e) = outcome { why = "\(e)" }
    return (text, "\(why) efter \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
}

@main struct T { static func main() async {
    policyChecks()
    await resolveChecks()
    // lukket port: ingen server
    var r = await cleanup("http://127.0.0.1:\(portBase + 99)", timeout: 3)
    check(r.0 == raw, "lukket port: rå tekst leveres (\(r.1))")
    r = await cleanup("http://127.0.0.1:\(ports["hang"]!)", timeout: 2)
    check(r.0 == raw, "timeout: rå tekst leveres (\(r.1))")
    r = await cleanup("http://127.0.0.1:\(ports["err500"]!)", timeout: 3)
    check(r.0 == raw, "HTTP 500: rå tekst leveres (\(r.1))")
    r = await cleanup("http://127.0.0.1:\(ports["empty"]!)", timeout: 3)
    check(r.0 == raw && r.1.hasPrefix("enhancementFailed"), "tomt svar: rå tekst leveres, ikke tom tekst (\(r.1))")
    r = await cleanup("http://127.0.0.1:\(ports["garbage"]!)", timeout: 3)
    check(r.0 == raw, "ugyldigt svar: rå tekst leveres (\(r.1))")
    r = await cleanup("http://127.0.0.1:\(ports["ok"]!)", timeout: 3)
    check(r.0 == "Ryddet tekst.", "kontrol, alt virker: ryddet tekst leveres (\(r.1))")

    // anden maskine = denne Macs netværksadresse (ikke loopback), fælles UserDefaults for testprocessen
    UserDefaults.standard.set(false, forKey: OllamaHostPolicy.allowRemoteKey)
    r = await cleanup("http://\(lan):\(ports["ok"]!)", timeout: 3)
    check(r.0 == raw && r.1.contains("invalidURL"), "netværksadresse med fremmed maskine slået fra: afvist, rå tekst (\(r.1))")
    UserDefaults.standard.set(true, forKey: OllamaHostPolicy.allowRemoteKey)
    r = await cleanup("http://\(lan):\(ports["ok"]!)", timeout: 3)
    check(r.0 == "Ryddet tekst.", "netværksadresse med fremmed maskine slået til: ryddet tekst (\(r.1))")
    r = await cleanup("http://\(lan):\(ports["hang"]!)", timeout: 2)
    check(r.0 == raw, "fremmed maskine hænger: rå tekst efter timeout (\(r.1))")
    print(fails == 0 ? "ALLE TESTS BESTÅET" : "\(fails) FEJL")
    exit(fails == 0 ? 0 : 1)
}}
