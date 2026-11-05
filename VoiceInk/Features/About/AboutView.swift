import SwiftUI

/// Om-side: version, licens og kreditering af de dele Diktat bygger på.
struct AboutView: View {
    private let credits: [(name: String, text: String)] = [
        (
            "Ikke VoiceInks egen udgave",
            "Diktat er en ændret udgave af VoiceInk (https://github.com/Beingpax/VoiceInk). Det er ikke VoiceInk-projektets officielle udgave. Send fejl i Diktat til Diktats eget repo (https://github.com/stougaard-plan/diktat) og ikke til VoiceInk. Diktat opdateres ikke af sig selv."
        ),
        (
            "VoiceInk",
            "VoiceInk er skrevet af Pax (GitHub: Beingpax) og udgivet under GNU General Public License v3 (GPL v3). Diktat er også udgivet under GPL v3, og kildekoden ligger i repoet. Ændringerne i forhold til VoiceInk står i filen NOTICE."
        ),
        (
            "Parakeet TDT 0.6B v3",
            "Hurtig talegenkendelse med NVIDIAs model parakeet-tdt-0.6b-v3 (CC-BY-4.0, https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), konverteret til CoreML af FluidInference. Modellen er brugt uden ændringer af indholdet."
        ),
        ("FluidAudio", "Swift-pakke til Parakeet på Apple-chip. Apache License 2.0."),
        ("whisper.cpp", "Whisper-modeller til diktering og møder. MIT-licens."),
        ("Silero VAD", "Stemmeaktivitetsfilter i ggml-format. MIT, Copyright (c) 2020-present Silero Team (snakers4/silero-vad)."),
        (
            "SenseVoice Small",
            "Model fra FunAudioLLM / Alibaba, hvis du selv vælger den. FunASR Model Open Source License Agreement (https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE)."
        ),
        (
            "Ingen garanti",
            "Programmet leveres uden nogen form for garanti, se GPL v3 §15."
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Diktat")
                        .font(.system(size: 30, weight: .semibold))
                    Text("Version \(version)")
                        .foregroundStyle(.secondary)
                    Text("Lokal diktering og mødenoter. Efter gennemgang af kildekoden sendes lyd og tekst ikke til nogen tjeneste.")
                        .padding(.top, 4)
                }

                ForEach(credits, id: \.name) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.system(size: 14, weight: .semibold))
                        Text(item.text)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }
}
