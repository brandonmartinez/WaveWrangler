import CoreML
import Foundation

let configuration = MLModelConfiguration()
configuration.computeUnits = .cpuAndNeuralEngine
let plan = try await MLComputePlan.load(
    contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), configuration: configuration)
var counts: [String: Int] = [:]
func record(_ usage: MLComputePlan.DeviceUsage?) {
    let device: String
    switch usage?.preferred {
    case .cpu: device = "CPU"
    case .gpu: device = "GPU"
    case .neuralEngine: device = "Neural Engine"
    case nil: device = "Unknown"
    @unknown default: device = "Unknown device"
    }
    counts[device, default: 0] += 1
}
func inspect(_ block: MLModelStructure.Program.Block) {
    for operation in block.operations {
        record(plan.deviceUsage(for: operation))
        for nested in operation.blocks { inspect(nested) }
    }
}
switch plan.modelStructure {
case .program(let program):
    for function in program.functions.values { inspect(function.block) }
case .neuralNetwork(let network):
    for layer in network.layers { record(plan.deviceUsage(for: layer)) }
default:
    throw NSError(domain: "Unsupported model structure", code: 1)
}
let data = try JSONSerialization.data(withJSONObject: [
    "computeUnits": "cpuAndNeuralEngine",
    "anticipatedPreferredOperations": counts,
    "qualification": "Compute plan, not a runtime execution trace or all-ANE proof"
], options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
