import SwiftUI

/// Settings ▸ Account ▸ Acknowledgements. Pushed with a closure
/// `NavigationLink` from the Support section, like the other hub children, so
/// it stays out of `SettingsCategory` and the tour's deep-link map.
///
/// This screen is how attribution reaches a *binary*: the DMG carries only
/// `Pupa.app`, and the App Store build carries nothing else at all, so
/// `NOTICE.md` in the repo satisfies neither channel on its own.
struct AcknowledgementsView: View {
    var body: some View {
        Form {
            Section {
                ForEach(Acknowledgement.all) { ack in
                    NavigationLink {
                        AcknowledgementDetailView(ack: ack)
                    } label: {
                        SettingsHubRow(icon: "shippingbox", title: ack.name,
                                       caption: "\(ack.licence) · \(ack.copyright)")
                    }
                }
            } footer: {
                Text("Pupa links these packages into its app. Each is used under "
                     + "its own licence, reproduced here in full.")
            }
        }
        .navigationTitle("Acknowledgements")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// One package's full notice. Selectable, so a licence-minded reader can copy
/// the text out rather than retype it.
private struct AcknowledgementDetailView: View {
    let ack: Acknowledgement

    var body: some View {
        Form {
            Section {
                LabeledContent("Licence", value: ack.licence)
                LabeledContent("Copyright", value: ack.copyright)
                Link(destination: ack.url) {
                    HStack {
                        Text("Project")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(ack.origin)
            }
            Section("Licence text") {
                Text(ack.licenceText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    // A `Form` row will otherwise truncate a block this tall.
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle(ack.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
