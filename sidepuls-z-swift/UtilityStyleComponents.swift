import SwiftUI

struct UtilityStyleOption: Identifiable {
    let id: String
    let title: String
    let style: Binding<StateLightStyle>

    init(_ title: String, style: Binding<StateLightStyle>) {
        self.id = title
        self.title = title
        self.style = style
    }
}

struct UtilityStyleSelector: View {
    let options: [UtilityStyleOption]
    let preview: (StateLightStyle) -> Void

    @State private var selectedTitle: String?

    init(
        options: [UtilityStyleOption],
        preview: @escaping (StateLightStyle) -> Void
    ) {
        self.options = options
        self.preview = preview
        _selectedTitle = State(initialValue: options.first?.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if options.isEmpty {
                Text("No styles available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(options) { option in
                        let style = option.style.wrappedValue
                        let selected = option.title == selectedOption?.title
                        let accent = Color(hex: style.colorHex)

                        Button {
                            selectedTitle = option.title
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    UtilityStyleSwatch(style: style)
                                        .frame(width: 26, height: 16)
                                    Spacer(minLength: 0)
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(accent)
                                    }
                                }

                                Text(option.title)
                                    .font(.caption.weight(selected ? .semibold : .medium))
                                    .foregroundStyle(selected ? accent : .primary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)

                                Text(style.motion.title)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
                            .padding(10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(
                            UtilityStyleInteractiveButtonStyle(
                                accent: accent,
                                selected: selected
                            )
                        )
                        .accessibilityLabel("\(option.title), \(style.motion.title)")
                        .accessibilityValue(selected ? "Selected" : "Not selected")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }

                if let selectedOption {
                    UtilityStyleEditor(
                        title: selectedOption.title,
                        style: selectedOption.style,
                        preview: { preview(selectedOption.style.wrappedValue) }
                    )
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: selectedTitle)
    }

    private var selectedOption: UtilityStyleOption? {
        options.first(where: { $0.title == selectedTitle }) ?? options.first
    }
}

struct UtilityStyleEditor: View {
    let title: String
    @Binding var style: StateLightStyle
    let preview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 9) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(styleSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                UtilityStyleSwatch(style: style)
                    .frame(width: 30, height: 18)

                Button {
                    preview()
                } label: {
                    Label("Preview", systemImage: "play.fill")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(
                    UtilityStyleInteractiveButtonStyle(
                        accent: Color(hex: style.colorHex),
                        selected: false
                    )
                )
                .accessibilityLabel("Preview \(title) style on SidePulse")
            }

            Picker("Color behavior", selection: $style.colorMode) {
                ForEach(LightColorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .accessibilityLabel("\(title) color behavior")

            if style.colorMode != .rainbow {
                ColorPicker(
                    style.colorMode == .single ? "Color" : "First color",
                    selection: Binding(
                        get: { Color(hex: style.colorHex) },
                        set: { style.colorHex = $0.hexString }
                    )
                )
                .controlSize(.small)

                if style.colorMode != .single {
                    ColorPicker(
                        "Second color",
                        selection: Binding(
                            get: { Color(hex: style.secondaryColorHex) },
                            set: { style.secondaryColorHex = $0.hexString }
                        )
                    )
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    ForEach(Array(previewColors.enumerated()), id: \.offset) { _, color in
                        Circle()
                            .fill(color)
                            .frame(width: 14, height: 14)
                    }
                    Text("Spectrum generated automatically")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Rainbow spectrum generated automatically")
            }

            Picker("Motion", selection: $style.motion) {
                ForEach(LightMotion.allCases) { motion in
                    Text(motion.title).tag(motion)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .accessibilityLabel("\(title) motion")

            HStack(spacing: 9) {
                Text("Intensity")
                    .font(.caption)
                Slider(value: $style.intensity, in: 0...1, step: 0.01)
                    .accessibilityLabel("\(title) intensity")
                Text("\(Int((style.intensity * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }

            if style.motion.isAnimated || style.colorMode == .rotatingColorway {
                HStack(spacing: 9) {
                    Text("Cycle")
                        .font(.caption)
                    Slider(value: $style.cycleSeconds, in: 0.2...12, step: 0.1)
                        .accessibilityLabel("\(title) cycle speed")
                    Text(style.cycleSeconds.formatted(.number.precision(.fractionLength(0...1))))
                        .font(.caption.monospacedDigit())
                        .frame(width: 38, alignment: .trailing)
                    Text("s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.75)
        }
    }

    private var styleSummary: String {
        switch style.colorMode {
        case .single:
            style.motion.title
        case .colorway, .rainbow, .rotatingColorway:
            "\(style.colorMode.title) · \(style.motion.title)"
        }
    }

    private var previewColors: [Color] {
        switch style.colorMode {
        case .single:
            [Color(hex: style.colorHex), Color(hex: style.colorHex)]
        case .colorway:
            [Color(hex: style.colorHex), Color(hex: style.secondaryColorHex)]
        case .rainbow:
            [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]
        case .rotatingColorway:
            [Color(hex: style.colorHex), Color(hex: style.secondaryColorHex), Color(hex: style.colorHex)]
        }
    }
}

private struct UtilityStyleSwatch: View {
    let style: StateLightStyle

    var body: some View {
        swatch
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.32), lineWidth: 0.6)
            }
            .shadow(color: swatchAccent.opacity(0.24), radius: 3, y: 1)
    }

    @ViewBuilder
    private var swatch: some View {
        switch style.colorMode {
        case .single:
            Color(hex: style.colorHex)
        case .colorway, .rotatingColorway:
            LinearGradient(
                colors: [Color(hex: style.colorHex), Color(hex: style.secondaryColorHex)],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .rainbow:
            AngularGradient(
                colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink],
                center: .center
            )
        }
    }

    private var swatchAccent: Color {
        Color(hex: style.colorHex)
    }
}

private struct UtilityStyleInteractiveButtonStyle: ButtonStyle {
    let accent: Color
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        UtilityStyleInteractiveButton(
            configuration: configuration,
            accent: accent,
            selected: selected
        )
    }
}

private struct UtilityStyleInteractiveButton: View {
    let configuration: ButtonStyle.Configuration
    let accent: Color
    let selected: Bool

    @State private var isHovered = false

    var body: some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(borderColor, lineWidth: selected || isHovered ? 1 : 0.75)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
        if configuration.isPressed {
            return accent.opacity(0.24)
        }
        if selected {
            return accent.opacity(0.13)
        }
        if isHovered {
            return Color.primary.opacity(0.07)
        }
        return Color.primary.opacity(0.035)
    }

    private var borderColor: Color {
        if selected {
            return accent.opacity(0.72)
        }
        if isHovered {
            return Color.primary.opacity(0.28)
        }
        return Color.primary.opacity(0.12)
    }
}
