//
//  SettingsAndStorageTests.swift
//  VigilISAPITests
//
//  The motion grid's `gridMap` encoding, the image sub-resources and their read-modify-write
//  patches, JPEG snapshot policy and sniffing, storage volumes in decimal MB, two-way audio codec
//  negotiation, and the event-trigger and schedule readers.
//  Covers docs/spec-isapi.md §12.5, §14.7–§14.9, §15.4, §16 and §17.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - StorageSuite

@Suite struct StorageSuite {

    @Test func storageDecodesVolumesInDecimalMegabytes() throws {
        let info = StorageInfo(document: try SettingsFixtures.document(SettingsFixtures.storage))
        #expect(info.volumes.count == 2)
        #expect(info.workMode == "group")

        let hdd = info.volumes[0]
        #expect(hdd.id == 1)
        #expect(hdd.name == "hdd1")
        #expect(hdd.kind == .sata)
        #expect(hdd.status == .ok)
        #expect(hdd.capacityMB == 3_815_447)
        #expect(hdd.freeSpaceMB == 1_258_291)
        #expect(!hdd.isReadOnly)
        // Decimal MB, so the figures match the camera's own web UI.
        #expect(hdd.capacityBytes == 3_815_447_000_000)
        #expect(abs(hdd.usedFraction - 0.67) < 0.01)

        let sd = info.volumes[1]
        #expect(sd.kind == .sd)
        #expect(sd.status == .unformatted)
        #expect(sd.usedFraction == 1)
    }

    @Test func storageSurfacesAVolumeThatNeedsAttention() throws {
        let info = StorageInfo(document: try SettingsFixtures.document(SettingsFixtures.storage))
        #expect(info.needsAttention)
        #expect(info.totalCapacityMB == 3_876_482)
        #expect(info.totalFreeMB == 1_258_291)

        let healthy = StorageInfo(document: try SettingsFixtures.document("""
            <storage><hddList size="1"><hdd><id>1</id><hddType>SATA</hddType>
            <status>sleeping</status><capacity>1000</capacity><freeSpace>500</freeSpace>
            </hdd></hddList><workMode>quota</workMode></storage>
            """))
        // A sleeping or idle disk is healthy.
        #expect(!healthy.needsAttention)
        #expect(healthy.workMode == "quota")
    }

    @Test func storageAcceptsTheMisspelledStatus() throws {
        // `unformated` really is what several firmwares send.
        let info = StorageInfo(document: try SettingsFixtures.document("""
            <storage><hddList><hdd><id>1</id><status>unformated</status></hdd></hddList></storage>
            """))
        #expect(info.volumes.first?.status == .unformatted)
    }

    @Test func storageReadsNASEntries() throws {
        let info = StorageInfo(document: try SettingsFixtures.document("""
            <storage><hddList size="0"/><nasList size="1"><nas><id>5</id>
            <addressingFormatType>ipaddress</addressingFormatType><ipAddress>10.0.0.9</ipAddress>
            <mountType>NFS</mountType><path>/export/vigil</path><status>ok</status>
            <capacity>8000000</capacity><freeSpace>4000000</freeSpace><property>RO</property>
            </nas></nasList><workMode>group</workMode></storage>
            """))
        let nas = try #require(info.volumes.first)
        #expect(nas.kind == .nas(mount: "NFS"))
        #expect(nas.name == "/export/vigil")
        #expect(nas.isReadOnly)
    }

    @Test func storageQuotaListDecodes() throws {
        let quotas = StorageQuota.list(document: try SettingsFixtures.document("""
            <QuotaList><Quota><id>1</id><type>record</type><totalSpace>100000</totalSpace>
            <usedSpace>25000</usedSpace></Quota>
            <Quota><id>2</id><type>picture</type><totalSpace>1000</totalSpace>
            <usedSpace>10</usedSpace></Quota></QuotaList>
            """))
        #expect(quotas.count == 2)
        #expect(quotas[0].kind == "record")
        #expect(quotas[1].totalSpaceMB == 1000)
    }
}
