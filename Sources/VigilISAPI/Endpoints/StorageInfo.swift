//
//  StorageInfo.swift
//  VigilISAPI
//
//  `GET /ISAPI/ContentMgmt/Storage` and its optional quota sibling: volumes, capacity and health.
//  Implements docs/spec-isapi.md §15.4.
//
//  Capacity is **decimal MB** in Hikvision's accounting — 1 MB is 1 000 000 bytes — so Vigil formats
//  it decimally and its numbers match the camera's own web UI. Using binary units here would make
//  every figure disagree with the device by 5% and every support call harder.
//

import Foundation
import VigilProtocols

// MARK: - StorageVolume

/// One volume: an HDD, an SD card, or a network mount.
public struct StorageVolume: Sendable, Hashable, Codable, Identifiable {

    /// What kind of medium it is.
    public enum Kind: Sendable, Hashable, Codable {
        case sata, sd, esata, local, iscsi
        case nas(mount: String?)
        case other(String)

        init(raw: String?, mountType: String? = nil) {
            switch ISAPIVocabulary.normalize(raw ?? "") {
            case "sata": self = .sata
            case "sd": self = .sd
            case "esata": self = .esata
            case "local": self = .local
            case "iscsi": self = .iscsi
            case "nas": self = .nas(mount: mountType)
            case "": self = .other("")
            default: self = .other(raw ?? "")
            }
        }
    }

    /// Health, with the device's own misspelling accepted.
    public enum Status: String, Sendable, Hashable, Codable {
        case ok, unformatted, error, sleeping, idle, mismatch, absent, formatting, unknown

        init(raw: String?) {
            switch ISAPIVocabulary.normalize(raw ?? "") {
            case "ok": self = .ok
            // `unformated` really is what several firmwares send.
            case "unformatted", "unformated": self = .unformatted
            case "error": self = .error
            case "sleeping": self = .sleeping
            case "idle": self = .idle
            case "mismatch": self = .mismatch
            case "notexist": self = .absent
            case "formatting": self = .formatting
            default: self = .unknown
            }
        }
    }

    public let id: Int
    public let name: String?
    public let kind: Kind
    public let status: Status
    /// Decimal MB.
    public let capacityMB: Int
    /// Decimal MB.
    public let freeSpaceMB: Int
    public let isReadOnly: Bool

    public init(id: Int, name: String?, kind: Kind, status: Status, capacityMB: Int,
                freeSpaceMB: Int, isReadOnly: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
        self.capacityMB = capacityMB
        self.freeSpaceMB = freeSpaceMB
        self.isReadOnly = isReadOnly
    }

    /// 0…1. Zero for a volume reporting no capacity, rather than a division by zero.
    public var usedFraction: Double {
        guard capacityMB > 0 else { return 0 }
        return min(1, max(0, 1 - Double(freeSpaceMB) / Double(capacityMB)))
    }

    /// Capacity in bytes, decimal.
    public var capacityBytes: Int64 { ISAPIUnits.bytes(fromDecimalMB: capacityMB) }
    /// Free space in bytes, decimal.
    public var freeBytes: Int64 { ISAPIUnits.bytes(fromDecimalMB: freeSpaceMB) }
}

// MARK: - StorageQuota

/// One quota entry, meaningful only when `workMode == quota`.
public struct StorageQuota: Sendable, Hashable, Codable, Identifiable {
    public let id: Int
    /// `picture` or `record`.
    public let kind: String
    public let totalSpaceMB: Int
    public let usedSpaceMB: Int

    public init(id: Int, kind: String, totalSpaceMB: Int, usedSpaceMB: Int) {
        self.id = id
        self.kind = kind
        self.totalSpaceMB = totalSpaceMB
        self.usedSpaceMB = usedSpaceMB
    }

    /// Decodes a `<QuotaList>`. This endpoint 404s on many devices; the caller hides the section
    /// rather than surfacing an error.
    public static func list(document: ISAPIDocument) -> [StorageQuota] {
        document.nodes("Quota[]").compactMap { node in
            guard let id = node["id"].int else { return nil }
            return StorageQuota(id: id,
                                kind: node["type"].string ?? "record",
                                totalSpaceMB: node["totalSpace"].int ?? 0,
                                usedSpaceMB: node["usedSpace"].int ?? 0)
        }
    }
}

// MARK: - StorageInfo

/// The whole `<storage>` document.
public struct StorageInfo: Sendable, Hashable, Codable {
    public let volumes: [StorageVolume]
    /// `group` or `quota`.
    public let workMode: String
    /// Empty when the quota endpoint is unsupported, which is the normal case.
    public var quotas: [StorageQuota]

    public init(volumes: [StorageVolume], workMode: String, quotas: [StorageQuota] = []) {
        self.volumes = volumes
        self.workMode = workMode
        self.quotas = quotas
    }

    /// Decodes `<storage>`, reading both `<hddList>` and `<nasList>`.
    ///
    /// The `size` attribute on the lists is not trusted: some firmware omits it and some reports a
    /// count that disagrees with the number of children, so the children are what is counted.
    public init(document: ISAPIDocument) {
        var volumes = document.nodes("hddList/hdd[]").map { node in
            StorageVolume(id: node["id"].int ?? 0,
                          name: node["hddName"].string,
                          kind: StorageVolume.Kind(raw: node["hddType"].string),
                          status: StorageVolume.Status(raw: node["status"].string),
                          capacityMB: node["capacity"].int ?? 0,
                          freeSpaceMB: node["freeSpace"].int ?? 0,
                          isReadOnly: ISAPIVocabulary.normalize(node["property"].string ?? "")
                              == "ro")
        }
        volumes += document.nodes("nasList/nas[]").map { node in
            StorageVolume(id: node["id"].int ?? 0,
                          name: node["path"].string,
                          kind: .nas(mount: node["mountType"].string),
                          status: StorageVolume.Status(raw: node["status"].string),
                          capacityMB: node["capacity"].int ?? 0,
                          freeSpaceMB: node["freeSpace"].int ?? 0,
                          isReadOnly: ISAPIVocabulary.normalize(node["property"].string ?? "")
                              == "ro")
        }
        self.init(volumes: volumes,
                  workMode: document["workMode"].string ?? "group",
                  quotas: [])
    }

    /// Decimal MB across every volume.
    public var totalCapacityMB: Int { volumes.reduce(0) { $0 + $1.capacityMB } }
    /// Decimal MB across every volume.
    public var totalFreeMB: Int { volumes.reduce(0) { $0 + $1.freeSpaceMB } }

    /// True when any volume needs the user's attention — surfaced as a camera-row warning.
    ///
    /// A sleeping or idle disk is healthy; an unformatted or erroring one is not, and neither is a
    /// device that reports no volumes at all while claiming to record.
    public var needsAttention: Bool {
        volumes.contains { $0.status == .unformatted || $0.status == .error
            || $0.status == .mismatch || $0.status == .absent }
    }
}
