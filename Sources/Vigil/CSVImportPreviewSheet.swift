//
//  CSVImportPreviewSheet.swift
//  Vigil
//
//  Nothing reaches the library until this sheet confirms it. Valid rows are editable; invalid rows
//  keep their source line and named error, and can only be committed through the explicit skip mode.
//

#if os(macOS)

import SwiftUI

import VigilCore
import VigilUI

@MainActor
struct CSVImportPreviewSheet: View {
    @State private var preview: CameraCSVImporter.Preview
    @State private var skipsInvalidRows = false

    let onImport: ([CameraCSVImporter.PreviewRow]) -> Void
    let onCancel: () -> Void

    init(preview: CameraCSVImporter.Preview,
         onImport: @escaping ([CameraCSVImporter.PreviewRow]) -> Void,
         onCancel: @escaping () -> Void) {
        _preview = State(initialValue: preview)
        self.onImport = onImport
        self.onCancel = onCancel
    }

    private var cameras: [Camera] {
        preparedRows.compactMap(\.camera)
    }

    private var preparedRows: [CameraCSVImporter.PreviewRow] {
        preview.rows.compactMap { row in
            guard let camera = row.camera else { return nil }
            guard let validated = try? camera.validated() else { return nil }
            var updated = row
            updated.camera = validated
            return updated
        }
    }

    private var canImport: Bool {
        let rejectedAfterEditing = preview.rows.filter { $0.camera != nil }.count - cameras.count
        let invalid = preview.invalidCount + rejectedAfterEditing
        return !cameras.isEmpty && (invalid == 0 || skipsInvalidRows)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review Camera Import", bundle: .vigilUI).font(.title2.weight(.semibold))
            Text(String(format: vigilUIString("%@ · delimiter %@ · %@ valid · %@ invalid"),
                        preview.encoding, Self.delimiterName(preview.delimiter),
                        String(cameras.count), String(preview.invalidCount)))
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach($preview.rows) { $row in previewRow($row) }
                }
            }
            .frame(minHeight: 280, maxHeight: 460)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            if preview.invalidCount > 0 {
                Toggle("Skip invalid rows", isOn: $skipsInvalidRows)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Import") { onImport(preparedRows) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
        }
        .padding(20)
        .frame(width: 760)
    }

    @ViewBuilder
    private func previewRow(_ row: Binding<CameraCSVImporter.PreviewRow>) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: String(row.wrappedValue.sourceRow))
                .font(.body.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36)
            if row.wrappedValue.camera != nil {
                TextField("Name", text: Binding(
                    get: { row.wrappedValue.camera?.name ?? "" },
                    set: { value in
                        var camera = row.wrappedValue.camera
                        camera?.name = value
                        row.wrappedValue.camera = camera
                    }))
                TextField("Host", text: Binding(
                    get: { row.wrappedValue.camera?.host ?? "" },
                    set: { value in
                        var camera = row.wrappedValue.camera
                        camera?.host = value
                        row.wrappedValue.camera = camera
                    }))
                    .font(.body.monospaced())
                Text(verbatim: row.wrappedValue.camera.map {
                    "HTTP \($0.httpPort) · RTSP \($0.rtspPort) · ch \($0.channel.value)"
                } ?? "")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 210)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(verbatim: Self.failureDescription(row.wrappedValue.failure))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private static func delimiterName(_ delimiter: Character) -> String {
        delimiter == "\t" ? vigilUIString("tab") : String(delimiter)
    }

    private static func failureDescription(_ failure: CameraCSVImporter.Failure?) -> String {
        guard let failure else { return vigilUIString("Unknown row error") }
        switch failure {
        case .emptyDocument: return vigilUIString("Empty document")
        case .unsupportedTextEncoding: return vigilUIString("Unsupported text encoding")
        case .missingHostColumn: return vigilUIString("Missing host column")
        case .malformedRow(let row):
            return String(format: vigilUIString("Row %@ has the wrong number of columns"),
                          String(row))
        case .invalidInteger(let row, let column):
            return String(format: vigilUIString("Row %@ has an invalid number in %@"),
                          String(row), column)
        case .invalidBoolean(let row, let column):
            return String(format: vigilUIString("Row %@ has an invalid yes/no value in %@"),
                          String(row), column)
        case .invalidCamera(let row, let reason):
            return String(format: vigilUIString("Row %@ is not a valid camera: %@"),
                          String(row), reason)
        }
    }
}

#endif
