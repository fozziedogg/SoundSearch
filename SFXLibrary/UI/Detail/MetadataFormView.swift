import SwiftUI

struct MetadataFormView: View {
    let file: AudioFile

    @State private var description:    String = ""
    @State private var originator:     String = ""
    @State private var originationDate: String = ""
    @State private var scene:          String = ""
    @State private var take:           String = ""
    @State private var tapeName:       String = ""
    @State private var ixmlNote:       String = ""
    @State private var ucsCategory:    String = ""
    @State private var ucsSubCategory: String = ""
    @State private var notes:          String = ""
    @State private var stars:          Int    = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("BWF / iXML")

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                row("Description") {
                    TextField("", text: $description).textFieldStyle(.roundedBorder)
                }
                row("Originator") {
                    TextField("", text: $originator).textFieldStyle(.roundedBorder)
                }
                row("Date") {
                    TextField("YYYY-MM-DD", text: $originationDate)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(maxWidth: 120)
                    Spacer()
                }
                row("Scene") {
                    TextField("", text: $scene).textFieldStyle(.roundedBorder)
                }
                row("Take") {
                    TextField("", text: $take)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                    Spacer()
                }
                row("Tape") {
                    TextField("", text: $tapeName).textFieldStyle(.roundedBorder)
                }

                Divider().gridCellUnsizedAxes(.horizontal)

                row("UCS Cat") {
                    TextField("", text: $ucsCategory).textFieldStyle(.roundedBorder)
                }
                row("UCS Sub") {
                    TextField("", text: $ucsSubCategory).textFieldStyle(.roundedBorder)
                }

                Divider().gridCellUnsizedAxes(.horizontal)

                row("iXML Note") {
                    TextEditor(text: $ixmlNote)
                        .font(.system(size: 13))
                        .frame(height: 50)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                }
                row("Rating") {
                    StarRatingView(rating: $stars, interactive: true)
                }
                row("Notes") {
                    TextEditor(text: $notes)
                        .font(.system(size: 13))
                        .frame(height: 60)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                }
            }
        }
        .onAppear { populate() }
        .onChange(of: file.id) { _ in populate() }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            fieldLabel(label)
            content()
        }
    }

    private func populate() {
        description     = file.bwfDescription
        originator      = file.bwfOriginator
        originationDate = file.originationDate
        scene           = file.bwfScene
        take            = file.bwfTake
        tapeName        = file.tapeName
        ixmlNote        = file.ixmlNote
        ucsCategory     = file.ucsCategory
        ucsSubCategory  = file.ucsSubCategory
        notes           = file.notes
        stars           = file.starRating
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(width: 72, alignment: .trailing)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .tracking(1)
    }
}
