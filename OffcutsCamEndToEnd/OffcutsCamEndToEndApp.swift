//
// Created by Halle Winkler on Aug/18/22. Copyright © 2022. All rights reserved.
//

import SwiftUI

@main
struct OffcutsCamEndToEndApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(endToEndStreamProvider: EndToEndStreamProvider())
        }
    }
}
