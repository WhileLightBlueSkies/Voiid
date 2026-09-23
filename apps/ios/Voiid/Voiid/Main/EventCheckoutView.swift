import AuthenticationServices
import SwiftUI
import Razorpay

/// Presents the payment provider's checkout. Whatever it reports only closes the sheet — the
/// SERVER confirms payment (the signed webhook), and the caller polls it for the ticket.
///
/// Cashfree is not an SDK in this app: `checkout_url` is a page on our API that loads Cashfree's
/// own hosted checkout. It opens in an `ASWebAuthenticationSession` — Safari's engine, so UPI
/// apps, saved cards and bank pages behave as they do in Safari — and closes itself when the
/// page redirects to `voiid-pay://return`. That scheme needs no Info.plist entry: the session
/// intercepts it before the system would look for an app.
struct EventCheckoutView: UIViewControllerRepresentable {
    let checkout: EventService.Checkout
    let completion: (Bool) -> Void
    func makeUIViewController(context: Context) -> CheckoutController {
        CheckoutController(checkout: checkout, completion: completion)
    }
    func updateUIViewController(_ controller: CheckoutController, context: Context) {}
}

final class CheckoutController: UIViewController, RazorpayPaymentCompletionProtocol,
                                ASWebAuthenticationPresentationContextProviding {
    private let checkout: EventService.Checkout
    private let completion: (Bool) -> Void
    private var gateway: RazorpayCheckout?
    private var webSession: ASWebAuthenticationSession?
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
        guard checkout.amount > 0 else { finish(false); return }
        if checkout.isCashfree { openCashfree() } else { openRazorpay() }
    }

    // MARK: Cashfree

    private func openCashfree() {
        // Only ever our own API's checkout page, over https — never a URL that could send the
        // buyer somewhere else to type card details.
        guard let raw = checkout.checkout_url, let url = URL(string: raw),
              url.scheme == "https", url.path.hasPrefix("/payments/checkout/cashfree/") else {
            finish(false); return
        }
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "voiid-pay") { [weak self] callback, _ in
            // A callback means Cashfree sent the buyer back after an attempt; a cancel means they
            // closed the sheet. Either way the server decides, so both just end presentation —
            // `true` only makes the caller wait longer for the webhook.
            DispatchQueue.main.async { self?.finish(callback != nil) }
        }
        session.presentationContextProvider = self
        // Share cookies with Safari so a bank's saved session or a UPI handoff works normally.
        session.prefersEphemeralWebBrowserSession = false
        webSession = session
        if !session.start() { finish(false) }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        view.window ?? ASPresentationAnchor()
    }

    // MARK: Razorpay

    private func openRazorpay() {
        guard let key = checkout.key, let orderId = checkout.order_id,
              orderId.hasPrefix("order_"), key.hasPrefix("rzp_") else {
            finish(false); return
        }
        gateway = RazorpayCheckout.initWithKey(key, andDelegate: self)
        gateway?.open([
            "order_id": orderId, "amount": checkout.amount,
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
