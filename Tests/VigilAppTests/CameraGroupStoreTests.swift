//
//  CameraGroupStoreTests.swift
//  VigilAppTests
//

#if os(macOS)

import Testing
@testable import Vigil
import VigilProtocols

@Test func groupReorderUsesPreRemovalDestinationAndPreservesRecords() {
    let groups = ["A", "B", "C", "D"].map {
        CameraGroupRecord(id: GroupID(), name: $0, identityIndex: nil, members: [])
    }

    let downward = CameraGroupStore.moving(groups, id: groups[0].id, before: 3)
    #expect(downward.map(\.name) == ["B", "C", "A", "D"])
    #expect(Set(downward.map(\.id)) == Set(groups.map(\.id)))

    let upward = CameraGroupStore.moving(groups, id: groups[3].id, before: 1)
    #expect(upward.map(\.name) == ["A", "D", "B", "C"])
}

@Test func groupReorderRejectsUnknownAndAdjacentNoOps() {
    let groups = ["A", "B"].map {
        CameraGroupRecord(id: GroupID(), name: $0, identityIndex: nil, members: [])
    }

    #expect(CameraGroupStore.moving(groups, id: GroupID(), before: 0) == groups)
    #expect(CameraGroupStore.moving(groups, id: groups[0].id, before: 1) == groups)
}

#endif  // os(macOS)
