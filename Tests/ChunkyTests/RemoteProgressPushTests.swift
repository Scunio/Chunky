import Testing

/// Recognition of our CloudKit progress push. Payloads mirror CloudKit's wire format for a
/// record-zone notification (`ck.fet` with `sid`/`dbs`); simulators can't deliver silent
/// pushes (`simctl push` rejects them), so this is the check that runs in CI.
struct RemoteProgressPushTests {
    private func payload(subscriptionID: String) -> [AnyHashable: Any] {
        [
            "aps": ["content-available": 1],
            "ck": [
                "ce": 2,
                "cid": "iCloud.com.scunio.Chunky",
                "nid": "1A2B3C4D-0000-0000-0000-000000000001",
                "fet": ["dbs": 1, "sid": subscriptionID, "zid": "RemoteProgress", "zoo": "__defaultOwner__"]
            ]
        ]
    }

    @Test func recognisesOurSubscription() {
        #expect(RemoteProgressSync.isProgressPush(payload(subscriptionID: RemoteProgressSync.pushSubscriptionID)))
    }

    @Test func ignoresCoreDataMirroringPush() {
        #expect(!RemoteProgressSync.isProgressPush(payload(subscriptionID: "com.apple.coredata.cloudkit.private.subscription")))
    }

    @Test func ignoresNonCloudKitPayload() {
        #expect(!RemoteProgressSync.isProgressPush(["aps": ["content-available": 1]]))
    }
}
