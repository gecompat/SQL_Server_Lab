function renderTestGroupPlan(plan) {
  $('#test-group-status').textContent = plan.Total + ' Mitglieder · Power: ' + plan.PowerStatus + ' · SQL-Bereitschaft: nicht geprüft';
  $('#test-group-members').innerHTML = (plan.Members || []).map(member => {
    const runtime = [member.Provider, member.Power + ' → ' + member.Desired, member.Change, member.Reason].filter(Boolean).join(' · ');
    return '<div><strong>' + escapeHtml(member.Key) + '</strong>' +
      (member.RegistrationLabel ? '<div>' + escapeHtml(member.RegistrationLabel) + '</div>' : '') +
      '<div>' + escapeHtml(runtime) + '</div></div>';
  }).join('');
  $('#test-group-notice').textContent = plan.Notice;
}

function testGroupResult(lines) {
  const line = [...(lines || [])].reverse().find(item => String(item).startsWith('[TESTGROUP] '));
  if (!line) return '<p>Ergebnis noch unbestätigt. Bei Verbindungsverlust Gruppe erneut lesen; nicht automatisch wiederholen.</p>';
  try {
    const result = JSON.parse(String(line).slice(12));
    return '<section class="job-inventory"><strong>Gruppe: ' + escapeHtml(result.Status) + ' · SQL-Bereitschaft nicht geprüft</strong>' + (result.Details || []).map(item => '<div>' + escapeHtml(item.Key + ' · ' + item.Status + ' · ' + (item.Action || item.Change) + (item.Reason ? ' · ' + item.Reason : '')) + '</div>').join('') + '<p>Aktuellen Gruppenstatus lesen. Wiederholung nur nach neuer Vorschau und Bestätigung.</p></section>';
  } catch { return '<p>Gruppenergebnis nicht lesbar. Zustand erneut prüfen.</p>'; }
}
