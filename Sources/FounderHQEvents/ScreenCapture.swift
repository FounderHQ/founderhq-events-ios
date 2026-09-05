#if canImport(UIKit)
import UIKit
import ObjectiveC.runtime

enum FounderHQScreenCapture {
    private static weak var client: FounderHQEvents?
    private static var installed = false

    static func install(client: FounderHQEvents) {
        self.client = client
        guard !installed,
              let original = class_getInstanceMethod(UIViewController.self, #selector(UIViewController.viewDidAppear(_:))),
              let replacement = class_getInstanceMethod(UIViewController.self, #selector(UIViewController.fhq_viewDidAppear(_:))) else { return }
        installed = true
        method_exchangeImplementations(original, replacement)
    }

    static func appeared(_ controller: UIViewController) {
        let name = controller.title ?? String(describing: type(of: controller))
        client?.screen(name)
    }
}

private extension UIViewController {
    @objc func fhq_viewDidAppear(_ animated: Bool) {
        fhq_viewDidAppear(animated)
        FounderHQScreenCapture.appeared(self)
    }
}
#endif
