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

// MARK: - ImageSettingsSuite

@Suite struct ImageSettingsSuite {

    @Test func imageControlResourceNamesMatchTheWire() {
        // The capitalisation is the device's, not Swift's.
        #expect(ISAPIResource.image(ChannelID(1), .color) == "/Image/channels/1/color")
        #expect(ISAPIResource.image(ChannelID(1), .wdr) == "/Image/channels/1/WDR")
        #expect(ISAPIResource.image(ChannelID(1), .blc) == "/Image/channels/1/BLC")
        #expect(ISAPIResource.image(ChannelID(1), .hlc) == "/Image/channels/1/HLC")
        #expect(ISAPIResource.image(ChannelID(1), .ircut) == "/Image/channels/1/ircutFilter")
        #expect(ISAPIResource.image(ChannelID(2), .flip) == "/Image/channels/2/imageFlip")
        #expect(ISAPIResource.image(ChannelID(2), .powerLine)
                == "/Image/channels/2/powerLineFrequency")
        #expect(ISAPIResource.imageDefaults(ChannelID(1))
                == "/Image/channels/1/defaultConfiguration")
    }

    @Test func imageSettingsAbsorbTheColorDocument() throws {
        var settings = ImageSettings()
        settings.absorb(.color, document: try SettingsFixtures.document(SettingsFixtures.color))
        #expect(settings.brightness == 50)
        #expect(settings.contrast == 50)
        #expect(settings.saturation == 50)
        #expect(settings.available == [.color])
    }

    @Test func imageSettingsReadSharpnessUnderBothCasings() throws {
        var lower = ImageSettings()
        lower.absorb(.sharpness,
                     document: try SettingsFixtures.document(SettingsFixtures.sharpnessLowerCase))
        #expect(lower.sharpness == 72)
        var upper = ImageSettings()
        upper.absorb(.sharpness, document: try SettingsFixtures.document(
            "<Sharpness><SharpnessLevel>33</SharpnessLevel></Sharpness>"))
        #expect(upper.sharpness == 33)
    }

    @Test func imageSettingsRecordAControlEvenWithNoModelledValue() throws {
        // The device has the control; hiding the slider because a field was named differently
        // would be worse than showing it with the device's own default.
        var settings = ImageSettings()
        settings.absorb(.gamma, document: try SettingsFixtures.document(
            "<Gamma><enabled>true</enabled><gammaLevel>50</gammaLevel></Gamma>"))
        #expect(settings.available.contains(.gamma))
        settings.absorb(.blc, document: try SettingsFixtures.document("<BLC/>"))
        #expect(settings.available.contains(.blc))
    }

    @Test func wdrSettingReadsModeAndLevel() throws {
        let setting = WDRSetting(document: try SettingsFixtures.document(SettingsFixtures.wdr))
        #expect(setting.mode == .open)
        #expect(setting.level == 40)
        #expect(WDRSetting(document: try SettingsFixtures.document(
            "<WDR><mode>close</mode></WDR>")).mode == .close)
        #expect(WDRSetting(document: try SettingsFixtures.document(
            "<WDR><mode>auto</mode></WDR>")).mode == .auto)
        // Some firmware writes `<enabled>` instead of `<mode>`.
        #expect(WDRSetting(document: try SettingsFixtures.document(
            "<WDR><enabled>true</enabled></WDR>")).mode == .open)
    }

    @Test func irCutSettingReadsTypeAndThresholds() throws {
        let setting = IRCutSetting(document: try SettingsFixtures.document(SettingsFixtures.ircut))
        #expect(setting.mode == .auto)
        #expect(setting.nightToDayLevel == 4)
        #expect(setting.nightToDaySeconds == 5)
        #expect(IRCutSetting(document: try SettingsFixtures.document(
            "<IrcutFilter><IrcutFilterType>night</IrcutFilterType></IrcutFilter>")).mode == .night)
        #expect(IRCutSetting(document: try SettingsFixtures.document(
            "<IrcutFilter><IrcutFilterType>schedule</IrcutFilterType></IrcutFilter>")).mode
                == .schedule)
    }

    @Test func imageColorPatchEchoesTheWholeElement() throws {
        let node = try SettingsFixtures.document(SettingsFixtures.color).root
        let patched = ImageWrite.color(node, brightness: 62, contrast: nil, saturation: 55)
        let text = String(decoding: patched.serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("<brightnessLevel>62</brightnessLevel>"))
        #expect(text.contains("<saturationLevel>55</saturationLevel>"))
        // Untouched, and still present — some 5.4.x builds reject a `<Color>` without every
        // sibling.
        #expect(text.contains("<contrastLevel>50</contrastLevel>"))
        #expect(text.contains("version=\"2.0\""))
        // FIXED: the parser used to discard every `xmlns*` attribute, so no read-modify-write body
        // could carry the namespace. docs/spec-isapi.md §8 ("Namespace policy") and §17.2 both
        // require the `GET`'s `version` **and** `xmlns` to ride back out verbatim, because some
        // 5.4.x builds reject a `<Color>` element without them.
        #expect(text.contains("xmlns=\"http://www.hikvision.com/ver20/XMLSchema\""),
                "a read-modify-write body must echo the device's own xmlns verbatim (§8, §17.2)")
    }

    @Test func imageColorPatchClampsToZeroToHundred() throws {
        let node = try SettingsFixtures.document(SettingsFixtures.color).root
        let text = String(decoding: ImageWrite.color(node, brightness: 500, contrast: -20,
                                                     saturation: nil)
                            .serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("<brightnessLevel>100</brightnessLevel>"))
        #expect(text.contains("<contrastLevel>0</contrastLevel>"))
    }

    @Test func imageSharpnessPatchWritesWhicheverCasingTheDeviceUsed() throws {
        let lower = try SettingsFixtures.document(SettingsFixtures.sharpnessLowerCase).root
        let lowerText = String(decoding: ImageWrite.sharpness(lower, level: 80)
                                .serialized(declaration: false), as: UTF8.self)
        #expect(lowerText.contains("<sharpnessLevel>80</sharpnessLevel>"))
        #expect(!lowerText.contains("<SharpnessLevel>"))

        let upper = try SettingsFixtures.document(
            "<Sharpness><SharpnessLevel>10</SharpnessLevel></Sharpness>").root
        let upperText = String(decoding: ImageWrite.sharpness(upper, level: 80)
                                .serialized(declaration: false), as: UTF8.self)
        #expect(upperText.contains("<SharpnessLevel>80</SharpnessLevel>"))
    }

    @Test func imageWDRPatchWritesModeAndLevel() throws {
        let node = try SettingsFixtures.document(SettingsFixtures.wdr).root
        let text = String(decoding: ImageWrite.wdr(node, WDRSetting(mode: .close, level: 0))
                            .serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("<mode>close</mode>"))
        #expect(text.contains("<WDRLevel>0</WDRLevel>"))
    }

    @Test func imageIRCutPatchRefusesTheModesVigilDoesNotModel() throws {
        let node = try SettingsFixtures.document(SettingsFixtures.ircut).root
        let written = try #require(ImageWrite.irCut(node, IRCutSetting(mode: .night,
                                                                      nightToDayLevel: 9,
                                                                      nightToDaySeconds: 1)))
        let text = String(decoding: written.serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("<IrcutFilterType>night</IrcutFilterType>"))
        #expect(text.contains("<nightToDayFilterLevel>7</nightToDayFilterLevel>"))
        #expect(text.contains("<nightToDayFilterTime>3</nightToDayFilterTime>"))
        // `schedule` and `triggeredByAlarmIn` carry configuration Vigil does not model, so writing
        // the mode alone would silently discard it.
        #expect(ImageWrite.irCut(node, IRCutSetting(mode: .schedule, nightToDayLevel: nil,
                                                    nightToDaySeconds: nil)) == nil)
        #expect(ImageWrite.irCut(node, IRCutSetting(mode: .triggeredByAlarmIn,
                                                    nightToDayLevel: nil,
                                                    nightToDaySeconds: nil)) == nil)
    }
}
