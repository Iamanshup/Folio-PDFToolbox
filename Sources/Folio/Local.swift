import SwiftUI

/// Drop-in replacement for SwiftUI's `@State`.
///
/// In this SDK `@State` is a macro whose plugin only ships with Xcode, so the app would not build
/// with the Command Line Tools alone. `@Local` gives the same semantics (view-owned storage that
/// survives re-renders, `$value` bindings) on top of `@StateObject`, which is a plain property wrapper.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    @StateObject private var box: LocalBox<Value>

    init(wrappedValue: Value) { _box = StateObject(wrappedValue: LocalBox(wrappedValue)) }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> {
        let b = box
        return Binding(get: { b.value }, set: { b.value = $0 })
    }
}

final class LocalBox<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}
