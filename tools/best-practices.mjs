// Copyright the Elide Toolchain contributors.
// SPDX-License-Identifier: Apache-2.0 OR MIT
// Shared by the standalone page and its URL-construction tests.
export function proposalLinks(data, { projectId = '', published = false, edits = {} } = {}) {
  if (projectId && !/^[1-9][0-9]*$/.test(projectId)) throw new Error('Enter a positive numeric project ID, or leave it blank.');
  const links = [];
  for (const [level, criteria] of Object.entries(data.criteria)) {
    const base = projectId
      ? `https://www.bestpractices.dev/en/projects/${projectId}/${level}/edit`
      : 'https://www.bestpractices.dev/en/projects';
    const routing = projectId ? {} : { as: 'edit', section: level, url: data.evidence.repository };
    let fields = {};
    let names = [];
    const urlFor = (values) => `${base}?${new URLSearchParams({ ...routing, ...values })}`;
    const flush = () => {
      if (Object.keys(fields).length) links.push({ level, url: urlFor(fields), names: [...names] });
      fields = {}; names = [];
    };
    const add = (pair, name) => {
      if (urlFor(pair).length > 5500) throw new Error(`${name}: shorten the explanation to fit one autofill link.`);
      if (urlFor({ ...fields, ...pair }).length > 5500) flush();
      Object.assign(fields, pair); names.push(name);
    };
    if (level === 'passing') {
      for (const key of ['name', 'description', 'implementation_languages', ...(published ? ['license'] : [])]) {
        add({ [key]: data.answers[key] }, key);
      }
    }
    for (const [name, definition] of Object.entries(criteria)) {
      const edited = edits[name];
      if (!edited && data.evidence.phases[name] === 'published' && !published) continue;
      const status = edited?.status ?? data.answers[`${name}_status`];
      const reason = edited?.justification ?? data.answers[`${name}_justification`];
      if (status === '?') continue; // Unknown must never clear a user's saved answer.
      if (!['Met', 'Unmet', 'N/A'].includes(status)) throw new Error(`Invalid status for ${name}.`);
      if (status === 'N/A' && !definition.na_allowed) throw new Error(`N/A is not permitted for ${name}.`);
      add({ [`${name}_status`]: status, [`${name}_justification`]: (reason ?? '').trim() }, name);
    }
    flush();
  }
  return links;
}

export function cleanupLinks(data, { projectId = data.evidence.project_id ?? '' } = {}) {
  if (projectId && !/^[1-9][0-9]*$/.test(projectId)) throw new Error('Enter a positive numeric project ID, or leave it blank.');
  return Object.entries(data.criteria).flatMap(([level, criteria]) => {
    const notes = Object.fromEntries(Object.entries(data.evidence.cleanup_justifications ?? {})
      .filter(([field]) => field.endsWith('_justification') && Object.hasOwn(criteria, field.slice(0, -14))));
    if (!Object.keys(notes).length) return [];
    const base = projectId ? `https://www.bestpractices.dev/en/projects/${projectId}/${level}/edit`
      : 'https://www.bestpractices.dev/en/projects';
    const routing = projectId ? {} : { as: 'edit', section: level, url: data.evidence.repository };
    const params = new URLSearchParams({ ...routing, ...notes, overrides: Object.keys(notes).join(',') });
    const url = `${base}?${params}`;
    if (url.length > 6000) throw new Error('Cleanup link is too long.');
    return [{ level, url, fields: Object.keys(notes) }];
  });
}

export function mount(data) {
  const byId = (id) => document.getElementById(id);
  const edits = {};
  byId('project-id').value = data.evidence.project_id ?? '';
  function render() {
    const output = byId('links');
    output.replaceChildren();
    byId('error').textContent = '';
    byId('cleanup-links').replaceChildren();
    try {
      for (const link of cleanupLinks(data, { projectId: byId('project-id').value.trim() })) {
        const item = document.createElement('p');
        const a = document.createElement('a');
        a.href = link.url; a.target = '_blank'; a.rel = 'noopener noreferrer';
        a.textContent = `Remove old notes from ${link.level}`;
        const fields = document.createElement('small'); fields.textContent = link.fields.join(', ');
        item.append(a, fields); byId('cleanup-links').append(item);
      }
      const links = proposalLinks(data, { projectId: byId('project-id').value.trim(), published: byId('published').checked, edits });
      for (const level of ['passing', 'silver']) {
        const section = document.createElement('section');
        const heading = document.createElement('h3'); heading.textContent = level === 'passing' ? 'Passing' : 'Silver';
        section.append(heading);
        const parts = links.filter((link) => link.level === level);
        const list = document.createElement('ol');
        parts.forEach((part, index) => {
          const item = document.createElement('li');
          const a = document.createElement('a');
          a.href = part.url; a.target = '_blank'; a.rel = 'noopener noreferrer';
          a.textContent = `Autofill ${level} · part ${index + 1} of ${parts.length}`;
          const small = document.createElement('small'); small.textContent = part.names.join(', ');
          item.append(a, small); list.append(item);
        });
        section.append(list); output.append(section);
      }
      byId('link-summary').textContent = `${links.length} links prepared. Open one at a time; review and save before continuing.`;
    } catch (error) {
      byId('error').textContent = error.message;
      byId('link-summary').textContent = 'Fix the field above to regenerate links.';
    }
  }
  const table = byId('evidence');
  const seen = new Set();
  for (const [level, criteria] of Object.entries(data.criteria)) {
    for (const [name, definition] of Object.entries(criteria)) {
      if (seen.has(name)) continue;
      seen.add(name);
      const row = document.createElement('details');
      const summary = document.createElement('summary');
      const status = data.answers[`${name}_status`];
      const phase = data.evidence.phases[name] === 'published' ? 'project policy' : 'project reference';
      summary.textContent = `${name} — ${status === '?' ? 'unanswered' : status} · ${level} · ${definition.category}`;
      row.append(summary);
      const note = document.createElement('p');
      note.textContent = status === '?' ? 'No answer selected.' : `Default proposal: ${phase}.`;
      row.append(note);
      const selectLabel = document.createElement('label'); selectLabel.textContent = 'Answer';
      const select = document.createElement('select'); select.id = `status-${name}`; selectLabel.htmlFor = select.id;
      for (const value of ['?', 'Met', 'Unmet', ...(definition.na_allowed ? ['N/A'] : [])]) {
        const option = document.createElement('option'); option.value = value; option.textContent = value === '?' ? 'Leave unanswered' : value;
        select.append(option);
      }
      select.value = status;
      const textLabel = document.createElement('label'); textLabel.textContent = 'Evidence / justification';
      const reason = document.createElement('textarea'); reason.id = `reason-${name}`; textLabel.htmlFor = reason.id;
      reason.value = data.answers[`${name}_justification`]; reason.rows = 4;
      const apply = document.createElement('button'); apply.type = 'button'; apply.textContent = 'Use this answer';
      const confirmed = document.createElement('span'); confirmed.className = 'confirmation'; confirmed.setAttribute('aria-live', 'polite');
      apply.addEventListener('click', () => {
        edits[name] = { status: select.value, justification: reason.value };
        confirmed.textContent = 'Added to this page’s links.'; render();
      });
      row.append(selectLabel, select, textLabel, reason, apply, confirmed); table.append(row);
    }
  }
  byId('project-id').addEventListener('input', render);
  byId('published').addEventListener('change', render);
  render();
}

if (typeof document !== 'undefined') mount(JSON.parse(document.getElementById('proposal-data').textContent));
