const assert = require('node:assert/strict');
const fs = require('node:fs');
const YAML = require('yaml');
const Ajv = require('ajv');

const plugin = YAML.parse(fs.readFileSync('plugin.yml', 'utf8'));
const validate = new Ajv({ allErrors: true }).compile(plugin.configuration);
const readme = fs.readFileSync('README.md', 'utf8');
let count = 0;
for (const [, yaml] of readme.matchAll(/```yaml\n([\s\S]*?)```/g)) {
  const example = YAML.parse(yaml);
  const configs = example.steps
    ? example.steps.flatMap(step => (step.plugins || []).flatMap(entry =>
      Object.entries(entry).filter(([name]) => name.startsWith('buildkite/just-works#')).map(([, config]) => config)))
    : [example];
  for (const config of configs) {
    assert(validate(config), JSON.stringify(validate.errors));
    count++;
  }
}
assert(count > 0, 'No README examples were validated');
const pipeline = YAML.parse(fs.readFileSync('.buildkite/pipeline.yml', 'utf8'));
assert(Array.isArray(pipeline.steps) && pipeline.steps.length > 0);
console.log(`Plugin schema, ${count} README examples, and pipeline YAML validated`);
