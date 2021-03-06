import Foundation
import UIKit
import Display
import AsyncDisplayKit
import Postbox
import RLottieBinding
import AppBundle
import GZip
import SwiftSignalKit

public final class ManagedAnimationState {
    public let item: ManagedAnimationItem
    
    private let instance: LottieInstance
    
    let frameCount: Int
    let fps: Double
    
    var relativeTime: Double = 0.0
    public var frameIndex: Int?
    
    private let renderContext: DrawingContext
    
    public init?(displaySize: CGSize, item: ManagedAnimationItem, current: ManagedAnimationState?) {
        let resolvedInstance: LottieInstance
        let renderContext: DrawingContext
        
        if let current = current {
            resolvedInstance = current.instance
            renderContext = current.renderContext
        } else {
            guard let path = item.source.path else {
                return nil
            }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                return nil
            }
            guard let unpackedData = TGGUnzipData(data, 5 * 1024 * 1024) else {
                return nil
            }
            guard let instance = LottieInstance(data: unpackedData, cacheKey: item.source.cacheKey) else {
                return nil
            }
            resolvedInstance = instance
            renderContext = DrawingContext(size: displaySize, scale: UIScreenScale, premultiplied: true, clear: true)
        }
        
        self.item = item
        self.instance = resolvedInstance
        self.renderContext = renderContext
        
        self.frameCount = Int(self.instance.frameCount)
        self.fps = Double(self.instance.frameRate)
    }
    
    func draw() -> UIImage? {
        self.instance.renderFrame(with: Int32(self.frameIndex ?? 0), into: self.renderContext.bytes.assumingMemoryBound(to: UInt8.self), width: Int32(self.renderContext.size.width * self.renderContext.scale), height: Int32(self.renderContext.size.height * self.renderContext.scale), bytesPerRow: Int32(self.renderContext.bytesPerRow))
        return self.renderContext.generateImage()
    }
}

public struct ManagedAnimationFrameRange: Equatable {
    var startFrame: Int
    var endFrame: Int
    
    public init(startFrame: Int, endFrame: Int) {
        self.startFrame = startFrame
        self.endFrame = endFrame
    }
}

public enum ManagedAnimationSource: Equatable {
    case local(String)
    case resource(MediaBox, MediaResource)
    
    var cacheKey: String {
        switch self {
            case let .local(name):
                return name
            case let .resource(_, resource):
                return resource.id.uniqueId
        }
    }
    
    var path: String? {
        switch self {
            case let .local(name):
                return getAppBundle().path(forResource: name, ofType: "tgs")
            case let .resource(mediaBox, resource):
                return mediaBox.completedResourcePath(resource)
        }
    }
    
    public static func == (lhs: ManagedAnimationSource, rhs: ManagedAnimationSource) -> Bool {
        switch lhs {
            case let .local(lhsPath):
                if case let .local(rhsPath) = rhs, lhsPath == rhsPath {
                    return true
                } else {
                    return false
                }
            case let .resource(lhsMediaBox, lhsResource):
                if case let .resource(rhsMediaBox, rhsResource) = rhs, lhsMediaBox === rhsMediaBox, lhsResource.isEqual(to: rhsResource) {
                    return true
                } else {
                    return false
                }
        }
    }
}

public struct ManagedAnimationItem: Equatable {
    public let source: ManagedAnimationSource
    var frames: ManagedAnimationFrameRange
    var duration: Double
    var loop: Bool
    
    public init(source: ManagedAnimationSource, frames: ManagedAnimationFrameRange, duration: Double, loop: Bool = false) {
        self.source = source
        self.frames = frames
        self.duration = duration
        self.loop = loop
    }
}

open class ManagedAnimationNode: ASDisplayNode {
    public let intrinsicSize: CGSize
    
    private let imageNode: ASImageNode
    private let displayLink: CADisplayLink
    
    public var state: ManagedAnimationState?
    public var trackStack: [ManagedAnimationItem] = []
    public var didTryAdvancingState = false
    
    public init(size: CGSize) {
        self.intrinsicSize = size
        
        self.imageNode = ASImageNode()
        self.imageNode.displayWithoutProcessing = true
        self.imageNode.displaysAsynchronously = false
        self.imageNode.frame = CGRect(origin: CGPoint(), size: self.intrinsicSize)
        
        final class DisplayLinkTarget: NSObject {
            private let f: () -> Void
            
            init(_ f: @escaping () -> Void) {
                self.f = f
            }
            
            @objc func event() {
                self.f()
            }
        }
        var displayLinkUpdate: (() -> Void)?
        self.displayLink = CADisplayLink(target: DisplayLinkTarget {
            displayLinkUpdate?()
        }, selector: #selector(DisplayLinkTarget.event))
        
        super.init()
        
        self.addSubnode(self.imageNode)
        
        self.displayLink.add(to: RunLoop.main, forMode: .common)
        
        displayLinkUpdate = { [weak self] in
            self?.updateAnimation()
        }
    }
    
    open func advanceState() {
        guard !self.trackStack.isEmpty else {
            return
        }
        
        let item = self.trackStack.removeFirst()
        
        if let state = self.state, state.item.source == item.source {
            self.state = ManagedAnimationState(displaySize: self.intrinsicSize, item: item, current: state)
        } else {
            self.state = ManagedAnimationState(displaySize: self.intrinsicSize, item: item, current: nil)
        }
        
        self.didTryAdvancingState = false
    }
    
    public func updateAnimation() {
        if self.state == nil {
            self.advanceState()
        }
        
        guard let state = self.state else {
            return
        }
        let timestamp = CACurrentMediaTime()
        
        let fps = state.fps
        let frameRange = state.item.frames
        
        let duration: Double = state.item.duration
        var t = state.relativeTime / duration
        t = max(0.0, t)
        t = min(1.0, t)
        //print("\(t) \(state.item.name)")
        let frameOffset = Int(Double(frameRange.startFrame) * (1.0 - t) + Double(frameRange.endFrame) * t)
        let lowerBound: Int = 0
        let upperBound = state.frameCount - 1
        let frameIndex = max(lowerBound, min(upperBound, frameOffset))
        
        if state.frameIndex != frameIndex {
            state.frameIndex = frameIndex
            if let image = state.draw() {
                self.imageNode.image = image
            }
        }
        
        var animationAdvancement: Double = 1.0 / 60.0
        animationAdvancement *= Double(min(2, self.trackStack.count + 1))
        
        state.relativeTime += animationAdvancement
        
        if state.relativeTime >= duration && !self.didTryAdvancingState {
            if state.item.loop && self.trackStack.isEmpty {
                state.frameIndex = nil
                state.relativeTime = 0.0
            } else {
                self.didTryAdvancingState = true
                self.advanceState()
            }
        }
    }
    
    public func trackTo(item: ManagedAnimationItem) {
        self.trackStack.append(item)
        self.didTryAdvancingState = false
        self.updateAnimation()
    }
}
