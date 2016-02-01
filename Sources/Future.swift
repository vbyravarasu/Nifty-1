//
//  Future.swift
//  Nifty
//
//  Copyright © 2016 ElvishJerricco. All rights reserved.
//

import DispatchKit

// MARK: Promise

public class Promise<T> {
    private var state: Either<T, [T -> ()]> = .Right([])
    private let completionQueue: DispatchQueue = DispatchQueue("Nifty.Promise.completionQueue") // serial queue
    
    public init() {
    }
    
    private func onComplete(handler: T -> ()) {
        completionQueue.async {
            switch self.state {
            case .Left(let completed):
                Dispatch.globalQueue.async {
                    handler(completed)
                }
            case .Right(let handlers):
                self.state = .Right(handlers + handler)
            }
        }
    }
    
    public func complete(t: T, queue: DispatchQueue = Dispatch.globalQueue) {
        completionQueue.async {
            switch self.state {
            case .Left:
                fatalError("Attempted to complete completed promise")
            case .Right(let handlers):
                self.state = .Left(t)
                // queue.apply is blocking
                queue.apply(handlers.count) { index in
                    // Note: There is a potential deadlock here at queue.apply when queue targets completionQueue.
                    // This is because completionQueue is serial, so queue can't have blocks running at this time.
                    // The same deadlock would be caused when completionQueue targets queue if queue is serial.
                    // However, this deadlock IS NOT possible.
                    // CompletionQueue is never handed out to become targeted, nor is its target set.
                    // It does have an implicit target of some global queue.
                    // But global queues are always concurrent, so they won't cause this deadlock.
                    handlers[index](t)
                }
            }
        }
    }
    
    public var future: Future<T> {
        return Future(Continuation(self.onComplete))
    }
}

// MARK: Future

public struct Future<T> {
    public let cont: Continuation<(), T>
    public init(_ cont: Continuation<(), T>) {
        self.cont = cont
    }
    public init(_ cont: (T -> ()) -> ()) {
        self.cont = Continuation(cont)
    }
}

// MARK: Functor

public extension Future {
    public func map<U>(f: T -> U) -> Future<U> {
        return Future<U>(self.cont.map(f))
    }
}

public func <^><T, U>(f: T -> U, future: Future<T>) -> Future<U> {
    return future.map(f)
}

// MARK: Applicative

public extension Future {
    public func apply<U>(futureFunc: Future<T -> U>) -> Future<U> {
        return Future<U>(self.cont.apply(futureFunc.cont))
    }
}

public func <*><A, B>(f: Future<A -> B>, a: Future<A>) -> Future<B> {
    return a.apply(f)
}

// MARK: Monad

public extension Future {
    public static func of<T>(t: T) -> Future<T> {
        return Future<T>(Continuation.of(t))
    }

    public func flatMap<U>(f: T -> Future<U>) -> Future<U> {
        return Future<U>(self.cont.flatMap { f($0).cont })
    }
}

public func >>==<T, U>(future: Future<T>, f: T -> Future<U>) -> Future<U> {
    return future.flatMap(f)
}

// MARK: Run

public extension Future {
    public func onComplete(handler: T -> ()) {
        cont.run(handler)
    }
}

// MARK: Dispatch Integration

public extension DispatchQueue {
    public func future<T>(f: () -> T) -> Future<T> {
        let promise = Promise<T>()
        self.async {
            // promise.complete is non-blocking. No deadlock for using self inside a dispatch on self when self is serial
            promise.complete(f(), queue: self)
        }
        return promise.future
    }

    public func barrierFuture<T>(f: () -> T) -> Future<T> {
        let promise = Promise<T>()
        self.barrierAsync {
            // promise.complete is non-blocking. No deadlock for using self inside a dispatch on self when self is serial
            promise.complete(f(), queue: self)
        }
        return promise.future
    }
}

public extension DispatchGroup {
    public func future<T>(queue: DispatchQueue, f: () -> T) -> Future<T> {
        let promise = Promise<T>()
        self.notify(queue) {
            // promise.complete is non-blocking. No deadlock for using queue inside a dispatch on queue when queue is serial
            promise.complete(f(), queue: queue)
        }
        return promise.future
    }
}

public extension Future {
    public func wait() -> T {
        return wait(.Forever)!
    }
    
    public func wait(time: DispatchTime) -> T? {
        var t: T? = nil
        let semaphore = DispatchSemaphore(0)
        
        onComplete { completed in
            t = completed
            semaphore.signal()
        }
        
        semaphore.wait(time)
        
        return t
    }
}