import RealityKit
import SwiftUI

/// The room as it sounds: the listener's head in the middle, turning with head tracking; the speakers around it;
/// and a ball for each sound that stands out, gliding where it comes from, appearing and fading with it.
/// Drag to orbit around the head; scroll or pinch to zoom; click a speaker to solo it, again to hear all.
struct SoundStage: View {
    static let windowID = "stage"

    @ObservedObject var model: Model
    @ObservedObject var live: LiveState
    @StateObject private var scene = StageScene()
    @StateObject private var scrolling = ScrollMonitor()

    var body: some View {
        TimelineView(.animation) { timeline in
            RealityView { content in
                content.camera = .virtual
                content.add(scene.root)
            } update: { _ in
                scene.update(
                    levels: live.speakerLevels, sources: live.soundSources, solo: model.soloSpeaker, muted: model.mutedSpeakers,
                    yaw: live.yaw, time: timeline.date.timeIntervalSinceReferenceDate
                )
            }
            .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in
                guard let speaker = scene.speaker(of: value.entity) else { return }
                model.soloSpeaker = model.soloSpeaker == speaker ? nil : speaker
            })
        }
        .gesture(DragGesture().onChanged { scene.orbit(by: $0.translation) }.onEnded { _ in scene.endOrbit() })
        .simultaneousGesture(MagnifyGesture().onChanged { scene.zoom(by: $0.magnification) }.onEnded { _ in scene.endZoom() })
        .background(Color.black)
        .navigationTitle(Text("stage.title"))
        .onAppear { scrolling.start { [scene] in scene.scroll(by: $0) } }
        .onDisappear { scrolling.stop() }
    }
}

/// SwiftUI has no scroll wheel gesture on macOS, so scrolling over the stage window arrives as raw events.
@MainActor
final class ScrollMonitor: ObservableObject {
    private var monitor: Any?

    func start(_ scrolled: @escaping (CGFloat) -> Void) {
        stop()
        let title = String(localized: "stage.title")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            if event.window?.title == title {
                scrolled(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10))
            }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

/// The entities of the stage, built once and moved every frame.
@MainActor
final class StageScene: ObservableObject {
    let root = Entity()
    /// Circles the listener's head, starting behind and above it.
    private let camera = PerspectiveCamera()
    private var cameraAzimuth: Float = 0
    private var cameraElevation: Float = 30
    private var cameraDistance: Float = 7
    /// The orbit and zoom when the current gesture began.
    private var gestureStart: (azimuth: Float, elevation: Float, distance: Float)?

    /// Metres. The speakers stand on a circle at ear height; the subwoofer on the floor in front.
    private static let radius: Float = 2.2
    /// Balls circle inside the speakers so a cabinet never hides one.
    private static let ballRadius: Float = 1.6
    private static let earHeight: Float = 1.2
    private static let roomSize: Float = 7
    private static let roomHeight: Float = 3
    /// Seconds for a ball to cover about two thirds of the way to a new position and size, to grow in, and to shrink away.
    private static let glide: Float = 0.15
    private static let appear: Float = 0.1
    private static let fade: Float = 0.3
    /// Seconds a ball stays after its source was last found; quiet sources drop out for a few blocks at a time.
    private static let hold: TimeInterval = 0.5
    /// A source this close to a ball, in metres on the ball circle, is the same sound; about 40 degrees.
    private static let sameSound: Float = 1.1
    private static let ballCore = MeshResource.generateSphere(radius: 0.14)
    private static let ballHalo = MeshResource.generateSphere(radius: 0.3)
    private static let ballMaterial = UnlitMaterial(color: .systemOrange)

    /// Bass has no direction to show; each beat sends a ring across the floor from the subwoofer instead.
    /// A beat is the subwoofer's cone jumping out this far at once, about 3 dB, at most one per `waveGap`
    /// seconds; a steady beat keeps the cone from settling, so a jump is judged from where it was, not from
    /// an average. A ring spreads to `waveReach` metres over `waveLife` seconds.
    private static let beat: Float = 0.1
    private static let waveGap: TimeInterval = 0.12
    private static let waveReach: Float = 4
    private static let waveLife: TimeInterval = 1.2
    private static let subwoofer = SurroundChannel.allCases.firstIndex(of: .subwoofer)!

    private let head = Entity()
    private var balls: [SoundBall] = []
    /// A unit ring on the floor, copied for each wave, and the waves under way with when they started and how strong.
    private let ring = StageScene.revolved([[[1, 0], [0.97, 0]]], UnlitMaterial(color: .systemOrange))
    private var waves: [(entity: Entity, start: TimeInterval, strength: Float)] = []
    private var lastWave: TimeInterval = 0
    private var subwooferFloor = SIMD3<Float>.zero
    /// Each speaker's cabinet, which a click solos, and the moving part of its woofer, in `SurroundChannel` order.
    private var cabinets: [Entity] = []
    private var woofers: [Entity] = []
    /// Whether each speaker plays, as solo and mute leave it; a silenced speaker dims.
    private var playing = [Bool](repeating: true, count: SurroundChannel.allCases.count)
    private static let silencedOpacity: Float = 0.3
    /// How much of its depth the woofer's cone travels out at full level. The cone answers from -30 dB, moves
    /// out at once and settles back over about `coneReturn` seconds, so a low tone's block-to-block peaks
    /// don't shake it.
    private static let excursion: Float = 0.8
    private static let coneFloor = 30.0
    private static let coneReturn: Float = 0.12
    /// Each woofer's travel, 0 to 1, in `SurroundChannel` order.
    private var cones = [Float](repeating: 0, count: SurroundChannel.allCases.count)
    /// Each speaker's level meter above it, bottom segment first, and how many segments it lights.
    private static let segments = 10
    private static let unlit = UnlitMaterial(color: .init(white: 0.15, alpha: 1))
    private static let litMaterials = (0..<segments).map(segmentMaterial)
    private var meters: [[ModelEntity]] = []
    private var litSegments: [Int] = []
    private var lastTime: TimeInterval?
    private let headPosition = SIMD3<Float>(0, StageScene.earHeight, 0)

    init() {
        root.addChild(camera)
        // A key light from above and behind the listener's left shoulder brings out the drivers' relief.
        let light = DirectionalLight()
        light.light.intensity = 4000
        light.look(at: .zero, from: [-2, 4, 3], relativeTo: nil)
        root.addChild(light)
        placeCamera()
        buildRoom()
        buildListener()
        for channel in SurroundChannel.allCases {
            buildSpeaker(channel)
        }
    }

    /// `solo` and `muted` are speakers by `SurroundChannel` index, as in the speaker settings.
    func update(levels: [ChannelLevel], sources: [SoundSource], solo: Int?, muted: Set<Int>, yaw: Double, time: TimeInterval) {
        head.orientation = simd_quatf(angle: Float(-yaw * .pi / 180), axis: [0, 1, 0])
        let step = Float(time - (lastTime ?? time))
        lastTime = time
        let settle = 1 - exp(-step / Self.coneReturn)
        var power: Float = 0
        let bassBefore = cones[Self.subwoofer]
        for (index, channel) in SurroundChannel.allCases.enumerated() {
            let isPlaying = (solo == nil || solo == index) && !muted.contains(index)
            if isPlaying != playing[index] {
                playing[index] = isPlaying
                if isPlaying {
                    cabinets[index].components.remove(OpacityComponent.self)
                } else {
                    cabinets[index].components.set(OpacityComponent(opacity: Self.silencedOpacity))
                }
            }
            let level = Float(levels.first { $0.id == index }?.level ?? 0)
            let heard = isPlaying ? level : 0
            setMeter(index, level: Self.visible(Double(heard)))
            let travel = Self.visible(Double(heard), floor: Self.coneFloor)
            cones[index] = travel > cones[index] ? travel : cones[index] + (travel - cones[index]) * settle
            woofers[index].scale.z = 1 - Self.excursion * cones[index]
            if channel != .subwoofer {
                power += level * level
            }
        }
        moveWaves(bass: cones[Self.subwoofer], jump: cones[Self.subwoofer] - bassBefore, time: time)
        follow(sources, power: power, time: time)
        let glide = 1 - exp(-step / Self.glide)
        let appear = 1 - exp(-step / Self.appear), fade = 1 - exp(-step / Self.fade)
        for ball in balls {
            let isHeard = time - ball.lastHeard < Self.hold
            ball.offset += (ball.target - ball.offset) * glide
            ball.size += (ball.loudness - ball.size) * glide
            ball.presence += isHeard ? (1 - ball.presence) * appear : -ball.presence * fade
            ball.entity.position = headPosition + ball.offset
            // The core stays opaque: a translucent core would sort behind its halo and vanish.
            ball.entity.scale = .init(repeating: ball.presence * (0.4 + 0.8 * ball.size))
        }
        balls.removeAll { ball in
            let gone = time - ball.lastHeard >= Self.hold && ball.presence < 0.01
            if gone {
                ball.entity.removeFromParent()
            }
            return gone
        }
    }

    /// Starts a ring when `bass`, the subwoofer's cone travel, jumped by a beat in this frame, and spreads and
    /// fades the rings under way, easing out as they spread.
    private func moveWaves(bass: Float, jump: Float, time: TimeInterval) {
        if jump > Self.beat, time - lastWave > Self.waveGap {
            lastWave = time
            let wave = ring.clone(recursive: true)
            // The ring faces -z; this lays it on the floor, facing up.
            wave.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            wave.position = subwooferFloor
            wave.scale = .zero
            root.addChild(wave)
            waves.append((wave, time, bass))
        }
        waves.removeAll { wave in
            let age = Float((time - wave.start) / Self.waveLife)
            guard age < 1 else {
                wave.entity.removeFromParent()
                return true
            }
            let spread = 1 - (1 - age) * (1 - age)
            wave.entity.scale = .init(repeating: 0.3 + (Self.waveReach - 0.3) * spread)
            wave.entity.components.set(OpacityComponent(opacity: 0.3 * wave.strength * (1 - age)))
            return false
        }
    }

    /// Gives each source the nearest ball still free, or a new one; balls left without a source fade away.
    /// `power` is the speakers' summed power, shared out by each source's part of it.
    private func follow(_ sources: [SoundSource], power: Float, time: TimeInterval) {
        var free = balls
        for source in sources.sorted(by: { $0.share > $1.share }) {
            // RealityKit looks down -z.
            let target = SIMD3<Float>(source.position.x, 0, -source.position.y) * Self.ballRadius
            let ball: SoundBall
            if let nearest = free.indices.min(by: { simd_distance(free[$0].target, target) < simd_distance(free[$1].target, target) }),
               simd_distance(free[nearest].target, target) < Self.sameSound {
                ball = free.remove(at: nearest)
            } else {
                ball = makeBall(at: target)
            }
            ball.target = target
            ball.loudness = Self.visible(Double((power * source.share).squareRoot()))
            ball.lastHeard = time
        }
    }

    private func makeBall(at offset: SIMD3<Float>) -> SoundBall {
        let entity = Entity()
        entity.addChild(ModelEntity(mesh: Self.ballCore, materials: [Self.ballMaterial]))
        let halo = ModelEntity(mesh: Self.ballHalo, materials: [Self.ballMaterial])
        halo.components.set(OpacityComponent(opacity: 0.25))
        entity.addChild(halo)
        entity.scale = .zero
        entity.position = headPosition + offset
        root.addChild(entity)
        let ball = SoundBall(entity: entity, offset: offset)
        balls.append(ball)
        return ball
    }

    /// The speaker, by `SurroundChannel` index, whose cabinet holds `entity`.
    func speaker(of entity: Entity) -> Int? {
        var current: Entity? = entity
        while let candidate = current {
            if let index = cabinets.firstIndex(where: { $0 === candidate }) {
                return index
            }
            current = candidate.parent
        }
        return nil
    }

    /// Turns the camera around the head; a drag down tilts the view down.
    func orbit(by translation: CGSize) {
        let start = gestureStart ?? (cameraAzimuth, cameraElevation, cameraDistance)
        gestureStart = start
        cameraAzimuth = start.azimuth - Float(translation.width) * 0.3
        cameraElevation = min(85, max(5, start.elevation + Float(translation.height) * 0.3))
        placeCamera()
    }

    func endOrbit() {
        gestureStart = nil
    }

    func zoom(by magnification: CGFloat) {
        let start = gestureStart ?? (cameraAzimuth, cameraElevation, cameraDistance)
        gestureStart = start
        setDistance(start.distance / Float(magnification))
    }

    func endZoom() {
        gestureStart = nil
    }

    /// A scroll wheel or two-finger scroll: scrolling up moves closer.
    func scroll(by delta: CGFloat) {
        setDistance(cameraDistance * exp(-Float(delta) * 0.02))
    }

    private func setDistance(_ distance: Float) {
        cameraDistance = min(12, max(2.5, distance))
        placeCamera()
    }

    /// Azimuth 0 looks forward over the listener's shoulders.
    private func placeCamera() {
        let elevation = cameraElevation * .pi / 180
        let offset = -Self.direction(Double(cameraAzimuth)) * cos(elevation) + [0, sin(elevation), 0]
        camera.look(at: headPosition, from: headPosition + offset * cameraDistance, relativeTo: nil)
    }

    /// A linear peak on a -`floor` dB to 0 dB scale, 0 to 1.
    private static func visible(_ level: Double, floor: Double = 50) -> Float {
        guard level > 0 else { return 0 }
        return Float(min(max((20 * log10(level) + floor) / floor, 0), 1))
    }

    /// Clockwise degrees from straight ahead to a point on the floor plane; RealityKit looks down -z.
    private static func direction(_ azimuth: Double) -> SIMD3<Float> {
        let radians = Float(azimuth * .pi / 180)
        return [sin(radians), 0, -cos(radians)]
    }

    private func buildRoom() {
        let floor = ModelEntity(
            mesh: .generatePlane(width: Self.roomSize, depth: Self.roomSize),
            materials: [SimpleMaterial(color: .init(white: 0.08, alpha: 1), isMetallic: false)]
        )
        root.addChild(floor)
        let line = UnlitMaterial(color: .init(white: 0.3, alpha: 1))
        let half = Self.roomSize / 2
        for step in stride(from: -half, through: half, by: 0.5) {
            for (width, depth, position) in [
                (Self.roomSize, Float(0.005), SIMD3<Float>(0, 0.001, step)),
                (Float(0.005), Self.roomSize, SIMD3<Float>(step, 0.001, 0)),
            ] {
                let gridLine = ModelEntity(mesh: .generatePlane(width: width, depth: depth), materials: [line])
                gridLine.position = position
                root.addChild(gridLine)
            }
        }
        let edge = UnlitMaterial(color: .init(white: 0.45, alpha: 1))
        for x in [-half, half] {
            for z in [-half, half] {
                let post = ModelEntity(mesh: .generateBox(size: [0.02, Self.roomHeight, 0.02]), materials: [edge])
                post.position = [x, Self.roomHeight / 2, z]
                root.addChild(post)
            }
        }
        for y in [Float(0), Self.roomHeight] {
            for (size, position) in [
                (SIMD3<Float>(Self.roomSize, 0.02, 0.02), SIMD3<Float>(0, y, -half)),
                (SIMD3<Float>(Self.roomSize, 0.02, 0.02), SIMD3<Float>(0, y, half)),
                (SIMD3<Float>(0.02, 0.02, Self.roomSize), SIMD3<Float>(-half, y, 0)),
                (SIMD3<Float>(0.02, 0.02, Self.roomSize), SIMD3<Float>(half, y, 0)),
            ] {
                let beam = ModelEntity(mesh: .generateBox(size: size), materials: [edge])
                beam.position = position
                root.addChild(beam)
            }
        }
    }

    private func buildListener() {
        let skin = SimpleMaterial(color: .init(white: 0.85, alpha: 1), isMetallic: false)
        let skull = ModelEntity(mesh: .generateSphere(radius: 0.13), materials: [skin])
        let nose = ModelEntity(mesh: .generateBox(size: [0.05, 0.07, 0.12], cornerRadius: 0.015), materials: [skin])
        nose.position = [0, -0.01, -0.15]
        head.addChild(skull)
        head.addChild(nose)
        for side: Float in [-1, 1] {
            let ear = ModelEntity(mesh: .generateSphere(radius: 0.045), materials: [skin])
            ear.scale = [0.5, 1, 0.8]
            ear.position = [side * 0.13, 0, 0]
            head.addChild(ear)
        }
        // A beam of sight from the face, widening forward, so the head's direction reads from any angle.
        let sight: Float = 0.9
        let beam = ModelEntity(mesh: .generateCone(height: sight, radius: 0.22), materials: [UnlitMaterial(color: .systemTeal)])
        beam.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        beam.position = [0, 0, -0.14 - sight / 2]
        beam.components.set(OpacityComponent(opacity: 0.3))
        head.addChild(beam)
        head.position = headPosition
        let body = ModelEntity(
            mesh: .generateCylinder(height: 0.6, radius: 0.16),
            materials: [SimpleMaterial(color: .init(white: 0.35, alpha: 1), isMetallic: false)]
        )
        body.position = [0, Self.earHeight - 0.5, 0]
        root.addChild(body)
        root.addChild(head)
    }

    private func buildSpeaker(_ channel: SurroundChannel) {
        let isSubwoofer = channel == .subwoofer
        let position = isSubwoofer
            ? Self.direction(channel.azimuth) * (Self.radius + 0.4) + [0, 0.25, 0]
            : Self.direction(channel.azimuth) * Self.radius + [0, Self.earHeight, 0]
        let size: SIMD3<Float> = isSubwoofer ? [0.5, 0.5, 0.5] : [0.25, 0.4, 0.25]
        let cabinet = ModelEntity(
            mesh: .generateBox(size: size, cornerRadius: 0.03),
            materials: [SimpleMaterial(color: .init(white: 0.25, alpha: 1), isMetallic: false)]
        )
        cabinet.components.set([CollisionComponent(shapes: [.generateBox(size: size)]), InputTargetComponent()])
        cabinets.append(cabinet)
        cabinet.position = position
        if isSubwoofer {
            // Just above the floor and its grid lines.
            subwooferFloor = [position.x, 0.004, position.z]
        }
        cabinet.look(at: [0, position.y, 0], from: position, relativeTo: nil)
        root.addChild(cabinet)
        // The cabinet's front faces the listener along its -z; the drivers stand out from it by their depth.
        let face: Float = isSubwoofer ? -0.25 : -0.125
        let woofer = Self.driver(radius: isSubwoofer ? 0.19 : 0.085, isDome: false)
        woofer.frame.position = [0, isSubwoofer ? 0 : -0.06, face - woofer.depth]
        cabinet.addChild(woofer.frame)
        woofers.append(woofer.piston)
        if !isSubwoofer {
            let tweeter = Self.driver(radius: 0.03, isDome: true)
            tweeter.frame.position = [0, 0.12, face - tweeter.depth]
            cabinet.addChild(tweeter.frame)
        }
        let top: Float = isSubwoofer ? 0.25 : 0.2
        meters.append((0..<Self.segments).map { index in
            let segment = ModelEntity(mesh: .generateBox(size: [0.08, 0.022, 0.02], cornerRadius: 0.004), materials: [Self.unlit])
            segment.position = [0, top + 0.03 + Float(index) * 0.03, 0]
            cabinet.addChild(segment)
            return segment
        })
        litSegments.append(-1)
    }

    /// The color of a lit meter segment: teal, then yellow, then red at the top.
    private static func segmentMaterial(_ index: Int) -> UnlitMaterial {
        UnlitMaterial(color: index >= segments - 1 ? .systemRed : index >= segments - 4 ? .systemYellow : .systemTeal)
    }

    /// Lights the meter's segments up to `level` on the -50 dB to 0 dB scale, changing materials only when the count changes.
    private func setMeter(_ speaker: Int, level: Float) {
        let lit = Int((level * Float(Self.segments)).rounded())
        guard lit != litSegments[speaker] else { return }
        litSegments[speaker] = lit
        for (index, segment) in meters[speaker].enumerated() {
            segment.model?.materials = [index < lit ? Self.litMaterials[index] : Self.unlit]
        }
    }

    /// A round driver facing -z, its rim at the frame's origin and its back `depth` behind it. A woofer has a dished,
    /// ribbed paper cone with a domed dust cap, held by a rolled rubber surround; a tweeter is a dome.
    /// The piston is what moves: squashing it along z pushes its middle out while its edge stays on the surround.
    private static func driver(radius r: Float, isDome: Bool) -> (frame: Entity, piston: Entity, depth: Float) {
        let metal = SimpleMaterial(color: .init(white: 0.6, alpha: 1), roughness: 0.3, isMetallic: true)
        let rubber = SimpleMaterial(color: .init(white: 0.07, alpha: 1), roughness: 0.9, isMetallic: false)
        let paper = SimpleMaterial(color: .init(white: 0.3, alpha: 1), roughness: 0.85, isMetallic: false)
        let cap = SimpleMaterial(color: .init(white: 0.12, alpha: 1), roughness: 0.5, isMetallic: false)
        func curve(_ steps: Int, _ point: (Float) -> SIMD2<Float>) -> [SIMD2<Float>] {
            (0...steps).map { point(Float($0) / Float(steps)) }
        }
        let coneDepth = r * 0.4
        let depth = isDome ? r * 0.2 : coneDepth + 0.005
        let frame = Entity()
        frame.addChild(revolved([[[r * 1.08, depth], [r * 1.08, 0]], [[r * 1.08, 0], [r * 0.98, 0]]], metal))
        let piston = Entity()
        if isDome {
            frame.addChild(revolved([[[r * 0.98, 0], [r * 0.8, 0]]], rubber))
            piston.addChild(revolved([curve(12) { [r * 0.8 * cos($0 * .pi / 2), -r * 0.45 * sin($0 * .pi / 2)] }], cap))
        } else {
            frame.addChild(revolved([curve(12) { [r * (0.98 - 0.18 * $0), -r * 0.07 * sin($0 * .pi)] }], rubber))
            // A flared cone with four shallow ribs, deepest at the dust cap.
            piston.addChild(revolved([curve(48) { u in
                [r * (0.8 - 0.54 * u), coneDepth * (1 - pow(1 - u, 1.6)) + r * 0.02 * sin(u * .pi * 8) * sin(u * .pi)]
            }], paper))
            piston.addChild(revolved([curve(12) { [r * 0.26 * cos($0 * .pi / 2), coneDepth - r * 0.12 * sin($0 * .pi / 2)] }], cap))
        }
        frame.addChild(piston)
        return (frame, piston, depth)
    }

    /// A surface turned around the z axis from strips of (radius, z) points. Each strip is smooth and runs from
    /// its outer or back end inward, and is lit on its outer, front side.
    private static func revolved(_ strips: [[SIMD2<Float>]], _ material: any RealityKit.Material) -> Entity {
        let segments = 48
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        for strip in strips {
            let base = positions.count
            for (index, point) in strip.enumerated() {
                let tangent = strip[min(index + 1, strip.count - 1)] - strip[max(index - 1, 0)]
                let normal = simd_normalize(SIMD2<Float>(-tangent.y, tangent.x))
                for segment in 0..<segments {
                    let angle = Float(segment) / Float(segments) * 2 * .pi
                    positions.append([point.x * cos(angle), point.x * sin(angle), point.y])
                    normals.append([normal.x * cos(angle), normal.x * sin(angle), normal.y])
                }
            }
            for ring in 0..<(strip.count - 1) {
                for segment in 0..<segments {
                    let a = base + ring * segments + segment, b = base + ring * segments + (segment + 1) % segments
                    for var triangle in [[a, b, a + segments], [b, b + segments, a + segments]] {
                        // Counter-clockwise faces the viewer.
                        let facing = simd_cross(positions[triangle[1]] - positions[triangle[0]], positions[triangle[2]] - positions[triangle[0]])
                        if simd_dot(facing, normals[triangle[0]] + normals[triangle[2]]) < 0 {
                            triangle.swapAt(1, 2)
                        }
                        indices += triangle.map(UInt32.init)
                    }
                }
            }
        }
        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return Entity() }
        return ModelEntity(mesh: mesh, materials: [material])
    }
}

/// A ball of sound following one source; `offset` is from the head.
@MainActor
private final class SoundBall {
    let entity: Entity
    var offset: SIMD3<Float>
    var target: SIMD3<Float>
    /// 0 to 1: how loud its source is and how big the ball shows it, and how far the ball has grown in.
    var loudness: Float = 0
    var size: Float = 0
    var presence: Float = 0
    var lastHeard: TimeInterval = 0

    init(entity: Entity, offset: SIMD3<Float>) {
        self.entity = entity
        self.offset = offset
        target = offset
    }
}
