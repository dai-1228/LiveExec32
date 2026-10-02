#import <StoreKit/StoreKit.h>
#import <objc/runtime.h>

/*
 * Legacy identifier-based payment creation, kept guest-local.
 *
 * mfm's shop reaches +[SKPayment paymentWithProductIdentifier:] on every
 * buy button with hardcoded 2013 product identifiers, ungated on products
 * having loaded (GameIAPLayer dismissAlertViewWithOK:, GameCellButton),
 * so the path is live even though the identifiers will never resolve.  The
 * generated shim forwards the selector to the host StoreKit, which makes
 * two unproven assumptions: that the host process has StoreKit loaded at
 * all (nothing links or dlopens it - unlike GameKit/AVFoundation there is
 * no host-side dependency and no LC32LoadHostFramework call), and that the
 * NS_DEPRECATED_IOS(3_0, 5_0) class method survives on a host that does.
 * Without the image the bridge's guest-mirror dispatch no-ops the call;
 * with the image but without the selector it raises an unrecognized
 * selector through the host exception net.
 *
 * Build the payment through SKMutablePayment instead: its mutable setters
 * are the modern, non-deprecated surface that the current host still
 * implements, and the resulting object carries the same identifier/quantity
 * defaults the legacy factory produced.  When host StoreKit is loaded the
 * payment reaches the real queue and the inevitable failure returns
 * through paymentQueue:updatedTransactions: into the app's
 * failedTransaction: branch (IAProductPurchaseFailed), the same designed
 * outcome; without it every downstream call is already a nil-receiver
 * no-op, so an inert payment object changes nothing.
 *
 * The adapter method carries an lc32_ name and replaces the generated
 * forwarder from +load, following the legacy-alert adapter's pattern: the
 * generated sources cannot be edited, and a same-named category would rely
 * on formally undefined attach precedence.
 */
@implementation SKPayment (LC32LegacyPayments)

+ (void)load {
    static const char *const publicName =
        "paymentWithProductIdentifier:";
    static const char *const adapterName =
        "lc32_paymentWithProductIdentifier:";

    Method original = class_getClassMethod(
        self, sel_registerName(publicName));
    Method adapter = class_getClassMethod(
        self, sel_registerName(adapterName));
    if(!adapter) return;
    Class metaclass = object_getClass(self);
    SEL publicSelector = sel_registerName(publicName);
    if(original) {
        class_replaceMethod(metaclass, publicSelector,
            method_getImplementation(adapter),
            method_getTypeEncoding(original));
    } else {
        /* A future generator run may skip-list this deprecated selector;
         * install the adapter directly then. */
        class_addMethod(metaclass, publicSelector,
            method_getImplementation(adapter),
            method_getTypeEncoding(adapter));
    }
}

+ (id)lc32_paymentWithProductIdentifier:(NSString *)productIdentifier {
    SKMutablePayment *payment = [[SKMutablePayment alloc] init];
    payment.productIdentifier = productIdentifier;
    /* The legacy factory defaulted to a single item; SKMutablePayment
     * leaves the property at zero, which the payment queue rejects as
     * malformed before it can deliver the designed failure callback. */
    payment.quantity = 1;
    return payment;
}

@end
