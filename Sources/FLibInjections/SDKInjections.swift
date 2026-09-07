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
        
        // Detects test executions (both XCTest and Swift Testing in Xcode)
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
    @TaskLocal private static var overrideBox: OverrideBox?
    
    private init() {
        storage = [:]
    }
    
    // MARK: - Registration Methods
    
    /// Registers a static dependency.
    public func register<T>(
        _ type: T.Type,
        live: () -> T
    ) {
        let selectedValue = live()
        set(selectedValue, for: type)
    }
    
    // MARK: - Core Methods (Safe Access)
    
    /// Obtiene un valor de forma opcional sin lanzar fatalError si no existe en el contenedor.
    public func getOptional<T>(_ type: T.Type) -> T? {
        let id = ObjectIdentifier(type)
        
        // Prioridad 1: Override box del task actual (Unit Tests asíncronos)
        if let box = Self.overrideBox, let value = box.get(id) as? T {
            return value
        }
        
        // Prioridad 2: Almacenamiento global
        lock.lock()
        defer { lock.unlock() }
        return storage[id] as? T
    }
    
    /// Acceso principal con resolución de Fallback automático (Previews / Tests / Simulador).
    public func get<T>(
        _ type: T.Type,
        preview: @autoclosure () -> T,
        testing: (() -> T)? = nil
    ) -> T {
        // Si la dependencia ya fue registrada explícitamente (.live u override de test), se usa de inmediato
        if let registeredValue = getOptional(type) {
            return registeredValue
        }
        
#if DEBUG
        // Si no existe registro explícito, resuelve según el entorno actual de ejecución
        switch RuntimeEnvironment.current {
        case .testing:
            if let testing {
                return testing()
            }
            return preview()
        case .preview, .live:
            return preview()
        }
#else
        fatalError("Dependency missing in Release build: \(type)")
#endif
    }
    
    /// Acceso estricto tradicional (requiere registro previo explícito).
    public func get<T>(_ type: T.Type) -> T {
        if let registeredValue = getOptional(type) {
            return registeredValue
        }
        
        fatalError("Dependency missing: \(type)")
    }
    
    public func set<T>(_ value: T, for type: T.Type) {
        let id = ObjectIdentifier(type)
        
        // Si estamos dentro de un bloque withOverrides, los writes van a la caja local del Task
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
    
    public func withOverrides<R>(
        _ body: () async throws -> R
    ) async rethrows -> R {
        let baseline = snapshotStorage()
        
        let box = OverrideBox(baseline)
        return try await Self.$overrideBox.withValue(box, operation: body)
    }
    
    /// Access via KeyPath for @propertyWrapper and for mocks in tests.
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
