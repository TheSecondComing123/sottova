import AVFoundation

public actor Controller {
    private let engine = AVAudioEngine()
    private let deckA = AVAudioPlayerNode()
    private let mixerA = AVAudioMixerNode()

    public init() {
        engine.attach(deckA)
        engine.attach(mixerA)
        engine.connect(mixerA, to: engine.mainMixerNode, format: nil)
    }

    public func play(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        deckA.stop()
        engine.connect(deckA, to: mixerA, format: file.processingFormat)
        try engine.start()
        deckA.scheduleFile(file, at: nil, completionHandler: nil)
        deckA.play()
    }
}
