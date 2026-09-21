import AppKit
import BrowsemiumCEF
import Foundation

// The Chromium edition's entry point. It is a plain `main.swift` rather than
// `@main` because two things have to happen before SwiftUI touches AppKit:
//
//  1. The CEF framework has to be loaded from the app bundle (CEF cannot be
//     linked directly on macOS).
//  2. A helper process — renderer, GPU, utility — has to be handed straight to
//     CEF, which exits with its own status. The same executable serves both
//     roles; CEF decides from the command line the browser process passes.

guard BrowsemiumCEFRuntime.loadFramework() else {
    FileHandle.standardError.write(Data("Browsemium Chromium could not load its Chromium framework.\n".utf8))
    exit(1)
}

let helperStatus = BrowsemiumCEFRuntime.executeProcess()
if helperStatus >= 0 {
    exit(helperStatus)
}

BrowsemiumChromiumApp.main()
