import Foundation
import TBDShared

extension RPCRouter {
    public func registerSubscription(writer: @escaping @Sendable (Data) -> Bool) -> StateSubscriptionManager.SubscriberID {
        subscriptions.addSubscriber(writer)
    }

    public func removeSubscription(id: StateSubscriptionManager.SubscriberID) {
        subscriptions.removeSubscriber(id)
    }

    /// A new subscriber's catch-up: the pending set of every terminal holding
    /// a capture or an open prompt, sent to that subscriber alone. The socket
    /// server calls it after writing the subscription's ack.
    public func replayPendingPrompts(to id: StateSubscriptionManager.SubscriberID) async {
        await subscriptions.replayPendingPrompts(to: id, from: pendingQuestions)
    }
}
