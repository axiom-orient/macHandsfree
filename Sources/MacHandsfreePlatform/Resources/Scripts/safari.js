ObjC.import('Foundation');
ObjC.import('AppKit');

function readInput(path) {
  return JSON.parse(ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null)));
}
function windowJSON(w, i) {
  return { id: i + 1, name: String(w.name()), visible: Boolean(w.visible()), current_tab_index: Number(w.currentTab().index()) };
}
function tabJSON(t, w) {
  return { window_id: w, index: Number(t.index()), name: String(t.name()), url: String(t.url()), visible: Boolean(t.visible()) };
}
function getWindow(app, id) {
  const values = app.windows();
  if (id < 1 || id > values.length) throw new Error('window_not_found');
  return values[id - 1];
}
function getTab(app, wid, index) {
  const w = getWindow(app, wid), tabs = w.tabs();
  if (index < 1 || index > tabs.length) throw new Error('tab_not_found');
  return [w, tabs[index - 1]];
}
function exactKeys(value, keys) {
  return value && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).sort().join('|') === keys.slice().sort().join('|');
}
function positiveInteger(value) { return Number.isSafeInteger(value) && value > 0; }
function nativeString(value) {
  const text = typeof value === 'string' ? value : ObjC.unwrap(value);
  if (typeof text !== 'string' || text.length === 0) throw new Error('safari_application_identity_unavailable');
  return text;
}
function tabTarget(pair, wid, current) {
  const nativeID = Number(pair[0].id());
  if (!positiveInteger(nativeID)) throw new Error('native_window_identity_unavailable');
  return { window_id: wid, native_window_id: nativeID, index: current.index, name: current.name, url: current.url };
}
function requireExpectedTab(pair, wid, index, expected) {
  if (!exactKeys(expected, ['window_id', 'native_window_id', 'index', 'name', 'url'])
    || !positiveInteger(expected.window_id) || !positiveInteger(expected.native_window_id)
    || !positiveInteger(expected.index) || typeof expected.name !== 'string' || typeof expected.url !== 'string'
    || expected.window_id !== wid || expected.index !== index) throw new Error('plan_preview_invalid');
  const current = tabTarget(pair, wid, tabJSON(pair[1], wid));
  if (Object.keys(current).some(key => current[key] !== expected[key])) throw new Error('plan_state_changed');
}

// This observes the actual process through AppKit; it never launches or activates Safari.
// Swift separately validates the more precise MacProcessStartTime immediately before launch.
function safariApplicationSnapshot() {
  const applications = $.NSRunningApplication.runningApplicationsWithBundleIdentifier('com.apple.Safari');
  if (Number(applications.count) !== 1) throw new Error('safari_application_unavailable');
  const application = applications.objectAtIndex(0);
  const launchDate = application.launchDate;
  const bundleURL = application.bundleURL;
  if (!launchDate || !bundleURL || launchDate.isNil() || bundleURL.isNil()) {
    throw new Error('safari_application_identity_unavailable');
  }
  const formatter = $.NSISO8601DateFormatter.alloc.init;
  formatter.formatOptions = Number($.NSISO8601DateFormatWithInternetDateTime)
    | Number($.NSISO8601DateFormatWithFractionalSeconds);
  return {
    pid: Number(application.processIdentifier),
    bundle_id: nativeString(application.bundleIdentifier),
    bundle_path: nativeString(bundleURL.URLByStandardizingPath.path),
    launch_date: nativeString(formatter.stringFromDate(launchDate)),
  };
}
function requireExpectedApplication(expected) {
  if (!exactKeys(expected, ['pid', 'bundle_id', 'bundle_path', 'launch_date', 'process_start_time'])
    || !positiveInteger(expected.pid) || expected.pid > 2147483647 || expected.bundle_id !== 'com.apple.Safari'
    || typeof expected.bundle_path !== 'string' || !expected.bundle_path.startsWith('/')
    || expected.bundle_path.includes('\u0000')
    || typeof expected.launch_date !== 'string' || !Number.isFinite(Date.parse(expected.launch_date))) {
    throw new Error('plan_preview_invalid');
  }
  const start = expected.process_start_time;
  if (start !== null && (!exactKeys(start, ['seconds', 'microseconds'])
    || !Number.isSafeInteger(start.seconds) || start.seconds < 0
    || !Number.isSafeInteger(start.microseconds) || start.microseconds < 0 || start.microseconds >= 1000000)) {
    throw new Error('plan_preview_invalid');
  }
}
function requireCurrentApplication(expected) {
  const current = safariApplicationSnapshot();
  if (['pid', 'bundle_id', 'bundle_path', 'launch_date'].some(key => current[key] !== expected[key])) {
    throw new Error('plan_state_changed');
  }
}
function guardFailure(code, error) {
  const result = new Error(String(error.message || error));
  result.safariGuardCode = code;
  return result;
}
function reviewedTab(app, input) {
  try { requireExpectedApplication(input.expected_application); }
  catch (error) { throw guardFailure('plan_preview_invalid', error); }
  try {
    requireCurrentApplication(input.expected_application);
    const ordinalPair = getTab(app, input.window_id, input.tab_index);
    requireExpectedTab(ordinalPair, input.window_id, input.tab_index, input.expected_tab);
    // Anchor the eventual effect to the approved native window, not a reusable ordinal specifier.
    // This is the same verified window, never a fallback after a reorder.
    const approvedWindow = app.windows.byId(input.expected_tab.native_window_id);
    const tabs = approvedWindow.tabs();
    if (input.tab_index > tabs.length) throw new Error('plan_state_changed');
    const pair = [approvedWindow, tabs[input.tab_index - 1]];
    requireExpectedTab(pair, input.window_id, input.tab_index, input.expected_tab);
    if (Number(getWindow(app, input.window_id).id()) !== input.expected_tab.native_window_id) {
      throw new Error('plan_state_changed');
    }
    // Recheck after JXA's target reads, immediately before returning the effect target.
    requireCurrentApplication(input.expected_application);
    return pair;
  } catch (error) {
    throw guardFailure(String(error.message || error) === 'plan_preview_invalid' ? 'plan_preview_invalid' : 'plan_state_changed', error);
  }
}

function dispatch(op, input) {
  const app = Application('Safari');
  switch (op) {
  case 'safari.windows.list': return { windows: app.windows().map(windowJSON) };
  case 'safari.tabs.list': {
    let out = [];
    app.windows().forEach((w, wi) => w.tabs().forEach(t => out.push(tabJSON(t, wi + 1))));
    if (input.window_id) out = out.filter(t => t.window_id === input.window_id);
    return { tabs: out };
  }
  case 'safari.tabs.get': {
    const pair = getTab(app, input.window_id, input.tab_index);
    const current = tabJSON(pair[1], input.window_id);
    const result = { tab: current };
    if (input.snapshot_for_mutation === true) result.tab_target = tabTarget(pair, input.window_id, current);
    return result;
  }
  case 'safari.tabs.open': {
    let w = input.window_id ? getWindow(app, input.window_id)
      : (app.windows().length ? app.windows()[0] : app.Window().make());
    const tab = app.Tab({ url: input.url });
    w.tabs.push(tab);
    if (input.activate !== false) w.currentTab = tab;
    return { tab: tabJSON(tab, input.window_id || 1) };
  }
  case 'safari.tabs.close': {
    const pair = reviewedTab(app, input);
    app.close(pair[1]);
    return { closed: true };
  }
  case 'safari.tabs.activate': {
    const pair = reviewedTab(app, input);
    pair[0].currentTab = pair[1];
    pair[0].index = 1;
    return { tab: tabJSON(pair[1], input.window_id) };
  }
  case 'safari.reading-list.add':
    app.addReadingListItem(input.url, { withTitle: input.title || '', andPreviewText: input.preview_text || '' });
    return { added: true, url: input.url };
  default: throw new Error('unsupported_operation:' + op);
  }
}
function run(argv) {
  try { return JSON.stringify({ ok: true, data: dispatch(argv[0], readInput(argv[1])) }); }
  catch (error) {
    const result = { code: 'safari_operation_failed', message: String(error.message || error) };
    if (error.safariGuardCode) {
      result.code = error.safariGuardCode;
      result.exit_code = 6;
      result.outcome_uncertain = false;
    }
    return JSON.stringify({ ok: false, error: result });
  }
}
