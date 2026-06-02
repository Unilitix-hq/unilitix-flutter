import Flutter
import UIKit
import XCTest

@testable import unilitix_flutter

class RunnerTests: XCTestCase {

  func testGetBatteryLevelReturnsDouble() {
    let plugin = UnilitixPlugin()
    let call = FlutterMethodCall(methodName: "getBatteryLevel", arguments: nil)
    let expectation = self.expectation(description: "result block called")
    plugin.handle(call) { result in
      // Returns a Double (0.0–1.0) or -1.0 — never nil or a non-Double
      XCTAssertTrue(result is Double, "getBatteryLevel must return a Double, got \(type(of: result))")
      expectation.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testGetCarrierNameReturnsString() {
    let plugin = UnilitixPlugin()
    let call = FlutterMethodCall(methodName: "getCarrierName", arguments: nil)
    let expectation = self.expectation(description: "result block called")
    plugin.handle(call) { result in
      XCTAssertTrue(result is String, "getCarrierName must return a String, got \(type(of: result))")
      expectation.fulfill()
    }
    waitForExpectations(timeout: 1)
  }
}
