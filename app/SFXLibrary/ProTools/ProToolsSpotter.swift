import AppKit
import Carbon
import Foundation
import os

// MARK: - Apple Event "Spot to Region" for Pro Tools
//
// Sends the classic 'Sd2a'/'SRgn' AppleEvent that Pro Tools has accepted since
// PT 5.1. No PTSL/gRPC required. Ported from ptpeep's PTAppleEventSpot.
//
// Key parameters (from the Avid RegionSpotter SDK, 2005):
//   Trak = -99       → spot onto the currently selected track(s)
//   TkOf             → track offset (0 = selected track, 1 = next track down, …)
//   SMSt             → sample offset from the current PT edit-cursor position
//   Rgn.Star / Stop  → source in/out within the audio file (samples);
//                      Star=0 / Stop=fileLength exposes full pre/post-roll handles
//
// Sending Apple Events to Pro Tools requires the NSAppleEventsUsageDescription
// Info.plist key; the first send triggers a one-time Automation consent prompt.
// If the user denies it, AESend returns -1743 (errAEEventNotPermitted).

enum SpotError: LocalizedError {
    case proToolsNotRunning
    case badTargetDescriptor
    case sendFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .proToolsNotRunning:
            return "Pro Tools is not running."
        case .badTargetDescriptor:
            return "Could not address Pro Tools."
        case .sendFailed(let err):
            if err == -1743 {
                return "Pro Tools automation was not permitted. Allow SoundSearch to control Pro Tools in System Settings ▸ Privacy & Security ▸ Automation."
            }
            return "Pro Tools rejected the spot (AESend OSStatus \(err))."
        }
    }
}

enum ProToolsSpotter {

    private static let log = Logger(subsystem: "com.mattchan.SoundSearch", category: "spot")

    /// Spots a single audio file onto the selected Pro Tools track at the
    /// current edit-cursor position.
    ///
    /// - Parameters:
    ///   - fileURL:        Absolute path to the audio file.
    ///   - srcStartSample: First source sample to include (0 = start of file).
    ///   - srcStopSample:  Last source sample to include (frameCount = end of file).
    ///   - name:           Region name shown in Pro Tools.
    static func spot(fileURL: URL,
                     srcStartSample: Int32,
                     srcStopSample: Int32,
                     name: String) async throws {
        // AESend is synchronous — run it off the main thread.
        try await Task.detached(priority: .userInitiated) {
            try aeSendSpot(url: fileURL,
                           srcStart: srcStartSample,
                           srcStop: srcStopSample,
                           name: name,
                           trackOffset: 0,
                           sampleOffset: 0,   // place at the PT edit cursor
                           stream: 1)
        }.value
    }

    // MARK: - Private implementation

    /// Sends one 'Sd2a'/'SRgn' AppleEvent to Pro Tools.
    private static func aeSendSpot(url: URL,
                                   srcStart: Int32,
                                   srcStop: Int32,
                                   name: String,
                                   trackOffset: Int16,
                                   sampleOffset: Int32,
                                   stream: Int16,
                                   muted: Bool = false) throws {
        // ── Target: Pro Tools by kernel PID (most reliable across macOS versions) ──
        guard let ptApp = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.avid.ProTools").first
        else { throw SpotError.proToolsNotRunning }
        var pid = ptApp.processIdentifier
        guard let targetDesc = NSAppleEventDescriptor(
            descriptorType: DescType(typeKernelProcessID),
            bytes: &pid,
            length: MemoryLayout<pid_t>.size
        ) else { throw SpotError.badTargetDescriptor }

        // ── Build the AppleEvent ──────────────────────────────────────────────
        let ae = NSAppleEventDescriptor(
            eventClass: aeCC("Sd2a"),   // Digidesign Audio Suite
            eventID:    aeCC("SRgn"),   // Spot Region
            targetDescriptor: targetDesc,
            returnID:   AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        // FILE — audio file as a typeFileURL descriptor
        ae.setParam(NSAppleEventDescriptor(fileURL: url), forKeyword: aeCC("FILE"))

        // Trak = -99 → spot to the currently selected track
        ae.setParam(ae16(-99),          forKeyword: aeCC("Trak"))
        // FFrm — frame format (PT parses then ignores)
        ae.setParam(ae16(1),            forKeyword: aeCC("FFrm"))
        // TkOf — track offset from selection
        ae.setParam(ae16(trackOffset),  forKeyword: aeCC("TkOf"))
        // SMSt — sample offset from PT edit cursor / selection start
        ae.setParam(ae32(sampleOffset), forKeyword: aeCC("SMSt"))
        // Strm — playlist/stream index within multichannel track
        ae.setParam(ae16(stream),       forKeyword: aeCC("Strm"))

        // ── Rgn record: Star, Stop, Name, [Mute] ─────────────────────────────
        let rgn = NSAppleEventDescriptor.record()
        rgn.setDescriptor(ae32(srcStart), forKeyword: aeCC("Star"))
        rgn.setDescriptor(ae32(srcStop),  forKeyword: aeCC("Stop"))
        if muted { rgn.setDescriptor(ae16(1), forKeyword: aeCC("Mute")) }

        // Pascal string: first byte is length, up to 255 macOSRoman chars, 256-byte buffer.
        var nameEncoded = name.data(using: .macOSRoman) ?? Data(name.utf8)
        if nameEncoded.count > 255 { nameEncoded = nameEncoded.prefix(255) }
        var pascal = Data([UInt8(nameEncoded.count)]) + nameEncoded
        pascal += Data(repeating: 0, count: max(0, 256 - pascal.count))
        let nameDesc = pascal.withUnsafeBytes {
            NSAppleEventDescriptor(descriptorType: DescType(typeChar),
                                   bytes: $0.baseAddress, length: pascal.count)
        } ?? NSAppleEventDescriptor(string: name)
        rgn.setDescriptor(nameDesc, forKeyword: aeCC("Name"))

        ae.setParam(rgn, forKeyword: aeCC("Rgn "))

        // ── Send — fire and forget (kAENoReply: returns immediately, PT queues internally) ──
        log.debug("Sending Sd2a/SRgn → PT Trak=-99 TkOf=\(trackOffset) SMSt=\(sampleOffset) Star=\(srcStart) Stop=\(srcStop)")
        var reply = AEDesc()
        let err = AESend(ae.aeDesc,
                         &reply,
                         AESendMode(kAENoReply),
                         AESendPriority(kAENormalPriority),
                         Int32(kAEDefaultTimeout), nil, nil)
        if err != noErr {
            log.error("AESend FAILED OSStatus=\(err)")
            throw SpotError.sendFailed(OSStatus(err))
        }
    }

    // MARK: - FourCharCode helpers

    /// Converts a 4-character ASCII string to a big-endian FourCharCode (OSType).
    private static func aeCC(_ s: String) -> FourCharCode {
        s.unicodeScalars.prefix(4).reduce(into: FourCharCode(0)) { acc, c in
            acc = (acc << 8) | FourCharCode(c.value)
        }
    }

    /// Wraps an Int16 in a typeSInt16 ('shor') AEDesc.
    private static func ae16(_ v: Int16) -> NSAppleEventDescriptor {
        var val = v
        return NSAppleEventDescriptor(
            descriptorType: aeCC("shor"),
            bytes: &val, length: 2
        ) ?? .null()
    }

    /// Wraps an Int32 in a typeSInt32 ('long') AEDesc.
    private static func ae32(_ v: Int32) -> NSAppleEventDescriptor {
        var val = v
        return NSAppleEventDescriptor(
            descriptorType: aeCC("long"),
            bytes: &val, length: 4
        ) ?? .null()
    }
}
