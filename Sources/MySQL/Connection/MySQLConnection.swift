import Crypto
import NIO
import NIOOpenSSL

/// A MySQL frontend client.
public final class MySQLConnection: BasicWorker, DatabaseConnection {
    /// See `DatabaseConnection`.
    public typealias Database = MySQLDatabase
    
    /// See `Worker`.
    public var eventLoop: EventLoop {
        return channel.eventLoop
    }

    /// See `DatabaseConnection`.
    public var isClosed: Bool
    
    /// If non-nil, will log queries.
    public var logger: DatabaseLogger?
    
    /// Pointer to the last metadata returned from a call to `query(...)` or `simpleQuery(...)`.
    /// See `MySQLQueryMetadata` for more information.
    public var lastMetadata: Metadata?
    
    /// See `Extendable`
    public var extend: Extend

    /// Handles enqueued redis commands and responses.
    private let handler: MySQLConnectionHandler

    /// The channel
    private let channel: Channel

    /// Currently running `send(...)`.
    private var currentSend: Promise<Void>?
    
    /// Close has been requested.
    private var isClosing: Bool

    /// Creates a new MySQL client with the provided MySQL packet queue and channel.
    internal init(handler: MySQLConnectionHandler, channel: Channel) {
        self.handler = handler
        self.channel = channel
        self.extend = [:]
        self.isClosed = false
        self.isClosing = false

        // when the channel closes, set isClosed to true and fail any
        // currently running calls to `send(...)`.
        channel.closeFuture.always {
            self.isClosed = true
            if let current = self.currentSend {
                if self.isClosing {
                    // if we're closing, this is the close's current send
                    // so complete it!
                    current.succeed()
                } else {
                    // if currently sending, fail it
                    current.fail(error: closeError)
                }
            } else if let rfq = handler.readyForQuery {
                // connection is closing, the handler is not going to be ready for query
                rfq.fail(error: closeError)
            }
        }
    }

    /// Sends `MySQLPacket` to the server.
    internal func send(_ messages: [MySQLPacket], onResponse: @escaping (MySQLPacket) throws -> Bool) -> Future<Void> {
        // if the connection is closed, fail immidiately
        guard !isClosed else {
            return eventLoop.newFailedFuture(error: closeError)
        }
        
        // if currentSend is not nil, previous send has not completed
        assert(currentSend == nil, "Attempting to call `send(...)` again before previous invocation has completed.")
        switch handler.state {
        case .waiting: break
        default: assertionFailure("Attempting to call `send(...)` while handler is still: \(handler.state).")
        }
        
        // create a new promise and store it
        let promise = eventLoop.newPromise(Void.self)
        currentSend = promise
        
        handler.state = .callback(promise) { packet in
            switch packet {
            case .ok(let ok): self.lastMetadata = .init(ok)
            case .err(let err): throw err.makeError(source: .capture())
            default: break
            }
            return try onResponse(packet)
        }
        for message in messages {
            // if any writes fail, we need to fail the current send promise
            let writePromise = eventLoop.newPromise(Void.self)
            writePromise.futureResult.whenFailure { error in
                promise.fail(error: error)
            }
            channel.write(handler.wrapOutboundOut(message), promise: writePromise)
        }
        channel.flush()
        
        // FIXME: parse metadata from ok packet
        
        promise.futureResult.always { self.currentSend = nil }
        return promise.futureResult
    }
    
    /// See `DatabaseConnectable`.
    public func close() {
        self.close(done: nil)
    }
    
    /// Closes this client.
    public func close(done promise: Promise<Void>?) {
        assert(currentSend == nil, "Cannot close while sending.")
        self.isClosing = true
        let done = send([.quit]) { packet in
            return true
        }
        if let promise = promise {
            done.cascade(promise: promise)
        } else {
            // potentially warn about closing without waiting
        }
    }
}

/// Error to throw if the connection has closed.
private let closeError = MySQLError(identifier: "closed", reason: "Connection is closed.", source: .capture())
