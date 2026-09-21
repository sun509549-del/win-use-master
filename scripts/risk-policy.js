'use strict';

const fs = require('node:fs');

const RISK_POLICY_SCHEMA = 'win-use-master/risk-actions-v1';
const RISK_NORMALIZATION = Object.freeze([
  'unicode-nfkc', 'camel-case-boundary', 'separator-to-space', 'collapse-whitespace', 'trim',
]);

function normalizeRiskText(value) {
  return (value == null ? '' : String(value))
    .normalize('NFKC')
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/[_-]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function validateRiskPolicy(raw) {
  if (!raw || raw.schema !== RISK_POLICY_SCHEMA) throw new Error('risk policy schema mismatch');
  if (!Array.isArray(raw.normalization) || raw.normalization.length !== RISK_NORMALIZATION.length ||
      raw.normalization.some((value, index) => String(value) !== RISK_NORMALIZATION[index])) {
    throw new Error('risk policy normalization mismatch');
  }
  if (!Array.isArray(raw.blockedTextPatterns) || !raw.blockedTextPatterns.length) {
    throw new Error('risk policy text patterns missing');
  }
  const ids = new Set();
  const compiledTextPatterns = raw.blockedTextPatterns.map((rule) => {
    const id = String(rule?.id || '');
    const pattern = String(rule?.pattern || '');
    const flags = String(rule?.flags || '');
    if (!id || !pattern || ids.has(id)) throw new Error('risk policy rule id or pattern invalid');
    if (flags !== '' && flags !== 'i') throw new Error('risk policy rule flags unsupported');
    ids.add(id);
    return { id, regex: new RegExp(pattern, flags) };
  });
  if (!Array.isArray(raw.blockedKeyChords) || !raw.blockedKeyChords.includes('Enter')) {
    throw new Error('risk policy Enter guard missing');
  }
  if (!Array.isArray(raw.blockedDomSemantics) || !raw.blockedDomSemantics.includes('form-submit')) {
    throw new Error('risk policy form-submit guard missing');
  }
  return { ...raw, compiledTextPatterns };
}

function loadRiskPolicy(path) {
  let raw;
  try { raw = JSON.parse(fs.readFileSync(path, 'utf8')); }
  catch (error) { throw new Error('risk policy unavailable or invalid JSON'); }
  return validateRiskPolicy(raw);
}

function findBlockedTextRule(policy, value) {
  const normalized = normalizeRiskText(value);
  for (const rule of policy.compiledTextPatterns) {
    rule.regex.lastIndex = 0;
    if (rule.regex.test(normalized)) return rule.id;
  }
  return null;
}

module.exports = {
  RISK_POLICY_SCHEMA,
  RISK_NORMALIZATION,
  normalizeRiskText,
  validateRiskPolicy,
  loadRiskPolicy,
  findBlockedTextRule,
};
