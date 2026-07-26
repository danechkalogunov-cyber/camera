//
//  Placeholder.swift
//  VigilRTP
//
//  A target directory containing no .swift file is inferred by SwiftPM to be a C
//  target, and it then fails looking for an "include" directory. Every target
//  therefore needs at least one Swift file from the scaffolding commit onward.
//  See docs/BUILD-VERIFICATION.md, defect 3. Delete this file once the target has
//  real sources.
//

enum VigilRTPPlaceholder {}
