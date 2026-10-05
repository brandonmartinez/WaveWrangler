/// Library window and shallow sidebar (shows, collections, recent and unavailable entries).
///
/// Owner: library UI. Canonical library data is `WWCore.LibraryModel`, encoded by
/// `JSONEnvelopeCoder<LibraryModel>.library` (`.wwlibrary`); the derived index is rebuildable and lives
/// outside canonical data. Reserved namespace until the library UI lands.
enum LibraryArea {}
