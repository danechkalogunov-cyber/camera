//
//  WindowSheets.swift
//  Vigil
//
//  The small modal forms the main window puts up: camera settings, a group's name, a bookmark.
//  macOS-only. See docs/UX.md §4.3 (row actions) and docs/DESIGN.md §9.3 (form controls).
//

#if os(macOS)

import Foundation
import SwiftUI

import VigilCore
import VigilProtocols
import VigilUI

// MARK: - SheetFrame

/// The chrome every sheet in this file shares: a title, a body, Cancel and a confirm button.
///
/// Written once because three nearly-identical sheets that each drew their own buttons would drift —
/// one gets ⌘⏎ on the confirm button and the others do not, and the user learns that Return works
/// "sometimes". Here the key equivalents are part of the frame.
@MainActor
private struct SheetFrame<Content: View>: View {

    /// What the sheet is for, shown at the top.
    let title: LocalizedStringKey

    /// The confirm button's label.
    let confirmTitle: LocalizedStringKey

    /// Whether the confirm button can be pressed. A form with nothing in it disables it rather than
    /// accepting the press and failing quietly.
    let isConfirmEnabled: Bool

    /// Whether Return confirms the sheet. Multi-line editors keep Return for a newline.
    let allowsDefaultAction: Bool

    /// Performed on confirm. The caller dismisses.
    let onConfirm: () -> Void

    /// Performed on cancel.
    let onCancel: () -> Void

    @ViewBuilder let content: () -> Content

    init(title: LocalizedStringKey,
         confirmTitle: LocalizedStringKey,
         isConfirmEnabled: Bool,
         allowsDefaultAction: Bool = true,
         onConfirm: @escaping () -> Void,
         onCancel: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.isConfirmEnabled = isConfirmEnabled
        self.allowsDefaultAction = allowsDefaultAction
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.md) {
            Text(title, bundle: .vigilUI)
                .vType(VTheme.Typography.headline)
                .foregroundStyle(VTheme.Color.Text.primary)

            content()

            HStack(spacing: VTheme.Space.sm) {
                Spacer(minLength: 0)
                VButton("Cancel", style: .secondary, size: .sm, action: onCancel)
                VButton(confirmTitle, style: .primary, size: .sm, action: onConfirm)
                    .disabled(!isConfirmEnabled)
            }
        }
        .padding(VTheme.Space.lg)
        .frame(width: SheetMetrics.width)
        .background(VTheme.Color.Layer.surface)
        // Escape cancels. Single-line sheets also bind Return to confirm; multi-line editors keep
        // it for a newline. Both are zero-sized buttons because that is how a key equivalent is
        // declared in pure SwiftUI without an AppKit responder.
        .background {
            Button("", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .hidden()
            if allowsDefaultAction {
                Button("", action: { if isConfirmEnabled { onConfirm() } })
                    .keyboardShortcut(.defaultAction)
                    .hidden()
            }
        }
    }
}

// MARK: - SheetMetrics

/// Sizes shared by the sheets.
private enum SheetMetrics {

    /// Wide enough for a 64-character name at the body size without wrapping mid-word, and narrow
    /// enough that it still reads as a dialogue rather than as a second window.
    static let width: CGFloat = 380

    /// The note field's height: four lines, which is as much as a note wants to be.
    static let noteHeight: CGFloat = 76
}

// MARK: - Layout presets

private struct LayoutPresetNameSheet: View {
    @State private var name = ""
    let onSave: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        SheetFrame(title: "Save Layout Preset", confirmTitle: "Save",
                   isConfirmEnabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   onConfirm: { onSave(name.trimmingCharacters(in: .whitespacesAndNewlines)) },
                   onCancel: onCancel) {
            TextField("Preset Name", text: $name)
        }
    }
}

private struct LayoutPresetManagerSheet: View {
    @State private var presets: [VLayoutPreset]
    let onSave: (VLayoutPresetCollection) -> Void
    let onCancel: () -> Void

    init(collection: VLayoutPresetCollection,
         onSave: @escaping (VLayoutPresetCollection) -> Void,
         onCancel: @escaping () -> Void) {
        _presets = State(initialValue: collection.presets)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        SheetFrame(title: "Manage Layout Presets", confirmTitle: "Done",
                   isConfirmEnabled: true, onConfirm: commit, onCancel: onCancel) {
            VStack(spacing: VTheme.Space.sm) {
                ForEach(Array(presets.indices), id: \.self) { index in
                    HStack(spacing: VTheme.Space.sm) {
                        TextField("Preset Name", text: $presets[index].name)
                        Text(verbatim: presets[index].layout.rawValue)
                            .foregroundStyle(VTheme.Color.Text.secondary)
                        Button { reorderPreset(index, by: -1) } label: {
                            Image(systemName: "chevron.up")
                        }.disabled(index == 0)
                        Button { reorderPreset(index, by: 1) } label: {
                            Image(systemName: "chevron.down")
                        }.disabled(index == presets.count - 1)
                        Button(role: .destructive) { presets.remove(at: index) } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .frame(minHeight: 120)
        }
    }

    private func reorderPreset(_ index: Int, by delta: Int) {
        let destination = index + delta
        guard presets.indices.contains(destination) else { return }
        presets.swapAt(index, destination)
    }

    private func commit() {
        var collection = VLayoutPresetCollection()
        for preset in presets { collection.save(preset) }
        onSave(collection)
    }
}

// MARK: - CameraSettingsSheet

/// Basic settings for one camera: what it is called, and which group it is in.
///
/// **Only what the app can actually honour.** The address, the port and the transport are shown as
/// facts rather than as fields, because changing any of them means tearing down the session and
/// reconnecting, and this build resumes exactly one remembered connection. Offering an editable
/// address here would be offering a control that reconnects to nowhere.
@MainActor
struct CameraSettingsSheet: View {

    /// The camera's current name, edited in place.
    @State private var name: String

    /// The group it is in, or `nil` for none.
    @State private var groupID: GroupID?

    /// Whether the chrome drawn over this camera's picture is shown.
    @State private var showsOverlay: Bool

    /// Whether this camera participates in automatic connection.
    @State private var isEnabled: Bool

    /// Explicit identity colour, or `.none` for deterministic automatic assignment.
    @State private var colorTag: ColorTag

    /// Per-camera RTP transport preference.
    @State private var transport: RTSPTransportKind

    /// Address, port and model, for the read-only rows.
    let host: String
    let httpPort: Int
    let model: String

    /// The groups it could be put in.
    let groups: [CameraGroupRecord]

    /// Applies the edits. Called with the trimmed name, the chosen group and the overlay switch.
    let onSave: (String, GroupID?, Bool, Bool, ColorTag, RTSPTransportKind) -> Void

    /// Dismisses without applying.
    let onCancel: () -> Void

    /// Creates the sheet over a camera's current values.
    init(name: String,
         groupID: GroupID?,
         showsOverlay: Bool,
         isEnabled: Bool,
         colorTag: ColorTag,
         transport: RTSPTransportKind,
         host: String,
         httpPort: Int,
         model: String,
         groups: [CameraGroupRecord],
         onSave: @escaping (String, GroupID?, Bool, Bool, ColorTag, RTSPTransportKind) -> Void,
         onCancel: @escaping () -> Void) {
        _name = State(initialValue: name)
        _groupID = State(initialValue: groupID)
        _showsOverlay = State(initialValue: showsOverlay)
        _isEnabled = State(initialValue: isEnabled)
        _colorTag = State(initialValue: colorTag)
        _transport = State(initialValue: transport)
        self.host = host
        self.httpPort = httpPort
        self.model = model
        self.groups = groups
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        SheetFrame(title: "Camera Settings",
                   confirmTitle: "Save",
                   // An empty name is refused rather than stored, matching `Camera.validated()`,
                   // which replaces one with "Camera <host>" — better to say so than to silently
                   // rename the camera to something the user did not type.
                   isConfirmEnabled: !name.trimmingCharacters(in: .whitespaces).isEmpty,
                   onConfirm: {
                       onSave(name, groupID, showsOverlay, isEnabled, colorTag, transport)
                   },
                   onCancel: onCancel) {
            VStack(alignment: .leading, spacing: VTheme.Space.md) {
                field("Name") {
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                field("Group") {
                    Picker("", selection: $groupID) {
                        Text("None", bundle: .vigilUI).tag(GroupID?.none)
                        ForEach(groups) { group in
                            Text(verbatim: group.name).tag(GroupID?.some(group.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Divider()
                VInspectorToggleRow("Enable camera", isOn: $isEnabled)
                field("Colour tag") {
                    Picker("", selection: $colorTag) {
                        Text("Automatic", bundle: .vigilUI).tag(ColorTag.none)
                        ForEach(ColorTag.allCases, id: \.self) { tag in
                            if tag != .none {
                                Text(Self.colorTagTitle(tag), bundle: .vigilUI).tag(tag)
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                field("Transport") {
                    Picker("", selection: $transport) {
                        ForEach(RTSPTransportKind.allCases, id: \.self) { choice in
                            Text(Self.transportTitle(choice), bundle: .vigilUI).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Divider()
                VInspectorToggleRow("Show overlay on video", isOn: $showsOverlay)
                Text("""
                    The camera's name, the connection chip and the statistics readout. \
                    Warnings about a stream that is failing are always shown.
                    """, bundle: .vigilUI)
                    .vType(VTheme.Typography.caption1)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                fact("Address", "\(host):\(httpPort)")
                fact("Model", model.isEmpty ? "—" : model)
            }
        }
    }

    /// A caption over a control.
    private func field<Control: View>(_ label: LocalizedStringKey,
                                      @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: VTheme.Space.xxs) {
            Text(label, bundle: .vigilUI)
                .vType(VTheme.Typography.callout)
                .foregroundStyle(VTheme.Color.Text.tertiary)
            control()
        }
    }

    /// Localised user-facing colour name; raw persistence values never leak into UI.
    private static func colorTagTitle(_ tag: ColorTag) -> LocalizedStringKey {
        switch tag {
        case .none: "Automatic"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .teal: "Teal"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        case .graphite: "Graphite"
        }
    }

    private static func transportTitle(_ transport: RTSPTransportKind) -> LocalizedStringKey {
        switch transport {
        case .auto: "Auto (TCP / UDP)"
        case .tcpInterleaved: "TCP (interleaved)"
        case .udpUnicast: "UDP (unicast)"
        case .udpMulticast: "UDP (multicast)"
        case .tcpTLS: "RTSP over TLS"
        }
    }

    /// A read-only row: something true about the device that this sheet cannot change.
    private func fact(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: VTheme.Space.sm) {
            Text(label, bundle: .vigilUI)
                .vType(VTheme.Typography.callout)
                .foregroundStyle(VTheme.Color.Text.tertiary)
            Spacer(minLength: VTheme.Space.sm)
            Text(verbatim: value)
                .vType(VTheme.Typography.mono)
                .foregroundStyle(VTheme.Color.Text.secondary)
                .textSelection(.enabled)
        }
    }
}

// MARK: - GroupNameSheet

/// Names a group, new or existing.
///
/// One sheet for both because the two forms are identical apart from their titles, and a second
/// near-copy would be a second place for the empty-name rule to be got wrong.
@MainActor
struct GroupNameSheet: View {

    @State private var name: String

    /// Whether this is a new group, which decides the wording.
    let isNew: Bool

    /// Applies the name.
    let onSave: (String) -> Void

    /// Dismisses without applying.
    let onCancel: () -> Void

    /// Creates the sheet.
    init(name: String = "",
         isNew: Bool,
         onSave: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        _name = State(initialValue: name)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        SheetFrame(title: isNew ? "New Group" : "Rename Group",
                   confirmTitle: isNew ? "Create" : "Rename",
                   isConfirmEnabled: !name.trimmingCharacters(in: .whitespaces).isEmpty,
                   onConfirm: { onSave(name) },
                   onCancel: onCancel) {
            TextField("", text: $name)
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - BookmarkSheet

/// Marks a moment, or edits a mark that already exists.
///
/// The title may be left empty on purpose — `VBookmarksView` renders the timestamp in its place,
/// because requiring a title at the moment of marking is what stops people marking anything. So the
/// confirm button is never disabled here, unlike the two sheets above.
@MainActor
struct BookmarkSheet: View {

    @State private var title: String
    @State private var note: String

    /// The moment being marked, shown so the user can see what they are labelling.
    let instant: Date

    /// Whether this is a new mark, which decides the wording.
    let isNew: Bool

    /// Applies the title and note.
    let onSave: (String, String) -> Void

    /// Dismisses without applying.
    let onCancel: () -> Void

    /// Creates the sheet.
    init(title: String = "",
         note: String = "",
         instant: Date,
         isNew: Bool,
         onSave: @escaping (String, String) -> Void,
         onCancel: @escaping () -> Void) {
        _title = State(initialValue: title)
        _note = State(initialValue: note)
        self.instant = instant
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        SheetFrame(title: isNew ? "Bookmark This Moment" : "Edit Bookmark",
                   confirmTitle: isNew ? "Add" : "Save",
                   isConfirmEnabled: true,
                   allowsDefaultAction: false,
                   onConfirm: { onSave(title, note) },
                   onCancel: onCancel) {
            VStack(alignment: .leading, spacing: VTheme.Space.md) {
                Text(verbatim: Self.stamp.string(from: instant))
                    .vType(VTheme.Typography.mono.numeric)
                    .foregroundStyle(VTheme.Color.Text.secondary)
                TextField("", text: $title, prompt: Text("Title (optional)", bundle: .vigilUI))
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $note)
                    .font(.body)
                    .frame(height: SheetMetrics.noteHeight)
                    .overlay {
                        VTheme.Radius.shape(VTheme.Radius.sm)
                            .strokeBorder(VTheme.Color.Stroke.default)
                    }
            }
        }
    }

    /// The moment, in the user's own calendar and zone.
    ///
    /// A `DateFormatter` rather than `TimelineClock`: that type belongs to `VigilUI`'s timeline and
    /// is built for decomposing an instant into a day's coordinates, not for one line of prose.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

// MARK: - The window's sheets

/// ⚠️ `internal` rather than `private`, for the reason given in `MainWindowView+Library.swift`:
/// `private` reaches a type's extensions only within one file.
///
/// Moved out of `MainWindowView.swift` when that file crossed the 600-line ceiling
/// API_CONTRACT.md §7.2 sets — and which `Scripts/lint.py` now enforces, which is how the crossing
/// was noticed at all. The sheets it presents are the four types below, so this is where it belongs.
extension MainWindowView {


    /// The form behind whichever sheet is up.
    ///
    /// One `switch` rather than five `.sheet(isPresented:)` modifiers stacked on the same view:
    /// SwiftUI presents only one of those and drops the rest silently, so two that could both be
    /// true is a bug waiting for a fast double-click. `MainWindowSheet` makes that unrepresentable.
    @ViewBuilder
    func sheetBody(_ sheet: MainWindowSheet) -> some View {
        switch sheet {
        case .cameraSettings:
            CameraSettingsSheet(name: identity.name,
                                groupID: groups.group(for: cameraID),
                                showsOverlay: window.showsVideoOverlay,
                                isEnabled: selectedCamera?.isEnabled ?? true,
                                colorTag: selectedCamera?.colorTag ?? .none,
                                transport: selectedCamera?.transport ?? .tcpInterleaved,
                                host: identity.host,
                                httpPort: selectedCamera?.httpPort ?? 80,
                                model: deviceInfo.identity.model,
                                groups: groups.groups,
                                onSave: { name, group, overlay, enabled, colorTag, transport in
                                    renameCamera(to: name)
                                    updateCameraMetadata(isEnabled: enabled, colorTag: colorTag)
                                    updateCameraTransport(transport)
                                    groups.setGroup(group, for: cameraID)
                                    window.showsVideoOverlay = overlay
                                    session.rememberVideoOverlay(overlay)
                                    window.sheet = nil
                                },
                                onCancel: { window.sheet = nil })
        case .newGroup:
            GroupNameSheet(isNew: true,
                           onSave: { name in
                               // The camera goes in as the group is created. A user who makes a
                               // group while looking at a camera means that camera to be in it.
                               groups.create(named: name, cameras: [cameraID])
                               window.sheet = nil
                           },
                           onCancel: { window.sheet = nil })
        case .renameGroup(let id):
            GroupNameSheet(name: groups.groups.first { $0.id == id }?.name ?? "",
                           isNew: false,
                           onSave: { name in
                               groups.rename(id, to: name)
                               window.sheet = nil
                           },
                           onCancel: { window.sheet = nil })
        case .newBookmark(let instant):
            BookmarkSheet(instant: instant,
                          isNew: true,
                          onSave: { title, note in
                              bookmarks.add(cameraID: cameraID,
                                            instant: instant,
                                            title: title,
                                            note: note)
                              window.sheet = nil
                          },
                          onCancel: { window.sheet = nil })
        case .editBookmark(let id):
            let record = bookmarks.bookmarks.first { $0.id == id }
            BookmarkSheet(title: record?.title ?? "",
                          note: record?.note ?? "",
                          instant: record?.instant ?? Date(),
                          isNew: false,
                          onSave: { title, note in
                              bookmarks.update(id, title: title, note: note)
                              window.sheet = nil
                          },
                          onCancel: { window.sheet = nil })
        case .shortcuts:
            VShortcutsSheet(sections: VShortcutReference.sections) { window.sheet = nil }
        case .csvImport:
            if let preview = window.csvImportPreview {
                CSVImportPreviewSheet(
                    preview: preview,
                    onImport: { rows in
                        window.sheet = nil
                        window.csvImportPreview = nil
                        importPreviewRows(rows)
                    },
                    onCancel: {
                        window.sheet = nil
                        window.csvImportPreview = nil
                    })
            }
        case .streamDoctor:
            StreamDoctorSheet(
                cameraName: window.streamDoctorCameraName,
                outcomes: window.streamDoctorOutcomes,
                failures: window.streamDoctorFailures,
                details: window.streamDoctorDetails,
                isRunning: window.isStreamDoctorRunning,
                onCopy: copyStreamDoctorReport,
                onRunAgain: runStreamDoctor,
                onClose: {
                    window.streamDoctorTask?.cancel()
                    window.sheet = nil
                })
        case .saveLayoutPreset:
            LayoutPresetNameSheet(
                onSave: { name in
                    window.layoutPresets.save(VLayoutPreset(
                        name: name, layout: window.layout,
                        cameraIDs: stageAssignment.visibleCameras.map { $0.rawValue.uuidString }))
                    window.sheet = nil
                },
                onCancel: { window.sheet = nil })
        case .manageLayoutPresets:
            LayoutPresetManagerSheet(
                collection: window.layoutPresets,
                onSave: { collection in
                    window.layoutPresets = collection
                    window.sheet = nil
                },
                onCancel: { window.sheet = nil })
        }
    }
}

#endif  // os(macOS)
