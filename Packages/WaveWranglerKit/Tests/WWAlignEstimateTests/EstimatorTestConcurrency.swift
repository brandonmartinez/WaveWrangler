import Foundation
import Testing

enum EstimatorTestConcurrency {
    static let defaultMaximum = 2
    static let hardMaximum = 4

    enum ConfigurationError: Error, Equatable {
        case invalidMaximum(String)
        case explicitGrantRequired(Int)
    }

    static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        maximumConcurrency: Int,
        operation: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        guard (1...hardMaximum).contains(maximumConcurrency) else {
            throw ConfigurationError.invalidMaximum(String(maximumConcurrency))
        }
        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var nextIndex = min(maximumConcurrency, inputs.count)
            for index in 0..<nextIndex {
                group.addTask { (index, try await operation(inputs[index])) }
            }

            var results: [(Int, Output)] = []
            while let (index, result) = try await group.next() {
                results.append((index, result))
                if nextIndex < inputs.count {
                    let index = nextIndex
                    nextIndex += 1
                    group.addTask { (index, try await operation(inputs[index])) }
                }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func maximumConcurrency(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Int {
        let requested: Int
        if let value = environment["WW_ESTIMATOR_MAX_CONCURRENCY"] {
            guard let parsed = Int(value), (1...hardMaximum).contains(parsed) else {
                throw ConfigurationError.invalidMaximum(value)
            }
            requested = parsed
        } else {
            requested = defaultMaximum
        }

        if requested > defaultMaximum,
           environment["WW_ESTIMATOR_CONCURRENCY_GRANT"] != String(requested) {
            throw ConfigurationError.explicitGrantRequired(requested)
        }
        return requested
    }
}

@Suite("Estimator test concurrency")
struct EstimatorTestConcurrencyTests {
    @Test func defaultsToTwoCasesWithoutProcessorCountExpansion() throws {
        #expect(try EstimatorTestConcurrency.maximumConcurrency(environment: [:]) == 2)
    }

    @Test func raisedWindowRequiresAnExactExplicitGrant() throws {
        #expect(throws: EstimatorTestConcurrency.ConfigurationError.explicitGrantRequired(4)) {
            try EstimatorTestConcurrency.maximumConcurrency(environment: ["WW_ESTIMATOR_MAX_CONCURRENCY": "4"])
        }
        #expect(try EstimatorTestConcurrency.maximumConcurrency(environment: [
            "WW_ESTIMATOR_MAX_CONCURRENCY": "4",
            "WW_ESTIMATOR_CONCURRENCY_GRANT": "4",
        ]) == 4)
    }

    @Test func rejectsValuesOutsideTheHardLimit() throws {
        #expect(throws: EstimatorTestConcurrency.ConfigurationError.invalidMaximum("5")) {
            try EstimatorTestConcurrency.maximumConcurrency(environment: ["WW_ESTIMATOR_MAX_CONCURRENCY": "5"])
        }
    }

    @Test func schedulerPreservesOrderAndNeverExceedsItsLimit() async throws {
        actor Activity {
            var active = 0
            var peak = 0

            func enter() {
                active += 1
                peak = max(peak, active)
            }

            func leave() { active -= 1 }
            func peakActivity() -> Int { peak }
        }

        let activity = Activity()
        let input = Array(0..<12)
        let output = try await EstimatorTestConcurrency.map(input, maximumConcurrency: 2) { value in
            await activity.enter()
            try await Task.sleep(nanoseconds: 1_000_000)
            await activity.leave()
            return value * 2
        }

        #expect(output == input.map { $0 * 2 })
        #expect(await activity.peakActivity() <= 2)
    }
}
