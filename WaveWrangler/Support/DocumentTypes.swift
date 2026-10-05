import WWPersistence

/// Uniform Type Identifiers declared in `Info.plist`. Unit tests check these stay in sync with the plist.
enum DocumentTypes {
    static let show = DocumentFormat.show.identifier
    static let library = DocumentFormat.library.identifier
}
