//
//  NotificationSoundPlayer.swift
//  Nook
//
//  Plays bundled notification sounds with a system-sound fallback.
//

import AppKit
import Foundation

@MainActor
enum NotificationSoundPlayer {
    private static var activeSounds: [NSSound] = []

    static func play(_ notificationSound: NotificationSound) {
        guard let soundName = notificationSound.soundName else { return }
        guard let sound = bundledSound(named: soundName) ?? NSSound(named: soundName) else { return }

        sound.volume = 1.0
        activeSounds.append(sound)
        sound.play()

        let retentionDuration = (sound.duration.isFinite && sound.duration > 0)
            ? sound.duration + 0.2
            : 1.2
        DispatchQueue.main.asyncAfter(deadline: .now() + retentionDuration) {
            activeSounds.removeAll { $0 === sound }
        }
    }

    private static func bundledSound(named soundName: String) -> NSSound? {
        let resourceName = "NookNotification-\(soundName)"
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "aiff") else {
            return nil
        }
        return NSSound(contentsOf: url, byReference: false)
    }
}
