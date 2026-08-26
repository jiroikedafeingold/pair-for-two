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
    let primary: Color
    let deep: Color

    /// The color's name for display.
    var localizedName: LocalizedStringKey { LocalizedStringKey(displayName) }
}

let playerThemes: [PlayerTheme] = [
    .init(id: "crimson",   displayName: "Crimson",
          primary: Color(red: 1.00, green: 0.18, blue: 0.28),
          deep:    Color(red: 0.78, green: 0.06, blue: 0.14)),
    .init(id: "coral",     displayName: "Coral",
          primary: Color(red: 1.00, green: 0.50, blue: 0.30),
          deep:    Color(red: 0.82, green: 0.30, blue: 0.10)),
    .init(id: "tangerine", displayName: "Tangerine",
          primary: Color(red: 1.00, green: 0.62, blue: 0.10),
          deep:    Color(red: 0.85, green: 0.40, blue: 0.04)),
    .init(id: "gold",      displayName: "Gold",
          primary: Color(red: 1.00, green: 0.85, blue: 0.15),
          deep:    Color(red: 0.78, green: 0.58, blue: 0.02)),
    .init(id: "lime",      displayName: "Lime",
          primary: Color(red: 0.55, green: 0.95, blue: 0.18),
          deep:    Color(red: 0.30, green: 0.65, blue: 0.08)),
    .init(id: "mint",      displayName: "Mint",
          primary: Color(red: 0.16, green: 0.92, blue: 0.50),
          deep:    Color(red: 0.05, green: 0.62, blue: 0.30)),
    .init(id: "teal",      displayName: "Teal",
          primary: Color(red: 0.10, green: 0.88, blue: 0.85),
          deep:    Color(red: 0.02, green: 0.55, blue: 0.62)),
    .init(id: "sky",       displayName: "Sky",
          primary: Color(red: 0.18, green: 0.66, blue: 1.00),
          deep:    Color(red: 0.06, green: 0.36, blue: 0.85)),
    .init(id: "indigo",    displayName: "Indigo",
          primary: Color(red: 0.40, green: 0.36, blue: 1.00),
          deep:    Color(red: 0.20, green: 0.16, blue: 0.80)),
    .init(id: "plum",      displayName: "Plum",
          primary: Color(red: 0.78, green: 0.28, blue: 1.00),
          deep:    Color(red: 0.55, green: 0.10, blue: 0.80)),
    .init(id: "magenta",   displayName: "Magenta",
          primary: Color(red: 1.00, green: 0.22, blue: 0.82),
          deep:    Color(red: 0.78, green: 0.06, blue: 0.58)),
    .init(id: "rose",      displayName: "Rose",
          primary: Color(red: 1.00, green: 0.45, blue: 0.68),
          deep:    Color(red: 0.82, green: 0.20, blue: 0.45)),
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

extension View {
    /// Flash a subtle gold halo once each time `trigger` changes.
    func attentionGlow(trigger: Int) -> some View { modifier(AttentionGlow(trigger: trigger)) }
}
