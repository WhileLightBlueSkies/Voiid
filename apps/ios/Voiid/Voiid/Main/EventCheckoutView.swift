import SwiftUI
import Razorpay

/// SDK callbacks only finish checkout presentation; the server confirms ticket issuance.
struct EventCheckoutView: UIViewControllerRepresentable {
    let checkout: EventService.Checkout
    let completion: (Bool) -> Void
    func makeUIViewController(context: Context) -> CheckoutController {
        CheckoutController(checkout: checkout, completion: completion)
    }
    func updateUIViewController(_ controller: CheckoutController, context: Context) {}
}

final class CheckoutController: UIViewController, RazorpayPaymentCompletionProtocol {
    private let checkout: EventService.Checkout
    private let completion: (Bool) -> Void
    private var gateway: RazorpayCheckout?
    private var started = false
    private var finished = false
    init(checkout: EventService.Checkout, completion: @escaping (Bool) -> Void) {
        self.checkout = checkout; self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }; started = true
        guard checkout.amount > 0, checkout.order_id.hasPrefix("order_"), checkout.key.hasPrefix("rzp_") else {
            finish(false); return
        }
        gateway = RazorpayCheckout.initWithKey(checkout.key, andDelegate: self)
        gateway?.open([
            "order_id": checkout.order_id, "amount": checkout.amount,
            "currency": checkout.currency, "name": "Voiid",
            "description": checkout.description ?? "Event tickets",
            "theme": ["color": "#13828C"]
        ], displayController: self)
    }
    func onPaymentSuccess(_ payment_id: String) { finish(true) }
    func onPaymentError(_ code: Int32, description str: String, andData response: [AnyHashable: Any]) { finish(false) }
    private func finish(_ submitted: Bool) {
        guard !finished else { return }; finished = true
        completion(submitted)
    }
}
