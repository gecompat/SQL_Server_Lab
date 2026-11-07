(() => {
  'use strict';
  const byId = (name) => document.getElementById('environment-groups-' + name);
  const openButton = byId('open');
  const dialog = byId('dialog');
  const closeButton = byId('close');
  const dismissButton = byId('dismiss');
  const readButton = byId('read');
  const status = byId('status');
  const list = byId('list');
  if (!openButton || !dialog || !closeButton || !dismissButton || !readButton || !status || !list) return;

  let requestGeneration = 0;
  let activeRequest = false;
  const isGuid = (value) => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
  const lifecycleStates = new Set(['STOPPED', 'STARTING', 'ACTIVE', 'STOPPING', 'RECOVERY_REQUIRED']);
  const operationStates = new Set(['IN_PROGRESS', 'COMPLETED', 'RECOVERY_REQUIRED']);
  const operationActions = new Set(['Start', 'Stop']);
  const bindingStatuses = new Set(['CURRENT', 'STALE']);
  const hasOnlyKeys = (value, expected) => {
    const keys = Object.keys(value);
    return keys.length === expected.length && expected.every((key) => Object.prototype.hasOwnProperty.call(value, key));
  };

  function validView(value) {
    return value && typeof value === 'object' && !Array.isArray(value) &&
      hasOnlyKeys(value, ['contractVersion', 'groups']) &&
      value.contractVersion === 'SqlServerLab.EnvironmentGroups.BrowserView/1.1' && Array.isArray(value.groups) &&
      value.groups.every((group) => group && typeof group === 'object' && !Array.isArray(group) &&
        hasOnlyKeys(group, ['groupId', 'name', 'createdAt', 'lifecycleState', 'operation', 'members']) &&
        isGuid(group.groupId) && typeof group.name === 'string' && group.name.length > 0 && group.name.length <= 80 &&
        typeof group.createdAt === 'string' && lifecycleStates.has(group.lifecycleState) && Array.isArray(group.members) &&
        group.members.every((member) => member && typeof member === 'object' && !Array.isArray(member) &&
          hasOnlyKeys(member, ['runId', 'instanceIds', 'assignedAt', 'bindingStatus']) &&
          isGuid(member.runId) && Array.isArray(member.instanceIds) && member.instanceIds.length > 0 &&
          member.instanceIds.every((id) => typeof id === 'string' && /^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(id)) &&
          new Set(member.instanceIds).size === member.instanceIds.length && typeof member.assignedAt === 'string' &&
          bindingStatuses.has(member.bindingStatus)) &&
        (group.operation === null || (group.operation && typeof group.operation === 'object' && !Array.isArray(group.operation) &&
          hasOnlyKeys(group.operation, ['action', 'state', 'startedAt', 'updatedAt']) &&
          operationActions.has(group.operation.action) && operationStates.has(group.operation.state) &&
          typeof group.operation.startedAt === 'string' && typeof group.operation.updatedAt === 'string')));
  }

  function addText(parent, tag, value, className) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    node.textContent = String(value ?? '');
    parent.appendChild(node);
    return node;
  }

  function requestGroupCommand(group, action, runId) {
    requestGeneration++;
    dialog.close();
    window.dispatchEvent(new CustomEvent('sqlserverlab:environment-group-command-request', {
      detail: { action, groupId: group.groupId, groupName: group.name, ...(runId ? { runId } : {}) }
    }));
  }

  function requestGroupCreation(name) {
    requestGeneration++;
    dialog.close();
    window.dispatchEvent(new CustomEvent('sqlserverlab:environment-group-command-request', {
      detail: { action: 'Create', name }
    }));
  }

  function addGroupCreationForm(parent) {
    const editor = document.createElement('div');
    editor.className = 'form-grid';
    const label = document.createElement('label');
    label.textContent = 'Neue Gruppe';
    const input = document.createElement('input');
    input.type = 'text';
    input.maxLength = 80;
    input.autocomplete = 'off';
    label.appendChild(input);
    editor.appendChild(label);
    const create = document.createElement('button');
    create.type = 'button';
    create.className = 'button secondary';
    create.textContent = 'Leere Gruppe erstellen';
    create.addEventListener('click', () => {
      const name = input.value.trim();
      if (!name || name.length > 80 || /[\x00-\x1f\x7f]/.test(name)) {
        status.textContent = 'Gruppenname muss 1 bis 80 Zeichen ohne Steuerzeichen enthalten.';
        return;
      }
      requestGroupCreation(name);
    });
    editor.appendChild(create);
    parent.appendChild(editor);
  }

  function addGroupCommandAction(parent, label, action, group, className, runId) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = className || 'button secondary';
    button.textContent = label;
    button.addEventListener('click', () => requestGroupCommand(group, action, runId));
    parent.appendChild(button);
    return button;
  }

  function addMembershipEditor(parent, group) {
    const editor = document.createElement('div');
    editor.className = 'form-grid';
    const label = document.createElement('label');
    label.textContent = 'Run-ID hinzufügen';
    const input = document.createElement('input');
    input.type = 'text';
    input.maxLength = 36;
    input.autocomplete = 'off';
    input.spellcheck = false;
    input.placeholder = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx';
    label.appendChild(input);
    editor.appendChild(label);
    const add = document.createElement('button');
    add.type = 'button';
    add.className = 'button secondary';
    add.textContent = 'Run zuordnen';
    add.addEventListener('click', () => {
      const runId = input.value.trim();
      if (!isGuid(runId)) {
        status.textContent = 'Gültige Run-ID als GUID eingeben.';
        return;
      }
      requestGroupCommand(group, 'AddMember', runId);
    });
    editor.appendChild(add);
    parent.appendChild(editor);
  }

  function render(view) {
    list.replaceChildren();
    if (view.groups.length === 0) {
      addText(list, 'p', 'Es sind keine Lab-Umgebungsgruppen registriert.', 'empty');
      addGroupCreationForm(list);
      return;
    }
    for (const group of view.groups) {
      const card = document.createElement('article');
      card.className = 'card';
      addText(card, 'h3', group.name);
      addText(card, 'p', 'Gespeicherter Status: ' + group.lifecycleState);
      addText(card, 'p', 'Gruppen-ID: ' + group.groupId);
      if (group.operation) addText(card, 'p', 'Letzter Vorgang: ' + group.operation.action + ' · ' + group.operation.state);
      if (group.members.length === 0) addText(card, 'p', 'Mitglieder: keine');
      else {
        const members = document.createElement('ul');
        for (const member of group.members) {
          const row = document.createElement('li');
          const bindingLabel = member.bindingStatus === 'CURRENT' ? 'Bindung aktuell' : 'Bindung veraltet oder nicht lesbar';
          addText(row, 'span', member.runId + ' · Instanzen: ' + member.instanceIds.join(', ') + ' · ' + bindingLabel);
          if (group.lifecycleState === 'STOPPED' && group.operation?.state !== 'IN_PROGRESS') {
            addGroupCommandAction(row, 'Zuordnung lösen', 'RemoveMember', group, 'button secondary', member.runId);
          }
          members.appendChild(row);
        }
        card.appendChild(members);
      }
      if (group.operation?.state === 'IN_PROGRESS') {
        addText(card, 'p', 'Ein Gruppenvorgang ist laut gespeichertem Status noch in Bearbeitung. Lies den Status erneut, bevor du eine weitere Aktion startest.', 'form-note');
      } else if (group.lifecycleState === 'STOPPED') {
        addMembershipEditor(card, group);
        const actions = document.createElement('div');
        actions.className = 'dialog-actions';
        const start = addGroupCommandAction(actions, 'Gruppe starten', 'Start', group);
        start.disabled = group.members.length === 0;
        addGroupCommandAction(actions, 'Gruppe entfernen', 'RemoveGroup', group, 'button danger');
        if (start.disabled) addText(card, 'p', 'Zum Starten muss die Gruppe mindestens einen Run enthalten.', 'form-note');
        card.appendChild(actions);
      } else {
        const actions = document.createElement('div');
        actions.className = 'dialog-actions';
        const label = group.lifecycleState === 'RECOVERY_REQUIRED' ? 'Wiederherstellen und stoppen' : 'Gruppe stoppen';
        addGroupCommandAction(actions, label, 'Stop', group, 'button danger');
        card.appendChild(actions);
      }
      list.appendChild(card);
    }
    addGroupCreationForm(list);
  }

  async function readGroups() {
    if (activeRequest) return;
    activeRequest = true;
    readButton.disabled = true;
    const generation = ++requestGeneration;
    status.textContent = 'Gespeicherte Gruppen werden gelesen …';
    try {
      const response = await sqlServerLabUiFetch('/api/environment-groups');
      if (!response.ok) throw new Error('READ_FAILED');
      const view = await response.json();
      if (!validView(view)) throw new Error('VIEW_INVALID');
      if (generation !== requestGeneration || !dialog.open) return;
      render(view);
      status.textContent = view.groups.length + ' gespeicherte Gruppe(n). Runtime- und SQL-Zustand sind damit nicht bestätigt.';
    } catch {
      if (generation !== requestGeneration || !dialog.open) return;
      list.replaceChildren();
      status.textContent = 'Gruppen konnten nicht sicher gelesen werden. Fehlercode: ENVIRONMENT_GROUPS_READ_UNCONFIRMED';
    } finally {
      activeRequest = false;
      readButton.disabled = false;
      if (generation !== requestGeneration && dialog.open) status.textContent = 'Leseanfrage veraltet; bitte erneut lesen.';
    }
  }

  openButton.addEventListener('click', () => dialog.showModal());
  closeButton.addEventListener('click', () => dialog.close());
  dismissButton.addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', () => { requestGeneration++; });
  readButton.addEventListener('click', readGroups);
})();
