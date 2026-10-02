ObjC.import('Foundation');

const MAX_SNAPSHOT_BYTES = 256 * 1024;
const MAX_COLLECTION = 500;
const MAX_MAILBOXES = 2000;
const MAX_MESSAGE_SCAN = 100000;
const MAX_ATTACHMENT_READY_WAIT_MS = 5000;
const ATTACHMENT_STABLE_WINDOW_MS = 750;
const MUTATIONS = [
  'mail.drafts.create', 'mail.drafts.send', 'mail.messages.send', 'mail.messages.reply',
  'mail.messages.forward', 'mail.messages.move', 'mail.messages.set-read',
];
let effectStarted = false;
let effectEvidence = null;

function readInput(path) {
  return JSON.parse(ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null)));
}

function failure(code, message) {
  const error = new Error(message);
  error.mailCode = code;
  if (!effectStarted && (code === 'plan_preview_invalid' || code === 'plan_state_changed')) {
    error.mailGuardCode = code;
  }
  return error;
}

function text(value, field, allowEmpty) {
  if (typeof value !== 'string' || (!allowEmpty && value.length === 0)) {
    throw failure('mail_state_unavailable', 'Unreadable Mail text: ' + field);
  }
  return value;
}

function boolean(value, field) {
  if (typeof value !== 'boolean') throw failure('mail_state_unavailable', 'Unreadable Mail boolean: ' + field);
  return value;
}

function finite(value, field) {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw failure('mail_state_unavailable', 'Unreadable Mail number: ' + field);
  }
  return value;
}

function array(value, field, maximum) {
  if (!Array.isArray(value)) throw failure('mail_state_unavailable', 'Unreadable Mail collection: ' + field);
  if (maximum !== undefined && value.length > maximum) {
    throw failure('mail_snapshot_too_large', 'Mail collection exceeds its bound: ' + field);
  }
  return value;
}

function date(value, field) {
  if (value === undefined || value === null) return null;
  if (!(value instanceof Date) || !Number.isFinite(value.getTime())) {
    throw failure('mail_state_unavailable', 'Unreadable Mail date: ' + field);
  }
  return value.toISOString();
}

function numericID(value, field) {
  const raw = typeof value === 'number' ? String(value) : text(value, field, false);
  const number = Number(raw);
  if (!Number.isSafeInteger(number) || String(number) !== raw) {
    throw failure('mail_identifier_invalid', 'Mail requires an exact safe decimal identifier: ' + field);
  }
  return raw;
}

function compareText(a, b) { return a < b ? -1 : a > b ? 1 : 0; }
function has(object, key) { return Object.prototype.hasOwnProperty.call(object, key); }

function bytes(value) {
  const encoded = JSON.stringify(value);
  let count = 0;
  for (let i = 0; i < encoded.length; i += 1) {
    const c = encoded.charCodeAt(i);
    if (c < 0x80) count += 1;
    else if (c < 0x800) count += 2;
    else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < encoded.length
      && encoded.charCodeAt(i + 1) >= 0xDC00 && encoded.charCodeAt(i + 1) <= 0xDFFF) {
      count += 4;
      i += 1;
    } else count += 3;
  }
  return count;
}

function bounded(value) {
  if (bytes(value) > MAX_SNAPSHOT_BYTES) {
    throw failure('mail_snapshot_too_large', 'The Mail snapshot exceeds 256 KiB; no state was truncated');
  }
  return value;
}

function same(a, b) {
  if (a === b) return true;
  if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object') return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a)) return a.length === b.length && a.every((v, i) => same(v, b[i]));
  const left = Object.keys(a).sort();
  const right = Object.keys(b).sort();
  return same(left, right) && left.every((key) => same(a[key], b[key]));
}

function accountID(account) { return text(account.id(), 'account.id', false); }

function accounts(app) {
  const values = array(app.accounts(), 'accounts', MAX_COLLECTION);
  const ids = new Set();
  values.forEach((account) => {
    const id = accountID(account);
    if (ids.has(id)) throw failure('mail_identifier_ambiguous', 'Duplicate Mail account identifier');
    ids.add(id);
  });
  return values.sort((a, b) => compareText(accountID(a), accountID(b)));
}

function accountState(account) {
  return {
    id: accountID(account), name: text(account.name(), 'account.name', true),
    email_addresses: array(account.emailAddresses(), 'account.email_addresses', MAX_COLLECTION)
      .map((address) => text(address, 'account.email_address', false)).sort(compareText),
    enabled: boolean(account.enabled(), 'account.enabled'),
  };
}

function address(app, value, field) {
  const raw = text(value, field, false);
  if (/[\r\n]/.test(raw)) throw failure('mail_address_invalid', 'Mail address contains a line break: ' + field);
  const result = text(app.extractAddressFrom(raw), field, false).trim();
  if (!result.includes('@') || /[\s,;<>]/.test(result)) {
    throw failure('mail_address_invalid', 'Mail did not resolve one exact address: ' + field);
  }
  return result;
}

function senderState(app, account, selectedAddress) {
  const state = accountState(account);
  if (!state.enabled) throw failure('mail_account_disabled', 'The selected Mail account is disabled');
  const delivery = account.deliveryAccount();
  if (delivery === undefined || delivery === null) {
    throw failure('mail_sender_unavailable', 'The selected Mail account has no delivery account');
  }
  state.delivery = {
    name: text(delivery.name(), 'delivery.name', true),
    enabled: boolean(delivery.enabled(), 'delivery.enabled'),
  };
  if (!state.delivery.enabled) throw failure('mail_account_disabled', 'The delivery account is disabled');
  return { account: state, address: selectedAddress };
}

function chooseSender(app, input, source, fixedAddress) {
  const choices = accounts(app).map((object) => ({ object, state: accountState(object) }));
  let selectedAddress = fixedAddress || input.sender_address;
  let selectedID = input.account_id;
  if (selectedAddress !== undefined && selectedAddress !== null) selectedAddress = address(app, selectedAddress, 'sender_address');
  if (!selectedID && !selectedAddress && source && source.mailbox.account_id) selectedID = source.mailbox.account_id;
  const candidates = choices.filter((choice) => choice.state.enabled && (!selectedID || choice.state.id === selectedID));
  if (selectedID && candidates.length !== 1) throw failure('mail_sender_selection_required', 'Select one enabled Mail account');
  if (!selectedAddress && selectedID) {
    const aliases = candidates[0].state.email_addresses;
    if (aliases.length === 0) throw failure('mail_sender_selection_required', 'The Mail account has no sender address');
    if (input.account_id || aliases.length === 1) selectedAddress = address(app, aliases[0], 'sender_address');
    else throw failure('mail_sender_selection_required', 'Specify sender_address for the source account with multiple aliases');
  }
  if (!selectedAddress) selectedAddress = address(app, app.primaryEmail(), 'primary_email');
  const key = selectedAddress.toLowerCase();
  // outgoing message has no delivery-account setter. One alias must resolve to one enabled account.
  const owners = choices.filter((choice) => choice.state.enabled
    && choice.state.email_addresses.some((alias) => address(app, alias, 'account.alias').toLowerCase() === key));
  if (owners.length !== 1 || (selectedID && owners[0].state.id !== selectedID)) {
    throw failure('mail_sender_selection_required', 'The sender address must identify one enabled Mail account');
  }
  return senderState(app, owners[0].object, selectedAddress);
}

function mailboxState(mailbox) {
  const owner = mailbox.account();
  const ownerID = owner === undefined || owner === null ? null : accountID(owner);
  const path = [];
  let current = mailbox;
  for (let depth = 0; current !== undefined && current !== null; depth += 1) {
    if (depth >= 32) throw failure('mail_mailbox_path_invalid', 'Mailbox ancestry exceeds 32 levels');
    path.unshift(text(current.name(), 'mailbox.name', false));
    const parentOwner = current.account();
    const parentID = parentOwner === undefined || parentOwner === null ? null : accountID(parentOwner);
    if (parentID !== ownerID) throw failure('mail_mailbox_path_invalid', 'Mailbox ancestry crosses accounts');
    current = current.container();
  }
  const id = 'mailbox/v1:' + JSON.stringify([ownerID, path]);
  if (id.length > 2048) throw failure('mail_mailbox_path_invalid', 'Mailbox reference exceeds the public identifier bound');
  return { id, name: path[path.length - 1], account_id: ownerID, path };
}

function mailboxes(app) {
  const found = new Map();
  function visit(mailbox, depth) {
    if (depth > 32) throw failure('mail_mailbox_path_invalid', 'Mailbox traversal exceeds 32 levels');
    const state = mailboxState(mailbox);
    if (found.has(state.id)) return;
    if (found.size >= MAX_MAILBOXES) throw failure('mail_snapshot_too_large', 'Mailbox catalog exceeds its bound');
    found.set(state.id, { object: mailbox, state });
    array(mailbox.mailboxes(), 'mailbox.children', MAX_MAILBOXES).forEach((child) => visit(child, depth + 1));
  }
  array(app.mailboxes(), 'application.mailboxes', MAX_MAILBOXES).forEach((mailbox) => visit(mailbox, 0));
  accounts(app).forEach((account) => {
    array(account.mailboxes(), 'account.mailboxes', MAX_MAILBOXES).forEach((mailbox) => visit(mailbox, 0));
  });
  return Array.from(found.values()).sort((a, b) => compareText(a.state.id, b.state.id));
}

function exactMailbox(app, id) {
  text(id, 'mailbox_id', false);
  const found = mailboxes(app).filter((entry) => entry.state.id === id);
  if (found.length !== 1) throw failure('mail_mailbox_not_found', 'Rediscover the exact mailbox reference');
  return found[0];
}

function normalizedMailMessageID(value) {
  const raw = text(value, 'message.message_id', false).trim();
  if (raw.startsWith('<') && raw.endsWith('>')) return raw.slice(1, -1);
  return raw;
}

function decodeMailRFCMessageLocator(rawID) {
  const prefix = 'mail-rfcid:v1:';
  if (typeof rawID !== 'string' || !rawID.startsWith(prefix)) return null;
  const token = rawID.slice(prefix.length);
  if (token.length === 0 || !/^[A-Za-z0-9_-]+$/.test(token)) {
    throw failure('mail_identifier_invalid', 'The indexed Mail message locator is malformed');
  }
  let base64 = token.replace(/-/g, '+').replace(/_/g, '/');
  while (base64.length % 4 !== 0) base64 += '=';
  const data = $.NSData.alloc.initWithBase64EncodedStringOptions($(base64), 0);
  if (data === undefined || data === null) {
    throw failure('mail_identifier_invalid', 'The indexed Mail message locator is not valid base64url');
  }
  const decoded = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding));
  const messageID = normalizedMailMessageID(decoded);
  if (messageID.length > 1024 || /[\r\n]/.test(messageID)) {
    throw failure('mail_identifier_invalid', 'The indexed Mail message locator is outside its text bound');
  }
  return messageID;
}

function exactMessage(app, rawID, mailboxID) {
  const indexedMessageID = decodeMailRFCMessageLocator(rawID);
  const id = indexedMessageID === null ? numericID(rawID, 'message_id') : null;
  const found = new Map();
  let entries;
  if (mailboxID === undefined || mailboxID === null) {
    entries = mailboxes(app);
  } else {
    try {
      entries = [exactMailbox(app, mailboxID)];
    } catch (error) {
      if (error && error.mailCode === 'mail_mailbox_not_found') {
        throw failure('plan_state_changed', 'The reviewed source mailbox is no longer available');
      }
      throw error;
    }
  }
  entries.forEach((entry) => {
    const specifier = indexedMessageID === null
      ? entry.object.messages.whose({ id: Number(id) })()
      : entry.object.messages.whose({ messageId: indexedMessageID })();
    const matches = array(specifier, 'message.matches', MAX_COLLECTION);
    matches.forEach((message) => {
      const nativeID = numericID(message.id(), 'message.id');
      if (indexedMessageID === null && nativeID !== id) {
        throw failure('mail_identifier_invalid', 'Mail returned a different message ID');
      }
      if (indexedMessageID !== null
        && normalizedMailMessageID(message.messageId()) !== indexedMessageID) {
        throw failure('mail_identifier_invalid', 'Mail returned a different RFC Message-ID');
      }
      const actualMailbox = mailboxState(message.mailbox());
      const key = actualMailbox.id + '\n' + nativeID;
      if (actualMailbox.id !== entry.state.id) {
        throw failure('plan_state_changed', 'Message mailbox changed while the reviewed target was resolved');
      }
      found.set(key, message);
    });
  });
  if (found.size !== 1) {
    const code = found.size > 1
      ? 'mail_identifier_ambiguous'
      : mailboxID !== undefined && mailboxID !== null
        ? 'plan_state_changed'
        : 'mail_message_not_found';
    throw failure(
      code,
      mailboxID === undefined || mailboxID === null
        ? 'The message ID must identify one message'
        : 'The message ID must still identify one message in the reviewed source mailbox'
    );
  }
  return Array.from(found.values())[0];
}

function exactDraft(app, rawID) {
  const id = numericID(rawID, 'draft_id');
  const matches = array(app.outgoingMessages(), 'outgoing_messages', MAX_COLLECTION)
    .filter((draft) => numericID(draft.id(), 'draft.id') === id);
  if (matches.length !== 1) throw failure('mail_draft_not_found', 'The draft ID must identify one currently available outgoing message');
  return matches[0];
}

function recipientState(app, collection, field) {
  return array(collection(), field, MAX_COLLECTION).map((person) => ({
    address: address(app, person.address(), field + '.address'), name: text(person.name(), field + '.name', true),
  })).sort((a, b) => compareText(a.address, b.address) || compareText(a.name, b.name));
}

function receivedAttachments(message) {
  return array(message.mailAttachments(), 'message.attachments', MAX_COLLECTION).map((attachment) => ({
    id: text(attachment.id(), 'attachment.id', false), name: text(attachment.name(), 'attachment.name', true),
    mime_type: text(attachment.mimeType(), 'attachment.mime_type', true),
    approximate_bytes: finite(attachment.fileSize(), 'attachment.file_size'),
    downloaded: boolean(attachment.downloaded(), 'attachment.downloaded'),
  })).sort((a, b) => compareText(a.id, b.id));
}

function messageState(app, message, includeBody) {
  const result = {
    id: numericID(message.id(), 'message.id'), message_id: text(message.messageId(), 'message.message_id', true),
    subject: text(message.subject(), 'message.subject', true), sender: text(message.sender(), 'message.sender', true),
    reply_to: text(message.replyTo(), 'message.reply_to', true),
    date_received: date(message.dateReceived(), 'message.date_received'), date_sent: date(message.dateSent(), 'message.date_sent'),
    read: boolean(message.readStatus(), 'message.read'), flagged: boolean(message.flaggedStatus(), 'message.flagged'),
    deleted: boolean(message.deletedStatus(), 'message.deleted'), junk: boolean(message.junkMailStatus(), 'message.junk'),
    was_forwarded: boolean(message.wasForwarded(), 'message.was_forwarded'),
    was_replied_to: boolean(message.wasRepliedTo(), 'message.was_replied_to'),
    mailbox: mailboxState(message.mailbox()),
    to: recipientState(app, message.toRecipients, 'message.to'), cc: recipientState(app, message.ccRecipients, 'message.cc'),
    bcc: recipientState(app, message.bccRecipients, 'message.bcc'),
  };
  result.mailbox_id = result.mailbox.id;
  if (includeBody) {
    result.content = messageContentState(message.content);
    result.attachments = receivedAttachments(message);
  }
  return bounded(result);
}

function localFilePath(value) {
  if (value === undefined || value === null) throw failure('mail_attachment_unavailable', 'The outgoing attachment exposes no file');
  let path = String(value);
  if (path.startsWith('file://')) {
    const url = $.NSURL.URLWithString(path);
    if (!url || !url.isFileURL) throw failure('mail_attachment_unavailable', 'The attachment is not a local file');
    path = ObjC.unwrap(url.path);
  }
  if (!path.startsWith('/')) throw failure('mail_attachment_unavailable', 'The attachment does not expose an absolute local path');
  return text(ObjC.unwrap($(path).stringByStandardizingPath), 'attachment.path', false);
}

function richPlainText(content, field) {
  const nativeValue = content();
  if (nativeValue === undefined || nativeValue === null) {
    throw failure('mail_state_unavailable', 'Unreadable Mail rich text: ' + field);
  }
  if (typeof nativeValue === 'string') return nativeValue;
  try {
    const unwrapped = ObjC.unwrap(nativeValue);
    if (typeof unwrapped === 'string') return unwrapped;
  } catch (_) {}
  try {
    const unwrapped = ObjC.unwrap(nativeValue.string());
    if (typeof unwrapped === 'string') return unwrapped;
  } catch (_) {}
  const rendered = String(nativeValue);
  if (rendered === '[object Object]' || rendered.length === 0) {
    if (rendered.length === 0) return '';
    throw failure('mail_state_unavailable', 'Unreadable Mail rich text: ' + field);
  }
  return rendered;
}

function richTextState(content) {
  const body = text(richPlainText(content, 'draft.content'), 'draft.content', true);
  bounded(body);
  return bounded({ text: body, attachments: attachmentState(content) });
}

function attachmentState(content) {
  const nativeAttachments = array(content.attachments(), 'draft.attachments', 100);
  const attachments = nativeAttachments.map((attachment, index) => {
    let raw = null;
    try { raw = attachment.fileName(); } catch (_) {}
    if (raw === undefined || raw === null) return { path: null, name: 'attachment-' + (index + 1) };
    try {
      const path = localFilePath(raw);
      return { path, name: path.split('/').pop() };
    } catch (_) {
      const display = String(raw);
      const name = display.split('/').pop() || 'attachment-' + (index + 1);
      return { path: null, name };
    }
  });
  return attachments;
}

function attachmentDescriptors(attachments) {
  return attachments.map((attachment) => ({ path: attachment.path, name: attachment.name }))
    .sort((a, b) => compareText(a.path, b.path));
}

function expectedAttachmentDescriptors(paths) {
  return array(paths, 'attachments', 100).map((value) => {
    const path = localFilePath(value);
    return { path, name: path.split('/').pop() };
  }).sort((a, b) => compareText(a.path, b.path));
}

function waitForAttachments(outgoing, expectedPaths) {
  const expected = expectedAttachmentDescriptors(expectedPaths);
  if (expected.length === 0) {
    const actual = attachmentState(outgoing.content());
    if (actual.length !== 0) {
      throw failure('mail_attachment_mismatch', 'Mail added an attachment that was not in the reviewed composition');
    }
    return;
  }
  const deadline = Date.now() + MAX_ATTACHMENT_READY_WAIT_MS;
  let stableSince = null;
  do {
    try {
      const attachments = attachmentState(outgoing.content());
      const actual = attachmentDescriptors(attachments);
      if (actual.every((attachment) => attachment.path !== null) && same(actual, expected)) {
        if (stableSince === null) stableSince = Date.now();
        if (Date.now() - stableSince >= ATTACHMENT_STABLE_WINDOW_MS) return;
      } else {
        stableSince = null;
      }
    } catch (_) {}
    $.NSThread.sleepForTimeInterval(0.1);
  } while (Date.now() < deadline);
  throw failure(
    'mail_attachment_not_ready',
    'Mail did not expose the exact reviewed attachment paths stably within 5 seconds; no send was attempted'
  );
}

function messageContentState(content) {
  const body = text(richPlainText(content, 'message.content'), 'message.content', true);
  bounded(body);
  return bounded({ text: body });
}

function outgoingState(app, draft) {
  const signature = draft.messageSignature();
  return bounded({
    id: numericID(draft.id(), 'draft.id'), sender: text(draft.sender(), 'draft.sender', false),
    sender_address: address(app, draft.sender(), 'draft.sender'),
    subject: text(draft.subject(), 'draft.subject', true),
    to: recipientState(app, draft.toRecipients, 'draft.to'), cc: recipientState(app, draft.ccRecipients, 'draft.cc'),
    bcc: recipientState(app, draft.bccRecipients, 'draft.bcc'),
    content: richTextState(draft.content),
    signature: signature === undefined || signature === null ? null : {
      name: text(signature.name(), 'draft.signature.name', true),
      content: text(signature.content(), 'draft.signature.content', true),
    },
  });
}

function outgoingJSON(state) {
  const attachments = state.content.attachments.map((attachment) => ({ name: attachment.name }));
  return {
    id: state.id, draft_id: state.id, subject: state.subject, sender: state.sender,
    sender_address: state.sender_address, to: state.to, cc: state.cc, bcc: state.bcc,
    content: state.content.text, rich_text: { text: state.content.text, attachments },
    attachments, signature: state.signature,
  };
}

function composePreferences(app) {
  return {
    always_cc_myself: boolean(app.alwaysCcMyself(), 'always_cc_myself'),
    always_bcc_myself: boolean(app.alwaysBccMyself(), 'always_bcc_myself'),
    default_message_format: text(app.defaultMessageFormat(), 'default_message_format', false),
    same_reply_format: boolean(app.sameReplyFormat(), 'same_reply_format'),
    quote_original_message: boolean(app.quoteOriginalMessage(), 'quote_original_message'),
    include_all_original_message_text: boolean(app.includeAllOriginalMessageText(), 'include_all_original_message_text'),
    selected_signature: text(app.selectedSignature(), 'selected_signature', true),
    primary_email: text(app.primaryEmail(), 'primary_email', true),
  };
}

function inputAddresses(app, input, field) {
  if (!has(input, field)) return [];
  return array(input[field], field, 200).map((entry) => address(app, entry, field)).sort(compareText);
}

function captureMutation(app, operation, input, expectedSourceMailboxID) {
  if (!MUTATIONS.includes(operation)) throw failure('plan_preview_invalid', 'Unknown Mail mutation');
  const state = { source_message: null, sender: null, draft: null, destination_mailbox: null, preferences: null };
  const candidate = {};
  let target = null;
  let destination = null;
  if (operation === 'mail.drafts.create' || operation === 'mail.messages.send') {
    state.sender = chooseSender(app, input, null, null);
    state.preferences = composePreferences(app);
    candidate.action = operation === 'mail.messages.send' ? 'create_and_send_exact_composition' : 'create_draft_only';
    candidate.subject = text(input.subject, 'subject', true);
    candidate.body = text(input.body, 'body', true);
    candidate.to = inputAddresses(app, input, 'to');
    candidate.cc = inputAddresses(app, input, 'cc');
    candidate.bcc = inputAddresses(app, input, 'bcc');
    if (operation === 'mail.messages.send'
      && candidate.to.length + candidate.cc.length + candidate.bcc.length === 0) {
      throw failure('mail_recipients_required', 'A send command requires at least one recipient');
    }
    // Swift owns the signed original paths, immutable copies and byte guards; names are display metadata.
    candidate.attachment_names = array(input.attachments || [], 'attachments', 100)
      .map((path) => text(path, 'attachment.path', false).split('/').pop());
  } else if (operation === 'mail.drafts.send') {
    target = exactDraft(app, input.draft_id);
    state.draft = outgoingState(app, target);
    state.sender = chooseSender(app, {}, null, state.draft.sender_address);
    state.preferences = composePreferences(app);
    if (state.draft.to.length + state.draft.cc.length + state.draft.bcc.length === 0) {
      throw failure('mail_recipients_required', 'The draft has no recipient');
    }
    candidate.action = 'send_existing_reviewed_draft';
    candidate.draft_id = state.draft.id;
  } else {
    target = exactMessage(app, input.message_id, expectedSourceMailboxID);
    state.source_message = messageState(
      app, target, operation === 'mail.messages.reply' || operation === 'mail.messages.forward');
    if (state.source_message.deleted) throw failure('mail_message_deleted', 'The source message is marked deleted');
    if (operation === 'mail.messages.move') {
      destination = exactMailbox(app, input.mailbox_id);
      state.destination_mailbox = destination.state;
      candidate.action = 'move_message';
      candidate.mailbox_id = destination.state.id;
    } else if (operation === 'mail.messages.set-read') {
      candidate.action = 'set_read_status';
      candidate.read = boolean(input.read, 'read');
    } else {
      state.sender = chooseSender(app, input, state.source_message, null);
      state.preferences = composePreferences(app);
      candidate.action = 'create_native_draft_only';
      candidate.send_requested = has(input, 'send') ? boolean(input.send, 'send') : false;
      candidate.external_send_in_this_step = false;
      candidate.send_requires = 'mail.drafts.get, then a separately reviewed mail.drafts.send';
      if (operation === 'mail.messages.reply') {
        candidate.body = text(input.body, 'body', true);
        candidate.reply_all = has(input, 'reply_all') ? boolean(input.reply_all, 'reply_all') : false;
      } else {
        candidate.body_prefix = has(input, 'body') ? text(input.body, 'body', true) : '';
        candidate.to = inputAddresses(app, input, 'to');
        candidate.cc = inputAddresses(app, input, 'cc');
      }
      candidate.rendering = 'Mail generates the native subject, reply recipients, quoted content and attachments. The actual draft is returned for review before any send.';
    }
  }
  return { snapshot: bounded({ version: 1, command: operation, state, candidate }), target, destination };
}

function stableCapture(app, operation, input, expectedSourceMailboxID) {
  const first = captureMutation(app, operation, input, expectedSourceMailboxID);
  const second = captureMutation(app, operation, input, expectedSourceMailboxID);
  if (!same(first.snapshot, second.snapshot)) throw failure('plan_state_changed', 'Mail state changed while being observed');
  return second;
}

function reviewedMutation(app, operation, input) {
  const expected = input.expected_mail;
  if (!expected || Array.isArray(expected) || typeof expected !== 'object'
    || Object.keys(expected).sort().join('|') !== 'candidate|command|state|version'
    || expected.version !== 1 || expected.command !== operation) {
    throw failure('plan_preview_invalid', 'This Mail mutation requires its exact reviewed snapshot');
  }
  bounded(expected);
  const sourceMailboxID = [
    'mail.messages.reply', 'mail.messages.forward', 'mail.messages.move', 'mail.messages.set-read',
  ].includes(operation)
    ? text(
      expected.state?.source_message?.mailbox_id,
      'expected_mail.state.source_message.mailbox_id',
      false
    )
    : null;
  const context = stableCapture(app, operation, input, sourceMailboxID);
  if (!same(context.snapshot, expected)) throw failure('plan_state_changed', 'Mail state changed after the plan was reviewed');
  return context;
}

function messageDateSort(left, right) {
  const a = left.date_received ? Date.parse(left.date_received) : 0;
  const b = right.date_received ? Date.parse(right.date_received) : 0;
  return b - a || compareText(left.id, right.id);
}

function messageSummary(app, message) {
  return messageState(app, message, false);
}

function messageCollection(mailbox) {
  return array(mailbox.messages(), 'mailbox.messages', 100000);
}

function selectedMailboxes(app, mailboxID) {
  if (mailboxID === undefined || mailboxID === null) return mailboxes(app);
  return [exactMailbox(app, mailboxID)];
}

function mailboxScope(mailboxEntries, requestedMailboxID) {
  const selected = requestedMailboxID !== undefined && requestedMailboxID !== null;
  const scope = {
    mode: selected ? 'exact_mailbox' : 'all_mail_app_visible_mailboxes',
    mailbox_count: mailboxEntries.length,
  };
  if (selected) scope.mailbox_id = requestedMailboxID;
  return scope;
}

function listMessages(app, input) {
  const limit = input.limit === undefined ? 50 : input.limit;
  const unreadOnly = input.unread_only === true;
  const candidates = [];
  let scanned = 0;
  let matching = 0;
  const boxes = selectedMailboxes(app, input.mailbox_id);
  boxes.forEach((entry) => {
    messageCollection(entry.object).forEach((message) => {
      scanned += 1;
      if (scanned > MAX_MESSAGE_SCAN) throw failure('mail_scan_limit', 'Mail listing exceeds its 100000 message safety bound');
      if (!unreadOnly || boolean(message.readStatus(), 'message.read') === false) {
        matching += 1;
        candidates.push(messageSummary(app, message));
        candidates.sort(messageDateSort);
        if (candidates.length > limit) candidates.pop();
      }
    });
  });
  const resultsTruncated = matching > candidates.length;
  return {
    messages: candidates, limit, scan_count: scanned,
    scan_truncated: resultsTruncated, results_truncated: resultsTruncated,
    mailbox_scope: mailboxScope(boxes, input.mailbox_id),
  };
}

function searchMessages(app, input) {
  const query = text(input.query, 'query', false).toLocaleLowerCase();
  const scanLimit = input.scan_limit === undefined ? 5000 : input.scan_limit;
  const resultLimit = input.limit === undefined ? 50 : input.limit;
  const unreadOnly = input.unread_only === true;
  const boxes = selectedMailboxes(app, input.mailbox_id);
  const matches = [];
  let scanned = 0;
  let matchCount = 0;
  let truncated = false;
  for (const entry of boxes) {
    const messages = messageCollection(entry.object);
    for (const message of messages) {
      if (scanned >= scanLimit) {
        truncated = true;
        break;
      }
      scanned += 1;
      if (unreadOnly && boolean(message.readStatus(), 'message.read')) continue;
      const body = richPlainText(message.content, 'message.content');
      const haystack = [
        text(message.subject(), 'message.subject', true),
        text(message.sender(), 'message.sender', true),
        body,
      ].join('\n').toLocaleLowerCase();
      if (haystack.includes(query)) {
        matchCount += 1;
        matches.push(messageSummary(app, message));
        matches.sort(messageDateSort);
        if (matches.length > resultLimit) matches.pop();
      }
    }
    if (truncated) break;
  }
  matches.sort(messageDateSort);
  const resultsTruncated = matchCount > resultLimit;
  return {
    messages: matches.slice(0, resultLimit), query: input.query,
    scan_limit: scanLimit, scanned, limit: resultLimit,
    scan_truncated: truncated || resultsTruncated,
    scan_limit_reached: truncated, results_truncated: resultsTruncated,
    mailbox_scope: mailboxScope(boxes, input.mailbox_id),
  };
}

function addRecipients(app, outgoing, kind, values) {
  const collection = kind === 'to' ? outgoing.toRecipients
    : kind === 'cc' ? outgoing.ccRecipients : outgoing.bccRecipients;
  const constructor = kind === 'to' ? app.ToRecipient
    : kind === 'cc' ? app.CcRecipient : app.BccRecipient;
  values.forEach((value) => collection.push(constructor({ address: value })));
}

function addAttachments(app, outgoing, paths) {
  if (paths.length === 0) return;
  const richContent = outgoing.content();
  paths.forEach((path) => {
    richContent.attachments.push(app.Attachment({ fileName: Path(path) }));
  });
}

function composeMessage(app, input, sender) {
  const outgoing = app.OutgoingMessage().make();
  outgoing.visible = false;
  outgoing.sender = sender.address;
  outgoing.subject = text(input.subject, 'subject', true);
  outgoing.content = text(input.body, 'body', true);
  addRecipients(app, outgoing, 'to', inputAddresses(app, input, 'to'));
  addRecipients(app, outgoing, 'cc', inputAddresses(app, input, 'cc'));
  addRecipients(app, outgoing, 'bcc', inputAddresses(app, input, 'bcc'));
  addAttachments(app, outgoing, array(input.attachments || [], 'attachments', 100));
  return outgoing;
}

function addressList(values) {
  return values.map((person) => person.address).sort(compareText);
}

function sameAddresses(actual, expected) {
  return same(addressList(actual), expected.slice().sort(compareText));
}

function attachmentCompositionMatches(attachments, expectedPaths, approvedNames) {
  const expectedAttachments = expectedAttachmentDescriptors(expectedPaths);
  const expectedNames = expectedAttachments.map((attachment) => attachment.name).sort(compareText);
  return same(attachmentDescriptors(attachments), expectedAttachments)
    && same(expectedNames, approvedNames.slice().sort(compareText));
}

function compositionMatches(state, candidate, senderAddress) {
  return state.sender_address === senderAddress
    && state.subject === candidate.subject
    && state.content.text === candidate.body
    && state.signature === null
    && sameAddresses(state.to, candidate.to)
    && sameAddresses(state.cc, candidate.cc)
    && sameAddresses(state.bcc, candidate.bcc);
}

function draftEvidence(app, outgoing) {
  let draftID = null;
  try { draftID = numericID(outgoing.id(), 'draft.id'); } catch (_) {}
  if (draftID !== null) effectEvidence = { action: 'draft_created', draft_id: draftID };
  return draftID;
}

function persistDraft(app, outgoing, action, reviewRequired, expectedAttachmentPaths, approvedAttachmentNames) {
  if (
    expectedAttachmentPaths !== undefined
    && !attachmentCompositionMatches(
      attachmentState(outgoing.content()), expectedAttachmentPaths, approvedAttachmentNames || []
    )
  ) {
    throw failure(
      'mail_attachment_mismatch',
      'The outgoing attachment paths changed before the draft was saved'
    );
  }
  effectStarted = true;
  const priorEvidence = effectEvidence;
  effectEvidence = { action };
  if (priorEvidence && priorEvidence.draft_id !== undefined) {
    effectEvidence.draft_id = priorEvidence.draft_id;
  }
  outgoing.save();
  const state = outgoingState(app, outgoing);
  effectEvidence = { action: 'draft_created', draft_id: state.id };
  return {
    sent: false, draft_id: state.id, draft: outgoingJSON(state),
    send_review_required: reviewRequired === true,
    disposition: 'draft_saved_locally',
  };
}

function sendOutgoing(outgoing, draftID) {
  effectStarted = true;
  effectEvidence = { action: 'send_requested', draft_id: draftID };
  const sent = outgoing.send();
  if (sent !== true) throw failure('mail_send_not_confirmed', 'Mail did not confirm the send command');
  effectEvidence = { action: 'send_command_returned', draft_id: draftID };
  return { sent: true, delivery_confirmed: false, disposition: 'send_command_returned', draft_id: draftID };
}

function createDraft(app, operation, input, context) {
  const outgoing = composeMessage(app, input, context.snapshot.state.sender);
  waitForAttachments(outgoing, input.attachments || []);
  return persistDraft(
    app,
    outgoing,
    operation,
    false,
    input.attachments || [],
    context.snapshot.candidate.attachment_names
  );
}

function sendNewMessage(app, input, context) {
  const outgoing = composeMessage(app, input, context.snapshot.state.sender);
  waitForAttachments(outgoing, input.attachments || []);
  const actual = outgoingState(app, outgoing);
  const approved = context.snapshot.candidate;
  const sender = context.snapshot.state.sender.address;
  if (!attachmentCompositionMatches(
    actual.content.attachments, input.attachments || [], approved.attachment_names
  )) {
    throw failure(
      'mail_attachment_mismatch',
      'The outgoing attachment paths do not match the reviewed files; no draft was saved or message sent'
    );
  }
  if (!compositionMatches(actual, approved, sender)) {
    return persistDraft(
      app,
      outgoing,
      'composition_requires_review',
      true,
      input.attachments || [],
      approved.attachment_names
    );
  }
  const result = sendOutgoing(outgoing, actual.id);
  result.recipients = { to: addressList(actual.to), cc: addressList(actual.cc), bcc: addressList(actual.bcc) };
  return result;
}

function prependNativeBody(outgoing, body) {
  if (body.length === 0) return;
  const storage = outgoing.content();
  storage.beginEditing();
  try {
    storage.mutableString().insertString_atIndex(body + '\n\n', 0);
  } finally {
    storage.endEditing();
  }
}

function createNativeReplyOrForward(app, operation, input, context) {
  const source = context.target;
  effectStarted = true;
  effectEvidence = { action: 'native_reply_or_forward_requested', message_id: input.message_id };
  let outgoing;
  if (operation === 'mail.messages.reply') {
    outgoing = source.reply({ openingWindow: false, replyToAll: input.reply_all === true });
    draftEvidence(app, outgoing);
    prependNativeBody(outgoing, input.body);
  } else {
    outgoing = source.forward({ openingWindow: false });
    draftEvidence(app, outgoing);
    addRecipients(app, outgoing, 'to', inputAddresses(app, input, 'to'));
    addRecipients(app, outgoing, 'cc', inputAddresses(app, input, 'cc'));
    prependNativeBody(outgoing, input.body || '');
  }
  outgoing.sender = context.snapshot.state.sender.address;
  outgoing.visible = false;
  return persistDraft(app, outgoing, operation, input.send === true);
}

function mutateMessage(app, operation, input, context) {
  const message = context.target;
  const before = context.snapshot.state.source_message;
  if (operation === 'mail.messages.move') {
    if (before.mailbox_id === context.destination.state.id) return { changed: false, message_id: before.id, mailbox: before.mailbox };
    effectStarted = true;
    effectEvidence = { action: 'message_move_requested', message_id: before.id, destination_mailbox_id: context.destination.state.id };
    message.mailbox = context.destination.object;
    const after = messageState(app, message, false);
    if (after.mailbox_id !== context.destination.state.id) {
      throw failure('mail_move_observation_mismatch', 'Mail did not report the reviewed destination mailbox');
    }
    effectEvidence = { action: 'message_moved', message_id: after.id, mailbox_id: after.mailbox_id };
    return { changed: true, message: after };
  }
  const requested = input.read === true;
  if (before.read === requested) return { changed: false, message_id: before.id, read: before.read };
  effectStarted = true;
  effectEvidence = { action: 'read_status_change_requested', message_id: before.id, read: requested };
  message.readStatus = requested;
  const after = messageState(app, message, false);
  if (after.read !== requested) throw failure('mail_read_observation_mismatch', 'Mail did not report the requested read state');
  effectEvidence = { action: 'read_status_changed', message_id: after.id, read: after.read };
  return { changed: true, message: after };
}

function executeMutation(app, operation, input) {
  const context = reviewedMutation(app, operation, input);
  switch (operation) {
    case 'mail.drafts.create': return createDraft(app, operation, input, context);
    case 'mail.messages.send': return sendNewMessage(app, input, context);
    case 'mail.drafts.send': return sendOutgoing(context.target, context.snapshot.state.draft.id);
    case 'mail.messages.reply':
    case 'mail.messages.forward': return createNativeReplyOrForward(app, operation, input, context);
    case 'mail.messages.move':
    case 'mail.messages.set-read': return mutateMessage(app, operation, input, context);
    default: throw failure('plan_preview_invalid', 'Unknown Mail mutation');
  }
}

function dispatch(operation, input) {
  const app = Application('Mail');
  app.includeStandardAdditions = false;
  if (operation === 'mail.accounts.list' && has(input, 'mutation_preview')) {
    const preview = input.mutation_preview;
    if (!preview || typeof preview !== 'object' || Array.isArray(preview)
      || Object.keys(preview).sort().join('|') !== 'command|input'
      || typeof preview.command !== 'string' || !preview.input || typeof preview.input !== 'object') {
      throw failure('plan_preview_invalid', 'Malformed Mail mutation preview request');
    }
    return { mutation_snapshot: stableCapture(app, preview.command, preview.input).snapshot };
  }
  if (MUTATIONS.includes(operation)) return executeMutation(app, operation, input);
  switch (operation) {
    case 'mail.accounts.list':
      return { accounts: accounts(app).map(accountState) };
    case 'mail.mailboxes.list': {
      const selected = mailboxes(app).filter((entry) => !input.account_id || entry.state.account_id === input.account_id);
      return { mailboxes: selected.map((entry) => entry.state) };
    }
    case 'mail.messages.list': return listMessages(app, input);
    case 'mail.messages.get': {
      const message = exactMessage(app, input.message_id);
      return { message: messageState(app, message, true) };
    }
    case 'mail.messages.search': return searchMessages(app, input);
    case 'mail.drafts.get': {
      const draft = exactDraft(app, input.draft_id);
      return { draft: outgoingJSON(outgoingState(app, draft)) };
    }
    default: throw failure('unsupported_operation', 'Unsupported Mail operation: ' + operation);
  }
}

function run(argv) {
  effectStarted = false;
  effectEvidence = null;
  const operation = argv[0];
  try {
    return JSON.stringify({ ok: true, data: dispatch(operation, readInput(argv[1])) });
  } catch (error) {
    const message = String(error && error.message ? error.message : error);
    const guardCode = error && error.mailGuardCode;
    const code = error && error.mailCode ? error.mailCode : 'mail_operation_failed';
    const details = { operation };
    if (effectEvidence !== null) details.effect_evidence = effectEvidence;
    if (effectStarted) details.effect_started = true;
    const result = {
      code, message, exit_code: guardCode ? 6 : 5,
      outcome_uncertain: effectStarted,
    };
    if (Object.keys(details).length > 1 || guardCode) result.details = details;
    return JSON.stringify({ ok: false, error: result });
  }
}
