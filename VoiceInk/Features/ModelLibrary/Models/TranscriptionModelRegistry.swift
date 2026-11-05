import Foundation

enum TranscriptionModelRegistry {

    static var models: [any TranscriptionModel] {
        return predefinedModels
    }

    static func model(forSelectionKey key: String, in models: [any TranscriptionModel]) -> (any TranscriptionModel)? {
        if let model = models.first(where: { $0.selectionKey == key }) {
            return model
        }

        return models.first { $0.name == key }
    }

    private static let predefinedModels: [any TranscriptionModel] = {
        let nonCloudModels: [any TranscriptionModel] = [
            // Native Apple Model
            NativeAppleModel(
                name: "apple-speech",
                displayName: "Apple Speech",
                description: "Bruger Apples egen Speech-ramme til transskription. Kræver macOS 26",
                isMultilingualModel: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .nativeApple)
            ),

            // Parakeet Models
            FluidAudioModel(
                name: "parakeet-tdt-0.6b-v2",
                displayName: "Parakeet V2",
                description: "NVIDIAs Parakeet V2-model optimeret til lynhurtig transskription kun af engelsk",
                size: "474 MB",
                speed: 0.99,
                accuracy: 0.94,
                ramUsage: 0.8,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: false, provider: .fluidAudio)
            ),
            FluidAudioModel(
                name: "parakeet-tdt-0.6b-v3",
                displayName: "Parakeet V3",
                description: "Parakeet V3 med engelsk og 25 europæiske sprog",
                size: "494 MB",
                speed: 0.99,
                accuracy: 0.94,
                ramUsage: 0.8,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .fluidAudio)
            ),
            FluidAudioModel(
                name: "parakeet-unified-0.6b",
                displayName: "Parakeet Unified",
                description: "Parakeet-model kun til engelsk med indbygget realtidstransskription",
                size: "1.2 GB",
                speed: 0.99,
                accuracy: 0.95,
                ramUsage: 1.0,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: false, provider: .fluidAudio)
            ),
            FluidAudioModel(
                name: "nemotron-latin-0.6b",
                displayName: "Nemotron Latin",
                description: "NVIDIAs Nemotron-streamingmodel med understøttelse af latinske sprog",
                size: "620 MB",
                speed: 0.99,
                accuracy: 0.92,
                ramUsage: 1.2,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.nemotronLatin
            ),
            FluidAudioModel(
                name: "nemotron-multilingual-0.6b",
                displayName: "Nemotron Multilingual",
                description: "NVIDIAs Nemotron-streamingmodel med flersproget understøttelse",
                size: "672 MB",
                speed: 0.99,
                accuracy: 0.90,
                ramUsage: 1.5,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.nemotronMultilingual
            ),

            TranscribeCppModel(
                name: "cohere-transcribe",
                displayName: "Cohere Transcribe",
                description: "Nøjagtig flersproget transskription, der kører privat på din Mac",
                size: "1.56 GB",
                speed: 0.75,
                accuracy: 0.95,
                ramUsage: 2.5,
                publisher: "Cohere",
                supportedLanguages: LanguageDictionary.cohereTranscribe
            ),
            TranscribeCppModel(
                name: "sensevoice-small",
                displayName: "SenseVoice Small",
                description: "Hurtig transskription af CJK og engelsk, der kører privat på din Mac",
                size: "241 MB",
                speed: 0.99,
                accuracy: 0.92,
                ramUsage: 0.5,
                publisher: "FunAudioLLM / Alibaba",
                supportedLanguages: LanguageDictionary.senseVoiceSmall
            ),

            // Local Models
            WhisperModel(
                name: "ggml-tiny",
                displayName: "Tiny",
                size: "75 MB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
                description: "Tiny-model, hurtigst, mindst nøjagtig",
                speed: 0.95,
                accuracy: 0.6,
                ramUsage: 0.3
            ),
            WhisperModel(
                name: "ggml-tiny.en",
                displayName: "Tiny (engelsk)",
                size: "75 MB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: false, provider: .whisper),
                description: "Tiny-model optimeret til engelsk, hurtigst, mindst nøjagtig",
                speed: 0.95,
                accuracy: 0.65,
                ramUsage: 0.3
            ),
            WhisperModel(
                name: "ggml-base",
                displayName: "Base",
                size: "142 MB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
                description: "Basismodel, god balance mellem hastighed og nøjagtighed, understøtter flere sprog",
                speed: 0.85,
                accuracy: 0.72,
                ramUsage: 0.5
            ),
            WhisperModel(
                name: "ggml-base.en",
                displayName: "Base (engelsk)",
                size: "142 MB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: false, provider: .whisper),
                description: "Basismodel optimeret til engelsk, god balance mellem hastighed og nøjagtighed",
                speed: 0.85,
                accuracy: 0.75,
                ramUsage: 0.5
            ),
            WhisperModel(
                name: "ggml-large-v2",
                displayName: "Large v2",
                size: "2.9 GB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
                description: "Stor model v2, langsommere end Medium men mere nøjagtig",
                speed: 0.3,
                accuracy: 0.95,
                ramUsage: 3.8
            ),
            WhisperModel(
                name: "ggml-large-v3",
                displayName: "Large v3",
                size: "2.9 GB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
                description: "Stor model v3, meget langsom men mest nøjagtig",
                speed: 0.3,
                accuracy: 0.95,
                ramUsage: 3.9
            ),
            WhisperModel(
                name: "ggml-large-v3-turbo",
                displayName: "Large v3 Turbo",
                size: "1.5 GB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
                description: "Stor model v3 Turbo, hurtigere end v3 med nogenlunde samme nøjagtighed",
                speed: 0.75,
                accuracy: 0.94,
                ramUsage: 1.8
            ),
            WhisperModel(
                name: "ggml-large-v3-turbo-q5_0",
                displayName: "Large v3 Turbo (Quantized)",
                size: "547 MB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
                description: "Kvantiseret version af Large v3 Turbo, hurtigere med lidt lavere nøjagtighed",
                speed: 0.75,
                accuracy: 0.94,
                ramUsage: 1.0
            ),
        ]

        return nonCloudModels
    }()
}
