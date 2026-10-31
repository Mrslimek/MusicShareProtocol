import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var engine: Engine
    @State private var nameField = ""
    @State private var trackField = "Fake Track 01"
    @State private var statusField = "stopped"
    @State private var positionField = "0"
    @State private var selectedPeer: String?
    @State private var testText = "hi from mac"
    @State private var connectField = "127.0.0.1:"

    var body: some View {
        VStack(spacing: 8) {
            header
            if engine.permissionProblem { banner }
            HStack(alignment: .top, spacing: 12) {
                peersGroup.frame(maxWidth: .infinity)
                VStack(spacing: 12) {
                    playbackGroup
                    testGroup
                    manualGroup
                }.frame(width: 330)
            }
            logGroup
        }
        .padding(12)
        .frame(minWidth: 640, minHeight: 480)
        .onAppear { nameField = engine.displayName }
    }

    private var header: some View {
        HStack {
            Text("Music Share MVP").font(.headline)
            Text("id \(engine.identity.id.prefix(8))").font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
            Text("port \(engine.listenPort)").font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer()
            TextField("device name", text: $nameField, onCommit: { engine.setName(nameField) })
                .textFieldStyle(.roundedBorder).frame(width: 180)
        }
    }

    private var banner: some View {
        Text("Local Network access missing — grant Music Share in System Settings → " +
             "Privacy & Security → Local Network, or restart the app; " +
             "manual connect (host:port) still works.")
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.25))
    }

    private var peersGroup: some View {
        GroupBox(label: Text("Peers (\(engine.peersView.count))")) {
            if engine.peersView.isEmpty {
                Text("none discovered yet").foregroundColor(.secondary).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(engine.peersView) { p in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(p.name)  ·\(p.id.prefix(8))").fontWeight(.medium)
                                Text(p.addr + (p.note.isEmpty ? "" : "  (\(p.note))"))
                                    .font(.caption).foregroundColor(.secondary)
                                Text("peer state: \(p.remoteState)").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(p.state.rawValue)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(stateColor(p.state).opacity(0.2))
                                .cornerRadius(6)
                        }
                        .padding(6)
                        .background(selectedPeer == p.id ? Color.accentColor.opacity(0.15) : .clear)
                        .onTapGesture { selectedPeer = p.id }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func stateColor(_ s: PeerDisplay) -> Color {
        switch s {
        case .discovered: return .gray
        case .connecting: return .orange
        case .connected: return .green
        case .unreachable: return .red
        case .gone: return .secondary
        }
    }

    private var playbackGroup: some View {
        GroupBox(label: Text("Simulated playback (seq \(engine.ownSeq))")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("track"); TextField("track", text: $trackField, onCommit: pushPlayback) }
                HStack {
                    Text("status")
                    Picker("status", selection: $statusField) {
                        Text("playing").tag("playing"); Text("paused").tag("paused"); Text("stopped").tag("stopped")
                    }.labelsHidden().pickerStyle(.segmented)
                    Spacer()
                }.onChange(of: statusField) { _ in pushPlayback() }
                HStack {
                    Text("pos s"); TextField("pos", text: $positionField, onCommit: pushPlayback).frame(width: 70)
                    Stepper("", value: Binding(get: { Double(positionField) ?? 0 },
                                               set: { positionField = String(format: "%.1f", $0) }), step: 5)
                        .onChange(of: positionField) { _ in }
                    Spacer()
                    Button("Broadcast") { engine.broadcastManual() }
                }
            }.padding(4)
        }
    }

    private func pushPlayback() {
        engine.setOwnPlayback(track: trackField, status: statusField,
                              position: Double(positionField), broadcast: true)
    }

    private var testGroup: some View {
        GroupBox(label: Text("Test message → " + (selectedPeer.map { String($0.prefix(8)) } ?? "no peer selected"))) {
            HStack {
                TextField("text", text: $testText)
                Button("Send") {
                    if let sel = selectedPeer { engine.sendTest(testText, peerId: sel) }
                }.disabled(selectedPeer == nil)
            }.padding(4)
        }
    }

    private var manualGroup: some View {
        GroupBox(label: Text("Manual connect (overrides id tie-break)")) {
            HStack {
                TextField("host:port", text: $connectField, onCommit: { engine.manualConnect(connectField) })
                Button("Connect") { engine.manualConnect(connectField) }
            }.padding(4)
        }
    }

    private var logGroup: some View {
        GroupBox(label: HStack {
            Text("Log").bold()
            Spacer()
            Button("Copy") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(engine.logLines.joined(separator: "\n"), forType: .string)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([engine.logger.fileURL])
            }
        }) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(engine.logLines.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onChange(of: engine.logLines.count) { _ in
                    if let last = engine.logLines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }
}
