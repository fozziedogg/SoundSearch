import Foundation

extension AudioFile {

    /// Combined 64-bit BEXT TimeReference (samples since midnight).
    var timeReferenceSamples: Int64 {
        let lo = UInt64(UInt32(truncatingIfNeeded: bwfTimeRefLow))
        let hi = UInt64(UInt32(truncatingIfNeeded: bwfTimeRefHigh))
        return Int64(bitPattern: (hi << 32) | lo)
    }

    /// Display string for a metadata field, sourced from the stored columns.
    /// Returns nil when the field is empty or not persisted (rendered as "—").
    func displayValue(for key: BWFFieldKey) -> String? {
        func ne(_ s: String) -> String? { s.isEmpty ? nil : s }
        let sr = Double(sampleRate ?? 0)

        switch key {
        // iXML
        case .ixmlScene:       return ne(bwfScene)
        case .ixmlTake:        return ne(bwfTake)
        case .ixmlTape:        return ne(tapeName)
        case .ixmlNote:        return ne(ixmlNote)
        case .ixmlCircled:     return ne(ixmlCircled)
        case .ixmlTrackNames:  return ne(ixmlTrackNames)
        case .ixmlCategory:    return ne(ucsCategory)
        case .ixmlSubCategory: return ne(ucsSubCategory)
        case .ixmlProject:     return ne(ixmlProject)
        case .ixmlFileUID:     return ne(ixmlFileUID)
        case .ixmlUbits:       return ne(ixmlUbits)
        // iXML speed / timecode
        case .ixmlMasterSpeed:    return ne(ixmlMasterSpeed).map(bwfHumanizeFPS)
        case .ixmlTimecodeRate:   return ne(ixmlTimecodeRate).map(bwfHumanizeFPS)
        case .ixmlTimecodeFlag:   return ne(ixmlTimecodeFlag)
        case .ixmlFileSampleRate: return bwfHumanizeRate(ne(ixmlFileSampleRate))
        // iXML file family / location
        case .ixmlFamilyName:   return ne(ixmlFamilyName)
        case .ixmlLocationName: return ne(ixmlLocationName)
        // File attributes
        case .filePath:         return ne(fileURL)
        case .containingFolder:
            return ne(URL(fileURLWithPath: fileURL).deletingLastPathComponent().lastPathComponent)
        // bext
        case .bextDescription:   return ne(bwfDescription)
        case .bextOriginator:    return ne(bwfOriginator)
        case .bextOriginatorRef: return ne(bwfOriginatorRef)
        case .bextDate:          return ne(originationDate)
        case .bextTime:          return ne(bwfTime)
        case .bextTimeReference:
            let ref = timeReferenceSamples
            return ref > 0 ? bwfFormatTimecode(samples: ref, sampleRate: sr) : nil
        case .bextTimeReferenceSamples:
            let ref = timeReferenceSamples
            return ref > 0 ? String(ref) : nil
        case .bextVersion:       return bwfVersion.map { "v\($0)" }
        case .bextUMID:          return ne(bwfUMID)
        case .bextLoudness:      return lufs.map          { String(format: "%.1f LUFS", $0) }
        case .bextLoudnessRange: return loudnessRange.map { String(format: "%.1f LU",   $0) }
        case .bextMaxTruePeak:   return maxTruePeak.map   { String(format: "%.1f dBTP", $0) }
        case .bextMaxMomentary:  return maxMomentary.map  { String(format: "%.1f LUFS", $0) }
        case .bextMaxShortTerm:  return maxShortTerm.map  { String(format: "%.1f LUFS", $0) }
        case .bextCodingHistory: return ne(bwfCodingHistory)
        // RIFF INFO
        case .infoTitle:      return ne(infoTitle)
        case .infoArtist:     return ne(infoArtist)
        case .infoComment:    return ne(infoComment)
        case .infoCopyright:  return ne(infoCopyright)
        case .infoGenre:      return ne(infoGenre)
        case .infoCreated:    return ne(infoCreated)
        case .infoSoftware:   return ne(infoSoftware)
        case .infoEngineer:   return ne(infoEngineer)
        case .infoSource:     return ne(infoSource)
        case .infoProduct:    return ne(infoProduct)
        case .infoSubject:    return ne(infoSubject)
        case .infoTechnician: return ne(infoTechnician)
        // Not persisted → "—"
        case .ixmlWildTrack, .ixmlNoGood, .ixmlFalseStart, .ixmlSyncPoint,
             .ixmlDigitizerRate, .ixmlFamilyUID, .ixmlFileSetIndex, .ixmlTotalFiles,
             .ixmlLocationGPS:
            return nil
        }
    }
}
