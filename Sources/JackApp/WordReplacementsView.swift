import SwiftUI

struct WordReplacementsView: View {
    @Binding var replacements: [WordReplacement]
    @State private var newOriginal = ""
    @State private var newReplacement = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Word Replacements")
                .font(.headline)

            Text("Automatically replace words in transcriptions. Matching is case-insensitive and whole-word only.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Add form
            HStack(spacing: 8) {
                TextField("Original", text: $newOriginal)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 100)

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)

                TextField("Replacement", text: $newReplacement)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 100)

                Button {
                    addReplacement()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(newOriginal.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.plain)
            }

            if replacements.isEmpty {
                Text("No replacements configured.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                List {
                    ForEach(replacements) { replacement in
                        HStack {
                            Text(replacement.original)
                                .font(.body.weight(.medium))
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(replacement.replacement)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    .onDelete(perform: deleteReplacements)
                }
                .listStyle(.inset)
                .frame(minHeight: 100, maxHeight: 300)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func addReplacement() {
        let original = newOriginal.trimmingCharacters(in: .whitespaces)
        guard !original.isEmpty else { return }
        let replacement = newReplacement.trimmingCharacters(in: .whitespaces)
        replacements.append(WordReplacement(original: original, replacement: replacement))
        newOriginal = ""
        newReplacement = ""
    }

    private func deleteReplacements(at offsets: IndexSet) {
        replacements.remove(atOffsets: offsets)
    }
}
