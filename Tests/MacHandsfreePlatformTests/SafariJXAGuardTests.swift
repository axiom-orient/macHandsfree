import Foundation
import Testing
import MacHandsfreeCore
@testable import MacHandsfreePlatform

#if os(macOS)
  import JavaScriptCore

  struct SafariJXAGuardTests {
    @Test func nativeStringsKeepAlreadyBridgedValuesAndUnwrapObjects() throws {
      let resource = try #require(Bundle.module.url(forResource: "safari", withExtension: "js"))
      let context = try #require(JSContext())
      context.evaluateScript("var ObjC = { import: function () {}, unwrap: function (value) { return value.wrapped; } };")
      context.evaluateScript(try String(contentsOf: resource, encoding: .utf8))
      let result = try #require(context.evaluateScript("nativeString('already bridged') + '|' + nativeString({wrapped: 'native object'});")?.toString())
      #expect(result == "already bridged|native object")
      #expect(context.exception == nil)
    }

    @Test func nativeNilLaunchIdentityIsRejectedExplicitly() throws {
      let resource = try #require(Bundle.module.url(forResource: "safari", withExtension: "js"))
      let context = try #require(JSContext())
      context.evaluateScript("var ObjC = { import: function () {} };")
      context.evaluateScript(try String(contentsOf: resource, encoding: .utf8))
      let result = try #require(context.evaluateScript("""
        var $ = { NSRunningApplication: { runningApplicationsWithBundleIdentifier: function () {
          return { count: 1, objectAtIndex: function () {
            return { launchDate: { isNil: function () { return true; } },
              bundleURL: { isNil: function () { return false; } } };
          } };
        } } };
        (function () {
          try { safariApplicationSnapshot(); return 'incorrectly accepted'; }
          catch (error) { return String(error.message); }
        })();
        """)?.toString())
      #expect(result == "safari_application_identity_unavailable")
      #expect(context.exception == nil)
    }

    @Test func reorderedDuplicateWindowsCannotCloseAnotherWindow() throws {
      let result = try runFixture("windows.reverse();")
      #expect(result["response"]?["ok"]?.boolValue == false)
      #expect(result["response"]?["error"]?["code"]?.stringValue == "plan_state_changed")
      #expect(result["closed"]?.arrayValue?.isEmpty == true)
      #expect(result["activated"]?.arrayValue?.isEmpty == true)
    }

    @Test func relaunchBeforeTheEffectRejectsReusedWindowIDs() throws {
      let result = try runFixture("replaceSessionOnRead = 2;")
      #expect(result["response"]?["ok"]?.boolValue == false)
      #expect(result["response"]?["error"]?["code"]?.stringValue == "plan_state_changed")
      #expect(result["closed"]?.arrayValue?.isEmpty == true)
    }

    @Test func lastMomentReorderCannotRedirectTheNativeWindowEffect() throws {
      let result = try runFixture("reverseWindowsOnRead = 2;")
      #expect(result["closed"]?.arrayValue == [.integer(101)])
    }

    @Test func missingOrMalformedPrivateGuardsNeverDispatch() throws {
      for change in [
        "delete fixtureInput.expected_application;",
        "fixtureInput.expected_application.launch_date = null;",
        "delete fixtureInput.expected_application.process_start_time;",
        "delete fixtureInput.expected_tab.native_window_id;",
        "fixtureInput.expected_tab.native_window_id = '101';",
        "delete fixtureInput.expected_tab;",
      ] {
        let result = try runFixture(change)
        #expect(result["response"]?["ok"]?.boolValue == false)
        #expect(result["response"]?["error"]?["outcome_uncertain"]?.boolValue == false)
        #expect(result["closed"]?.arrayValue?.isEmpty == true)
      }
    }

    @Test func unchangedReviewedWindowCanCloseAndActivate() throws {
      for operation in ["safari.tabs.close", "safari.tabs.activate"] {
        let result = try runFixture("", operation: operation)
        #expect(result["response"]?["ok"]?.boolValue == true)
        let effects = operation == "safari.tabs.close" ? result["closed"] : result["activated"]
        #expect(effects?.arrayValue == [.integer(101)])
      }
    }

    @Test func publicTabReadRetainsItsOriginalShape() throws {
      let result = try runFixture("", operation: "safari.tabs.get")
      let data = try #require(result["response"]?["data"]?.objectValue)
      #expect(Set(data.keys) == ["tab"])
      let tab = try #require(data["tab"]?.objectValue)
      #expect(Set(tab.keys) == ["window_id", "index", "name", "url", "visible"])
    }

    private func runFixture(_ setup: String, operation: String = "safari.tabs.close") throws -> JSONValue {
      let resource = try #require(Bundle.module.url(forResource: "safari", withExtension: "js"))
      let script = try String(contentsOf: resource, encoding: .utf8)
      let context = try #require(JSContext())
      context.evaluateScript("var ObjC = { import: function () {} };")
      context.evaluateScript(script)
      #expect(context.exception == nil)
      let fixture = """
        var closed = [], activated = [];
        function fixtureWindow(id) {
          var tab = { owner: id, index: function () { return 1; },
            name: function () { return 'Same'; }, url: function () { return 'https://example.test'; },
            visible: function () { return true; } };
          var window = { id: function () { return id; }, tabs: function () { return [tab]; } };
          Object.defineProperty(window, 'currentTab', {
            get: function () { return function () { return tab; }; },
            set: function () { activated.push(id); }
          });
          return window;
        }
        var windows = [fixtureWindow(101), fixtureWindow(202)];
        var application = { windows: function () { return windows; },
          close: function (tab) { closed.push(tab.owner); } };
        application.windows.byId = function (id) {
          var matches = windows.filter(function (window) { return window.id() === id; });
          if (matches.length !== 1) throw new Error('window_not_found');
          return matches[0];
        };
        function Application() { return application; }
        var session = { pid: 111, bundle_id: 'com.apple.Safari', bundle_path: '/Applications/Safari.app',
          launch_date: '2026-10-02T01:02:03.000Z', process_start_time: { seconds: 100, microseconds: 10 } };
        var sessionReads = 0, replaceSessionOnRead = 0, reverseWindowsOnRead = 0;
        function safariApplicationSnapshot() {
          sessionReads += 1;
          if (reverseWindowsOnRead && sessionReads === reverseWindowsOnRead) windows.reverse();
          if (replaceSessionOnRead && sessionReads >= replaceSessionOnRead) {
            return Object.assign({}, session, { pid: 222, launch_date: '2026-10-02T01:02:04.000Z' });
          }
          return session;
        }
        var fixtureInput = { window_id: 1, tab_index: 1,
          expected_tab: { window_id: 1, native_window_id: 101, index: 1, name: 'Same', url: 'https://example.test' },
          expected_application: Object.assign({}, session) };
        function readInput() { return fixtureInput; }
        \(setup)
        JSON.stringify({ response: JSON.parse(run(['\(operation)', 'fixture.json'])),
          closed: closed, activated: activated });
        """
      let value = try #require(context.evaluateScript(fixture)?.toString())
      #expect(context.exception == nil)
      return try JSONValue.parse(Data(value.utf8))
    }
  }
#endif
