import SwiftUI

// MARK: - Felt palette (reused from Criboard)

extension Color {
    static let feltDark  = Color(red: 0.05, green: 0.13, blue: 0.10)
    static let feltMid   = Color(red: 0.09, green: 0.20, blue: 0.15)
    static let cribGold  = Color(red: 0.94, green: 0.79, blue: 0.45)

    /// Cream card face.
    static let cardFace  = Color(red: 0.98, green: 0.965, blue: 0.90)
    /// Near-black used for spades/clubs and dark ink.
    static let cardInk   = Color(red: 0.12, green: 0.12, blue: 0.14)
    /// Red used for hearts/diamonds.
    static let cardRed   = Color(red: 0.80, green: 0.12, blue: 0.16)
    /// Elegant face-down back.
    static let cardBack  = Color(red: 0.10, green: 0.22, blue: 0.45)
}

// MARK: - Player themes (reused from Criboard)

struct PlayerTheme: Identifiable, Hashable {
    let id: String
    /// English name, used as the localization key — see `localizedName`. The stored `id` is what
    /// persists, so translating a color never migrates anyone's saved choice.
    let displayName: String
    /// Base color as 0xRRGGBB. `primary` and `deep` are derived from it.
    let hex: UInt32

    /// The color's name for display.
    var localizedName: LocalizedStringKey { LocalizedStringKey(displayName) }

    var primary: Color { Self.color(hex, brightness: 1) }
    /// A darker shade of `primary`, for gradients.
    var deep: Color { Self.color(hex, brightness: 0.72) }
    /// A much brighter shade for the scoring rings: a two-point line in the deep palette vanished
    /// against the felt, where the names and scores have their cream rim to carry them.
    var ring: Color { Self.color(hex, brightness: 2) }

    /// `hex` with its HSB brightness scaled by `brightness` (capped at full brightness).
    private static func color(_ hex: UInt32, brightness factor: Double) -> Color {
        let ui = UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                         green: CGFloat((hex >> 8) & 0xFF) / 255,
                         blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: s, brightness: min(1, b * factor))
    }
}

/// Deep, jewel-toned palette built around Plum #4D1821 and Mint #1B7931.
let playerThemes: [PlayerTheme] = [
    .init(id: "crimson",   displayName: "Crimson",   hex: 0x8E1B24),
    .init(id: "coral",     displayName: "Coral",     hex: 0xA5442F),
    .init(id: "tangerine", displayName: "Tangerine", hex: 0xB5621A),
    .init(id: "gold",      displayName: "Gold",      hex: 0xB08A1E),
    .init(id: "lime",      displayName: "Lime",      hex: 0x5E7A1A),
    .init(id: "mint",      displayName: "Mint",      hex: 0x1B7931),
    .init(id: "teal",      displayName: "Teal",      hex: 0x156B66),
    .init(id: "sky",       displayName: "Sky",       hex: 0x1D5A8C),
    .init(id: "indigo",    displayName: "Indigo",    hex: 0x2E3480),
    .init(id: "plum",      displayName: "Plum",      hex: 0x4D1821),
    .init(id: "magenta",   displayName: "Magenta",   hex: 0x7A1D5C),
    .init(id: "rose",      displayName: "Rose",      hex: 0x9E3A5E),
]

/// Maps the model's integer `colorID` onto a theme (wraps around the palette).
func playerTheme(colorID: Int) -> PlayerTheme {
    let count = playerThemes.count
    return playerThemes[((colorID % count) + count) % count]
}

// MARK: - Card backs

/// The available face-down card-back designs. Stored as an Int in `@AppStorage("cardBackID")`.
enum CardBack: Int, CaseIterable, Identifiable {
    case royal = 0, celestial = 1, midnight = 2

    var id: Int { rawValue }

    /// Image-set name in the asset catalog.
    var assetName: String {
        switch self {
        case .royal:     return "CardBackRoyal"
        case .celestial: return "CardBackCelestial"
        case .midnight:  return "CardBackMidnight"
        }
    }

    var displayName: String {
        switch self {
        case .royal:     return String(localized: "Royal", comment: "Card back design name")
        case .celestial: return String(localized: "Celestial", comment: "Card back design name")
        case .midnight:  return String(localized: "Midnight", comment: "Card back design name")
        }
    }

    /// Resolve a stored id to a back, defaulting to Royal for anything unexpected.
    static func from(_ id: Int) -> CardBack { CardBack(rawValue: id) ?? .royal }
}

// MARK: - The felt

/// The table itself: baize rather than a flat wash of green.
///
/// Four layers over the old gradient, all static and cheap. **Mottling** — very low-resolution noise
/// stretched across the whole surface — gives the large-scale unevenness of a real cloth, the part
/// that reads as "table" rather than "background". **Grain** is fine tiled noise for the fibre.
/// A **vignette** lets the edges fall away so the middle feels lit. Both noise images are generated
/// once from a fixed seed, so the table looks the same every launch, and the stack is rasterised with
/// `drawingGroup()` — nothing here animates, and blending three layers per frame behind a game that
/// does would be waste.
struct FeltSurface: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [.feltMid, .feltDark], startPoint: .top, endPoint: .bottom)

            // Stretched, not tiled: at this scale a repeat would be obvious.
            Image(uiImage: Self.mottle)
                .resizable()
                .interpolation(.high)
                .blendMode(.overlay)
                .opacity(0.40)

            Image(uiImage: Self.grain)
                .resizable(resizingMode: .tile)
                .blendMode(.overlay)
                .opacity(0.16)

            RadialGradient(colors: [.clear, .black.opacity(0.26)],
                           center: .center, startRadius: 120, endRadius: 760)
        }
        .drawingGroup()
    }

    /// Mid-grey is neutral under an overlay blend, so noise around 128 lightens and darkens the felt
    /// without shifting its colour.
    private static func greyNoise(dimension: Int, spread: Double, seed: UInt64, scale: CGFloat) -> UIImage {
        var rng = SeededGenerator(seed: seed)
        var bytes = [UInt8](repeating: 128, count: dimension * dimension)
        for i in bytes.indices {
            let t = Double(rng.next() % 2_000) / 2_000.0 - 0.5        // -0.5…0.5
            bytes[i] = UInt8(max(0, min(255, 128 + t * spread * 255)))
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: dimension, height: dimension,
                                  bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: dimension,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return UIImage() }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }

    /// Broad unevenness: 44 patches across the screen, smoothed by the interpolation on the way up.
    /// Fewer than that and it reads as a stained cloth rather than nap.
    private static let mottle = greyNoise(dimension: 44, spread: 0.38, seed: 0x5EED_FE17, scale: 1)
    /// Fibre: at scale 3 one noise pixel lands on about one device pixel.
    private static let grain = greyNoise(dimension: 192, spread: 0.5, seed: 0xBA1_2E, scale: 3)
}

// MARK: - Naming the hardware

/// "iPad" or "phone", for copy that names the thing in the player's hands ("lay the iPad between
/// you"). The one place an idiom check is right: this is a sentence, not a layout decision — size
/// classes can't tell an iPad from a big iPhone in landscape, and they shouldn't have to.
///
/// Localized, because it lands inside translated sentences. "iPad" is a product name and stays as it
/// is in every language; "phone" is an ordinary noun and doesn't.
func deviceWord() -> String {
    UIDevice.current.userInterfaceIdiom == .pad
        ? String(localized: "iPad", comment: "The device in the player's hands, named in a sentence")
        : String(localized: "phone", comment: "The device in the player's hands, named in a sentence")
}

// MARK: - Attention glow

/// A brief attention glow: a soft gold halo that flashes once behind an icon whenever `trigger`
/// changes. Apply it to the icon itself so the halo stays centered on it. Subtle by design — it
/// fades in and back out a single time.
struct AttentionGlow: ViewModifier {
    let trigger: Int

    func body(content: Content) -> some View {
        content
            .background {
                Circle()
                    .fill(Color.cribGold)
                    .frame(width: 30, height: 30)
                    .blur(radius: 10)
                    .phaseAnimator([0.0, 1.0, 0.0], trigger: trigger) { halo, p in
                        halo.opacity(p * 0.5).scaleEffect(1.0 + p * 0.25)
                    } animation: { _ in .easeInOut(duration: 0.55) }
                    .allowsHitTesting(false)
            }
    }
}

// MARK: - Player-color legibility

/// A thin cream rim and soft light halo for text drawn in a player color, so the deep palette still
/// reads against the dark felt. Two tight shadows stack into an outline-like edge; the wide one lifts
/// the glyphs off the table.
struct PlayerColorRim: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: .cardFace.opacity(0.85), radius: 0.6)
            .shadow(color: .cardFace.opacity(0.85), radius: 0.6)
            .shadow(color: .cardFace.opacity(0.30), radius: 8)
    }
}

extension View {
    /// Outline and halo text drawn in a player color so it stands out on the felt.
    func playerColorRim() -> some View { modifier(PlayerColorRim()) }

    /// Flash a subtle gold halo once each time `trigger` changes.
    func attentionGlow(trigger: Int) -> some View { modifier(AttentionGlow(trigger: trigger)) }
}
