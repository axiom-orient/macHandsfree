ObjC.import('Foundation');

function readInput(path) {
  const text = ObjC.unwrap(
    $.NSString.stringWithContentsOfFileEncodingError(
      path,
      $.NSUTF8StringEncoding,
      null
    )
  );
  return JSON.parse(text);
}

function value(callable, fallback) {
  try {
    const result = callable();
    return result === undefined || result === null ? fallback : result;
  } catch (_) {
    return fallback;
  }
}

function requiredCollection(callable, name) {
  try {
    const result = callable();
    if (Array.isArray(result)) return result;
  } catch (_) {}
  throw new Error('notes_collection_unavailable:' + name);
}

function optionalArray(callable) {
  try {
    const result = callable();
    return Array.isArray(result) ? result : null;
  } catch (_) {
    return null;
  }
}

function optionalBoolean(callable) {
  try {
    const result = callable();
    return typeof result === 'boolean' ? result : null;
  } catch (_) {
    return null;
  }
}

function optionalID(callable) {
  try {
    const result = callable();
    if (result === undefined || result === null) return null;
    const identifier = String(result);
    return identifier.length > 0 ? identifier : null;
  } catch (_) {
    return null;
  }
}

function iso(date) {
  try {
    return date ? new Date(date).toISOString() : null;
  } catch (_) {
    return null;
  }
}

function compareText(left, right) {
  const a = String(left);
  const b = String(right);
  return a < b ? -1 : a > b ? 1 : 0;
}

function objectID(object) {
  return String(value(() => object.id(), ''));
}

function requiredObjectID(object) {
  const identifier = objectID(object);
  if (identifier.length === 0) throw new Error('notes_object_identity_unavailable');
  return identifier;
}

function sortedAccounts(app) {
  return requiredCollection(() => app.accounts(), 'accounts').sort((left, right) => {
    const nameOrder = compareText(value(() => left.name(), ''), value(() => right.name(), ''));
    return nameOrder !== 0 ? nameOrder : compareText(objectID(left), objectID(right));
  });
}

function accountJSON(account) {
  return {
    id: requiredObjectID(account),
    name: String(account.name()),
    upgraded: optionalBoolean(() => account.upgraded()),
  };
}

function folderJSON(entry) {
  const folder = entry.object;
  const accountID = String(entry.accountID || '');
  if (accountID.length === 0) throw new Error('notes_object_identity_unavailable');
  return {
    id: entry.folderID || requiredObjectID(folder),
    account_id: accountID,
    name: Object.prototype.hasOwnProperty.call(entry, 'folderName')
      ? entry.folderName : String(folder.name()),
    shared: Object.prototype.hasOwnProperty.call(entry, 'folderShared')
      ? entry.folderShared : optionalBoolean(() => folder.shared()),
    container_id: Object.prototype.hasOwnProperty.call(entry, 'containerID')
      ? entry.containerID : optionalID(() => folder.container().id()),
  };
}

function noteJSON(entry, includeBody) {
  const note = entry.object;
  const accountID = String(entry.accountID || '');
  if (accountID.length === 0) throw new Error('notes_object_identity_unavailable');
  const hasSearchIndex = Object.prototype.hasOwnProperty.call(entry, 'modifiedTimestamp');
  const passwordProtected = optionalBoolean(() => note.passwordProtected());
  const result = {
    id: hasSearchIndex && entry.noteID ? entry.noteID : requiredObjectID(note),
    account_id: accountID,
    title: hasSearchIndex ? searchNoteTitle(entry) : String(note.name()),
    folder_id: optionalID(() => note.container().id()),
    created_at: iso(value(() => note.creationDate(), null)),
    modified_at: hasSearchIndex ? entry.modifiedAt : iso(value(() => note.modificationDate(), null)),
    shared: optionalBoolean(() => note.shared()),
    password_protected: passwordProtected,
  };
  if (includeBody) {
    let failures = 0;
    const readText = (callable) => {
      try {
        const content = callable();
        if (content === undefined || content === null) throw new Error('notes_body_unavailable');
        return String(content);
      } catch (_) {
        failures += 1;
        return '';
      }
    };
    result.body = readText(() => note.body());
    result.plaintext = readText(() => note.plaintext());
    if (passwordProtected === null) {
      result.body_read_status = 'incomplete';
    } else if (failures > 0) {
      result.body_read_status = passwordProtected ? 'password_protected' : 'incomplete';
    } else if (passwordProtected && result.plaintext === '') {
      // An empty protected plaintext read does not prove the body was available.
      result.body_read_status = 'incomplete';
    } else {
      result.body_read_status = 'complete';
    }
    result.body_read_failures = failures;
  }
  return result;
}

function collectFolders(container, accountID, output) {
  const collection = container.folders;
  // Bulk property chains avoid one Notes event per folder; IDs bracket the arrays to catch drift.
  const folderIDs = optionalArray(() => collection.id());
  const folders = requiredCollection(() => collection(), 'folders');
  if (folders.length === 0) return;
  const folderNames = optionalArray(() => collection.name());
  const containerIDs = optionalArray(() => collection.container.id());
  const folderShared = optionalArray(() => collection.shared());
  const folderIDsAfterRead = optionalArray(() => collection.id());
  const bulkMatches = folderIDs !== null && folderNames !== null && folderIDsAfterRead !== null
    && folderIDs.length === folders.length && folderNames.length === folders.length
    && folderIDsAfterRead.length === folders.length
    && folderIDs.every((id) => id !== null && id !== undefined && String(id).length > 0)
    && folderIDs.every((id, index) => id === folderIDsAfterRead[index]);
  folders.forEach((folder, index) => {
    const folderID = bulkMatches && folderIDs[index] !== null && folderIDs[index] !== undefined
      ? String(folderIDs[index]) : objectID(folder);
    if (folderID.length === 0) throw new Error('notes_object_identity_unavailable');
    const folderName = bulkMatches ? String(folderNames[index]) : String(folder.name());
    const bulkContainerID = containerIDs !== null && containerIDs.length === folders.length
      ? optionalID(() => containerIDs[index]) : null;
    const containerID = bulkContainerID
      || optionalID(() => folder.container().id());
    const sharedValue = folderShared !== null && folderShared.length === folders.length
      ? folderShared[index] : null;
    const shared = typeof sharedValue === 'boolean'
      ? sharedValue : optionalBoolean(() => folder.shared());
    output.push({
      object: folder, accountID, folderID, folderName, containerID, folderShared: shared,
    });
    collectFolders(folder, accountID, output);
  });
}

function uniqueEntries(entries) {
  const output = [];
  const seen = Object.create(null);
  entries.forEach((entry) => {
    const key = '$' + (entry.folderID || entry.noteID || objectID(entry.object));
    if (!seen[key]) {
      seen[key] = true;
      output.push(entry);
    }
  });
  return output;
}

function indexSearchNoteEntry(entry, noteID, sequence, title, modifiedAt) {
  const modifiedTimestamp = modifiedAt === null || modifiedAt === undefined
    ? 0 : new Date(modifiedAt).getTime();
  return {
    object: entry.object,
    accountID: entry.accountID,
    noteID,
    sequence,
    modifiedAt: iso(modifiedAt),
    searchTitle: String(title),
    modifiedTimestamp: Number.isFinite(modifiedTimestamp) ? modifiedTimestamp : 0,
  };
}

function searchNoteTitle(entry) {
  if (!Object.prototype.hasOwnProperty.call(entry, 'searchTitle')) {
    entry.searchTitle = String(entry.object.name());
  }
  return entry.searchTitle;
}

function compareSearchNoteEntries(left, right) {
  const modifiedOrder = right.modifiedTimestamp - left.modifiedTimestamp;
  if (modifiedOrder !== 0) return modifiedOrder;
  const titleOrder = compareText(searchNoteTitle(left), searchNoteTitle(right));
  if (titleOrder !== 0) return titleOrder;
  const idOrder = compareText(left.noteID || '', right.noteID || '');
  // Match the prior stable sort when every observable key ties.
  return idOrder !== 0 ? idOrder : left.sequence - right.sequence;
}

function retainSearchNoteEntry(index, entry) {
  index.count += 1;
  const heap = index.heap;
  if (index.limit <= 0) return;
  // The root is the least recent retained candidate, so the heap stays result-sized.
  if (heap.length < index.limit) {
    heap.push(entry);
    let child = heap.length - 1;
    while (child > 0) {
      const parent = Math.floor((child - 1) / 2);
      if (compareSearchNoteEntries(heap[child], heap[parent]) <= 0) break;
      [heap[parent], heap[child]] = [heap[child], heap[parent]];
      child = parent;
    }
    return;
  }
  if (compareSearchNoteEntries(entry, heap[0]) >= 0) return;
  heap[0] = entry;
  let parent = 0;
  while (true) {
    const left = parent * 2 + 1;
    if (left >= heap.length) return;
    const right = left + 1;
    let worseChild = left;
    if (right < heap.length && compareSearchNoteEntries(heap[right], heap[left]) > 0) {
      worseChild = right;
    }
    if (compareSearchNoteEntries(heap[worseChild], heap[parent]) <= 0) return;
    [heap[parent], heap[worseChild]] = [heap[worseChild], heap[parent]];
    parent = worseChild;
  }
}

function retainSearchNoteCandidate(note, accountID, rawNoteID, title, modifiedAt, coverage, index) {
  const noteID = rawNoteID === null || rawNoteID === undefined ? '' : String(rawNoteID);
  if (noteID.length === 0) {
    coverage.identityFailures += 1;
  } else {
    const key = '$' + noteID;
    if (index.seen[key]) return;
    index.seen[key] = true;
  }
  const entry = indexSearchNoteEntry(
    { object: note, accountID }, noteID || null, index.count, title, modifiedAt
  );
  retainSearchNoteEntry(index, entry);
}

function addSearchNoteObjects(notes, accountID, coverage, index) {
  notes.forEach((note) => {
    let title = '';
    let modifiedAt = null;
    try { title = note.name(); } catch (_) { coverage.collectionFailures += 1; }
    try { modifiedAt = note.modificationDate(); } catch (_) { coverage.collectionFailures += 1; }
    retainSearchNoteCandidate(note, accountID, objectID(note), title, modifiedAt, coverage, index);
  });
}

function addSearchNoteCollection(container, accountID, coverage, index) {
  let collection;
  try {
    collection = container.notes;
  } catch (_) {
    coverage.collectionFailures += 1;
    return;
  }
  const failuresBeforeRead = coverage.collectionFailures;
  // JXA property chains fetch metadata columns per collection, not once per note.
  const noteIDs = searchCollection(() => collection.id(), coverage);
  const notes = searchCollection(() => collection(), coverage);
  if (noteIDs.length === 0 && notes.length === 0) return;
  const titles = searchCollection(() => collection.name(), coverage);
  const modificationDates = searchCollection(() => collection.modificationDate(), coverage);
  // Do not zip rows if Notes changed collection membership during the bulk reads.
  const noteIDsAfterRead = searchCollection(() => collection.id(), coverage);
  const stableIDs = noteIDs.length === noteIDsAfterRead.length
    && noteIDs.every((id, noteIndex) => id === noteIDsAfterRead[noteIndex]);
  if (!stableIDs || notes.length !== noteIDs.length || titles.length !== noteIDs.length
    || modificationDates.length !== noteIDs.length) {
    if (coverage.collectionFailures === failuresBeforeRead) coverage.collectionFailures += 1;
    addSearchNoteObjects(notes, accountID, coverage, index);
    return;
  }
  notes.forEach((note, noteIndex) => {
    retainSearchNoteCandidate(
      note, accountID, noteIDs[noteIndex], titles[noteIndex],
      modificationDates[noteIndex], coverage, index
    );
  });
}

function allFolderEntries(app, requestedAccountID) {
  const output = [];
  const selectedAccounts = requestedAccountID === null || requestedAccountID === undefined
    ? sortedAccounts(app)
    : requiredCollection(() => app.accounts(), 'accounts').filter(
      (account) => objectID(account) === requestedAccountID
    );
  if (selectedAccounts.length > 1) throw new Error('ambiguous_id:' + requestedAccountID);
  selectedAccounts.forEach((account) => {
    collectFolders(account, requiredObjectID(account), output);
  });
  return uniqueEntries(output).sort((left, right) => {
    const accountOrder = compareText(left.accountID, right.accountID);
    if (accountOrder !== 0) return accountOrder;
    const nameOrder = compareText(left.folderName, right.folderName);
    return nameOrder !== 0
      ? nameOrder
      : compareText(left.folderID, right.folderID);
  });
}

function allNoteEntries(app) {
  const output = [];
  sortedAccounts(app).forEach((account) => {
    const accountID = requiredObjectID(account);
    requiredCollection(() => account.notes(), 'notes').forEach((note) => {
      output.push({ object: note, accountID });
    });
    const folders = [];
    collectFolders(account, accountID, folders);
    folders.forEach((entry) => {
      requiredCollection(() => entry.object.notes(), 'notes').forEach((note) => {
        output.push({ object: note, accountID });
      });
    });
  });
  return uniqueEntries(output);
}

function searchCollection(callable, coverage) {
  try {
    const entries = callable();
    if (!Array.isArray(entries)) throw new Error('invalid_notes_search_collection');
    return entries;
  } catch (_) {
    coverage.collectionFailures += 1;
    return [];
  }
}

// Visit folders in place instead of retaining a scope-wide proxy list.
function visitSearchFolders(container, accountID, coverage, visit) {
  let collection;
  try {
    collection = container.folders;
  } catch (_) {
    coverage.collectionFailures += 1;
    return;
  }
  const failuresBeforeRead = coverage.collectionFailures;
  const folderIDs = searchCollection(() => collection.id(), coverage);
  const folders = searchCollection(() => collection(), coverage);
  if (folderIDs.length === 0 && folders.length === 0) return;
  const folderIDsAfterRead = searchCollection(() => collection.id(), coverage);
  const stableIDs = folderIDs.length === folderIDsAfterRead.length
    && folderIDs.every((id, folderIndex) => id === folderIDsAfterRead[folderIndex]);
  if (!stableIDs || folders.length !== folderIDs.length) {
    if (coverage.collectionFailures === failuresBeforeRead) coverage.collectionFailures += 1;
    folders.forEach((folder) => {
      const id = objectID(folder);
      if (id) visit({ object: folder, accountID, folderID: id });
      else coverage.collectionFailures += 1;
      visitSearchFolders(folder, accountID, coverage, visit);
    });
    return;
  }
  folders.forEach((folder, folderIndex) => {
    const rawFolderID = folderIDs[folderIndex];
    const folderID = rawFolderID === null || rawFolderID === undefined
      ? '' : String(rawFolderID);
    if (folderID) visit({ object: folder, accountID, folderID });
    else coverage.collectionFailures += 1;
    visitSearchFolders(folder, accountID, coverage, visit);
  });
}

function searchNoteEntries(app, requestedAccountID, requestedFolderID, coverage, candidateLimit) {
  const accounts = searchCollection(() => app.accounts(), coverage).slice().sort((left, right) => {
    const nameOrder = compareText(value(() => left.name(), ''), value(() => right.name(), ''));
    return nameOrder !== 0 ? nameOrder : compareText(objectID(left), objectID(right));
  });
  const selectedAccounts = requestedAccountID
    ? accounts.filter((account) => objectID(account) === requestedAccountID)
    : accounts;
  let scopeFound = !requestedAccountID || selectedAccounts.length > 0;
  const accountEntries = [];
  const noteIndex = {
    limit: candidateLimit,
    count: 0,
    seen: Object.create(null),
    heap: [],
  };

  selectedAccounts.forEach((account) => {
    const accountID = objectID(account);
    if (!accountID) {
      coverage.collectionFailures += 1;
      return;
    }
    accountEntries.push({ object: account, accountID });
  });

  if (!requestedFolderID) {
    accountEntries.forEach((entry) => {
      addSearchNoteCollection(entry.object, entry.accountID, coverage, noteIndex);
    });
  }

  const folderMatches = [];
  accountEntries.forEach((entry) => {
    visitSearchFolders(entry.object, entry.accountID, coverage, (folderEntry) => {
      if (requestedFolderID) {
        if (folderEntry.folderID === requestedFolderID) folderMatches.push(folderEntry);
      } else {
        addSearchNoteCollection(folderEntry.object, entry.accountID, coverage, noteIndex);
      }
    });
  });

  if (requestedFolderID
    && !folderMatches.some((entry) => entry.folderID === requestedFolderID)) {
    accountEntries.forEach((entry) => {
      try {
        const defaultFolder = entry.object.defaultFolder();
        const defaultFolderID = strictString(defaultFolder.id(), 'default_folder_id', false);
        if (defaultFolderID === requestedFolderID) {
          folderMatches.push({
            object: defaultFolder, accountID: entry.accountID, folderID: defaultFolderID,
          });
        }
      } catch (_) {
        coverage.collectionFailures += 1;
      }
    });
  }

  let scopeAmbiguous = false;
  if (requestedFolderID) {
    scopeFound = scopeFound && folderMatches.length > 0;
    scopeAmbiguous = folderMatches.length > 1;
    if (!scopeAmbiguous) {
      folderMatches.forEach((entry) => {
        addSearchNoteCollection(entry.object, entry.accountID, coverage, noteIndex);
      });
    }
  }

  if (scopeAmbiguous) return { entries: [], count: 0, scopeFound: false, scopeAmbiguous };
  const entries = noteIndex.heap.sort(compareSearchNoteEntries);
  return { entries, count: noteIndex.count, scopeFound, scopeAmbiguous };
}

function entryByID(entries, id) {
  const matches = entries.filter((entry) => objectID(entry.object) === String(id));
  if (matches.length === 0) throw new Error('not_found:' + id);
  if (matches.length > 1) throw new Error('ambiguous_id:' + id);
  return matches[0];
}

function escapeHTML(text) {
  return String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/\n/g, '<br>');
}

function noteBody(title, body, format) {
  const content = format === 'html' ? String(body) : escapeHTML(body);
  return '<h1>' + escapeHTML(title) + '</h1>' + content;
}

// Only the host adds snapshot selectors and expected state after public schema validation.
// These reads deliberately do not use value(..., fallback): missing evidence stops the mutation.
function notesGuardFailure(code, message) {
  const error = new Error(message);
  error.notesGuardCode = code;
  return error;
}

function strictString(result, field, allowEmpty) {
  if (typeof result !== 'string' || (!allowEmpty && result.length === 0)) {
    throw new Error('invalid_note_snapshot_field:' + field);
  }
  return result;
}

function strictArray(result, field) {
  if (!Array.isArray(result)) throw new Error('invalid_note_snapshot_collection:' + field);
  return result;
}

function strictNoteEntry(app, noteID) {
  let match = null;
  const visitedFolders = Object.create(null);
  function collectNotes(container, accountID) {
    strictArray(container.notes(), 'notes').forEach((note) => {
      if (strictString(note.id(), 'note_id', false) !== noteID) return;
      if (match !== null && match.accountID !== accountID) {
        throw new Error('ambiguous_id:' + noteID);
      }
      match = { object: note, accountID };
    });
  }
  function collectStrictFolders(container, accountID) {
    strictArray(container.folders(), 'folders').forEach((folder) => {
      const key = JSON.stringify([accountID, strictString(folder.id(), 'folder_id', false)]);
      if (visitedFolders[key]) return;
      visitedFolders[key] = true;
      collectNotes(folder, accountID);
      collectStrictFolders(folder, accountID);
    });
  }
  strictArray(app.accounts(), 'accounts').forEach((account) => {
    const accountID = strictString(account.id(), 'account_id', false);
    collectNotes(account, accountID);
    collectStrictFolders(account, accountID);
  });
  if (match === null) throw new Error('not_found:' + noteID);
  return match;
}

function strictModifiedAt(note) {
  const date = note.modificationDate();
  if (!(date instanceof Date) || !Number.isFinite(date.getTime())) {
    throw new Error('invalid_note_snapshot_field:modified_at');
  }
  return date.toISOString();
}

function noteUpdateSnapshot(entry) {
  const note = entry.object;
  const modifiedAt = strictModifiedAt(note);
  const protectedNote = note.passwordProtected();
  if (typeof protectedNote !== 'boolean' || protectedNote) {
    throw new Error('note_update_protected_or_unreadable');
  }
  const snapshot = {
    version: 1,
    note_id: strictString(note.id(), 'note_id', false),
    account_id: strictString(entry.accountID, 'account_id', false),
    folder_id: strictString(note.container().id(), 'folder_id', false),
    title: strictString(note.name(), 'title', true),
    body: strictString(note.body(), 'body', true),
    modified_at: modifiedAt,
  };
  if (strictModifiedAt(note) !== modifiedAt) throw new Error('note_changed_during_snapshot');
  return snapshot;
}

function validateExpectedNote(expected, noteID) {
  const fields = ['version', 'note_id', 'account_id', 'folder_id', 'title', 'body', 'modified_at'];
  if (!expected || typeof expected !== 'object' || Array.isArray(expected)
    || Object.keys(expected).sort().join('|') !== fields.slice().sort().join('|')
    || expected.version !== 1 || expected.note_id !== noteID) {
    throw new Error('invalid_note_snapshot');
  }
  fields.slice(1).forEach((field) => {
    strictString(expected[field], field, field === 'title' || field === 'body');
  });
  const date = new Date(expected.modified_at);
  if (!Number.isFinite(date.getTime()) || date.toISOString() !== expected.modified_at) {
    throw new Error('invalid_note_snapshot_field:modified_at');
  }
  return fields;
}

function reviewedNoteForUpdate(app, input) {
  let fields;
  try {
    fields = validateExpectedNote(input.expected_note, input.note_id);
  } catch (error) {
    throw notesGuardFailure('plan_preview_invalid', String(error.message || error));
  }
  try {
    const entry = strictNoteEntry(app, input.note_id);
    const current = noteUpdateSnapshot(entry);
    if (fields.some((field) => current[field] !== input.expected_note[field])) {
      throw new Error('note_changed_after_plan');
    }
    return entry;
  } catch (error) {
    throw notesGuardFailure('plan_state_changed', String(error.message || error));
  }
}

const maximumNotesMutationBytes = 256 * 1024;
const maximumNotesMutationEntities = 500;

function boundedMutationCollection(collection, name, maximumCount) {
  const count = collection.length;
  if (!Number.isSafeInteger(count) || count < 0) {
    throw new Error('notes_collection_count_unavailable:' + name);
  }
  if (count > maximumCount) throw new Error('notes_mutation_snapshot_too_large');
  if (count === 0) return [];
  const values = requiredCollection(() => collection(), name);
  if (values.length > maximumCount) throw new Error('notes_mutation_snapshot_too_large');
  if (values.length !== count) throw new Error('notes_changed_during_snapshot');
  return values;
}

function strictBoolean(result, field) {
  if (typeof result !== 'boolean') throw new Error('invalid_note_snapshot_field:' + field);
  return result;
}

function strictDate(result, field) {
  if (!(result instanceof Date) || !Number.isFinite(result.getTime())) {
    throw new Error('invalid_note_snapshot_field:' + field);
  }
  return result.toISOString();
}

function snapshotBytes(snapshot) {
  return Number($(JSON.stringify(snapshot)).lengthOfBytesUsingEncoding($.NSUTF8StringEncoding));
}

function requireBoundedNotesState(snapshot) {
  const bytes = snapshotBytes(snapshot);
  if (!Number.isFinite(bytes) || bytes > maximumNotesMutationBytes) {
    throw new Error('notes_mutation_snapshot_too_large');
  }
  return snapshot;
}

function sameNotesState(left, right) {
  if (left === right) return true;
  if (!left || !right || typeof left !== 'object' || typeof right !== 'object'
    || Array.isArray(left) !== Array.isArray(right)) return false;
  const leftKeys = Object.keys(left).sort();
  const rightKeys = Object.keys(right).sort();
  return leftKeys.length === rightKeys.length
    && leftKeys.every((key, index) => key === rightKeys[index] && sameNotesState(left[key], right[key]));
}

function strictFolderEntry(app, folderID) {
  let match = null;
  const visited = Object.create(null);
  function visit(container, accountID) {
    strictArray(container.folders(), 'folders').forEach((folder) => {
      const id = strictString(folder.id(), 'folder_id', false);
      const key = JSON.stringify([accountID, id]);
      if (id === folderID) {
        if (match && match.accountID !== accountID) throw new Error('ambiguous_id:' + folderID);
        match = { object: folder, accountID };
      }
      if (visited[key]) return;
      visited[key] = true;
      visit(folder, accountID);
    });
  }
  strictArray(app.accounts(), 'accounts').forEach((account) => {
    visit(account, strictString(account.id(), 'account_id', false));
  });
  if (!match) throw new Error('not_found:' + folderID);
  return match;
}

function strictFolderSnapshot(entry) {
  return {
    folder_id: strictString(entry.object.id(), 'folder_id', false),
    account_id: strictString(entry.accountID, 'account_id', false),
    name: strictString(entry.object.name(), 'folder_name', true),
    container_id: strictString(entry.object.container().id(), 'container_id', false),
    shared: strictBoolean(entry.object.shared(), 'folder_shared'),
  };
}

function strictDefaultFolderEntry(app, accountID) {
  const accountEntry = strictAccountEntry(app, accountID);
  const folderEntry = { object: accountEntry.object.defaultFolder(), accountID };
  const snapshot = strictFolderSnapshot(folderEntry);
  if (snapshot.container_id !== accountID) throw new Error('default_folder_account_mismatch');
  return folderEntry;
}

function strictNoteFolderEntryByID(app, folderID) {
  try {
    return strictFolderEntry(app, folderID);
  } catch (error) {
    if (String(error.message || error) !== 'not_found:' + folderID) throw error;
  }
  const matches = strictArray(app.accounts(), 'accounts').filter((account) =>
    strictString(account.defaultFolder().id(), 'default_folder_id', false) === folderID);
  if (matches.length === 0) throw new Error('not_found:' + folderID);
  if (matches.length > 1) throw new Error('ambiguous_id:' + folderID);
  return strictDefaultFolderEntry(app, strictString(matches[0].id(), 'account_id', false));
}

function strictNoteFolderEntry(app, entry) {
  const containerID = strictString(entry.object.container().id(), 'note_container_id', false);
  const folderEntry = strictNoteFolderEntryByID(app, containerID);
  if (folderEntry.accountID !== entry.accountID) throw new Error('note_container_account_mismatch');
  return folderEntry;
}

function hasSharedFolderAncestor(app, entry) {
  const accountID = strictString(entry.accountID, 'account_id', false);
  const account = strictAccountEntry(app, accountID);
  const defaultFolderID = strictString(account.object.defaultFolder().id(), 'default_folder_id', false);
  let parentObject = entry.object.container();
  let parentID = strictString(parentObject.id(), 'folder_container_id', false);
  const visited = Object.create(null);
  let depth = 0;
  let shared = false;
  while (parentID !== accountID && parentID !== defaultFolderID) {
    if (visited[parentID]) throw new Error('folder_cycle');
    visited[parentID] = true;
    depth += 1;
    if (depth > maximumNotesMutationEntities) throw new Error('notes_mutation_snapshot_too_large');
    const parent = strictFolderSnapshot({ object: parentObject, accountID });
    if (parent.folder_id !== parentID) throw new Error('folder_changed_during_snapshot');
    if (parent.shared) shared = true;
    parentID = parent.container_id;
    parentObject = parentObject.container();
  }
  return shared;
}

function noteFolderSelectorKey(input) {
  const hasAccount = Object.prototype.hasOwnProperty.call(input, 'account_id');
  const hasFolder = Object.prototype.hasOwnProperty.call(input, 'folder_id');
  if (hasAccount === hasFolder) throw new Error('notes_folder_selector_invalid');
  return hasAccount ? 'account_id' : 'folder_id';
}

function strictNoteFolderTarget(app, input) {
  const key = noteFolderSelectorKey(input);
  const targetID = strictString(input[key], key, false);
  return key === 'account_id'
    ? strictDefaultFolderEntry(app, targetID)
    : strictNoteFolderEntryByID(app, targetID);
}

function strictAccountEntry(app, accountID) {
  const matches = strictArray(app.accounts(), 'accounts').filter((account) =>
    strictString(account.id(), 'account_id', false) === accountID);
  if (matches.length !== 1) throw new Error(matches.length ? 'ambiguous_id:' + accountID : 'not_found:' + accountID);
  return { object: matches[0], accountID };
}

function strictAccountSnapshot(entry) {
  return {
    account_id: strictString(entry.object.id(), 'account_id', false),
    name: strictString(entry.object.name(), 'account_name', true),
    upgraded: strictBoolean(entry.object.upgraded(), 'account_upgraded'),
  };
}

function strictSavedNoteResult(entry) {
  const note = entry.object;
  const content = noteUpdateSnapshot(entry);
  const result = {
    id: content.note_id,
    account_id: content.account_id,
    title: content.title,
    folder_id: content.folder_id,
    folder_name: strictString(note.container().name(), 'folder_name', true),
    created_at: strictDate(note.creationDate(), 'created_at'),
    modified_at: content.modified_at,
    shared: strictBoolean(note.shared(), 'note_shared'),
    password_protected: false,
    body: content.body,
    plaintext: strictString(note.plaintext(), 'plaintext', true),
    body_read_status: 'complete',
    body_read_failures: 0,
  };
  if (strictModifiedAt(note) !== content.modified_at) throw new Error('note_changed_during_readback');
  return result;
}

function noteExportSnapshot(entry, format) {
  if (format !== 'html' && format !== 'plaintext') throw new Error('invalid_notes_export_format');
  const note = entry.object;
  const modifiedAt = strictModifiedAt(note);
  if (strictBoolean(note.passwordProtected(), 'password_protected')) {
    throw new Error('note_export_protected');
  }
  const snapshot = {
    version: 1,
    note_id: strictString(note.id(), 'note_id', false),
    account_id: strictString(entry.accountID, 'account_id', false),
    folder_id: strictString(note.container().id(), 'folder_id', false),
    title: strictString(note.name(), 'title', true),
    shared: strictBoolean(note.shared(), 'note_shared'),
    modified_at: modifiedAt,
    format,
    content: strictString(format === 'html' ? note.body() : note.plaintext(), 'export_content', true),
  };
  if (strictModifiedAt(note) !== modifiedAt) throw new Error('note_changed_during_snapshot');
  return requireBoundedNotesState(snapshot);
}

function exportSnapshotRequest(app, input) {
  try {
    if (input.snapshot_for_export !== true
      || Object.keys(input).sort().join('|') !== 'format|note_id|snapshot_for_export') {
      throw new Error('invalid_notes_export_snapshot_request');
    }
    const noteID = strictString(input.note_id, 'note_id', false);
    const first = noteExportSnapshot(strictNoteEntry(app, noteID), input.format);
    const second = noteExportSnapshot(strictNoteEntry(app, noteID), input.format);
    if (first.note_id !== noteID || second.note_id !== noteID || !sameNotesState(first, second)) {
      throw new Error('note_changed_during_snapshot');
    }
    return { export_snapshot: second };
  } catch (error) {
    throw notesGuardFailure('notes_export_snapshot_unavailable', String(error.message || error));
  }
}

function structuralNoteSnapshot(
  entry, maximumEntities = maximumNotesMutationEntities, expectedContent = null
) {
  const note = entry.object;
  const content = expectedContent || noteUpdateSnapshot(entry);
  if (!Number.isSafeInteger(maximumEntities) || maximumEntities < 1) {
    throw new Error('notes_mutation_snapshot_too_large');
  }
  const attachments = boundedMutationCollection(note.attachments, 'attachments', maximumEntities - 1);
  const ids = Object.create(null);
  const snapshot = {
    content,
    created_at: strictDate(note.creationDate(), 'created_at'),
    shared: strictBoolean(note.shared(), 'note_shared'),
    attachments: attachments.map((attachment) => {
      const id = strictString(attachment.id(), 'attachment_id', false);
      const containerID = strictString(attachment.container().id(), 'attachment_container', false);
      if (ids[id] || containerID !== content.note_id) throw new Error('ambiguous_attachment:' + id);
      ids[id] = true;
      const url = attachment.url();
      return {
        id,
        name: strictString(attachment.name(), 'attachment_name', true),
        container_id: containerID,
        content_identifier: strictString(attachment.contentIdentifier(), 'content_identifier', true),
        created_at: strictDate(attachment.creationDate(), 'attachment_created_at'),
        modified_at: strictDate(attachment.modificationDate(), 'attachment_modified_at'),
        url: url === null || url === undefined ? null : strictString(url, 'attachment_url', true),
        shared: strictBoolean(attachment.shared(), 'attachment_shared'),
      };
    }).sort((left, right) => compareText(left.id, right.id)),
  };
  if (strictModifiedAt(note) !== content.modified_at) throw new Error('note_changed_during_snapshot');
  return requireBoundedNotesState(snapshot);
}

function folderDeletionSnapshot(app, rootEntry) {
  const root = strictFolderSnapshot(rootEntry);
  const account = strictAccountEntry(app, root.account_id);
  const defaultFolderID = strictString(account.object.defaultFolder().id(), 'default_folder_id', false);
  root.is_default_folder = defaultFolderID === root.folder_id;
  root.shared_ancestor = hasSharedFolderAncestor(app, rootEntry);
  const folders = Object.create(null);
  const notes = Object.create(null);
  let entityCount = 0;
  let bytes = 2;
  function consume(snapshot, count) {
    entityCount += count;
    bytes += snapshotBytes(snapshot) + 1;
    if (entityCount > maximumNotesMutationEntities || bytes > maximumNotesMutationBytes) {
      throw new Error('notes_mutation_snapshot_too_large');
    }
  }
  function visit(entry) {
    const folder = strictFolderSnapshot(entry);
    if (folders[folder.folder_id]) {
      if (!sameNotesState(folders[folder.folder_id], folder)) throw new Error('folder_changed_during_snapshot');
      return;
    }
    consume(folder, 1);
    folders[folder.folder_id] = folder;
    const folderNotes = boundedMutationCollection(
      entry.object.notes, 'folder_notes', maximumNotesMutationEntities - entityCount);
    folderNotes.forEach((note) => {
      const entry = { object: note, accountID: root.account_id };
      const content = noteUpdateSnapshot(entry);
      const maximumEntities = notes[content.note_id]
        ? maximumNotesMutationEntities : maximumNotesMutationEntities - entityCount;
      const snapshot = structuralNoteSnapshot(entry, maximumEntities, content);
      const id = snapshot.content.note_id;
      if (notes[id]) {
        if (!sameNotesState(notes[id], snapshot)) throw new Error('note_changed_during_snapshot');
      } else {
        consume(snapshot, 1 + snapshot.attachments.length);
        notes[id] = snapshot;
      }
    });
    const childFolders = boundedMutationCollection(
      entry.object.folders, 'child_folders', maximumNotesMutationEntities - entityCount);
    childFolders.forEach((folderObject) => {
      visit({ object: folderObject, accountID: root.account_id });
    });
  }
  visit(rootEntry);
  if (folders[root.container_id]) throw new Error('folder_cycle');
  const folderValues = Object.keys(folders).sort().map((id) => folders[id]);
  folderValues.forEach((folder) => {
    const seen = Object.create(null);
    let cursor = folder;
    while (cursor.folder_id !== root.folder_id) {
      if (seen[cursor.folder_id]) throw new Error('folder_cycle');
      seen[cursor.folder_id] = true;
      cursor = folders[cursor.container_id];
      if (!cursor) throw new Error('folder_changed_during_snapshot');
    }
  });
  const noteValues = Object.keys(notes).sort().map((id) => notes[id]);
  noteValues.forEach((note) => {
    if (!folders[note.content.folder_id]) throw new Error('note_changed_during_snapshot');
  });
  return { root, folders: folderValues, notes: noteValues };
}

function structuralMutationVersion(command) {
  if (command === 'notes.folders.delete') return 3;
  if (command === 'notes.items.delete') return 2;
  return 1;
}

function captureStructuralMutation(app, command, input) {
  if (command === 'notes.folders.create') {
    const accountID = strictString(input.account_id, 'account_id', false);
    const accountEntry = strictAccountEntry(app, accountID);
    let parentEntry = null;
    if (input.parent_folder_id !== undefined) {
      parentEntry = strictFolderEntry(app, strictString(input.parent_folder_id, 'parent_folder_id', false));
      if (parentEntry.accountID !== accountID) throw new Error('folder_account_mismatch');
    }
    const target = {
      account: strictAccountSnapshot(accountEntry),
      parent_folder: parentEntry ? strictFolderSnapshot(parentEntry) : null,
    };
    return { accountEntry, parentEntry, snapshot: requireBoundedNotesState({ version: 1, command, target }) };
  }
  if (command === 'notes.items.create') {
    const destinationEntry = strictNoteFolderTarget(app, input);
    const accountEntry = strictAccountEntry(app, destinationEntry.accountID);
    const target = {
      account: strictAccountSnapshot(accountEntry),
      destination_folder: strictFolderSnapshot(destinationEntry),
    };
    if (Object.prototype.hasOwnProperty.call(input, 'account_id')) {
      target.destination_is_default = true;
    }
    if (target.destination_folder.folder_id
      !== strictString(destinationEntry.object.id(), 'folder_id', false)
      || target.account.account_id !== target.destination_folder.account_id) {
      throw new Error('folder_changed_during_snapshot');
    }
    return { destinationEntry, snapshot: requireBoundedNotesState({ version: 1, command, target }) };
  }
  if (command === 'notes.folders.delete') {
    const folderID = strictString(input.folder_id, 'folder_id', false);
    const folderEntry = strictFolderEntry(app, folderID);
    const target = folderDeletionSnapshot(app, folderEntry);
    if (target.root.folder_id !== folderID) throw new Error('folder_changed_during_snapshot');
    return { folderEntry, snapshot: requireBoundedNotesState({ version: structuralMutationVersion(command), command, target }) };
  }
  const noteID = strictString(input.note_id, 'note_id', false);
  const noteEntry = strictNoteEntry(app, noteID);
  const note = structuralNoteSnapshot(noteEntry);
  const sourceFolderEntry = strictNoteFolderEntry(app, noteEntry);
  const sourceFolder = strictFolderSnapshot(sourceFolderEntry);
  if (note.content.note_id !== noteID
    || note.content.account_id !== sourceFolder.account_id
    || note.content.folder_id !== sourceFolder.folder_id) {
    throw new Error('note_changed_during_snapshot');
  }
  let destinationEntry = null;
  if (command === 'notes.items.move') {
    destinationEntry = strictNoteFolderTarget(app, input);
  } else if (command !== 'notes.items.delete') {
    throw new Error('invalid_notes_mutation');
  }
  const target = {
    note,
    source_folder: sourceFolder,
    destination_folder: destinationEntry ? strictFolderSnapshot(destinationEntry) : null,
  };
  if (command === 'notes.items.delete') {
    target.shared_ancestor = hasSharedFolderAncestor(app, sourceFolderEntry);
  }
  if (command === 'notes.items.move' && Object.prototype.hasOwnProperty.call(input, 'account_id')) {
    target.destination_is_default = true;
  }
  return { noteEntry, destinationEntry, snapshot: requireBoundedNotesState({ version: structuralMutationVersion(command), command, target }) };
}

function stableStructuralMutation(app, command, input) {
  const first = captureStructuralMutation(app, command, input);
  const second = captureStructuralMutation(app, command, input);
  if (!sameNotesState(first.snapshot, second.snapshot)) throw new Error('notes_changed_during_snapshot');
  return second;
}

function mutationSnapshotRequest(app, input, folderRequest) {
  try {
    const command = input.snapshot_for_mutation;
    let expectedKeys;
    if (folderRequest) {
      if (command === 'notes.folders.create') {
        expectedKeys = ['account_id', 'snapshot_for_mutation'];
        if (input.parent_folder_id !== undefined) expectedKeys.push('parent_folder_id');
      } else if (command === 'notes.folders.delete') {
        expectedKeys = ['folder_id', 'snapshot_for_mutation'];
      } else if (command === 'notes.items.create') {
        expectedKeys = [noteFolderSelectorKey(input), 'snapshot_for_mutation'];
      }
    } else if (command === 'notes.items.move') {
      expectedKeys = [noteFolderSelectorKey(input), 'note_id', 'snapshot_for_mutation'];
    } else if (command === 'notes.items.delete') {
      expectedKeys = ['note_id', 'snapshot_for_mutation'];
    }
    if (!expectedKeys || Object.keys(input).sort().join('|') !== expectedKeys.sort().join('|')) {
      throw new Error('invalid_notes_snapshot_request');
    }
    return { mutation_snapshot: stableStructuralMutation(app, command, input).snapshot };
  } catch (error) {
    throw notesGuardFailure('notes_mutation_snapshot_unavailable', String(error.message || error));
  }
}

function reviewedStructuralMutation(app, command, input) {
  const expected = input.expected_notes_state;
  const expectedVersion = structuralMutationVersion(command);
  if (!expected || expected.version !== expectedVersion || expected.command !== command || !expected.target
    || Object.keys(expected).sort().join('|') !== 'command|target|version') {
    throw notesGuardFailure('plan_preview_invalid', 'invalid_notes_mutation_snapshot');
  }
  try {
    requireBoundedNotesState(expected);
    const current = stableStructuralMutation(app, command, input);
    if (!sameNotesState(current.snapshot, expected)) throw new Error('notes_changed_after_plan');
    return current;
  } catch (error) {
    throw notesGuardFailure('plan_state_changed', String(error.message || error));
  }
}

function selectedNotesReadScope(input) {
  const selectedID = (key) => {
    if (!Object.prototype.hasOwnProperty.call(input, key)) return null;
    const value = input[key];
    if (typeof value !== 'string' || value.length === 0) {
      throw new Error('notes_scope_invalid:invalid_' + key);
    }
    return value;
  };
  const accountID = selectedID('account_id');
  const folderID = selectedID('folder_id');
  const allVisibleNotes = Object.prototype.hasOwnProperty.call(input, 'all_visible_notes')
    ? input.all_visible_notes
    : false;
  if (typeof allVisibleNotes !== 'boolean') {
    throw new Error('notes_scope_invalid:invalid_all_visible_notes');
  }
  if (allVisibleNotes && (accountID !== null || folderID !== null)) {
    throw new Error('notes_scope_invalid:all_visible_notes_conflicts_with_selector');
  }
  if (!allVisibleNotes && accountID === null && folderID === null) {
    throw new Error('notes_scope_invalid:account_id_or_folder_id_required');
  }
  return { accountID, folderID, allVisibleNotes };
}

function dispatch(operation, input) {
  const readScope = operation === 'notes.items.list' || operation === 'notes.items.search'
    ? selectedNotesReadScope(input)
    : null;
  const app = Application('Notes');
  app.includeStandardAdditions = false;
  const accounts = () => sortedAccounts(app);
  const folders = (accountID) => allFolderEntries(app, accountID);
  const notes = () => allNoteEntries(app);

  switch (operation) {
    case 'notes.accounts.list':
      return { accounts: accounts().map(accountJSON) };
    case 'notes.folders.list': {
      if (Object.prototype.hasOwnProperty.call(input, 'snapshot_for_mutation')) {
        return mutationSnapshotRequest(app, input, true);
      }
      const accountID = Object.prototype.hasOwnProperty.call(input, 'account_id')
        ? strictString(input.account_id, 'account_id', false) : null;
      return { folders: folders(accountID).map(folderJSON) };
    }
    case 'notes.folders.create': {
      const reviewed = reviewedStructuralMutation(app, operation, input);
      const parent = reviewed.parentEntry ? reviewed.parentEntry.object : reviewed.accountEntry.object;
      const created = app.Folder({ name: input.name });
      parent.folders.push(created);
      const snapshot = strictFolderSnapshot({ object: created, accountID: reviewed.accountEntry.accountID });
      const expectedParent = reviewed.snapshot.target.parent_folder
        ? reviewed.snapshot.target.parent_folder.folder_id : reviewed.snapshot.target.account.account_id;
      if (snapshot.container_id !== expectedParent) throw new Error('notes_create_observation_mismatch');
      return { folder: {
        id: snapshot.folder_id, account_id: snapshot.account_id, name: snapshot.name,
        shared: snapshot.shared, container_id: snapshot.container_id,
      } };
    }
    case 'notes.folders.delete': {
      const reviewed = reviewedStructuralMutation(app, operation, input);
      app.delete(reviewed.folderEntry.object);
      return { deleted: true, folder_id: input.folder_id };
    }
    case 'notes.items.list': {
      const scope = readScope;
      const { accountID, folderID } = scope;
      const coverage = { collectionFailures: 0, identityFailures: 0 };
      const limit = input.limit || 100;
      const scoped = searchNoteEntries(app, accountID, folderID, coverage, limit + 1);
      const incomplete = coverage.collectionFailures > 0 || coverage.identityFailures > 0
        || !scoped.scopeFound || scoped.scopeAmbiguous;
      return {
        notes: scoped.entries.slice(0, limit).map((entry) => noteJSON(entry, false)),
        truncated: scoped.count > limit,
        scope: {
          mode: scope.allVisibleNotes ? 'all_visible_notes' : folderID ? 'exact_folder' : 'exact_account',
          account_id: accountID,
          folder_id: folderID,
        },
        scope_found: scoped.scopeFound,
        scope_ambiguous: scoped.scopeAmbiguous,
        scope_enumeration_failures: coverage.collectionFailures,
        note_identity_failures: coverage.identityFailures,
        list_incomplete: incomplete,
      };
    }
    case 'notes.items.get':
      if (Object.prototype.hasOwnProperty.call(input, 'snapshot_for_export')) {
        return exportSnapshotRequest(app, input);
      }
      if (Object.prototype.hasOwnProperty.call(input, 'snapshot_for_mutation')) {
        return mutationSnapshotRequest(app, input, false);
      }
      if (Object.prototype.hasOwnProperty.call(input, 'snapshot_for_update')) {
        try {
          if (input.snapshot_for_update !== true
            || Object.keys(input).sort().join('|') !== 'note_id|snapshot_for_update') {
            throw new Error('invalid_note_snapshot_request');
          }
          const noteID = strictString(input.note_id, 'note_id', false);
          const snapshot = noteUpdateSnapshot(strictNoteEntry(app, noteID));
          if (snapshot.note_id !== noteID) throw new Error('note_changed_during_snapshot');
          return { update_snapshot: snapshot };
        } catch (error) {
          throw notesGuardFailure('notes_update_snapshot_unavailable', String(error.message || error));
        }
      }
      return { note: noteJSON(strictNoteEntry(app, input.note_id), true) };
    case 'notes.items.search': {
      const query = String(input.query).toLocaleLowerCase();
      const includeBody = Boolean(input.include_body);
      const scope = readScope;
      const { accountID, folderID } = scope;
      const coverage = { collectionFailures: 0, identityFailures: 0, unaddressableMatches: 0 };
      const scanLimit = input.scan_limit || (includeBody ? 200 : 2_000);
      const scoped = searchNoteEntries(app, accountID, folderID, coverage, scanLimit + 1);
      const candidates = scoped.entries.slice(0, scanLimit);
      const scanLimitReached = scoped.count > scanLimit;
      const matches = [];
      let bodySearchFailures = 0;
      candidates.forEach((entry) => {
        const note = entry.object;
        const titleMatches = searchNoteTitle(entry).toLocaleLowerCase().includes(query);
        let bodyMatches = false;
        if (includeBody && !titleMatches) {
          try {
            const plaintext = note.plaintext();
            if (plaintext === undefined || plaintext === null) {
              throw new Error('notes_search_body_unavailable');
            }
            const searchableText = String(plaintext);
            if (Boolean(note.passwordProtected()) && searchableText === '') {
              throw new Error('notes_search_protected_empty_plaintext_ambiguous');
            }
            bodyMatches = searchableText.toLocaleLowerCase().includes(query);
          } catch (_) {
            bodySearchFailures += 1;
          }
        }
        if (titleMatches || bodyMatches) {
          if (!entry.noteID) {
            coverage.unaddressableMatches += 1;
          } else {
            matches.push(entry);
          }
        }
      });
      const limit = input.limit || 100;
      const incomplete = scanLimitReached || bodySearchFailures > 0
        || coverage.collectionFailures > 0 || coverage.identityFailures > 0
        || coverage.unaddressableMatches > 0 || !scoped.scopeFound || scoped.scopeAmbiguous;
      return {
        notes: matches.slice(0, limit).map((entry) => noteJSON(entry, false)),
        truncated: matches.length > limit,
        scanned: candidates.length,
        scan_limit: scanLimit,
        scan_limit_reached: scanLimitReached,
        scope: {
          mode: scope.allVisibleNotes ? 'all_visible_notes' : folderID ? 'exact_folder' : 'exact_account',
          account_id: accountID,
          folder_id: folderID,
        },
        scope_found: scoped.scopeFound,
        scope_ambiguous: scoped.scopeAmbiguous,
        scope_enumeration_failures: coverage.collectionFailures,
        note_identity_failures: coverage.identityFailures,
        unaddressable_matches: coverage.unaddressableMatches,
        body_search_failures: bodySearchFailures,
        body_search_incomplete: includeBody && incomplete,
        search_incomplete: incomplete,
      };
    }
    case 'notes.items.create': {
      const reviewed = reviewedStructuralMutation(app, operation, input);
      const destinationEntry = reviewed.destinationEntry;
      const created = app.Note({
        name: input.title,
        body: noteBody(input.title, input.body, input.format),
      });
      destinationEntry.object.notes.push(created);
      const note = strictSavedNoteResult({ object: created, accountID: destinationEntry.accountID });
      if (note.folder_id !== reviewed.snapshot.target.destination_folder.folder_id
          || note.account_id !== reviewed.snapshot.target.destination_folder.account_id
          || note.title !== String(input.title)) {
        throw new Error('notes_create_observation_mismatch');
      }
      return { note };
    }
    case 'notes.items.update': {
      const entry = reviewedNoteForUpdate(app, input);
      const note = entry.object;
      const title = input.title === undefined ? input.expected_note.title : String(input.title);
      // The guard phase has ended. Setter/readback failures retain the mutation's uncertain outcome.
      if (input.body !== undefined) {
        note.body = noteBody(title, input.body, input.format);
      }
      if (input.title !== undefined) note.name = input.title;
      const result = strictSavedNoteResult(entry);
      if (result.id !== input.expected_note.note_id
          || result.account_id !== input.expected_note.account_id
          || result.folder_id !== input.expected_note.folder_id
          || result.title !== title) {
        throw new Error('notes_update_observation_mismatch');
      }
      return { note: result };
    }
    case 'notes.items.move': {
      const reviewed = reviewedStructuralMutation(app, operation, input);
      const noteEntry = reviewed.noteEntry;
      const destinationEntry = reviewed.destinationEntry;
      app.move(noteEntry.object, { to: destinationEntry.object });
      const movedEntry = { object: noteEntry.object, accountID: destinationEntry.accountID };
      const moved = structuralNoteSnapshot(movedEntry);
      if (moved.content.folder_id !== reviewed.snapshot.target.destination_folder.folder_id) {
        throw new Error('notes_move_observation_mismatch');
      }
      const result = noteJSON(movedEntry, false);
      result.id = moved.content.note_id;
      result.account_id = moved.content.account_id;
      result.folder_id = moved.content.folder_id;
      result.folder_name = strictString(noteEntry.object.container().name(), 'folder_name', true);
      result.title = moved.content.title;
      result.created_at = moved.created_at;
      result.modified_at = moved.content.modified_at;
      result.shared = moved.shared;
      result.password_protected = false;
      return { note: result };
    }
    case 'notes.items.delete': {
      const reviewed = reviewedStructuralMutation(app, operation, input);
      app.delete(reviewed.noteEntry.object);
      return { deleted: true, note_id: input.note_id };
    }
    case 'notes.selection.get': {
      const selected = requiredCollection(() => app.selection(), 'selection');
      const all = notes();
      const byID = Object.create(null);
      let unaddressableNote = null;
      all.forEach((entry) => {
        const id = objectID(entry.object);
        if (id) byID['$' + id] = entry;
        else if (unaddressableNote === null) unaddressableNote = entry;
      });
      const selectedEntries = [];
      selected.forEach((note) => {
        const id = objectID(note);
        const match = id ? byID['$' + id] : unaddressableNote;
        if (match) selectedEntries.push(match);
      });
      return { notes: selectedEntries.map((entry) => noteJSON(entry, false)) };
    }
    default:
      throw new Error('unsupported_operation:' + operation);
  }
}

function errorCode(message) {
  if (message.startsWith('notes_collection_unavailable:')) return 'notes_collection_unavailable';
  if (message === 'notes_object_identity_unavailable') return 'notes_object_identity_unavailable';
  if (message.startsWith('notes_scope_invalid:')) return 'notes_scope_invalid';
  if (message.startsWith('not_found:')) return 'not_found';
  if (message.startsWith('ambiguous_id:')) return 'ambiguous_id';
  if (message === 'folder_account_mismatch') return 'folder_account_mismatch';
  return 'notes_operation_failed';
}

function run(argv) {
  try {
    return JSON.stringify({ ok: true, data: dispatch(argv[0], readInput(argv[1])) });
  } catch (error) {
    const message = String(error.message || error);
    const result = { code: errorCode(message), message };
    if (error.notesGuardCode) {
      result.code = error.notesGuardCode;
      result.exit_code = 6;
      result.outcome_uncertain = false;
    }
    return JSON.stringify({ ok: false, error: result });
  }
}
