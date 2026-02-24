//
//  KeygenAboutView.swift
//  anubis
//
//  Adapted from devPad's cracktro About screen.
//  Egyptian gold theme for Anubis.
//

import SwiftUI
import AVFoundation
import Combine

// MARK: - Keygen-Style About View (The "Cracktro" Edition)
struct KeygenAboutView: View {
    var onClose: (() -> Void)? = nil

    // Animation state
    @State private var animationTime: Double = 0
    @State private var showView = false
    @State private var isAnimating = true

    // Audio Manager
    @StateObject private var musicPlayer = AboutMusicPlayer.shared

    // App info
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private var copyrightYear: String {
        let year = Calendar.current.component(.year, from: Date())
        return "\(year)"
    }

    // Palette — Egyptian Gold
    private let goldBright = Color(red: 0.96, green: 0.78, blue: 0.33)   // #F5C854
    private let goldDeep = Color(red: 0.83, green: 0.66, blue: 0.29)     // #D4A84B
    private let amber = Color(red: 1.0, green: 0.58, blue: 0.0)          // #FF9500
    private let sandLight = Color(red: 0.96, green: 0.94, blue: 0.88)    // #F5F0E1
    private let desertPurple = Color(red: 0.4, green: 0.1, blue: 0.6)

    var body: some View {
        contentView
            .frame(width: 560, height: 540)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(borderOverlay)
            .shadow(color: goldBright.opacity(0.6), radius: 30)
            .opacity(showView ? 1 : 0)
            .scaleEffect(showView ? 1 : 0.9)
            .onAppear(perform: handleAppear)
            .onDisappear(perform: handleDisappear)
            .background(animationTimeline)
    }

    // MARK: - Sub-views

    private var contentView: some View {
        ZStack {
            backgroundLayers
            mainContentLayer
            AboutCRTOverlayView()
                .opacity(0.15)
                .allowsHitTesting(false)
        }
    }

    private var backgroundLayers: some View {
        ZStack {
            // LAYER 0: Deep space background (Click to close)
            Color(red: 0.1, green: 0.08, blue: 0.05)
                .contentShape(Rectangle())
                .onTapGesture { closeView() }

            // LAYER 1: Starfield
            AboutStarfieldView(time: animationTime)
                .allowsHitTesting(false)

            // LAYER 2: Raster bars
            AboutRasterBarsView(time: animationTime)
                .opacity(0.25)
                .allowsHitTesting(false)

            // LAYER 3: 3D Wireframe Pyramid
            AboutWireframePyramidView(time: animationTime)
                .frame(width: 400, height: 400)
                .opacity(0.5)
                .allowsHitTesting(false)
                .blendMode(.screen)

            // LAYER 4: Retro grid floor
            AboutRetroGridView(time: animationTime)
                .opacity(0.5)
                .allowsHitTesting(false)
        }
    }

    private var mainContentLayer: some View {
        let glitchOffset = calculateGlitchOffset()
        return mainContentVStack
            .padding(.horizontal)
            .modifier(AboutChromaticAberration(offset: glitchOffset))
    }

    private var mainContentVStack: some View {
        VStack(spacing: 0) {
            closeButton
            Spacer()
            titleSection
            Spacer().frame(height: 4)
            versionInfo
            Spacer().frame(height: 25)
            scrollerSection
            Spacer().frame(height: 20)
            descriptionSection
            Spacer().frame(height: 25)
            acknowledgementsBox
            Spacer().frame(height: 16)
            greetingsText
            Spacer()
            copyrightText
        }
    }

    private var closeButton: some View {
        HStack {
            Spacer()
            Button(action: { closeView() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .padding(12)
        }
    }

    private var titleSection: some View {
        AboutAnimatedTitleView(text: "ANUBIS", time: animationTime)
            .frame(height: 70)
            .offset(x: sin(animationTime * 2) * 2)
            .font(.custom("SF-Bold", size: 56))
    }

    private var versionInfo: some View {
        Text("v\(appVersion) (\(buildNumber)) // \(copyrightYear)")
            .font(.custom("SF Mono-Bold", size: 14))
            .foregroundColor(goldBright)
            .shadow(color: goldBright, radius: 8)
            .tracking(2)
    }

    private var scrollerSection: some View {
        AboutSineWaveTextView(
            text: "𓂀  Crafted by JT @ UncSoft  ●  \(copyrightYear)  ●  Built with SwiftUI  ●  Weighed & Measured  ●  Sic Semper Tyrannis  ●  ",
            time: animationTime
        )
        .frame(height: 40)
        .background(Color.black.opacity(0.3).blur(radius: 5))
    }

    private var descriptionSection: some View {
        VStack(spacing: 4) {
            Text("JUDGMENT RENDERED: TRUTH_VERIFIED")
                .font(.custom("SF Mono-Bold", size: 12))
                .foregroundColor(Color.green)
                .shadow(color: .green, radius: 5)

            Text("Local LLM Testing & Benchmarking for Apple Silicon")
                .font(.custom("SF Mono", size: 13))
                .foregroundColor(sandLight.opacity(0.9))
        }
    }

    private var acknowledgementsBox: some View {
        VStack(spacing: 8) {
            Text("- ACKNOWLEDGEMENTS -")
                .font(.custom("SF Mono-Bold", size: 10))
                .foregroundColor(amber)

            acknowledgementsLinks
        }
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .stroke(amber.opacity(0.4), lineWidth: 1)
                .background(Color.black.opacity(0.5))
        )
    }

    private var acknowledgementsLinks: some View {
        VStack(spacing: 4) {
            AboutAcknowledgementLink(text: "GRDB.swift .... Gwendal Roué", url: "https://github.com/groue/GRDB.swift", color: goldBright)
            AboutAcknowledgementLink(text: "Ollama ........ Ollama Team", url: "https://ollama.ai", color: goldBright)
            AboutAcknowledgementLink(text: "Sparkle ....... Sparkle Project", url: "https://sparkle-project.org", color: goldBright)
            AboutAcknowledgementLink(text: "Swift Charts ... Apple", url: "https://developer.apple.com/documentation/charts", color: goldBright)
        }
    }

    private var greetingsText: some View {
        Text("Greets to SwiftUI · Coffee · No Sleep")
            .font(.custom("SF Mono", size: 10))
            .foregroundColor(desertPurple.opacity(0.8))
    }

    private var copyrightText: some View {
        Text("© \(copyrightYear) UncSoft")
            .font(.custom("SF Mono-Bold", size: 12))
            .foregroundColor(.white.opacity(0.4))
            .padding(.bottom, 20)
    }

    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(
                LinearGradient(
                    colors: [goldBright, amber, goldDeep],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 2
            )
    }

    private var animationTimeline: some View {
        TimelineView(.animation(minimumInterval: 1/60)) { timeline in
            Color.clear.onChange(of: timeline.date) { _, newDate in
                if isAnimating {
                    animationTime = newDate.timeIntervalSinceReferenceDate
                }
            }
        }
    }

    // MARK: - Helper Methods

    private func closeView() {
        musicPlayer.stopMusic()
        onClose?()
    }

    private func calculateGlitchOffset() -> Double {
        let cycle = animationTime.truncatingRemainder(dividingBy: 4.0)
        let isGlitching = cycle < 0.3
        if isGlitching {
            let intensity = sin(cycle * .pi / 0.3)
            return intensity * (2 + sin(animationTime * 15) * 3)
        } else {
            return 0
        }
    }

    private func handleAppear() {
        showView = false
        isAnimating = true
        musicPlayer.playMusic()
        withAnimation(.easeOut(duration: 0.4)) {
            showView = true
        }
    }

    private func handleDisappear() {
        isAnimating = false
        musicPlayer.stopMusic()
    }
}

// MARK: - Chromatic Aberration
struct AboutChromaticAberration: ViewModifier {
    let offset: Double

    func body(content: Content) -> some View {
        ZStack {
            content.foregroundColor(.red).offset(x: offset, y: -offset/2).blendMode(.screen).opacity(0.7)
            content.foregroundColor(.blue).offset(x: -offset, y: 0).blendMode(.screen).opacity(0.7)
            content.foregroundColor(.green).offset(x: -offset/2, y: offset).blendMode(.screen).opacity(0.7)
            content
        }
        .drawingGroup()
    }
}

// MARK: - 3D Wireframe Pyramid
struct AboutWireframePyramidView: View {
    let time: Double

    private let vertices: [SIMD3<Double>] = [
        [0, -1.2, 0],     // Apex
        [-1, 0.8, -1],    // Base front-left
        [1, 0.8, -1],     // Base front-right
        [1, 0.8, 1],      // Base back-right
        [-1, 0.8, 1]      // Base back-left
    ]

    private let edges: [(Int, Int)] = [
        (0, 1), (0, 2), (0, 3), (0, 4), // Apex to base
        (1, 2), (2, 3), (3, 4), (4, 1)  // Base square
    ]

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let scale = min(size.width, size.height) * 0.35

            let angleX = time * 0.4
            let angleY = time * 0.8
            let angleZ = time * 0.2

            let projectedPoints: [CGPoint] = vertices.map { v in
                var x = v.x, y = v.y, z = v.z

                let tempX = x * cos(angleY) - z * sin(angleY)
                z = x * sin(angleY) + z * cos(angleY)
                x = tempX

                let tempY = y * cos(angleX) - z * sin(angleX)
                z = y * sin(angleX) + z * cos(angleX)
                y = tempY

                let tempX2 = x * cos(angleZ) - y * sin(angleZ)
                y = x * sin(angleZ) + y * cos(angleZ)
                x = tempX2

                let cameraDist = 3.0
                let perspective = 1.0 / (cameraDist - z)

                return CGPoint(
                    x: center.x + x * perspective * scale,
                    y: center.y + y * perspective * scale
                )
            }

            var path = Path()
            for (start, end) in edges {
                path.move(to: projectedPoints[start])
                path.addLine(to: projectedPoints[end])
            }

            let goldColor = Color(red: 0.96, green: 0.78, blue: 0.33)
            context.stroke(path, with: .color(goldColor.opacity(0.6)), lineWidth: 2)

            for p in projectedPoints {
                let rect = CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
                context.fill(Circle().path(in: rect), with: .color(.white))
                context.fill(Circle().path(in: rect.insetBy(dx: -4, dy: -4)), with: .color(goldColor.opacity(0.3)))
            }
        }
    }
}

// MARK: - Audio Player
class AboutMusicPlayer: ObservableObject {
    static let shared = AboutMusicPlayer()
    var player: AVAudioPlayer?

    func playMusic() {
        if let existingPlayer = player, existingPlayer.isPlaying { return }

        guard let url = Bundle.main.url(forResource: "keygen_music", withExtension: "mp3") else {
            print("Music file not found - add 'keygen_music.mp3' to bundle")
            return
        }

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1
            player?.volume = 0.4
            player?.prepareToPlay()
            player?.play()
        } catch {
            print("Audio error: \(error)")
        }
    }

    func stopMusic() {
        guard let player = player, player.isPlaying else { return }
        player.stop()
        self.player = nil
    }
}

// MARK: - Animated Title
struct AboutAnimatedTitleView: View {
    let text: String
    let time: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, char in
                AnimatedCharView(char: char, index: index, time: time)
            }
        }
    }
}

private struct AnimatedCharView: View {
    let char: Character
    let index: Int
    let time: Double

    private var yOffset: CGFloat {
        sin(time * 3 + Double(index) * 0.4) * 6
    }

    private var scale: CGFloat {
        1.0 + sin(time * 4 + Double(index) * 0.3) * 0.1
    }

    private var hue: Double {
        let hueBase = 0.08 + Double(index) * 0.012
        return (hueBase + time * 0.05).truncatingRemainder(dividingBy: 1.0)
    }

    private var gradient: LinearGradient {
        let topColor = Color(hue: hue, saturation: 0.8, brightness: 1.0)
        let bottomHue = (hue + 0.05).truncatingRemainder(dividingBy: 1.0)
        let bottomColor = Color(hue: bottomHue, saturation: 0.9, brightness: 0.85)
        return LinearGradient(colors: [topColor, bottomColor], startPoint: .top, endPoint: .bottom)
    }

    private var glowColor: Color {
        Color(hue: hue, saturation: 1.0, brightness: 1.0).opacity(0.5)
    }

    var body: some View {
        Text(String(char))
            .font(.custom("SF Mono-Bold", size: 56))
            .foregroundStyle(gradient)
            .shadow(color: .white.opacity(0.5), radius: 2)
            .shadow(color: glowColor, radius: 15)
            .offset(y: yOffset)
            .scaleEffect(scale)
    }
}

// MARK: - Starfield
struct AboutStarfieldView: View {
    let time: Double
    private let stars: [Star] = (0..<120).map { _ in
        Star(x: .random(in: 0...1), y: .random(in: 0...1), z: .random(in: 0.1...1), size: .random(in: 1...6))
    }

    struct Star { let x, y, z, size: CGFloat }

    var body: some View {
        Canvas { context, size in
            for star in stars {
                let speed = star.z * 0.05
                let xOffset = CGFloat(time * Double(speed) * 80).truncatingRemainder(dividingBy: size.width)
                var x = star.x * size.width - xOffset
                if x < 0 { x += size.width }
                let y = star.y * size.height

                let twinkle = sin(time * 5 + Double(star.x * 50)) * 0.5 + 0.5
                // Warm-tinted stars
                let warmth = star.z > 0.7 ? Color(red: 1.0, green: 0.9, blue: 0.7).opacity(Double(star.z) * twinkle) : Color.white.opacity(Double(star.z) * twinkle)

                let rect = CGRect(x: x, y: y, width: star.size * star.z, height: star.size * star.z)
                context.fill(Circle().path(in: rect), with: .color(warmth))
            }
        }
    }
}

// MARK: - Raster Bars
struct AboutRasterBarsView: View {
    let time: Double
    private let colors: [Color] = [
        Color(red: 0.96, green: 0.78, blue: 0.33), // gold
        Color(red: 1.0, green: 0.58, blue: 0.0),   // amber
        Color(red: 0.83, green: 0.66, blue: 0.29),  // deep gold
        .orange,
        Color(red: 0.4, green: 0.1, blue: 0.6)      // purple
    ]

    var body: some View {
        Canvas { context, size in
            for i in 0..<5 {
                let speed = 1.2 + Double(i) * 0.1
                let y = sin(time * speed + Double(i)) * size.height * 0.4 + size.height * 0.5
                let barHeight: CGFloat = 30 + CGFloat(i * 5)

                let rect = CGRect(x: 0, y: y - barHeight/2, width: size.width, height: barHeight)
                let gradient = Gradient(colors: [
                    colors[i].opacity(0),
                    colors[i].opacity(0.4),
                    colors[i].opacity(0)
                ])

                context.fill(
                    Rectangle().path(in: rect),
                    with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: y - barHeight/2), endPoint: CGPoint(x: 0, y: y + barHeight/2))
                )
            }
        }
    }
}

// MARK: - Retro Grid
struct AboutRetroGridView: View {
    let time: Double
    var body: some View {
        Canvas { context, size in
            let horizon = size.height * 0.6
            let speed = 15.0
            let offset = CGFloat(time * speed).truncatingRemainder(dividingBy: 40)

            let gridColor = Color(red: 0.83, green: 0.66, blue: 0.29) // deep gold

            for i in 0..<12 {
                let t = CGFloat(i) / 12.0
                let yBase = horizon + pow(t, 2) * (size.height - horizon)
                let y = yBase + offset * pow(t, 2)

                if y < size.height {
                    let path = Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) }
                    context.stroke(path, with: .color(gridColor.opacity(Double(t) * 0.5)), lineWidth: 1 + t)
                }
            }

            for i in 0...10 {
                let xTop = size.width / 2
                let xBottom = size.width * (CGFloat(i - 5) * 0.4 + 0.5)
                let path = Path { p in p.move(to: CGPoint(x: xTop, y: horizon)); p.addLine(to: CGPoint(x: xBottom, y: size.height)) }
                context.stroke(path, with: .color(gridColor.opacity(0.3)), lineWidth: 1)
            }
        }
    }
}

// MARK: - Sine Scroller
struct AboutSineWaveTextView: View {
    let text: String
    let time: Double

    var body: some View {
        Canvas { context, size in
            let fullText = text + text + text
            let chars = Array(fullText)
            let charWidth: CGFloat = 14
            let scroll = CGFloat(time * 60).truncatingRemainder(dividingBy: CGFloat(chars.count) * charWidth / 3)

            for (i, char) in chars.enumerated() {
                let x = CGFloat(i) * charWidth - scroll
                if x > -20 && x < size.width + 20 {
                    let yOff = sin(time * 3 + Double(i) * 0.2) * 8
                    let y = size.height / 2 + yOff

                    // Gold hue range
                    let hue = (0.08 + Double(i) * 0.003 - time * 0.1).truncatingRemainder(dividingBy: 1.0)
                    let color = Color(hue: abs(hue), saturation: 0.8, brightness: 1.0)

                    context.draw(Text(String(char)).font(.custom("SF Mono-Bold", size: 18)).foregroundColor(color), at: CGPoint(x: x, y: y))
                }
            }
        }
        .clipShape(Rectangle())
    }
}

// MARK: - CRT Overlay
struct AboutCRTOverlayView: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                context.fill(Rectangle().path(in: CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.3)))
                y += 3
            }
        }
    }
}

// MARK: - Acknowledgement Link
struct AboutAcknowledgementLink: View {
    let text: String
    let url: String
    let color: Color
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
        }) {
            Text(text)
                .font(.custom("SF Mono", size: 11))
                .foregroundColor(isHovered ? color : color.opacity(0.8))
                .underline(isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

#Preview {
    KeygenAboutView()
}
