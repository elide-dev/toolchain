// Copyright the Elide Toolchain contributors.
// SPDX-License-Identifier: Apache-2.0 OR MIT
import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { proposalLinks } from '../tools/best-practices.mjs';

const read = (path: string) => JSON.parse(readFileSync(new URL(path, import.meta.url), 'utf8'));
const data = {
  answers: read('../.bestpractices.json'),
  criteria: read('../tools/best-practices-criteria.json'),
  evidence: read('../tools/best-practices-evidence.json'),
};
const fields = (links: ReturnType<typeof proposalLinks>) => Object.assign({}, ...links.map((link) => Object.fromEntries(new URL(link.url).searchParams)));

describe('OpenSSF proposal links', () => {
  test('unpublished and unknown answers are withheld by default', () => {
    const links = proposalLinks(data);
    const values = fields(links);
    expect(values.floss_license_status).toBeUndefined();
    expect(values.license).toBeUndefined();
    expect(values.know_secure_design_status).toBeUndefined();
    expect(values.version_unique_status).toBe('Met');
    expect(values.overrides).toBeUndefined();
    for (const link of links) {
      const url = new URL(link.url);
      expect(url.origin).toBe('https://www.bestpractices.dev');
      expect(url.searchParams.get('url')).toBe(data.evidence.repository);
      expect(url.searchParams.get('section')).toBe(link.level);
    }
  });
  test('published answers stay paired with evidence, bounded and level-specific', () => {
    const links = proposalLinks(data, { projectId: '12345', published: true });
    expect(fields(links).floss_license_status).toBe('Met');
    expect(fields(links).license).toBe('Apache-2.0 OR MIT');
    for (const link of links) {
      expect(link.url.length).toBeLessThanOrEqual(5500);
      const url = new URL(link.url);
      expect(url.pathname).toBe(`/en/projects/12345/${link.level}/edit`);
      for (const [key, value] of url.searchParams) {
        if (!key.endsWith('_status')) continue;
        const criterion = key.slice(0, -7);
        expect(data.criteria[link.level][criterion]).toBeDefined();
        expect(url.searchParams.get(`${criterion}_justification`)).toBeTruthy();
        expect(value).not.toBe('?');
      }
    }
  });
  test('explicit human answers are included without silently overriding saved fields', () => {
    const links = proposalLinks(data, { edits: { know_secure_design: { status: 'Met', justification: 'Reviewed secure-design experience & evidence: https://example.org/review' } } });
    expect(fields(links).know_secure_design_status).toBe('Met');
    expect(fields(links).know_secure_design_justification).toContain('& evidence');
    expect(fields(links).overrides).toBeUndefined();
  });
  test('rejects invalid IDs, unsupported N/A and oversized evidence', () => {
    expect(() => proposalLinks(data, { projectId: '123/edit?overrides=*' })).toThrow();
    expect(() => proposalLinks(data, { edits: { description_good: { status: 'N/A', justification: 'No' } } })).toThrow();
    expect(() => proposalLinks(data, { edits: { description_good: { status: 'Met', justification: 'x'.repeat(6000) } } })).toThrow();
  });
  test('passes entered answers through without requiring a justification', () => {
    const values = fields(proposalLinks(data, { edits: { know_secure_design: { status: 'Met', justification: '' } } }));
    expect(values.know_secure_design_status).toBe('Met');
    expect(values.know_secure_design_justification).toBe('');
    for (const [key, value] of Object.entries(data.answers)) {
      if (key.endsWith('_status') && value === '?') {
        expect(data.answers[key.slice(0, -7) + '_justification']).toBe('');
      }
    }
  });
  test('leaving a criterion unanswered does not clear the server answer', () => {
    const values = fields(proposalLinks(data, { edits: { version_unique: { status: '?', justification: '' } } }));
    expect(values.version_unique_status).toBeUndefined();
  });
  test('branch policy requires one reviewer, never multiple', () => {
    const rules = read('../.github/rulesets/main.json');
    const pr = rules.rules.find((rule: { type: string }) => rule.type === 'pull_request');
    expect(pr.parameters.required_approving_review_count).toBe(1);
  });
});
