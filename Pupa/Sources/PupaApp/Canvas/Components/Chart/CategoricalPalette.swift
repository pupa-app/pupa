import SwiftUI

/// The app's categorical colour ramp — for colouring a set of unrelated things
/// (agents, chart series) where only "tell them apart" matters.
///
/// One list so the app's generated colours stay in family. Consumers index it
/// however suits them: charts walk it in draw order, `SlackAgentPalette` hashes
/// into it for a stable per-agent colour.
public enum CategoricalPalette {
    public static let colors: [Color] = [
        .blue, .green, .orange, .pink,
        .purple, .red, .teal, .indigo,
    ]
}
