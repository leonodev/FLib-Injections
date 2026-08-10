// The Swift Programming Language
// https://docs.swift.org/swift-book

import SwiftUI

public enum RuntimeEnvironment {
    case live
    case preview
    case testing
    
    public static var current: RuntimeEnvironment {
#if DEBUG
        let env = ProcessInfo.processInfo.environment
        
        // Detects test executions (both XCTest and Swift Testing in Xcode))
        let isTesting = env["XCTestConfigurationFilePath"] != nil
        || env["XCTestBundlePath"] != nil
        || env["XCTestSessionIdentifier"] != nil
        || NSClassFromString("XCTestCase") != nil
        
        if isTesting {
            return .testing
        }
        
        if env["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return .preview
        }
        
        return .live
#else
        return .live
#endif
    }
}

public var inject: DependenciesInjection { .shared }

public final class DependenciesInjection: @unchecked Sendable {
    public static let shared = DependenciesInjection()
    
    private let lock = NSLock()
    private var storage: [ObjectIdentifier: Any] = [:]
    
    // MARK: - Override scoping (Swift Testing / concurrencia segura)
    
    /// Overrides box specific to each task tree.
    /// Being a `class` with its own lock, it is mutable within the scope,
    /// but since it is TaskLocal, it is never shared between sibling trees.
    private final class OverrideBox: @unchecked Sendable {
        private let lock = NSLock()
        private var dict: [ObjectIdentifier: Any]
        
        init(_ dict: [ObjectIdentifier: Any]) {
            self.dict = dict
        }
        
        func get(_ id: ObjectIdentifier) -> Any? {
            lock.lock(); defer { lock.unlock() }
            return dict[id]
        }
        
        func set(_ id: ObjectIdentifier, _ value: Any) {
            lock.lock(); defer { lock.unlock() }
            dict[id] = value
        }
    }
    
    /// Task-local storage containing the active overrides box, if it exists.
    ///
    /// `nil` It means there is no active override scope.: `get(_:)`
    /// consult the gloabl dictionary `storage`. When executed `withOverrides(_:)`,
    /// A new `OverrideBox` is bound to this task-local for the duration.
    /// of its operational closure.
    ///
    /// As it is task-local (not global) state, the associated value is automatically
    /// inherited by any child task created within that scope,
    /// but it is completely invisible to sibling task trees
    /// running in parallel (for example, parallel tests in Swift Testing).
    /// This eliminates test races without the need for manual locking
    /// or snapshotting/restoring shared state.
    @TaskLocal private static var overrideBox: OverrideBox?
    
    private init() {
        storage = [:]
    }
    
    // MARK: - Registration Methods (unchanged)
    
    /// CASE 1: Register a dependency, distinguishing between the three possible environments (App, Previews, and Tests). .
    public func register<T>(
        _ type: T.Type,
        live: () -> T,
        preview: () -> T,
        testing: () -> T
    ) {
        let selectedValue: T
        switch RuntimeEnvironment.current {
        case .live: selectedValue = live()
        case .preview:  selectedValue = preview()
        case .testing:  selectedValue = testing()
        }
        set(selectedValue, for: type)
    }
    
    /// CASO 2: Register a dependency without a UI (use the standard version in the App and Previews, but a mock in unit tests)..
    public func register<T>(
        _ type: T.Type,
        live: () -> T,
        testing: () -> T
    ) {
        let selectedValue: T
        switch RuntimeEnvironment.current {
        case .live, .preview: selectedValue = live()
        case .testing:            selectedValue = testing()
        }
        set(selectedValue, for: type)
    }
    
    /// CASO 3: Registers a static dependency (uses the exact same actual instance in absolutely all environments).
    public func register<T>(
        _ type: T.Type,
        live: () -> T
    ) {
        let selectedValue = live()
        set(selectedValue, for: type)
    }
    
    // MARK: - Core Methods (Safe Access)
    public func get<T>(_ type: T.Type) -> T {
        let id = ObjectIdentifier(type)
        
        // If there is an active overrides box in THIS task tree, it takes absolute priority..
        if let box = Self.overrideBox, let value = box.get(id) as? T {
            return value
        }
        
        // Otherwise, the usual behavior: global storage..
        lock.lock()
        defer { lock.unlock() }
        guard let value = storage[id] as? T else {
            fatalError("Dependency missing: \(type)")
        }
        return value
    }
    
    public func set<T>(_ value: T, for type: T.Type) {
        let id = ObjectIdentifier(type)
        
        // If we are inside a withOverrides block, writes go to the local box,
        // NEVER to global storage. This is what eliminates race conditions between tests.
        if let box = Self.overrideBox {
            box.set(id, value)
            return
        }
        
        lock.lock()
        storage[id] = value
        lock.unlock()
    }
    
    private func snapshotStorage() -> [ObjectIdentifier: Any] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    
    // MARK: - Scope temporal (Swift Testing / XCTest async, sin fugas entre tests paralelos)
    
    /// Creates an isolated scope for the task tree. Everything read or written within
    /// `body` (including structured child tasks created inside) uses this container.
    /// Sibling tests running in parallel (Swift Testing) never see it.
    public func withOverrides<R>(
        _ body: () async throws -> R
    ) async rethrows -> R {
        let baseline = snapshotStorage()
        
        let box = OverrideBox(baseline)
        return try await Self.$overrideBox.withValue(box, operation: body)
    }
    
    /// Access via KeyPath for @propertyWrapper and for mocks in tests.
    /// Example: inject[\.splashRepository] = mock
    public subscript<T>(keyPath: KeyPath<DependenciesInjection, T>) -> T {
        get { self[keyPath: keyPath] }
        set { set(newValue, for: T.self) }
    }
}

@propertyWrapper
public struct Inject<T: Sendable> {
    private let keyPath: KeyPath<DependenciesInjection, T>
    
    public init(_ keyPath: KeyPath<DependenciesInjection, T>) {
        self.keyPath = keyPath
    }
    
    public var wrappedValue: T {
        DependenciesInjection.shared[keyPath]
    }
}
