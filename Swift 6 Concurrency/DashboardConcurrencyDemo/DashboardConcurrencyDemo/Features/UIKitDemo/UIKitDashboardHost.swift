//
//  UIKitDashboardHost.swift
//  DashboardConcurrencyDemo/Features/UIKitDemo
//
//  Bridges UIKit’s `UIViewController` into SwiftUI’s tab interface — lets you compare `.task` vs stored `Task`.
//

import SwiftUI // `UIViewControllerRepresentable`, `UIViewControllerType`, and `Coordinator` patterns live here.
import UIKit // Imports `DashboardDemoViewController`’s module dependency for the representable factory methods.

/// SwiftUI wrapper that embeds the UIKit demo view controller — minimal glue, no extra state synchronization.
struct UIKitDashboardHost: UIViewControllerRepresentable { // Protocol connects UIKit VC lifecycle into SwiftUI trees.
    /// SwiftUI calls this once to create the underlying UIKit object graph owned by the representable struct.
    func makeUIViewController(context: Context) -> DashboardDemoViewController { // `Context` includes coordinators.
        DashboardDemoViewController() // Construct the demo VC — `@MainActor` factory aligns with representable rules.
    } // End `makeUIViewController` — no dependency injection here — demo keeps construction trivial.

    /// SwiftUI calls this on updates — we have no external inputs, so nothing to forward to UIKit here.
    func updateUIViewController(_ uiViewController: DashboardDemoViewController, context: Context) { // Required stub.
        // Intentionally empty — if you later add bindings, update labels here when SwiftUI state changes.
    } // End `updateUIViewController` — presence satisfies protocol requirements without extra moving parts.
} // End `UIKitDashboardHost` — referenced from `RootTabView` as its own tab for side-by-side pedagogy.
