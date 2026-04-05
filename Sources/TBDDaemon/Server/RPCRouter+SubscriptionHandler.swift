import Foundation
import TBDShared

extension RPCRouter {
    public func registerSubscription(writer: @escaping @Sendable (Data) -> Bool) -> StateSubscriptionManager.SubscriberID {
        subscriptions.addSubscriber(writer)
    }

    public func removeSubscription(id: StateSubscriptionManager.SubscriberID) {
        subscriptions.removeSubscriber(id)
    }
}
