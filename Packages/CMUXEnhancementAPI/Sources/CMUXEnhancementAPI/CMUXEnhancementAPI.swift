import Foundation

public struct CMUXEnhancementManifest: Equatable {
    public var id: String
    public var name: String?
    public var version: String?
    public var apiVersion: String
    public var activation: [String]
    public var permissions: [String]

    public init(
        id: String,
        name: String? = nil,
        version: String? = nil,
        apiVersion: String = "0.1",
        activation: [String] = [],
        permissions: [String] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.apiVersion = apiVersion
        self.activation = activation
        self.permissions = permissions
    }
}

public protocol CMUXEnhancement {
    var manifest: CMUXEnhancementManifest { get }

    func activate(context: CMUXEnhancementContext) throws
    func deactivate()
}

public extension CMUXEnhancement {
    func deactivate() {}
}

public protocol CMUXEnhancementContext {
    var logger: CMUXEnhancementLogger { get }
    var actions: CMUXEnhancementActionRegistry { get }
    var scheduler: CMUXEnhancementScheduler { get }
}

public protocol CMUXEnhancementLogger {
    func debug(_ message: String)
    func info(_ message: String)
    func warning(_ message: String)
    func error(_ message: String)
}

public protocol CMUXEnhancementDisposable {
    func dispose()
}

public final class CMUXEnhancementBlockDisposable: CMUXEnhancementDisposable {
    private let lock = NSLock()
    private var onDispose: (() -> Void)?

    public init(_ onDispose: @escaping () -> Void) {
        self.onDispose = onDispose
    }

    public func dispose() {
        lock.lock()
        let action = onDispose
        onDispose = nil
        lock.unlock()
        action?()
    }
}

public struct CMUXEnhancementAction {
    public var id: String
    public var source: String
    public var params: [String: Any]
    public var payload: Any?

    public init(
        id: String,
        source: String,
        params: [String: Any] = [:],
        payload: Any? = nil
    ) {
        self.id = id
        self.source = source
        self.params = params
        self.payload = payload
    }
}

public enum CMUXEnhancementActionDisposition: Equatable {
    case handled
    case `continue`
}

public protocol CMUXEnhancementActionInterceptor {
    var id: String { get }
    var actionIds: Set<String> { get }
    var priority: Int { get }

    func intercept(
        action: CMUXEnhancementAction,
        proceed: @escaping (CMUXEnhancementAction) -> Void
    ) throws -> CMUXEnhancementActionDisposition
}

public extension CMUXEnhancementActionInterceptor {
    var priority: Int { 0 }
}

public protocol CMUXEnhancementActionRegistry {
    @discardableResult
    func registerInterceptor(_ interceptor: CMUXEnhancementActionInterceptor) -> CMUXEnhancementDisposable

    @discardableResult
    func dispatch(
        _ action: CMUXEnhancementAction,
        fallback: @escaping (CMUXEnhancementAction) -> Void
    ) -> Bool
}

public protocol CMUXEnhancementScheduler {
    func async(execute work: @escaping () -> Void)
    func asyncAfter(delay: TimeInterval, execute work: @escaping () -> Void) -> CMUXEnhancementDisposable
}
