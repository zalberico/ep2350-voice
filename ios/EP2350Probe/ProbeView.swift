import SwiftUI
import Combine

/// A diagnostic test, not a claim that another app is receiving this audio.
struct ProbeView: View {
    @StateObject private var capture = ProbeCapture()
    @StateObject private var form = ProbeForm()

    private let accent = Color(red: 1, green: 0.77, blue: 0.26)
    private let scenarios = ["Remote first", "Probe first", "Phone locked"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("EP-2350").font(.caption.weight(.bold)).tracking(3).foregroundStyle(accent)
                    Text("Can both apps listen?").font(.largeTitle.bold())
                    Text("Test the mic alongside Remote voice before adding a Dynamic Island display.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                #if targetEnvironment(simulator)
                Label("Simulator · physical input sharing is untested", systemImage: "iphone")
                    .font(.footnote.weight(.medium)).foregroundStyle(accent)
                #endif

                inputCard

                VStack(alignment: .leading, spacing: 12) {
                    Text("Test order").font(.headline)
                    Picker("Test order", selection: $form.scenario) {
                        ForEach(scenarios, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(capture.running || capture.starting)
                    Text(instructions).font(.subheadline).foregroundStyle(.secondary)
                    Text("Start with the handle released. Then squeeze, speak, and release.")
                        .font(.subheadline)
                    Button(action: start) {
                        Label("Start 90-second test", systemImage: "play.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 7)
                    }
                    .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                    .disabled(capture.running || capture.starting)
                    Button("Stop test") { capture.stop() }
                        .frame(maxWidth: .infinity).buttonStyle(.bordered)
                    Text("A second microphone session may pause the call. If that happens, stop this test and resume Remote. The probe won’t retry automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("What you observed").font(.headline)
                    Text("The probe can measure its own input. Only you can confirm the conversation still works.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("Remote still hears me", isOn: $form.remoteHearsMe)
                    Toggle("I can still hear replies", isOn: $form.repliesAudible)
                    Toggle("Also worked with screen locked", isOn: $form.lockedTest)
                }
                .tint(accent)

                DisclosureGroup("Input diagnostics") {
                    VStack(spacing: 10) {
                        diagnostic("Tested input", capture.capturedRoute)
                        diagnostic("Current route", capture.route)
                        diagnostic("Sample rate", capture.sampleRate > 0 ? "\(Int(capture.sampleRate)) Hz" : "—")
                        diagnostic("Audio callbacks", String(capture.callbacks))
                        diagnostic("Input frames", String(capture.frames))
                        diagnostic("Nonzero samples", String(capture.nonzeroSamples))
                        diagnostic("Cancel markers", String(capture.cancelCount))
                    }.padding(.top, 12)
                }
                .font(.subheadline).tint(accent)

                ShareLink(item: report) {
                    Label("Share test report", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Text("Local measurements only. No speech recording, transcription, model requests, or playback. No automatic control of Remote.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.045, green: 0.055, blue: 0.065))
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: capture.held ? "mic.fill" : "waveform")
                    .font(.title2).foregroundStyle(accent)
                Text(capture.held ? "Handle held" : capture.running ? "Monitoring input" : "Ready to test")
                    .font(.title3.bold())
                Spacer()
                if capture.running {
                    Text("\(capture.remainingSeconds)s").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            LevelBars(levelDB: capture.levelDB, active: capture.running && capture.callbacks > 0, tint: accent)
                .frame(height: 48)
                .accessibilityLabel("Input level")
                .accessibilityValue(capture.running ? "\(Int(capture.levelDB)) decibels" : "Inactive")
            HStack {
                Text("INPUT LEVEL").font(.caption2.weight(.semibold)).tracking(1)
                Spacer()
                Text(capture.running && capture.callbacks > 0 ? String(format: "%.0f dBFS", capture.levelDB) : "—")
                    .font(.caption.monospacedDigit())
            }.foregroundStyle(.secondary)
            Text(capture.status).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 28) {
                count("Squeezes", capture.pressCount)
                count("Releases", capture.releaseCount)
            }
        }
        .padding(20)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 24))
    }

    private var instructions: String {
        switch form.scenario {
        case "Probe first": return "Start this test, then switch to Remote and begin a voice call. Check both your input and its replies."
        case "Phone locked": return "With Remote voice already working, start this test, return to Remote, and lock the phone. Unlock before the timer ends to review the counters."
        default: return "Start a Remote voice call first. Return here to start the test, then switch back to Remote and keep talking."
        }
    }

    private func start() {
        form.remoteHearsMe = false
        form.repliesAudible = false
        form.lockedTest = false
        form.beganAt = Date()
        capture.start()
    }

    private func count(_ title: String, _ value: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(value)).font(.title2.monospacedDigit().bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func diagnostic(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    private var report: String {
        """
        EP-2350 iPhone input-sharing probe
        Test order: \(form.scenario)
        Started: \(form.beganAt?.formatted() ?? "Not started")
        Status: \(capture.status)
        Tested input: \(capture.capturedRoute)
        Current route: \(capture.route)
        Sample rate: \(capture.sampleRate) Hz
        Callbacks: \(capture.callbacks); frames: \(capture.frames); nonzero samples: \(capture.nonzeroSamples)
        Press/release/cancel markers: \(capture.pressCount)/\(capture.releaseCount)/\(capture.cancelCount)
        User observed Remote hearing speech: \(form.remoteHearsMe)
        User observed audible Remote replies: \(form.repliesAudible)
        User observed locked-screen operation: \(form.lockedTest)
        No audio is included. Local input measurements alone do not establish Remote compatibility.
        """
    }
}

private struct LevelBars: View {
    let levelDB: Float
    let active: Bool
    let tint: Color

    private var filled: Int {
        guard active, levelDB.isFinite else { return 0 }
        return Int((min(1, max(0, (levelDB + 60) / 60)) * 24).rounded())
    }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<24, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(index < filled ? tint : .white.opacity(0.09))
                    .frame(maxWidth: .infinity)
                    .frame(height: CGFloat(12 + index * 36 / 23))
            }
        }
        .animation(.linear(duration: 0.1), value: filled)
    }
}

@MainActor
private final class ProbeForm: ObservableObject {
    @Published var scenario = "Remote first"
    @Published var remoteHearsMe = false
    @Published var repliesAudible = false
    @Published var lockedTest = false
    @Published var beganAt: Date?
}
