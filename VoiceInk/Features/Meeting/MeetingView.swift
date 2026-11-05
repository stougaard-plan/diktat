import AppKit
import SwiftUI

struct MeetingView: View {
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var transcriber = MeetingTranscriber.shared
    @ObservedObject private var titler = MeetingTitler.shared
    @State private var title = ""
    @State private var editingID: String?
    @State private var editText = ""
    @State private var renameError: String?
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(title: "Møder")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls
                    transcriptionInfo
                    notice
                    list
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            recorder.refreshMeetings()
            transcriber.refreshDiarizationAvailability()
        }
    }

    private var languageBinding: Binding<String> {
        Binding(get: { transcriber.language }, set: { transcriber.setLanguage($0) })
    }

    @AppStorage(MeetingTitleSettings.enabledKey) private var titleEnabled = false
    @AppStorage(MeetingTitleSettings.urlKey) private var titleURL = ""
    @AppStorage(MeetingTitleSettings.modelKey) private var titleModel = ""

    /// Valgfri automatisk titel. FRA som standard: mødet hedder da dato og tid, og der sendes ingenting.
    private var titleSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Foreslå mødets titel med en Ollama-model, jeg selv har sat op", isOn: $titleEnabled)
                .toggleStyle(.switch)
            Text("Slået fra som standard. Så hedder mødet dato og tid, og du kan selv rette titlen. Slås den til, sendes et uddrag af transskriptet (uden tidsstempler, højst ca. 3000 tegn) til adressen herunder, uden kryptering. Standardadressen er denne Mac. En adresse på dit eget lokalnet kræver, at «Tillad anden maskine på mit netværk» er slået til under AI-modeller.")
                .font(.caption).foregroundStyle(.secondary)
            if titleEnabled {
                HStack(spacing: 8) {
                    TextField(MeetingTitleSettings.defaultURL, text: $titleURL).textFieldStyle(.roundedBorder)
                    TextField("Modelnavn, fx qwen3:8b", text: $titleModel).textFieldStyle(.roundedBorder)
                }
                if titleModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("Skriv et modelnavn, ellers bliver titlen ikke foreslået.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Color.orange)
                }
                Text("Kun nye transskripter får en titel af sig selv. En titel du selv har rettet, bliver aldrig overskrevet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Hvilken model mødetransskriptionen bruger, og hvad der er (og ikke er) delt op. Ærligt, ikke pyntet.
    private var transcriptionInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Transskription af møder").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Sprog").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: languageBinding) {
                    Text("Dansk").tag("da")
                    Text("Engelsk").tag("en")
                    Text("Automatisk").tag("auto")
                }
                .labelsHidden().frame(width: 130)
            }
            Text("Kører af sig selv, når en optagelse er stoppet normalt. Bruger \(transcriber.modelDescription), Selve transskriptionen sker helt lokalt på denne Mac. Det er en egen model til møder og følger ikke valget under AI-modeller.")
                .font(.caption).foregroundStyle(.secondary)
            titleSettings
            Text("Mikrofonen står som «Mig», computerlyden som «De». Valgt sprog gælder hele mødet: engelsk tale i et dansk-låst møde bliver forvansket. Et filter fjerner stilhed, så hele tekster kommer med, men det kan springe tale over, hvis der er musik eller støj under. Kontrollér mod lyden.")
                .font(.caption).foregroundStyle(.secondary)
            if transcriber.diarizationAvailable {
                Text("Talerseparation er mulig: hvis computerlyden har flere stemmer, står de som «De 1», «De 2». Det er et teknisk gæt på stemmer og siger ikke, hvem de er.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Talerseparation er slået fra (valgfri, kræver HF_TOKEN og pyannote, se scripts/transcribe/README.md). De andre bliver ikke delt op, alle står som «De».",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Color.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func chooseScript() {
        let panel = NSOpenPanel()
        panel.title = "Vælg moede_transcribe.py (fra scripts/transcribe)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { transcriber.setScriptPath(url.path) }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Genvej til start/stop:").font(.caption).foregroundStyle(.secondary)
                Text(ShortcutStore.shortcut(for: .meetingRecording)?.displayString ?? "ingen")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Text("(ændres under Indstillinger)").font(.caption).foregroundStyle(.secondary)
            }
            if recorder.isRecording {
                HStack(spacing: 10) {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                    Text("Optager \(recorder.currentTitle)  \(MeetingIndicator.format(recorder.elapsed))")
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    Button("Stop optagelse") { recorder.stop() }.buttonStyle(.borderedProminent)
                }
            } else {
                HStack {
                    TextField("Titel (fx kunde og emne)", text: $title).textFieldStyle(.roundedBorder)
                    Button("Start optagelse") {
                        recorder.start(title: title)
                        title = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("Optager computerens lyd og mikrofonen i to spor i ~/Moeder/. Sig det højt til de andre, før du starter. Optagelse startes aldrig automatisk.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var notice: some View {
        if let warning = recorder.warning {
            Text(warning).font(.system(size: 12)).foregroundStyle(.red)
        }
        if case .error(let message) = recorder.state {
            HStack {
                Text(message).font(.system(size: 12)).foregroundStyle(.red)
                Spacer()
                Button("Luk") { recorder.dismissError() }
            }
        }
        if let message = transcriber.lastMessage {
            HStack {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                if !FileManager.default.fileExists(atPath: transcriber.scriptPath) {
                    Button("Vælg script…") { chooseScript() }
                }
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Optagelser").font(.system(size: 13, weight: .semibold))
            if recorder.meetings.isEmpty {
                Text("Ingen optagelser endnu.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(recorder.meetings) { meeting in
                meetingCard(meeting)
            }
        }
    }

    @ViewBuilder
    private func meetingCard(_ meeting: MeetingInfo) -> some View {
        let state = transcriber.state(for: meeting.url)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    if editingID == meeting.id {
                        HStack {
                            TextField("Titel", text: $editText)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { commitRename(meeting) }
                            Button("Gem titel") { commitRename(meeting) }.buttonStyle(.borderedProminent)
                            Button("Fortryd") { editingID = nil; renameError = nil }
                        }
                        if let renameError {
                            Text(renameError).font(.caption).foregroundStyle(Color.red)
                        }
                        Text("Tom titel nulstiller til dato og tid. Er automatisk titel slået til, laves et nyt forslag.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 6) {
                            Text(meeting.meta.map { MeetingTitle.displayName(title: $0.title, titleSource: $0.titleSource, startedAt: $0.startedAt) } ?? meeting.id)
                                .font(.system(size: 13, weight: .medium))
                            if meeting.meta?.status != "recording" {
                            Button {
                                editText = (meeting.meta?.titleSource == nil && meeting.meta?.title == MeetingTitle.fallback)
                                    ? "" : (meeting.meta?.title ?? "")
                                editingID = meeting.id
                            } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            .help("Ret titlen")
                            }
                            if titler.pending.contains(meeting.id) {
                                Text("laver titel…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text(subtitle(meeting)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Åbn") { NSWorkspace.shared.activateFileViewerSelecting([meeting.url]) }
                Button("Kopiér sti") {
                    ClipboardManager.copyLocalOnly(meeting.url.path)
                }
                switch state {
                case .queued, .running:
                    ProgressView().controlSize(.small)
                default:
                    Button(meeting.hasTranscript ? "Transskribér igen" : "Transskribér") {
                        transcriber.enqueue(folder: meeting.url, automatic: false)
                    }
                    .disabled(recorder.isRecording)
                }
            }
            statusLine(state, meeting: meeting)
            if meeting.hasTranscript {
                Button(expanded.contains(meeting.id) ? "Skjul transskript" : "Vis transskript") {
                    if expanded.contains(meeting.id) { expanded.remove(meeting.id) } else { expanded.insert(meeting.id) }
                }
                .buttonStyle(.link)
                if expanded.contains(meeting.id) {
                    MeetingTranscriptView(folder: meeting.url, reloadKey: transcriptStamp(meeting.url, state))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func commitRename(_ meeting: MeetingInfo) {
        if titler.rename(folder: meeting.url, to: editText) {
            editingID = nil
            renameError = nil
        } else {
            renameError = "Titlen kunne ikke gemmes. Er mødet stadig under optagelse, eller er mappen skrivebeskyttet? Se transskribering.log."
        }
    }

    private func transcriptStamp(_ url: URL, _ state: MeetingTranscriptState) -> String {
        let d = (try? url.appendingPathComponent("transskript.txt").resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return "\(d?.timeIntervalSince1970 ?? 0)"
    }

    @ViewBuilder
    private func statusLine(_ state: MeetingTranscriptState, meeting: MeetingInfo) -> some View {
        switch state {
        case .none:
            if meeting.meta?.status == "interrupted" {
                Text("Optagelsen blev afbrudt. Den transskriberes ikke af sig selv. Tryk Transskribér, hvis du vil have tekst.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Ikke transskriberet.").font(.caption).foregroundStyle(.secondary)
            }
        case .queued(let waiting):
            Label(waiting ? "I kø. Venter, til optagelsen er stoppet." : "I kø. Starter, når det forrige møde er færdigt.",
                  systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
        case .running(let step, let since):
            TimelineView(.periodic(from: since, by: 1)) { ctx in
                Label("Transskriberer: \(step) (\(MeetingIndicator.format(ctx.date.timeIntervalSince(since))))",
                      systemImage: "waveform")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            Label("Transskript klar", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        case .failed(let message, let kept):
            VStack(alignment: .leading, spacing: 2) {
                Label("Transskriptionen fejlede", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Color.red)
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if kept {
                    Text("Det tidligere transskript er uændret. Lydfilerne er urørte.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Lydfilerne er urørte.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func subtitle(_ m: MeetingInfo) -> String {
        guard let meta = m.meta else { return "Uden meta.json" }
        let status: String
        switch meta.status {
        case "recording": status = "optager"
        case "interrupted": status = "afbrudt, kan transskriberes"
        default: status = "gemt"
        }
        let segments = meta.segments.count
        let f = DateFormatter()
        f.locale = Locale(identifier: "da_DK")
        f.dateFormat = "d. MMM yyyy 'kl.' HH.mm"
        let when = f.string(from: meta.startedAt)
        let auto = meta.titleSource == "auto" ? " · titel foreslået automatisk" : ""
        return "\(when) · \(status) · \(segments) segmenter\(auto)"
    }
}

/// Viser et transskript samlet: tidsstempler, Mig/De, markerbart, og «Kopiér transskript» lægger hele teksten på udklipsholderen.
struct MeetingTranscriptView: View {
    let folder: URL
    let reloadKey: String
    @State private var transcript: MeetingTranscript?
    @State private var loadError: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(Color.red)
            }
            if let transcript {
                HStack {
                    Button(copied ? "Kopieret" : "Kopiér transskript") {
                        ClipboardManager.copyLocalOnly(transcript.fullText)
                        copied = true
                        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
                    }
                    .buttonStyle(.borderedProminent)
                    Text("\(transcript.lines.count) replikker").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(transcript.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    Text(Self.attributed(transcript))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 120, maxHeight: 380)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            }
        }
        .task(id: reloadKey) { load() }
    }

    private func load() {
        let url = folder.appendingPathComponent("transskript.txt")
        do {
            transcript = MeetingTranscript.parse(try String(contentsOf: url, encoding: .utf8))
            loadError = nil
        } catch {
            transcript = nil
            loadError = "Transskriptet kunne ikke læses: \(error.localizedDescription)"
        }
    }

    static func attributed(_ t: MeetingTranscript) -> AttributedString {
        var out = AttributedString()
        for line in t.lines {
            var time = AttributedString("[\(line.time)] ")
            time.font = .system(size: 12, design: .monospaced)
            time.foregroundColor = .secondary
            var who = AttributedString(line.speaker + ": ")
            who.font = .system(size: 12, weight: .semibold)
            var text = AttributedString(line.text + "\n")
            text.font = .system(size: 12)
            out += time + who + text
        }
        return out
    }
}
