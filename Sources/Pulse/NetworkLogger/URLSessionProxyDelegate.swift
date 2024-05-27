// The MIT License (MIT)
//
// Copyright (c) 2020-2024 Alexander Grebenyuk (github.com/kean).

import Foundation

/// Automates URLSession request tracking.
///
/// - important: On iOS 16.0, tvOS 16.0, macOS 13.0, watchOS 9.0, it automatically
/// tracks new task creation using the `urlSession(_:didCreateTask:)` delegate
/// method which allows the logger to start tracking network requests right
/// after their creation. On earlier versions, you can (optionally) call
/// ``NetworkLogger/logTaskCreated(_:)`` manually.
public final class URLSessionProxyDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, URLSessionDownloadDelegate {
    private let actualDelegate: URLSessionDelegate?
    private let taskDelegate: URLSessionTaskDelegate?
    private var interceptedSelectors: Set<Selector>
    private let logger: NetworkLogger

    /// - parameter logger: By default, creates a logger with `LoggerStore.shared`.
    /// - parameter delegate: The "actual" session delegate, strongly retained.
    public init(logger: NetworkLogger = .init(), delegate: URLSessionDelegate? = nil) {
        self.actualDelegate = delegate
        self.taskDelegate = delegate as? URLSessionTaskDelegate
        self.logger = logger
        self.interceptedSelectors = [
            #selector(URLSessionDataDelegate.urlSession(_:dataTask:didReceive:)),
            #selector(URLSessionTaskDelegate.urlSession(_:task:didCompleteWithError:)),
            #selector(URLSessionTaskDelegate.urlSession(_:task:didFinishCollecting:)),
            #selector(URLSessionTaskDelegate.urlSession(_:task:didSendBodyData:totalBytesSent:totalBytesExpectedToSend:)),
            #selector(URLSessionDownloadDelegate.urlSession(_:downloadTask:didFinishDownloadingTo:)),
            #selector(URLSessionDownloadDelegate.urlSession(_:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:)),
        ]
        if #available(iOS 16.0, tvOS 16.0, macOS 13.0, watchOS 9.0, *) {
            self.interceptedSelectors.insert(
                #selector(URLSessionTaskDelegate.urlSession(_:didCreateTask:))
            )
        }
    }

    // MARK: URLSessionTaskDelegate

    public func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        logger.logTaskCreated(task)
        if #available(iOS 16.0, tvOS 16.0, macOS 13.0, watchOS 9.0, *) {
            taskDelegate?.urlSession?(session, didCreateTask: task)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        logger.logTask(task, didCompleteWithError: error)
        taskDelegate?.urlSession?(session, task: task, didCompleteWithError: error)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        logger.logTask(task, didFinishCollecting: metrics)
        taskDelegate?.urlSession?(session, task: task, didFinishCollecting: metrics)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if task is URLSessionUploadTask {
            logger.logTask(task, didUpdateProgress: (completed: totalBytesSent, total: totalBytesExpectedToSend))
        }
        (actualDelegate as? URLSessionTaskDelegate)?.urlSession?(session, task: task, didSendBodyData: bytesSent, totalBytesSent: totalBytesSent, totalBytesExpectedToSend: totalBytesExpectedToSend)
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        logger.logDataTask(dataTask, didReceive: data)
        (actualDelegate as? URLSessionDataDelegate)?.urlSession?(session, dataTask: dataTask, didReceive: data)
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        (actualDelegate as? URLSessionDownloadDelegate)?.urlSession(session, downloadTask: downloadTask, didFinishDownloadingTo: location)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        logger.logTask(downloadTask, didUpdateProgress: (completed: totalBytesWritten, total: totalBytesExpectedToWrite))
        (actualDelegate as? URLSessionDownloadDelegate)?.urlSession?(session, downloadTask: downloadTask, didWriteData: bytesWritten, totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
    }

    // MARK: Proxy

    public override func responds(to aSelector: Selector!) -> Bool {
        if interceptedSelectors.contains(aSelector) {
            return true
        }
        return (actualDelegate?.responds(to: aSelector) ?? false) || super.responds(to: aSelector)
    }

    public override func forwardingTarget(for selector: Selector!) -> Any? {
        interceptedSelectors.contains(selector) ? nil : actualDelegate
    }
}

// MARK: - Automatic Registration

private extension URLSession {
    @objc class func pulse_init(configuration: URLSessionConfiguration, delegate: URLSessionDelegate?, delegateQueue: OperationQueue?) -> URLSession {
        guard !String(describing: delegate).contains("GTMSessionFetcher") else {
             return original_init(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        }
        configuration.protocolClasses = [URLSessionMockingProtocol.self] + (configuration.protocolClasses ?? [])
        guard let sharedLogger else {
            assertionFailure("Shared logger is missing")
            return original_init(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        }
        let delegate = URLSessionProxyDelegate(logger: sharedLogger, delegate: delegate)
        return original_init(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
    }

    @objc class func original_init(configuration: URLSessionConfiguration, delegate: URLSessionDelegate?, delegateQueue: OperationQueue?) -> URLSession {
        fatalError("not implemented")
    }
}

private var sharedLogger: NetworkLogger? {
    get { _sharedLogger.value }
    set { _sharedLogger.value = newValue }
}
private let _sharedLogger = Atomic<NetworkLogger?>(value: nil)

public extension URLSessionProxyDelegate {
    /// Enables automatic registration of `URLSessionProxyDelegate`. After calling this method, every time
    /// you initialize a `URLSession` using `init(configuration:delegate:delegateQueue:))` method, the
    /// delegate will automatically get replaced with a `URLSessionProxyDelegate` that logs all the
    /// needed events and forwards the methods to your original delegate.
    static func enableAutomaticRegistration(logger: NetworkLogger = .init()) {
        sharedLogger = logger

        guard let originalMethod = class_getClassMethod(URLSession.self, #selector(URLSession.init(configuration:delegate:delegateQueue:))),
              let swizzledMethod = class_getClassMethod(URLSession.self, #selector(URLSession.pulse_init(configuration:delegate:delegateQueue:))),
              let originalPlaceholder = class_getClassMethod(URLSession.self, #selector(URLSession.original_init(configuration:delegate:delegateQueue:)))
        else {
            return
        }

        /// save original `URLSession.init(configuration:delegate:delegateQueue:)` implementation
        /// inside `original_init` method
        method_exchangeImplementations(originalMethod, originalPlaceholder)

        /// replace mocked `origina_init` implementation with `pulse_init` implementation for
        /// `URLSession.init(configuration:delegate:delegateQueue:)`
        method_setImplementation(originalMethod, method_getImplementation(swizzledMethod))
    }
}

