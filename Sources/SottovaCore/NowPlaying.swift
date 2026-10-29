import MediaPlayer

/// Now Playing info and media keys. macOS needs playbackState set by hand on every change.
@MainActor
final class NowPlaying {
    init(controller: Controller) {
        let commands = MPRemoteCommandCenter.shared()
        let actions: [(MPRemoteCommand, @MainActor (Controller) -> Void)] = [
            (commands.playCommand, { $0.play() }),
            (commands.pauseCommand, { $0.pause() }),
            (commands.togglePlayPauseCommand, { $0.toggle() }),
            (commands.nextTrackCommand, { $0.skip() }),
        ]
        for (command, action) in actions {
            command.isEnabled = true
            command.addTarget { [weak controller] _ in
                Task { @MainActor in
                    if let controller { action(controller) }
                }
                return .success
            }
        }
        // the scrubber in Control Center and the menu bar's Now Playing
        commands.changePlaybackPositionCommand.addTarget { [weak controller] event in
            guard let time = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in controller?.seek(to: time) }
            return .success
        }
    }

    func update(status: PlaybackStatus, title: String?, track: Track?) {
        let center = MPNowPlayingInfoCenter.default()
        // a gap has nothing to scrub through
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = status == .playing || status == .paused
        switch status {
        case .idle:
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        case .resting:
            // reported as paused so play/pause still reaches us during a gap
            center.nowPlayingInfo = [MPMediaItemPropertyTitle: "resting", MPMediaItemPropertyArtist: "sottova"]
            center.playbackState = .paused
        case .playing, .paused:
            var info: [String: Any] = [MPMediaItemPropertyTitle: title ?? "sottova", MPMediaItemPropertyArtist: "sottova"]
            if let track {
                info[MPMediaItemPropertyPlaybackDuration] = track.duration
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = track.elapsed
                info[MPNowPlayingInfoPropertyPlaybackRate] = status == .playing ? 1.0 : 0.0
            }
            center.nowPlayingInfo = info
            center.playbackState = status == .playing ? .playing : .paused
        }
    }
}
