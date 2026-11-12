import WWDecode

package enum SourceChannelOrder {
    package static func require(
        _ format: FormatInterpretation, legacyWavePCM: LegacyWavePCMChannelOrderEvidence?,
        m4aCodec: M4ACodecChannelOrderEvidence?
    ) throws {
        let declared = format.channelLayout.isDeclaredBySource
            && ((format.channelCount == 1 && format.channelLayout.channelLabels == [42])
                || (format.channelCount == 2 && format.channelLayout.channelLabels == [1, 2]))
        let legacy = format.channelLayout == .undeclared
            && legacyWavePCM?.channelCount == format.channelCount
        let m4a = format.channelLayout == .undeclared && format.container.kind == .m4a
            && [.aac, .appleLossless].contains(format.codec.kind)
            && m4aCodec?.channelCount == format.channelCount
        guard declared || legacy || m4a else {
            throw NativeSourcePreparationFailure.unsupportedChannelLayout
        }
    }
}
