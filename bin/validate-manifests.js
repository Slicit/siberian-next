#!/usr/bin/env node
// Validates every module manifest in modules/ against the contract schema.
//
// The reference modules exist so the contract cannot rot unnoticed. That only
// holds if something checks them, which is this.
const fs = require('fs');
const path = require('path');

let Ajv, addFormats, YAML;
try {
  Ajv = require('ajv/dist/2020');
  addFormats = require('ajv-formats');
  YAML = require('yaml');
} catch (e) {
  console.error('Missing dependencies. Run: npm install --no-save ajv ajv-formats yaml');
  process.exit(2);
}

const root = path.resolve(__dirname, '..');
const schema = JSON.parse(
  fs.readFileSync(path.join(root, 'lib/contracts/module_manifest.schema.json'), 'utf8')
);

const ajv = new Ajv.default({ allErrors: true, strict: false });
addFormats.default ? addFormats.default(ajv) : addFormats(ajv);
const validate = ajv.compile(schema);

const modulesDir = path.join(root, 'modules');
const manifests = fs
  .readdirSync(modulesDir, { withFileTypes: true })
  .filter((d) => d.isDirectory())
  .map((d) => path.join(modulesDir, d.name, 'module.yml'))
  .filter((p) => fs.existsSync(p));

if (manifests.length === 0) {
  console.error('No module manifests found under modules/.');
  process.exit(1);
}

let failed = 0;
for (const file of manifests) {
  const rel = path.relative(root, file);
  const doc = YAML.parse(fs.readFileSync(file, 'utf8'));
  if (validate(doc)) {
    console.log('ok    ' + rel);
  } else {
    failed++;
    console.log('FAIL  ' + rel);
    for (const err of validate.errors) {
      console.log('        ' + (err.instancePath || '/') + ' ' + err.message);
    }
  }
}

if (failed > 0) {
  console.error('\n' + failed + ' manifest(s) failed validation.');
  process.exit(1);
}
console.log('\nAll ' + manifests.length + ' manifest(s) valid.');
