//
//  Timer+Publisher.swift
//
//
//  Created by Sergej Jaskiewicz on 23.06.2020.
//

import CoreFoundation
import Foundation
import OpenCombine

// dgh -- Don't know why but this isn't found by Swift 5.3, probably
//   a library or compiler bug
let kCFStringEncodingUTF8 = 0x08000100

extension Timer {

    /// Returns a publisher that repeatedly emits the current date on the given interval.
    ///
    /// - Parameters:
    ///   - interval: The time interval on which to publish events. For example,
    ///     a value of `0.5` publishes an event approximately every half-second.
    ///   - tolerance: The allowed timing variance when emitting events.
    ///     Defaults to `nil`, which allows any variance.
    ///   - runLoop: The run loop on which the timer runs.
    ///   - mode: The run loop mode in which to run the timer.
    ///   - options: Scheduler options passed to the timer. Defaults to `nil`.
    /// - Returns: A publisher that repeatedly emits the current date on the given
    ///   interval.
    public static func publish(
        every interval: TimeInterval,
        tolerance _: TimeInterval? = nil,
        on runLoop: RunLoop,
        in mode: RunLoop.Mode,
        options: RunLoop.OCombine.SchedulerOptions? = nil
    ) -> OCombine.TimerPublisher {
        // A bug in Combine: tolerance is ignored.
        return .init(interval: interval, runLoop: runLoop, mode: mode, options: options)
    }

    /// A namespace for disambiguation when both OpenCombine and Combine are imported.
    ///
    /// Foundation overlay for Combine extends `Timer` with new methods and nested
    /// types.
    /// If you import both OpenCombine and Foundation, you will not be able
    /// to write `Timer.TimerPublisher`,
    /// because Swift is unable to understand which `TimerPublisher`
    /// you're referring to.
    ///
    /// So you have to write `Timer.OCombine.TimerPublisher`.
    ///
    /// This bug is tracked [here](https://bugs.swift.org/browse/SR-11183).
    ///
    /// You can omit this whenever Combine is not available (e. g. on Linux).
    public enum OCombine {

        /// A publisher that repeatedly emits the current date on a given interval.
        public final class TimerPublisher: ConnectablePublisher {
            public typealias Output = Date
            public typealias Failure = Never

            public let interval: TimeInterval
            public let tolerance: TimeInterval?
            public let runLoop: RunLoop
            public let mode: RunLoop.Mode
            public let options: RunLoop.OCombine.SchedulerOptions?

            private lazy var routingSubscription: RoutingSubscription = {
                RoutingSubscription(parent: self)
            }()

            /// Creates a publisher that repeatedly emits the current date
            /// on the given interval.
            ///
            /// - Parameters:
            ///   - interval: The interval on which to publish events.
            ///   - tolerance: The allowed timing variance when emitting events.
            ///     Defaults to `nil`, which allows any variance.
            ///   - runLoop: The run loop on which the timer runs.
            ///   - mode: The run loop mode in which to run the timer.
            ///   - options: Scheduler options passed to the timer. Defaults to `nil`.
            public init(
                interval: TimeInterval,
                tolerance: TimeInterval? = nil,
                runLoop: RunLoop,
                mode: RunLoop.Mode,
                options: RunLoop.OCombine.SchedulerOptions? = nil
            ) {
                self.interval = interval
                self.tolerance = tolerance
                self.runLoop = runLoop
                self.mode = mode
                self.options = options
            }

            /// Adapter subscription to allow `Timer` to multiplex to multiple subscribers
            /// the values produced by a single `TimerPublisher.Inner`
            private final class RoutingSubscription
                : Subscription,
                  CustomStringConvertible,
                  CustomReflectable,
                  CustomPlaygroundDisplayConvertible
            {
                typealias Input = Date
                typealias Failure = Never

                private typealias ErasedSubscriber = AnySubscriber<Output, Failure>

                private let lock = UnfairLock.allocate()

                // Inner is IUP due to init requirements
                // swiftlint:disable:next implicitly_unwrapped_optional
                private var inner: Inner!

                private var subscribers: [ErasedSubscriber] = []

                private var isConnected = false

                init(parent: TimerPublisher) {
                    inner = Inner(parent: parent, downstream: self)
                }

                deinit {
                    lock.deallocate()
                }

                func addSubscriber<Downstream: Subscriber>(_ downstream: Downstream)
                    where Downstream.Failure == Failure, Downstream.Input == Output
                {
                    lock.lock()
                    subscribers.append(AnySubscriber(downstream))
                    lock.unlock()

                    downstream.receive(subscription: self)
                }

                func receive(_ value: Input) -> Subscribers.Demand {
                    var resultingDemand = Subscribers.Demand.none
                    lock.lock()
                    let subscribers = self.subscribers
                    let isConnected = self.isConnected
                    lock.unlock()

                    guard isConnected else {
                        // This branch is only reachable in case of a race condition.
                        return .none
                    }

                    for subscriber in subscribers {
                        resultingDemand += subscriber.receive(value)
                    }
                    return resultingDemand
                }

                func request(_ demand: Subscribers.Demand) {
                    lock.lock()
                    let inner = self.inner!
                    lock.unlock()

                    inner.request(demand)
                }

                func cancel() {
                    lock.lock()
                    let inner = self.inner!
                    isConnected = false
                    subscribers = []
                    lock.unlock()

                    inner.cancel()
                }

                var description: String { return "Timer" }

                var customMirror: Mirror { return inner.customMirror }

                var playgroundDescription: Any { return description }

                var combineIdentifier: CombineIdentifier {
                    return inner.combineIdentifier
                }

                func startPublishing() {
                    lock.lock()
                    let isConnected = self.isConnected
                    self.isConnected = true
                    let inner = self.inner!
                    lock.unlock()
                    if isConnected { return }
                    inner.startPublishing()
                }
            }

            public func receive<Downstream: Subscriber>(subscriber: Downstream)
                where Failure == Downstream.Failure, Output == Downstream.Input
            {
                routingSubscription.addSubscriber(subscriber)
            }

            public func connect() -> Cancellable {
                routingSubscription.startPublishing()
                return routingSubscription
            }

            private typealias Parent = TimerPublisher

            private final class Inner
                : NSObject,
                  Subscription,
                  CustomReflectable,
                  CustomPlaygroundDisplayConvertible
            {
                private lazy var timer: CFRunLoopTimer? = {
                    let timer = CFRunLoopTimerCreateWithHandler(
                        nil,
                        Date().timeIntervalSinceReferenceDate,
                        parent?.interval ?? 0,
                        0,
                        0,
                        { [weak self] _ in self?.timerFired() }
                    )!
                    CFRunLoopTimerSetTolerance(timer, parent?.tolerance ?? 0)
                    return timer
                }()

                private let lock = UnfairLock.allocate()

                private var downstream: RoutingSubscription?

                private var parent: Parent?

                private var started = false

                private var demand = Subscribers.Demand.none

                init(parent: Parent, downstream: RoutingSubscription) {
                    self.parent = parent
                    self.downstream = downstream
                }

                deinit {
                    lock.deallocate()
                }

                func startPublishing() {
                    lock.lock()
                    guard let timer = self.timer,
                          let parent = self.parent,
                          !started else {
                        lock.unlock()
                        return
                    }

                    started = true
                    lock.unlock()

                    CFRunLoopAddTimer(parent.runLoop.getCFRunLoop(),
                                      timer,
                                      parent.mode.asCFRunLoopMode())
                }

                func cancel() {
                    lock.lock()
                    guard let timer = self.timer else {
                        lock.unlock()
                        return
                    }

                    downstream = nil
                    parent = nil
                    started = false
                    demand = .none
                    self.timer = nil
                    lock.unlock()

                    CFRunLoopTimerInvalidate(timer)
                }

                func request(_ demand: Subscribers.Demand) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard parent != nil else {
                        return
                    }
                    self.demand += demand
                }

                override var description: String { return "Timer" }

                var customMirror: Mirror {
                    lock.lock()
                    defer { lock.unlock() }
                    let children: [Mirror.Child] = [
                        ("downstream", downstream as Any),
                        ("interval", parent?.interval as Any),
                        ("tolerance", parent?.tolerance as Any),
                    ]
                    return Mirror(self, children: children)
                }

                var playgroundDescription: Any { return description }

                private func timerFired() {
                    lock.lock()
                    guard let downstream = self.downstream,
                          parent != nil,
                          demand > 0
                    else {
                        lock.unlock()
                        return
                    }

                    demand -= 1
                    lock.unlock()

                    let newDemand = downstream.receive(Date())
                    guard newDemand > 0 else {
                        return
                    }

                    lock.lock()
                    demand += newDemand
                    lock.unlock()
                }
            }
        }
    }
}

#if !canImport(Combine)
extension Timer {

    /// A publisher that repeatedly emits the current date on a given interval.
    public typealias TimerPublisher = OCombine.TimerPublisher
}
#endif

extension RunLoop.Mode {
    fileprivate func asCFRunLoopMode() -> CFRunLoopMode {
#if canImport(Darwin)
        return CFRunLoopMode(rawValue as CFString)
#else
        return rawValue.withCString {
            CFStringCreateWithCString(
                nil,
                $0,
                CFStringEncoding(kCFStringEncodingUTF8)
            )
        }
#endif
    }
}
