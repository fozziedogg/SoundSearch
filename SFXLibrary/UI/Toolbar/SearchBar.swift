import SwiftUI

struct SearchBar: View {
    @Binding var text: String
    @Binding var scope: SearchScope

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 13))
                .padding(.leading, 8)

            // Scope picker — compact menu style
            Picker("", selection: $scope) {
                ForEach(SearchScope.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .foregroundColor(scope == .all ? .secondary : .accentColor)

            // Divider between scope and text field
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 4)

            TextField(scope == .all ? "Search…" : "Search \(scope.rawValue)…",
                      text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
            }
        }
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}
