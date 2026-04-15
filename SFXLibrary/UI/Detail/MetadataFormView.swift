import SwiftUI

struct MetadataFormView: View {
    let file: AudioFile
    @Environment(AppEnvironment.self) private var env

    @State private var description:     String = ""
    @State private var originator:      String = ""
    @State private var originationDate: String = ""
    @State private var scene:           String = ""
    @State private var take:            String = ""
    @State private var tapeName:        String = ""
    @State private var ixmlNote:        String = ""
    @State private var ucsCategory:     String = ""
    @State private var ucsSubCategory:  String = ""
    @State private var notes:           String = ""
    @State private var stars:           Int    = 0

    var body: some View {
        let editable = env.metadataEditingEnabled
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
            field("Description",  value: description,     binding: $description,     editable: editable)
            field("Originator",   value: originator,      binding: $originator,      editable: editable)
            field("Date",         value: originationDate, binding: $originationDate,  editable: editable, mono: true, maxWidth: 120)
            field("Scene",        value: scene,           binding: $scene,           editable: editable)
            field("Take",         value: take,            binding: $take,            editable: editable, maxWidth: 80)
            field("Tape",         value: tapeName,        binding: $tapeName,        editable: editable)
            field("UCS Cat",      value: ucsCategory,     binding: $ucsCategory,     editable: editable)
            field("UCS Sub",      value: ucsSubCategory,  binding: $ucsSubCategory,  editable: editable)
            multilineField("iXML Note", value: ixmlNote,  binding: $ixmlNote,        editable: editable, height: 36)
            GridRow {
                fieldLabel("Rating")
                StarRatingView(rating: editable ? $stars : .constant(stars), interactive: editable)
            }
            multilineField("Notes", value: notes,         binding: $notes,           editable: editable, height: 44)
        }
        .onAppear { populate() }
        .onChange(of: file.id) { _ in populate() }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func field(_ label: String, value: String, binding: Binding<String>,
                       editable: Bool, mono: Bool = false, maxWidth: CGFloat? = nil) -> some View {
        GridRow {
            fieldLabel(label)
            if editable {
                TextField("", text: binding)
                    .textFieldStyle(.roundedBorder)
                    .font(mono ? .system(size: 13, design: .monospaced) : .system(size: 13))
                    .frame(maxWidth: maxWidth)
                if maxWidth != nil { Spacer() }
            } else {
                Text(value.isEmpty ? "—" : value)
                    .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12))
                    .foregroundColor(value.isEmpty ? .secondary.opacity(0.5) : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func multilineField(_ label: String, value: String, binding: Binding<String>,
                                editable: Bool, height: CGFloat) -> some View {
        GridRow {
            fieldLabel(label)
            if editable {
                TextEditor(text: binding)
                    .font(.system(size: 13))
                    .frame(height: height)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            } else {
                Text(value.isEmpty ? "—" : value)
                    .font(.system(size: 12))
                    .foregroundColor(value.isEmpty ? .secondary.opacity(0.5) : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
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
}
