#if DEBUG
import Darwin

enum OfflineContainmentPolicy {
    enum Outcome: Equatable {
        case denialCandidate(Int32)
        case stop(Int32?)
    }

    static func classify(_ result: Int32, error: Int32) -> Outcome {
        if result >= 0 { return .stop(nil) }
        if error == EPERM || error == EACCES { return .denialCandidate(error) }
        return .stop(error)
    }
}
#endif
