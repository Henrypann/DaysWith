import Photos
import SwiftUI
import UIKit

@main
struct JinbaoPhotoFixtureApp: App {
    @StateObject private var fixture = PhotoFixture()

    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Jinbao acceptance photos").font(.title2.bold())
                    Text(fixture.fullMedia ? "Adds 2 photos, 1 video and 1 genuine Live Photo. Existing photos stay untouched." : "Adds two synthetic images. Existing photos stay untouched.")
                    Text(fixture.runID)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("fixtureRunID")
                    ForEach(1...(fixture.fullMedia ? 4 : 2), id: \.self) { index in
                        Image(uiImage: fixture.image(number: index))
                            .resizable()
                            .scaledToFit()
                            .accessibilityLabel("JINBAO QA \(index), run \(fixture.runID)")
                    }
                    Button(fixture.fullMedia ? "Add four synthetic media" : "Add two synthetic photos") {
                        Task { await fixture.addPhotos() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(fixture.busy || fixture.addedCount > 0)
                    .accessibilityIdentifier("fixtureAddPhoto")
                    Text(fixture.status)
                        .accessibilityIdentifier("fixtureStatus")
                    Text("Added: \(fixture.addedCount)")
                        .accessibilityIdentifier("fixtureSuccessCount")
                        .accessibilityValue(String(fixture.addedCount))
                    if let error = fixture.statusFileError {
                        Text(error)
                            .accessibilityIdentifier("fixtureStatusFileError")
                    }
                }
                .padding(24)
            }
            .task { await fixture.addAutomaticallyIfRequested() }
        }
    }
}
