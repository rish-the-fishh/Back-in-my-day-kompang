import SwiftUI
import RealityKit
import ARKit
import QuartzCore

struct ImmersiveView: View {
    let arSession = ARKitSession()
    let handTracking = HandTrackingProvider()
    let worldTracking = WorldTrackingProvider()
    
    @State private var rightHandEntity = Entity()
    @State private var drumEntity: ModelEntity?
    @State private var npcEntity: ModelEntity?
    @State private var kompangSound: AudioFileResource?
    
    // MARK: - Game State
    enum GamePhase {
        case hidden, intro, demonstrating, userTurn, outro, finished
    }
    
    @State private var isNearNPC = false
    @State private var gamePhase: GamePhase = .hidden
    @State private var currentDialogueText = ""
    
    @State private var introIndex = 0
    let introDialogues = [
        "Eh, come, come! You know how to play this?",
        "Nowadays, you hear music everywhere... phone, radio, headphones.",
        "Back in my day, during weddings and celebrations, we'd get together and play kompang.",
        "Come, I'll teach you one rhythm."
    ]
    
    @State private var outroIndex = 0
    let outroDialogues = [
        "Good! Now you've got the rhythm.",
        "And if you listen closely, there are still plenty of stories around here. Go find the next one."
    ]
    
    @State private var currentBeatIndex = 0
    @State private var userHitTimestamps: [Double] = []
    @State private var lastHitTime: Double = 0.0
    
    // MARK: - Beat Tracker State
    @State private var trackerProgress: CGFloat = 0.0
    @State private var trackDuration: Double = 2.0
    @State private var activeIntervals: [Double] = []
    @State private var hitSuccesses: [Bool] = [] // NEW: Tracks real-time success of each circle
    
    // The 3 Sample Rhythms
    let beats = [
        (name: "Sample rhythm 1", text: "Hit ... Hit ... Hit", intervals: [0.0, 0.6, 1.2]),
        (name: "Sample rhythm 2", text: "Hit-Hit ... Hit ... Hit", intervals: [0.0, 0.3, 0.9, 1.5]),
        (name: "Sample rhythm 3", text: "Hit ... Hit-Hit ... Hit", intervals: [0.0, 0.5, 0.8, 1.4])
    ]
    
    var body: some View {
        RealityView { content, attachments in
            // 1. SETUP RIGHT HAND COLLIDER
            content.add(rightHandEntity)
            let handShape = ShapeResource.generateSphere(radius: 0.08)
            rightHandEntity.components.set(CollisionComponent(shapes: [handShape]))
            rightHandEntity.components.set(PhysicsBodyComponent(mode: .kinematic))
            
            // 2. LOAD NPC
            if let npc = try? await ModelEntity(named: "Baju_Melayu_Hitam") {
                npc.scale = [0.0085, 0.0085, 0.0085]
                npc.position = [1.5, 0.85, -2.0]
                
                if let idleAnim = npc.availableAnimations.first {
                    npc.playAnimation(idleAnim.repeat())
                }
                npcEntity = npc
                content.add(npc)
                
                if let dialogueAttachment = attachments.entity(for: "dialogue") {
                    dialogueAttachment.position = [1.5, 1.8, -2.0]
                    dialogueAttachment.components.set(BillboardComponent())
                    content.add(dialogueAttachment)
                }
            }
            
            // 3. LOAD KOMPANG
            if let drum = try? await ModelEntity(named: "Kompang") {
                drum.scale = [0.00165, 0.00165, 0.00165]
                drum.position = [1.5, 1.2, -1.5]
                drum.transform.rotation = simd_quatf(angle: -.pi / 2, axis: [0, 0, 1])
                
                let drumSurfaceShape = ShapeResource.generateBox(width: 0.18, height: 0.10, depth: 0.18)
                drum.components.set(CollisionComponent(shapes: [drumSurfaceShape.offsetBy(translation: [0, 0.02, 0])]))
                
                drum.isEnabled = false
                drumEntity = drum
                content.add(drum)
                
                if let trackerAttachment = attachments.entity(for: "beatTracker") {
                    trackerAttachment.position = [1.5, 1.5, -1.5]
                    trackerAttachment.components.set(BillboardComponent())
                    content.add(trackerAttachment)
                }
            }
            
            kompangSound = try? await AudioFileResource(named: "kompang")
            
            // 4. PHYSICS COLLISION LISTENER
            _ = content.subscribe(to: CollisionEvents.Began.self) { event in
                let entityA = event.entityA
                let entityB = event.entityB
                
                if (entityA == drumEntity && entityB == rightHandEntity) ||
                   (entityA == rightHandEntity && entityB == drumEntity) {
                    
                    if drumEntity?.isEnabled == true {
                        let currentTime = CACurrentMediaTime()
                        
                        if currentTime - lastHitTime > 0.2 {
                            lastHitTime = currentTime
                            
                            if let sound = kompangSound {
                                drumEntity?.playAudio(sound)
                            }
                            if gamePhase == .userTurn {
                                recordUserHit()
                            }
                        }
                    }
                }
            }
            
            // 5. START AR SESSION
            Task {
                do {
                    try await arSession.run([handTracking, worldTracking])
                    
                    // --- PROXIMITY CHECK LOOP ---
                    Task {
                        while true {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            
                            guard let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()),
                                  let npcPos = npcEntity?.position else { continue }
                            
                            let headPos = SIMD3<Float>(
                                deviceAnchor.originFromAnchorTransform.columns.3.x,
                                deviceAnchor.originFromAnchorTransform.columns.3.y,
                                deviceAnchor.originFromAnchorTransform.columns.3.z
                            )
                            
                            let distanceToNPC = distance(headPos, npcPos)
                            let wasNear = isNearNPC
                            let currentlyNear = distanceToNPC < 2.0
                            
                            if currentlyNear != wasNear {
                                await MainActor.run {
                                    isNearNPC = currentlyNear
                                    if currentlyNear {
                                        handleEnteredRadius()
                                    } else {
                                        handleExitedRadius()
                                    }
                                }
                            }
                        }
                    }
                    
                    // --- HAND TRACKING LOOP ---
                    for await update in handTracking.anchorUpdates {
                        let handAnchor = update.anchor
                        if !handAnchor.isTracked { continue }
                        guard let skeleton = handAnchor.handSkeleton else { continue }
                        
                        if handAnchor.chirality == .right {
                            let palmHitZone = skeleton.joint(.middleFingerKnuckle)
                            if palmHitZone.isTracked {
                                let rightWorldTransform = matrix_multiply(handAnchor.originFromAnchorTransform, palmHitZone.anchorFromJointTransform)
                                rightHandEntity.transform = Transform(matrix: rightWorldTransform)
                            }
                        }
                    }
                } catch {
                    print("ARKit error: \(error)")
                }
            }
        } attachments: {
            Attachment(id: "dialogue") {
                VStack {
                    Text(currentDialogueText)
                        .font(.system(size: 24, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .padding(24)
                        .glassBackgroundEffect()
                        .onTapGesture {
                            advanceDialogue()
                        }
                }
                .frame(width: 450)
                .opacity((gamePhase == .hidden || gamePhase == .finished) ? 0.0 : 1.0)
                .animation(.easeInOut(duration: 0.3), value: gamePhase)
                .allowsHitTesting(gamePhase != .hidden && gamePhase != .finished)
            }
            
            Attachment(id: "beatTracker") {
                VStack(spacing: 8) {
                    Text("Rhythm Guide")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.black.opacity(0.4))
                                .frame(height: 12)
                            
                            if trackDuration > 0 {
                                ForEach(activeIntervals.indices, id: \.self) { index in
                                    let interval = activeIntervals[index]
                                    let xPos = (interval / trackDuration) * geo.size.width
                                    
                                    // NEW: Check if this specific circle was hit successfully
                                    let isSuccessfulHit = index < hitSuccesses.count ? hitSuccesses[index] : false
                                    
                                    Circle()
                                        // Turn blue if hit correctly, stay yellow otherwise
                                        .fill(isSuccessfulHit ? Color.blue : Color.yellow)
                                        .frame(width: isSuccessfulHit ? 28 : 24, height: isSuccessfulHit ? 28 : 24)
                                        .position(x: xPos, y: geo.size.height / 2)
                                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSuccessfulHit)
                                }
                            }
                            
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: 4, height: 36)
                                .cornerRadius(2)
                                .position(x: trackerProgress * geo.size.width, y: geo.size.height / 2)
                        }
                    }
                    .frame(height: 40)
                }
                .padding(20)
                .frame(width: 400)
                .glassBackgroundEffect()
                .opacity((gamePhase == .demonstrating || gamePhase == .userTurn) ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.2), value: gamePhase)
            }
        }
    }
    
    // MARK: - Core Logic Methods
    
    private func handleEnteredRadius() {
        if gamePhase == .hidden || gamePhase == .finished {
            gamePhase = .intro
            introIndex = 0
            currentBeatIndex = 0
            currentDialogueText = introDialogues[introIndex]
        }
    }
    
    private func handleExitedRadius() {
        gamePhase = .hidden
        drumEntity?.isEnabled = false
        resetChallenge()
    }
    
    private func advanceDialogue() {
        switch gamePhase {
        case .intro:
            if introIndex < introDialogues.count - 1 {
                introIndex += 1
                currentDialogueText = introDialogues[introIndex]
            } else {
                drumEntity?.isEnabled = true
                startDemonstration()
            }
            
        case .outro:
            if outroIndex < outroDialogues.count - 1 {
                outroIndex += 1
                currentDialogueText = outroDialogues[outroIndex]
            } else {
                gamePhase = .finished
                drumEntity?.isEnabled = false
            }
            
        default:
            break
        }
    }
    
    private func resetChallenge() {
        currentBeatIndex = 0
        userHitTimestamps.removeAll()
        hitSuccesses.removeAll()
        introIndex = 0
        outroIndex = 0
    }
    
    private func startDemonstration() {
        gamePhase = .demonstrating
        userHitTimestamps.removeAll()
        
        let targetBeat = beats[currentBeatIndex]
        currentDialogueText = "Listen to \(targetBeat.name)..."
        
        let totalDuration = (targetBeat.intervals.last ?? 0.0) + 0.5
        
        activeIntervals = targetBeat.intervals
        trackDuration = totalDuration
        trackerProgress = 0.0
        
        // NEW: Reset all circles to yellow before starting
        hitSuccesses = Array(repeating: false, count: targetBeat.intervals.count)
        
        withAnimation(.linear(duration: totalDuration)) {
            trackerProgress = 1.0
        }
        
        Task {
            var previousInterval: Double = 0.0
            
            for interval in targetBeat.intervals {
                if !isNearNPC { return }
                
                let delta = interval - previousInterval
                if delta > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delta * 1_000_000_000))
                }
                
                if let sound = kompangSound {
                    drumEntity?.playAudio(sound)
                }
                previousInterval = interval
            }
            
            let remainder = totalDuration - previousInterval
            if remainder > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remainder * 1_000_000_000))
            }
            
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            if isNearNPC {
                await MainActor.run {
                    currentDialogueText = "Now, your turn!\n\(targetBeat.text)"
                    gamePhase = .userTurn
                    
                    trackerProgress = 0.0
                    withAnimation(.linear(duration: totalDuration)) {
                        trackerProgress = 1.0
                    }
                }
                
                try? await Task.sleep(nanoseconds: UInt64((totalDuration + 0.5) * 1_000_000_000))
                if gamePhase == .userTurn {
                    await MainActor.run {
                        evaluateRhythm()
                    }
                }
            }
        }
    }
    
    private func recordUserHit() {
        let timestamp = CACurrentMediaTime()
        userHitTimestamps.append(timestamp)
        
        let targetBeat = beats[currentBeatIndex]
        let hitIndex = userHitTimestamps.count - 1
        
        // NEW: Real-time hit evaluation for the visual tracker
        if hitIndex < targetBeat.intervals.count {
            if hitIndex == 0 {
                // First hit always anchors the timing, so it's technically always a "success"
                hitSuccesses[hitIndex] = true
            } else {
                let firstHit = userHitTimestamps[0]
                let userInterval = timestamp - firstHit
                let targetInterval = targetBeat.intervals[hitIndex]
                
                // Compare to our generous 0.5s tolerance
                if abs(userInterval - targetInterval) <= 0.5 {
                    hitSuccesses[hitIndex] = true
                }
            }
        }
        
        if userHitTimestamps.count == targetBeat.intervals.count {
            evaluateRhythm()
        }
    }
    
    private func evaluateRhythm() {
        guard gamePhase == .userTurn else { return }
        gamePhase = .demonstrating
        
        let targetBeat = beats[currentBeatIndex]
        let targetIntervals = targetBeat.intervals
        
        var passed = true
        let tolerance: Double = 0.5
        
        if userHitTimestamps.count != targetIntervals.count {
            passed = false
        } else {
            let firstHit = userHitTimestamps.first ?? 0.0
            let userIntervals = userHitTimestamps.map { $0 - firstHit }
            
            for (index, userInterval) in userIntervals.enumerated() {
                let targetInterval = targetIntervals[index]
                if abs(userInterval - targetInterval) > tolerance {
                    passed = false
                    break
                }
            }
        }
        
        if passed {
            currentDialogueText = "Well done!"
            currentBeatIndex += 1
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if !isNearNPC { return }
                
                if currentBeatIndex < beats.count {
                    startDemonstration()
                } else {
                    gamePhase = .outro
                    outroIndex = 0
                    currentDialogueText = outroDialogues[outroIndex]
                }
            }
        } else {
            currentDialogueText = "Try again!"
            userHitTimestamps.removeAll()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if isNearNPC {
                    startDemonstration()
                }
            }
        }
    }
}
