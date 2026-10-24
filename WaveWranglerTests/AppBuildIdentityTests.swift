import Testing

@Suite("Visible app build identity")
struct AppBuildIdentityTests {
    @Test func versionAndBuildComeFromMetadataWithoutChangingContext() {
        let identity = AppBuildIdentity(version: "0.1.0", buildNumber: "20261023033001123")
        #expect(identity.label == "WaveWrangler 0.1.0 (build 20261023033001123)")
        #expect(identity.subtitle(context: "My Show") == "My Show | \(identity.label)")
        #expect(identity.subtitle() == identity.label)
        #expect(identity.subtitle(context: "") == identity.label)
    }

    @Test func missingMetadataNeverPretendsToBeAKnownBuild() {
        let missing = AppBuildIdentity(version: " \n", buildNumber: nil)
        #expect(missing.version == nil && missing.buildNumber == nil)
        #expect(missing.label == "WaveWrangler version unavailable (build unavailable)")
    }
}
