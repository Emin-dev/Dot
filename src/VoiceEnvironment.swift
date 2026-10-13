import Foundation
import AVFoundation
import CoreAudio

/// Native device-change notifications revoke a conversation before another microphone invitation.
@MainActor
final class VoiceEnvironmentMonitor {
    var isActive: () -> Bool = { false }
    var onChange: () -> Void = {}
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var permissionTimer: Timer?
    private var microphoneWasAuthorized = false
    private var generation = UUID()
    private var running = false

    func start() {
        stop(); running = true
        microphoneWasAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        watchRoutes()
        let expected = generation
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == expected, self.isActive() else { return }
                let authorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                let revoked = self.microphoneWasAuthorized && !authorized
                self.microphoneWasAuthorized = authorized
                if revoked { self.onChange() }
            }
        }
        permissionTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func watchRoutes() {
        var devices = Set<AudioDeviceID>()
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            watch(object: AudioObjectID(kAudioObjectSystemObject), selector: selector, routesChanged: true)
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
            if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0, devices.insert(device).inserted {
                watch(object: device, selector: kAudioDevicePropertyNominalSampleRate, routesChanged: false)
                watch(object: device, selector: kAudioDevicePropertyDeviceIsAlive, routesChanged: false)
            }
        }
    }
    private func watch(object: AudioObjectID, selector: AudioObjectPropertySelector, routesChanged: Bool) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let expected = generation
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == expected else { return }
                if self.isActive() { self.onChange() }
                if routesChanged { self.removeListeners(); self.watchRoutes() }
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            listeners.append((object, address, block))
        }
    }
    private func removeListeners() {
        for (object, value, block) in listeners {
            var address = value
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners.removeAll()
    }
    func stop() { running = false; generation = UUID(); permissionTimer?.invalidate(); permissionTimer = nil; removeListeners() }
}


/// A fresh read supplements notifications: a missed device callback cannot transfer
/// an automatic invitation onto a different input/output route.
struct VoiceAudioRoute: Equatable {
    let input: AudioDeviceID
    let output: AudioDeviceID
    let inputRate: Double
    let outputRate: Double
    static func current() -> VoiceAudioRoute? {
        func device(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value) == noErr, value != 0 else { return nil }
            return value
        }
        func rate(_ device: AudioDeviceID) -> Double? {
            var aliveAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var alive: UInt32 = 0, aliveSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &aliveAddress, 0, nil, &aliveSize, &alive) == noErr, alive != 0 else { return nil }
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value = 0.0, size = UInt32(MemoryLayout<Double>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, value.isFinite, value > 0 else { return nil }
            return value
        }
        guard let input = device(kAudioHardwarePropertyDefaultInputDevice), let output = device(kAudioHardwarePropertyDefaultOutputDevice),
              let inputRate = rate(input), let outputRate = rate(output) else { return nil }
        return VoiceAudioRoute(input: input, output: output, inputRate: inputRate, outputRate: outputRate)
    }
}
