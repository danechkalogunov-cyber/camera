//
//  StreamDoctorSheet.swift
//  Vigil
//
//  Presents live progress and the copyable result of the eleven diagnostic stages.
//

#if os(macOS)

import SwiftUI

import VigilDiscovery
import VigilUI

struct StreamDoctorSheet: View {
    let cameraName: String
    let outcomes: [StreamDoctorStep: StreamDoctorOutcome]
    let failures: [StreamDoctorStep: StreamDoctorFailure]
    let details: [StreamDoctorStep: String]
    let isRunning: Bool
    let onCopy: () -> Void
    let onRunAgain: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stream Doctor", bundle: .vigilUI).font(.title2.bold())
                    Text(cameraName).foregroundStyle(.secondary)
                }
                Spacer()
                if isRunning { ProgressView().controlSize(.small) }
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(StreamDoctorStep.allCases.enumerated()), id: \.element) { index, step in
                        row(index: index + 1, step: step)
                        if step != StreamDoctorStep.allCases.last { Divider() }
                    }
                }
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack {
                Button("Copy Report", action: onCopy).disabled(outcomes.isEmpty)
                Button("Run Again", action: onRunAgain).disabled(isRunning)
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 570, height: 590)
    }

    @ViewBuilder
    private func row(index: Int, step: StreamDoctorStep) -> some View {
        let outcome = outcomes[step]
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol(for: outcome))
                .foregroundStyle(color(for: outcome))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(index). \(step.title)").font(.body.weight(.medium))
                if let failure = failures[step] {
                    Text(failure.message).font(.caption).foregroundStyle(.red)
                    if let fix = failure.fix {
                        Text(fix).font(.caption).foregroundStyle(.secondary)
                    }
                } else if let detail = details[step] {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                } else if outcome == nil, isRunning {
                    Text("Waiting…", bundle: .vigilUI).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 9)
    }

    private func symbol(for outcome: StreamDoctorOutcome?) -> String {
        switch outcome {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "minus.circle"
        case .cancelled: "stop.circle"
        case nil: "circle"
        }
    }

    private func color(for outcome: StreamDoctorOutcome?) -> Color {
        switch outcome {
        case .passed: .green
        case .failed: .red
        case .cancelled: .orange
        case .skipped, nil: .secondary
        }
    }
}

#endif
