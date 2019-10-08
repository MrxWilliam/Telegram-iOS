import Foundation
import UIKit
import SwiftSignalKit
import AppBundle
import AsyncDisplayKit
import Display
import QrCode
import AnimatedStickerNode

func shareInvoiceQrCode(context: WalletContext, invoice: String) {
    let _ = (qrCode(string: invoice, color: .black, backgroundColor: .white, icon: .custom(UIImage(bundleImageName: "Wallet/QrGem")))
    |> map { generator -> UIImage? in
        let imageSize = CGSize(width: 768.0, height: 768.0)
        let context = generator(TransformImageArguments(corners: ImageCorners(), imageSize: imageSize, boundingSize: imageSize, intrinsicInsets: UIEdgeInsets(), scale: 1.0))
        return context?.generateImage()
    }
    |> deliverOnMainQueue).start(next: { image in
        guard let image = image else {
            return
        }
        
        let activityController = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        context.presentNativeController(activityController)
    })
}

public final class WalletQrViewScreen: ViewController {
    private let context: WalletContext
    private let invoice: String
    private var presentationData: WalletPresentationData
    
    private var previousScreenBrightness: CGFloat?
    private var displayLinkAnimator: DisplayLinkAnimator?
    private let idleTimerExtensionDisposable: Disposable
    
    public init(context: WalletContext, invoice: String) {
        self.context = context
        self.invoice = invoice
        
        self.presentationData = context.presentationData
        
        let defaultTheme = self.presentationData.theme.navigationBar
        let navigationBarTheme = NavigationBarTheme(buttonColor: defaultTheme.buttonColor, disabledButtonColor: defaultTheme.disabledButtonColor, primaryTextColor: defaultTheme.primaryTextColor, backgroundColor: .clear, separatorColor: .clear, badgeBackgroundColor: defaultTheme.badgeBackgroundColor, badgeStrokeColor: defaultTheme.badgeStrokeColor, badgeTextColor: defaultTheme.badgeTextColor)
        
        self.idleTimerExtensionDisposable = context.idleTimerExtension()
        
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: navigationBarTheme, strings: NavigationBarStrings(back: self.presentationData.strings.Wallet_Navigation_Back, close: self.presentationData.strings.Wallet_Navigation_Close)))
        
        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
        self.navigationBar?.intrinsicCanTransitionInline = false
        
        self.title = self.presentationData.strings.Wallet_Qr_Title
        
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Wallet_Navigation_Back, style: .plain, target: nil, action: nil)

        self.navigationItem.rightBarButtonItem = UIBarButtonItem(image:  navigationShareIcon(self.presentationData.theme), style: .plain, target: self, action: #selector(self.shareButtonPressed))
    }
    
    deinit {
        self.idleTimerExtensionDisposable.dispose()
    }
    
    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override public func loadDisplayNode() {
        self.displayNode = WalletQrViewScreenNode(context: self.context, presentationData: self.presentationData, message: self.invoice)
        
        self.displayNodeDidLoad()
    }
    
    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        let screenBrightness = UIScreen.main.brightness
        if screenBrightness < 0.85 {
            self.previousScreenBrightness = screenBrightness
            self.displayLinkAnimator = DisplayLinkAnimator(duration: 0.5, from: screenBrightness, to: 0.85, update: { value in
                UIScreen.main.brightness = value
            }, completion: {
                self.displayLinkAnimator = nil
            })
        }
    }
    
    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        let screenBrightness = UIScreen.main.brightness
        if let previousScreenBrightness = self.previousScreenBrightness, screenBrightness > previousScreenBrightness {
            self.displayLinkAnimator = DisplayLinkAnimator(duration: 0.2, from: screenBrightness, to: previousScreenBrightness, update: { value in
                UIScreen.main.brightness = value
            }, completion: {
                self.displayLinkAnimator = nil
            })
        }
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        (self.displayNode as! WalletQrViewScreenNode).containerLayoutUpdated(layout: layout, navigationHeight: self.navigationHeight, transition: transition)
    }
    
    @objc private func shareButtonPressed() {
        shareInvoiceQrCode(context: self.context, invoice: self.invoice)
    }
}

private final class WalletQrViewScreenNode: ViewControllerTracingNode {
    private var presentationData: WalletPresentationData
    private let invoice: String
    
    private let imageNode: TransformImageNode
    private let iconNode: AnimatedStickerNode
  
    init(context: WalletContext, presentationData: WalletPresentationData, message: String) {
        self.presentationData = presentationData
        self.invoice = message
        
        self.imageNode = TransformImageNode()
        self.imageNode.clipsToBounds = true
        self.imageNode.cornerRadius = 14.0
        
        self.iconNode = AnimatedStickerNode()
        if let path = getAppBundle().path(forResource: "WalletIntroStatic", ofType: "tgs") {
            self.iconNode.setup(source: AnimatedStickerNodeLocalFileSource(path: path), width: 240, height: 240, mode: .direct)
            self.iconNode.visibility = true
        }
        
        super.init()
        
        self.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
        
        self.addSubnode(self.imageNode)
        self.addSubnode(self.iconNode)
        
        self.imageNode.setSignal(qrCode(string: self.invoice, color: .black, backgroundColor: .white, icon: .cutout), attemptSynchronously: true)
    }
    
    func containerLayoutUpdated(layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        let makeImageLayout = self.imageNode.asyncLayout()
        
        let imageSide = layout.size.width - 48.0 * 2.0
        var imageSize = CGSize(width: imageSide, height: imageSide)
        let imageApply = makeImageLayout(TransformImageArguments(corners: ImageCorners(), imageSize: imageSize, boundingSize: imageSize, intrinsicInsets: UIEdgeInsets(), emptyColor: nil))
        
        let _ = imageApply()
        
        let imageFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - imageSize.width) / 2.0), y: floor((layout.size.height - imageSize.height - layout.intrinsicInsets.bottom) / 2.0)), size: imageSize)
        transition.updateFrame(node: self.imageNode, frame: imageFrame)
        
        let iconSide = floor(imageSide * 0.24)
        let iconSize = CGSize(width: iconSide, height: iconSide)
        self.iconNode.updateLayout(size: iconSize)
        transition.updateBounds(node: self.iconNode, bounds: CGRect(origin: CGPoint(), size: iconSize))
        transition.updatePosition(node: self.iconNode, position: imageFrame.center.offsetBy(dx: 0.0, dy: -1.0))
    }
}