/// The kinds of Setup confirmation, and whether each is destruction the user chose (⌫ or a menu command).
/// Chosen destruction confirms with Return and has no destructive style (commands-keyboard K05, sources
/// A13; on macOS a destructive button can't keep Return, #114). Unchosen destruction keeps the destructive
/// style and no default button. Also compiled into the unhosted WaveWranglerTests target.
enum SetupConfirmationKind: CaseIterable, Sendable {
    case removeSources
    case deleteSpeaker
    case deleteGroup
    case cancelDownload

    var isChosenDestruction: Bool {
        switch self {
        case .removeSources, .deleteSpeaker, .deleteGroup: true
        case .cancelDownload: false
        }
    }
}
