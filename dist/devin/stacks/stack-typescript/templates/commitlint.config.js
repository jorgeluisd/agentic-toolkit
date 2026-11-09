// Copiar a la raíz del proyecto. Los scopes válidos se derivan de los bounded
// contexts (carpetas de apps/api/src/contexts) más los transversales.
const { readdirSync, existsSync } = require('node:fs');
const contextsDir = 'apps/api/src/contexts';
const contexts = existsSync(contextsDir)
  ? readdirSync(contextsDir, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name)
  : [];
module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'type-enum': [2, 'always', ['feat', 'fix', 'refactor', 'test', 'docs', 'chore', 'ci', 'build', 'perf', 'revert']],
    'scope-enum': [2, 'always', [...contexts, 'kernel', 'web', 'contracts', 'infra', 'docs', 'ci', 'deps']],
    'scope-empty': [1, 'never'],
    'subject-case': [2, 'always', 'lower-case'],
    'header-max-length': [2, 'always', 72],
    'trailer-exists': [0],
  },
};
