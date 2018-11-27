import XCTest

import PerfectNIOTests

var tests = [XCTestCaseEntry]()
tests += PerfectNIOTests.allTests()
XCTMain(tests)
