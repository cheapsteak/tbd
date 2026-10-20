import Foundation
import TBDShared

extension RPCRouter {
    public func registerSubscription(writer: @escaping @Sendable (Data) -> Bool) -> StateSubscriptionManager.SubscriberID {
        subscriptions.addSubscriber(writer)
    }

    public func removeSubscription(id: StateSubscriptionManager.SubscriberID) {
        subscriptions.removeSubscriber(id)
        // The app is the only subscriber, so no subscription left means no app,
        // and its composer drafts went with it.
        if subscriptions.subscriberCount == 0 {
            composerDrafts.clear()
        }
    }
}
