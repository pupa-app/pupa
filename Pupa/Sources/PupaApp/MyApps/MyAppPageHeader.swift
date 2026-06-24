import SwiftUI

/// Shared header for a MyApp's pages (Home / Agents / Memories / History) and
/// the orchestrator's. A small tinted eyebrow names the page so it's always
/// clear which one you're on; the line below carries the subject's icon + name.
/// Keeps every page visually consistent and self-labelling.
struct MyAppPageHeader: View {
    /// The page name shown in the eyebrow, e.g. "Home", "Memories".
    let page: String
    /// The subject's name on the title line (the MyApp or "Orchestrator").
    let name: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(page.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                Text(name)
                    .font(.title)
                    .fontWeight(.semibold)
                Spacer()
            }
        }
    }
}
