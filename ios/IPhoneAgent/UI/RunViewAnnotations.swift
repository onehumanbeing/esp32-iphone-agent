// View annotations: what Siri sees when a person is looking at the app.
//
// A view carrying an app entity identifier tells Siri which recorded run a row or a screen is
// about, so a request can say "replay this one" instead of naming the run. `appEntityIdentifier`
// is available from iOS 18.4; the entity itself needs the Siri AI Developer Preview (see
// SiriToolIntents.swift), so the annotation is written only when that is compiled in, and reads
// as a plain view otherwise.

import AppIntents
import SwiftUI

/// Identifies a recorded run on screen. Set on a row of the Runs list.
extension View {
    @ViewBuilder
    func handsyRunAnnotation(_ runID: String) -> some View {
        #if HANDSY_SIRI_AI
        if #available(iOS 27.3, *), !runID.isEmpty {
            appEntityIdentifier(EntityIdentifier(for: HandsyRunEntity.self, identifier: runID))
        } else {
            self
        }
        #else
        self
        #endif
    }
}
