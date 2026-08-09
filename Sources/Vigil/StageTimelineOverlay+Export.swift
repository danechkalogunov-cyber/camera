//
//  StageTimelineOverlay+Export.swift
//  Vigil
//
//  Compact I/O and export progress controls.
//

#if os(macOS)

import Foundation
import SwiftUI
import VigilUI

extension StageTimelineOverlay {
    @ViewBuilder
    var exportControls: some View {
        VButton("Set I", style: .ghost, size: .sm, action: onSetIn)
        VButton("Set O", style: .ghost, size: .sm, action: onSetOut)
        if let exportRange {
            Text(verbatim: exportDuration(exportRange))
                .vType(VTheme.Typography.monoSmall.numeric)
                .foregroundStyle(VTheme.Color.Text.secondary)
        }
        if let exportProgress {
            ProgressView(value: exportProgress)
                .progressViewStyle(.linear)
                .frame(width: 72)
            VButton(symbol: .stop, style: .icon, size: .sm,
                    accessibilityLabel: "Cancel export", action: onCancelExport)
        } else {
            VButton(symbol: .exportClip, style: .icon, size: .sm,
                    accessibilityLabel: "Export selected clip", action: onExport)
                .disabled(exportRange == nil)
        }
        if let exportFailure {
            Text(verbatim: exportFailure)
                .font(.caption)
                .foregroundStyle(VTheme.Color.Semantic.danger)
                .lineLimit(1)
                .help(exportFailure)
        }
    }

    private func exportDuration(_ range: Range<Date>) -> String {
        let total = max(0, Int(range.upperBound.timeIntervalSince(range.lowerBound).rounded()))
        return String(format: "%02d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
    }
}

#endif
