ObjC.import('Foundation');

const maximumSnapshotBytes = 64 * 1024;
const maximumAccounts = 64;
const maximumLookupEntries = 4096;
const maximumChatParticipants = 256;

function readInput(path) {
  return JSON.parse(ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(
    path, $.NSUTF8StringEncoding, null
  )));
}

function strictString(result, field, allowEmpty) {
  if (typeof result !== 'string' || (!allowEmpty && result.length === 0)) {
    throw new Error('messages_snapshot_unavailable:' + field);
  }
  return result;
}

function strictArray(result, field, maximum) {
  if (!Array.isArray(result)) throw new Error('messages_snapshot_unavailable:' + field);
  if (result.length > maximum) throw new Error('messages_lookup_limit:' + field);
  return result;
}

function compareText(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function sameState(left, right) {
  if (left === right) return true;
  if (!left || !right || typeof left !== 'object' || typeof right !== 'object'
    || Array.isArray(left) !== Array.isArray(right)) return false;
  const leftKeys = Object.keys(left).sort();
  const rightKeys = Object.keys(right).sort();
  return leftKeys.length === rightKeys.length
    && leftKeys.every((key, index) => key === rightKeys[index] && sameState(left[key], right[key]));
}

function boundedSnapshot(snapshot) {
  const bytes = Number($(JSON.stringify(snapshot)).lengthOfBytesUsingEncoding($.NSUTF8StringEncoding));
  if (!Number.isFinite(bytes) || bytes > maximumSnapshotBytes) {
    throw new Error('messages_snapshot_too_large');
  }
  return snapshot;
}

function accountSnapshot(account) {
  const enabled = account.enabled();
  if (typeof enabled !== 'boolean') throw new Error('messages_snapshot_unavailable:account_enabled');
  // JXA enumeration values are compared through the same explicit names used by the scripting dictionary.
  const service = String(account.serviceType());
  const status = String(account.connectionStatus());
  if (!['iMessage', 'RCS', 'SMS'].includes(service)
    || !['connected', 'connecting', 'disconnected', 'disconnecting'].includes(status)) {
    throw new Error('messages_snapshot_unavailable:account_enum');
  }
  return {
    id: strictString(account.id(), 'account_id', false),
    description: strictString(account.description(), 'account_description', true),
    service,
    enabled,
    connection_status: status,
  };
}

function accounts(app) {
  const ids = Object.create(null);
  return strictArray(app.accounts(), 'accounts', maximumAccounts).map((account) => {
    const snapshot = accountSnapshot(account);
    if (ids[snapshot.id]) throw new Error('service_ambiguous:' + snapshot.id);
    ids[snapshot.id] = true;
    return { object: account, snapshot };
  });
}

function accountRank(account) {
  const preference = { iMessage: 0, RCS: 1, SMS: 2 };
  return [account.snapshot.connection_status === 'connected' ? 0 : 1, preference[account.snapshot.service]];
}

function compareRanks(left, right) {
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] < right[index]) return -1;
    if (left[index] > right[index]) return 1;
  }
  return 0;
}

function bestAccount(values) {
  if (values.length === 0) throw new Error('service_not_found');
  const sorted = values.slice().sort((left, right) => compareRanks(accountRank(left), accountRank(right)));
  const rank = accountRank(sorted[0]);
  const best = sorted.filter((account) => compareRanks(accountRank(account), rank) === 0);
  if (best.length !== 1) throw new Error('service_ambiguous');
  return best[0];
}

function selector(input) {
  const hasChat = Object.prototype.hasOwnProperty.call(input, 'chat_guid');
  const hasHandle = Object.prototype.hasOwnProperty.call(input, 'handle');
  if (hasChat === hasHandle) throw new Error('handle_or_chat_required');
  const requested = input.service === undefined ? 'auto' : input.service;
  if (!['auto', 'iMessage', 'RCS', 'SMS'].includes(requested)) throw new Error('service_not_found');
  return {
    kind: hasChat ? 'chat' : 'participant',
    value: strictString(hasChat ? input.chat_guid : input.handle, 'selector', false),
    service: requested,
  };
}

function participantSnapshot(participant, accountID) {
  const owner = strictString(participant.account().id(), 'participant_account', false);
  if (owner !== accountID) throw new Error('messages_target_account_changed');
  return {
    id: strictString(participant.id(), 'participant_id', false),
    handle: strictString(participant.handle(), 'participant_handle', false),
    name: strictString(participant.name(), 'participant_name', true),
    account_id: owner,
  };
}

function capture(command, selected, recipient, requested, lookup) {
  const account = accountSnapshot(selected.object);
  if (!sameState(account, selected.snapshot)) throw new Error('messages_account_changed_during_snapshot');
  if (!account.enabled) throw new Error('messages_account_disabled');
  if (requested.service !== 'auto' && account.service !== requested.service) {
    throw new Error('messages_service_mismatch');
  }
  let target;
  if (requested.kind === 'chat') {
    const id = strictString(recipient.id(), 'chat_id', false);
    const owner = strictString(recipient.account().id(), 'chat_account', false);
    if (id !== requested.value || owner !== account.id) throw new Error('messages_target_account_changed');
    const ids = Object.create(null);
    const participants = strictArray(recipient.participants(), 'chat_participants', maximumChatParticipants)
      .map((participant) => {
        const value = participantSnapshot(participant, account.id);
        if (ids[value.id]) throw new Error('participant_ambiguous:' + value.id);
        ids[value.id] = true;
        return value;
      }).sort((left, right) => compareText(left.id, right.id));
    if (participants.length === 0) throw new Error('participant_not_found');
    target = {
      kind: 'chat', id, name: strictString(recipient.name(), 'chat_name', true),
      account_id: owner, participants,
    };
  } else {
    const participant = participantSnapshot(recipient, account.id);
    if (participant.handle !== requested.value) throw new Error('participant_not_found:' + requested.value);
    target = {
      kind: 'participant', lookup, id: participant.id, handle: participant.handle,
      name: participant.name, account_id: participant.account_id,
    };
  }
  return { recipient, snapshot: boundedSnapshot({ version: 1, command, selector: requested, account, recipient: target }) };
}

// Account ranking is used only while preparing the reviewed route.
function selectForPreview(app, command, input) {
  const requested = selector(input);
  const available = accounts(app);
  if (requested.kind === 'chat') {
    const matches = [];
    let visited = 0;
    available.forEach((account) => {
      const chats = strictArray(account.object.chats(), 'chats', maximumLookupEntries);
      visited += chats.length;
      if (visited > maximumLookupEntries) throw new Error('messages_lookup_limit:chats');
      chats.forEach((chat) => {
        if (strictString(chat.id(), 'chat_id', false) === requested.value) matches.push({ account, chat });
      });
    });
    if (matches.length === 0) throw new Error('chat_not_found:' + requested.value);
    if (matches.length !== 1) throw new Error('chat_ambiguous:' + requested.value);
    return capture(command, matches[0].account, matches[0].chat, requested, null);
  }
  const eligible = available.filter((account) => account.snapshot.enabled
    && (requested.service === 'auto' || account.snapshot.service === requested.service));
  if (eligible.length === 0) throw new Error('service_not_found:' + requested.service);
  const matches = [];
  let visited = 0;
  eligible.forEach((account) => {
    const participants = strictArray(account.object.participants(), 'participants', maximumLookupEntries);
    visited += participants.length;
    if (visited > maximumLookupEntries) throw new Error('messages_lookup_limit:participants');
    participants.forEach((participant) => {
      if (strictString(participant.handle(), 'participant_handle', false) === requested.value) {
        matches.push({ account, participant });
      }
    });
  });
  if (matches.length > 0) {
    matches.sort((left, right) => compareRanks(accountRank(left.account), accountRank(right.account)));
    const rank = accountRank(matches[0].account);
    const best = matches.filter((match) => compareRanks(accountRank(match.account), rank) === 0);
    if (best.length !== 1) throw new Error('participant_ambiguous:' + requested.value);
    return capture(command, best[0].account, best[0].participant, requested, 'listed_id');
  }
  const account = bestAccount(eligible);
  // A reference is not a make/chat/send command. It is usable only if its identity can be read now.
  const named = account.object.participants.byName(requested.value);
  return capture(command, account, named, requested, 'named_handle');
}

// Re-resolve only the approved account and target. No account ranking or route fallback occurs here.
function captureExpected(app, command, input, expected) {
  const requested = selector(input);
  if (!sameState(requested, expected.selector)) throw new Error('messages_selector_changed');
  const accountID = strictString(expected.account.id, 'expected_account_id', false);
  const accountMatches = accounts(app).filter((account) => account.snapshot.id === accountID);
  if (accountMatches.length !== 1) throw new Error('service_not_found:' + accountID);
  const account = accountMatches[0];
  if (requested.kind === 'chat') {
    const matches = strictArray(account.object.chats(), 'chats', maximumLookupEntries).filter(
      (chat) => strictString(chat.id(), 'chat_id', false) === requested.value
    );
    if (matches.length !== 1) throw new Error(matches.length ? 'chat_ambiguous' : 'chat_not_found');
    return capture(command, account, matches[0], requested, null);
  }
  const expectedID = strictString(expected.recipient.id, 'expected_participant_id', false);
  let recipient;
  if (expected.recipient.lookup === 'listed_id') {
    const matches = strictArray(account.object.participants(), 'participants', maximumLookupEntries).filter(
      (participant) => strictString(participant.id(), 'participant_id', false) === expectedID
    );
    if (matches.length !== 1) throw new Error(matches.length ? 'participant_ambiguous' : 'participant_not_found');
    recipient = matches[0];
  } else if (expected.recipient.lookup === 'named_handle') {
    recipient = account.object.participants.byName(requested.value);
  } else {
    throw new Error('messages_snapshot_unavailable:participant_lookup');
  }
  const current = capture(command, account, recipient, requested, expected.recipient.lookup);
  if (current.snapshot.recipient.id !== expectedID) throw new Error('messages_participant_changed');
  return current;
}

function guardFailure(code, error) {
  const result = new Error(String(error.message || error));
  result.sendGuardCode = code;
  return result;
}

function prepareRoute(app, command, input) {
  try {
    const allowed = ['handle', 'chat_guid', 'service', 'snapshot_for_send'];
    if (input.snapshot_for_send !== true || Object.keys(input).some((key) => !allowed.includes(key))) {
      throw new Error('messages_snapshot_unavailable:request');
    }
    const first = selectForPreview(app, command, input);
    const second = captureExpected(app, command, input, first.snapshot);
    if (!sameState(first.snapshot, second.snapshot)) throw new Error('messages_route_changed_during_snapshot');
    return { send_snapshot: second.snapshot };
  } catch (error) {
    throw guardFailure(errorCode(String(error.message || error), 'messages_snapshot_unavailable'), error);
  }
}

function reviewedRoute(app, command, input) {
  const expected = input.expected_send_snapshot;
  if (!expected || typeof expected !== 'object' || Array.isArray(expected)
    || Object.keys(expected).sort().join('|') !== 'account|command|recipient|selector|version'
    || expected.version !== 1 || expected.command !== command || !expected.account || !expected.recipient) {
    throw guardFailure('plan_preview_invalid', 'The reviewed Messages route snapshot is missing or malformed');
  }
  try {
    boundedSnapshot(expected);
    const first = captureExpected(app, command, input, expected);
    if (!sameState(first.snapshot, expected)) throw new Error('messages_route_changed_after_plan');
    const second = captureExpected(app, command, input, expected);
    if (!sameState(second.snapshot, expected)) throw new Error('messages_route_changed_after_plan');
    return second;
  } catch (error) {
    throw guardFailure('plan_state_changed', error);
  }
}

function dispatch(operation, input) {
  if (!['messages.send.text', 'messages.send.file'].includes(operation)) {
    throw guardFailure('unsupported_operation', 'Unsupported Messages operation: ' + operation);
  }
  const app = Application('Messages');
  app.includeStandardAdditions = false;
  // Private fields are injected by the host only after validating the public command schema.
  if (Object.prototype.hasOwnProperty.call(input, 'snapshot_for_send')) {
    return prepareRoute(app, operation, input);
  }
  const reviewed = reviewedRoute(app, operation, input);
  // Guard classification ends before the send. Send failures and lost replies remain uncertain.
  if (operation === 'messages.send.text') {
    app.send(input.text, { to: reviewed.recipient });
  } else {
    app.send(Path(input.path), { to: reviewed.recipient });
  }
  const result = {
    sent: true,
    disposition: 'send_command_returned',
    delivery_confirmed: false,
    route: reviewed.snapshot,
  };
  if (operation === 'messages.send.file') result.path = input.path;
  return result;
}

function errorCode(message, fallback) {
  const known = [
    'chat_not_found', 'chat_ambiguous', 'handle_or_chat_required', 'service_not_found',
    'service_ambiguous', 'participant_not_found', 'participant_ambiguous',
    'messages_snapshot_unavailable', 'messages_snapshot_too_large', 'messages_lookup_limit',
    'messages_account_disabled', 'messages_service_mismatch',
  ];
  for (const code of known) {
    if (message === code || message.startsWith(code + ':')) return code;
  }
  return fallback;
}

function run(argv) {
  try {
    return JSON.stringify({ ok: true, data: dispatch(argv[0], readInput(argv[1])) });
  } catch (error) {
    const message = String(error.message || error);
    const result = { code: errorCode(message, 'messages_send_failed'), message };
    if (error.sendGuardCode) {
      result.code = error.sendGuardCode;
      result.exit_code = 6;
      result.outcome_uncertain = false;
    }
    return JSON.stringify({ ok: false, error: result });
  }
}
