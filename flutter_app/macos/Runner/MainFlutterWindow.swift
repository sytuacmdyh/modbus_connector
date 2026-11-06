import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.contentMinSize = NSSize(width: 900, height: 650)
    let contentSize = flutterViewController.view.frame.size
    self.setContentSize(NSSize(
      width: max(contentSize.width, 900),
      height: max(contentSize.height, 650)
    ))

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
