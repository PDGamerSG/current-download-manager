import SwiftUI

// New SDKs also export a State macro that needs an Xcode-only plugin. Naming the
// longstanding property wrapper explicitly keeps this app buildable with CLT.
typealias ViewState<Value> = SwiftUI.State<Value>
