@preconcurrency import AVFAudio
import AppKit
import AudioToolbox
import CoreAudioKit
import Darwin
import Foundation
import Synchronization
import WWCore

public struct MixerComponent: Sendable, Equatable, Identifiable {
    public let identity: AudioUnitComponentIdentity
    public let name: String
    public let manufacturer: String
    public let version: Int
    public var id: String { "\(identity.type):\(identity.subtype):\(identity.manufacturer)" }
}

public enum MixerAudioUnits {
    /// Discovery loads no unit, reads no media, and includes only installed audio/music effects.
    @MainActor public static func installedEffects() -> [MixerComponent] {
        [kAudioUnitType_Effect, kAudioUnitType_MusicEffect].flatMap { type in
            let description = AudioComponentDescription(componentType: type, componentSubType: 0,
                componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            return AVAudioUnitComponentManager.shared().components(matching: description).map { component in
                let d = component.audioComponentDescription
                return MixerComponent(identity: .init(type: d.componentType, subtype: d.componentSubType,
                    manufacturer: d.componentManufacturer), name: component.name,
                    manufacturer: component.manufacturerName, version: component.version)
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public struct MixerParameter: Sendable, Equatable {
    public let address: UInt64
    public let name: String
    public let identifier: String
    public let minimum: Float
    public let maximum: Float
    public let value: Float
    public let unitName: String?
    public let valueStrings: [String]?
    public let readable: Bool
    public let writable: Bool
    public let canRamp: Bool
}

public struct MixerUnitStatus: Sendable, Equatable {
    public let slot: AudioUnitSlotID
    public let loadedInProcess: Bool
    public let bypassed: Bool
    public let channels: Int
    public let latencyFrames: Int
    public let tailFrames: Int
    public let parameterRevision: UInt64
}

/// Only the supported editor request crosses to the main actor. The processor owns unit lifetime,
/// state and rendering. Native editor parameter writes use the Audio Unit's own thread-safe API.
public final class MixerUnitEditor: @unchecked Sendable {
    private let unit: AUAudioUnit
    init(_ unit: AUAudioUnit) { self.unit = unit }

    @MainActor public func requestViewController() async -> NSViewController? {
        await withCheckedContinuation { continuation in
            unit.requestViewController { controller in continuation.resume(returning: controller) }
        }
    }
}

/// Input storage is prepared only by the serial processor; the synchronous pull callback borrows it.
/// No actor calls, locks, file access, tasks, or allocation occur inside the pull callback.
private final class UnitPullInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var frames = 0
    var sampleTime: Double = 0

    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func pull(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
              _ timestamp: UnsafePointer<AudioTimeStamp>, _ count: AVAudioFrameCount,
              _ bus: Int, _ output: UnsafeMutablePointer<AudioBufferList>?) -> AUAudioUnitStatus {
        guard bus == 0, Int(count) == frames, timestamp.pointee.mSampleTime == sampleTime,
              let output else { return kAudioUnitErr_InvalidParameter }
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(output)
        guard destination.count == source.count else { return kAudioUnitErr_FormatNotSupported }
        let bytes = frames * MemoryLayout<Float>.stride
        for channel in 0..<source.count {
            guard let input = source[channel].mData else { return kAudioUnitErr_InvalidParameter }
            if let data = destination[channel].mData {
                guard destination[channel].mDataByteSize >= bytes else { return kAudioUnitErr_TooManyFramesToProcess }
                memcpy(data, input, bytes)
            } else {
                destination[channel].mData = input
            }
            destination[channel].mDataByteSize = UInt32(bytes)
        }
        return noErr
    }
}

private final class ParameterRevision: Sendable {
    let value = Atomic<UInt64>(0)
}

/// Framework objects are transferred once from async instantiation, then touched by one processor
/// actor, except vendor editors and the explicitly thread-safe parameter observation callback.
final class NativeAudioUnit: @unchecked Sendable {
    let slot: AudioUnitSlot
    let unit: AUAudioUnit
    let channels: Int
    let latencyFrames: Int
    let tailFrames: Int
    private let input: UnitPullInput
    private let output: AVAudioPCMBuffer
    private let outputPointers: [UnsafeMutablePointer<Float>]
    private let renderBlock: AURenderBlock
    private let pullBlock: AURenderPullInputBlock
    private let revision = ParameterRevision()
    private let includesTail: Bool
    private var observer: AUParameterObserverToken?
    private var sampleTime: Double = 0

    static func load(_ slot: AudioUnitSlot, channels: Int, policy: MixerRenderPolicy) async throws -> NativeAudioUnit {
        try Task.checkCancellation()
        guard slot.isValid else { throw MixerFailure.state(slot.id, "invalid portable slot") }
        var d = AudioComponentDescription(componentType: slot.component.type, componentSubType: slot.component.subtype,
            componentManufacturer: slot.component.manufacturer, componentFlags: 0, componentFlagsMask: 0)
        guard AudioComponentFindNext(nil, &d) != nil else { throw MixerFailure.missingUnit(slot.id) }
        let request = UnitLoadRequest()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
            request.complete(.failure(MixerFailure.loading(slot.id, "instantiation exceeded 30 seconds")))
        }
        defer { timeout.cancel() }
        let box = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                AUAudioUnit.instantiate(with: d, options: [.loadOutOfProcess]) { unit, error in
                    if let unit { request.complete(.success(LoadedUnit(unit))) }
                    else { request.complete(.failure(MixerFailure.loading(slot.id,
                        error?.localizedDescription ?? "instantiation returned no Audio Unit"))) }
                }
            }
        } onCancel: {
            request.complete(.failure(CancellationError()))
        }
        try Task.checkCancellation()
        return try NativeAudioUnit(slot: slot, unit: box.unit, channels: channels, policy: policy)
    }

    init(slot: AudioUnitSlot, unit: AUAudioUnit, channels: Int, policy: MixerRenderPolicy) throws {
        self.slot = slot
        self.unit = unit
        self.channels = channels
        includesTail = policy.tail == .includeReported
        guard (1...2).contains(channels), unit.inputBusses.count == 1, unit.outputBusses.count == 1,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(MixerRecipe.sampleRate),
                channels: AVAudioChannelCount(channels)),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: format,
                frameCapacity: AVAudioFrameCount(MixerRecipe.blockFrames)),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format,
                frameCapacity: AVAudioFrameCount(MixerRecipe.blockFrames)),
              let outputData = outputBuffer.floatChannelData else {
            throw MixerFailure.format(slot.id)
        }
        if let data = slot.documentState {
            guard let state = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                    as? [String: Any] else { throw MixerFailure.state(slot.id, "not a property-list dictionary") }
            unit.fullStateForDocument = state
            guard let recalled = unit.fullStateForDocument, NSDictionary(dictionary: recalled).isEqual(to: state) else {
                throw MixerFailure.state(slot.id, "the unit did not recall the complete document state")
            }
        }
        let pullInput = UnitPullInput(buffer: inputBuffer)
        // AUv2 bridges use the legacy input callback rather than the render block's pull argument.
        if let bridge = unit as? AUAudioUnitV2Bridge {
            var callback = AURenderCallbackStruct(inputProc: { context, flags, time, bus, count, data in
                return Unmanaged<UnitPullInput>.fromOpaque(context).takeUnretainedValue()
                    .pull(flags, time, count, Int(bus), data)
            }, inputProcRefCon: Unmanaged.passUnretained(pullInput).toOpaque())
            let status = AudioUnitSetProperty(bridge.audioUnit, kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            guard status == noErr else { throw MixerFailure.render(slot.id, status) }
        }
        do {
            try unit.inputBusses[0].setFormat(format)
            try unit.outputBusses[0].setFormat(format)
            unit.inputBusses[0].isEnabled = true
            unit.outputBusses[0].isEnabled = true
        } catch { throw MixerFailure.format(slot.id) }
        unit.maximumFramesToRender = AVAudioFrameCount(MixerRecipe.blockFrames)
        do { try unit.allocateRenderResources() }
        catch { throw MixerFailure.loading(slot.id, error.localizedDescription) }
        guard unit.inputBusses[0].format == format, unit.outputBusses[0].format == format else {
            unit.deallocateRenderResources()
            throw MixerFailure.format(slot.id)
        }
        unit.reset()
        // Host bypass is an explicit zero-latency dry path; no claim about a vendor's bypass behavior.
        let latency = slot.bypassed ? 0 : unit.latency * Double(MixerRecipe.sampleRate)
        guard latency.isFinite, latency >= 0, latency <= Double(policy.maximumLatencyFrames),
              abs(latency - latency.rounded()) < 0.000_1 else {
            unit.deallocateRenderResources()
            throw MixerFailure.latencyLimit
        }
        let tail = slot.bypassed ? 0 : unit.tailTime * Double(MixerRecipe.sampleRate)
        guard tail.isFinite, tail >= 0,
              policy.tail == .truncate || tail <= Double(policy.maximumTailFrames) else {
            unit.deallocateRenderResources()
            throw MixerFailure.tailLimit
        }
        latencyFrames = Int(latency.rounded())
        tailFrames = Int(min(ceil(tail), Double(policy.maximumTailFrames)))
        input = pullInput
        output = outputBuffer
        outputPointers = (0..<channels).map { outputData[$0] }
        renderBlock = unit.renderBlock
        let input = self.input
        pullBlock = { flags, time, frames, bus, data in input.pull(flags, time, frames, bus, data) }
        let revision = self.revision
        observer = unit.parameterTree?.token(byAddingParameterObserver: { _, _ in
            revision.value.wrappingAdd(1, ordering: .relaxed)
        })
    }

    deinit {
        if let observer { unit.parameterTree?.removeParameterObserver(observer) }
        unit.deallocateRenderResources()
    }

    var status: MixerUnitStatus {
        .init(slot: slot.id, loadedInProcess: unit.isLoadedInProcess, bypassed: slot.bypassed,
            channels: channels, latencyFrames: latencyFrames, tailFrames: tailFrames,
            parameterRevision: revision.value.load(ordering: .relaxed))
    }

    func parameters() throws -> [MixerParameter] {
        try (unit.parameterTree?.allParameters ?? []).map {
            guard $0.minValue.isFinite, $0.maxValue.isFinite, $0.value.isFinite, $0.minValue <= $0.maxValue else {
                throw MixerFailure.parameter(slot.id)
            }
            return MixerParameter(address: $0.address, name: $0.displayName, identifier: $0.identifier,
                minimum: $0.minValue, maximum: $0.maxValue, value: $0.value, unitName: $0.unitName,
                valueStrings: $0.valueStrings, readable: $0.flags.contains(.flag_IsReadable),
                writable: $0.flags.contains(.flag_IsWritable), canRamp: $0.flags.contains(.flag_CanRamp))
        }
    }

    func setParameter(address: UInt64, value: Float) throws {
        guard value.isFinite, let parameter = unit.parameterTree?.parameter(withAddress: address),
              parameter.flags.contains(.flag_IsWritable), value >= parameter.minValue, value <= parameter.maxValue else {
            throw MixerFailure.parameter(slot.id)
        }
        parameter.setValue(value, originator: nil)
    }

    func capture() throws -> AudioUnitSlot {
        guard let state = unit.fullStateForDocument else {
            throw MixerFailure.state(slot.id, "the unit returned no document state")
        }
        let data: Data
        do { data = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0) }
        catch { throw MixerFailure.state(slot.id, error.localizedDescription) }
        var result = slot
        result.documentState = data
        guard result.isValid else { throw MixerFailure.state(slot.id, "invalid, nonfinite, or oversized vendor state") }
        return result
    }

    func render(_ samples: [[Float]]) throws -> [[Float]] {
        let frames = samples.first?.count ?? 0
        guard samples.count == channels, frames > 0, frames <= MixerRecipe.blockFrames,
              samples.allSatisfy({ $0.count == frames }) else { throw MixerFailure.incompletePCM }
        if slot.bypassed { return samples }
        guard abs(unit.latency * Double(MixerRecipe.sampleRate) - Double(latencyFrames)) < 0.000_1 else {
            throw MixerFailure.changedLatency(slot.id)
        }
        if includesTail {
            let tail = unit.tailTime * Double(MixerRecipe.sampleRate)
            guard tail.isFinite, tail >= 0, ceil(tail) == Double(tailFrames) else {
                throw MixerFailure.changedTail(slot.id)
            }
        }
        guard let inputChannels = input.buffer.floatChannelData else { throw MixerFailure.incompletePCM }
        input.buffer.frameLength = AVAudioFrameCount(frames)
        input.frames = frames
        input.sampleTime = sampleTime
        output.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels {
            samples[channel].withUnsafeBufferPointer {
                if let base = $0.baseAddress { inputChannels[channel].update(from: base, count: frames) }
            }
        }
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mFlags = .sampleTimeValid
        var status: AUAudioUnitStatus = noErr
        var renderedSilence = false
        for attempt in 0..<4 {
            let buffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
            for channel in 0..<channels {
                buffers[channel].mData = UnsafeMutableRawPointer(outputPointers[channel])
                buffers[channel].mNumberChannels = 1
                buffers[channel].mDataByteSize = UInt32(frames * MemoryLayout<Float>.stride)
                outputPointers[channel].update(repeating: .nan, count: frames)
            }
            var flags = AudioUnitRenderActionFlags()
            status = renderBlock(&flags, &timestamp, AVAudioFrameCount(frames), 0,
                output.mutableAudioBufferList, pullBlock)
            if status == noErr {
                renderedSilence = flags.contains(.unitRenderAction_OutputIsSilence)
                break
            }
            guard status == kAudioUnitErr_CannotDoInCurrentContext else { throw MixerFailure.render(slot.id, status) }
            if attempt == 3 { throw MixerFailure.noProgress }
        }
        guard status == noErr else { throw MixerFailure.render(slot.id, status) }
        sampleTime += Double(frames)
        let buffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        guard buffers.count == channels else { throw MixerFailure.incompletePCM }
        return try buffers.map { buffer in
            guard buffer.mNumberChannels == 1, buffer.mDataByteSize >= frames * MemoryLayout<Float>.stride,
                  let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                throw MixerFailure.incompletePCM
            }
            let result = renderedSilence ? [Float](repeating: 0, count: frames)
                : Array(UnsafeBufferPointer(start: data, count: frames))
            guard result.allSatisfy(\.isFinite) else { throw MixerFailure.nonfinitePCM }
            return result
        }
    }
}

private final class LoadedUnit: @unchecked Sendable {
    let unit: AUAudioUnit
    init(_ unit: AUAudioUnit) { self.unit = unit }
}

private final class UnitLoadRequest: Sendable {
    private struct State {
        var continuation: CheckedContinuation<LoadedUnit, any Error>?
        var result: Result<LoadedUnit, any Error>?
    }
    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<LoadedUnit, any Error>) {
        let result: Result<LoadedUnit, any Error>? = state.withLock { state in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }

    func complete(_ result: Result<LoadedUnit, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<LoadedUnit, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
