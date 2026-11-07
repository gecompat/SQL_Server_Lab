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
  const hasOnlyKeys = (value, expected) => {
    const keys = Object.keys(value);
    return keys.length === expected.length && expected.every((key) => Object.prototype.hasOwnProperty.call(value, key));
  };

  function validView(value) {
    return value && typeof value === 'object' && !Array.isArray(value) &&
      hasOnlyKeys(value, ['contractVersion', 'groups']) &&
      value.contractVersion === 'SqlServerLab.EnvironmentGroups.BrowserView/1.0' && Array.isArray(value.groups) &&
      value.groups.every((group) => group && typeof group === 'object' && !Array.isArray(group) &&
        hasOnlyKeys(group, ['groupId', 'name', 'createdAt', 'lifecycleState', 'operation', 'members']) &&
        isGuid(group.groupId) && typeof group.name === 'string' && group.name.length > 0 && group.name.length <= 80 &&
        typeof group.createdAt === 'string' && lifecycleStates.has(group.lifecycleState) && Array.isArray(group.members) &&
        group.members.every((member) => member && typeof member === 'object' && !Array.isArray(member) &&
          hasOnlyKeys(member, ['runId', 'instanceIds', 'assignedAt']) &&
          isGuid(member.runId) && Array.isArray(member.instanceIds) && member.instanceIds.length > 0 &&
          member.instanceIds.every((id) => typeof id === 'string' && /^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(id)) &&
          new Set(member.instanceIds).size === member.instanceIds.length && typeof member.assignedAt === 'string') &&
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

  function render(view) {
    list.replaceChildren();
    if (view.groups.length === 0) {
      addText(list, 'p', 'Es sind keine Lab-Umgebungsgruppen registriert.', 'empty');
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
        for (const member of group.members) addText(members, 'li', member.runId + ' · Instanzen: ' + member.instanceIds.join(', '));
        card.appendChild(members);
      }
      list.appendChild(card);
    }
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
