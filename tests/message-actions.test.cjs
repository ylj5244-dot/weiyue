const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const modulePath = require.resolve('../Resources/ui/model.js').replace(/model\.js$/, 'message-actions.js');
const A = fs.existsSync(modulePath) ? require(modulePath) : {};

test('translation availability detects English characters in words and mixed messages', () => {
  assert.equal(typeof A.hasEnglish, 'function', 'message action policy must exist');
  for (const value of ['Hello', 'Please read this paragraph.', '这段英文 earnings growth 需要翻译。', 'AI', 'GPU', 'NVDA', '关注NVDA财报', 'I am ready.', 'I', 'a', '“I”', '中文 a 中文']) assert.equal(A.hasEnglish(value), true, value);
});
test('Chinese, numeric and punctuation-only messages do not offer translation', () => {
  assert.equal(typeof A.hasEnglish, 'function');
  for (const value of [null, undefined, 123, {}, ['English'], '', '  ', '这是一段中文。', '123.45% + 2026-10-20', '！？（）🙂', 'C', 'x', 'A股', '123I456']) assert.equal(A.hasEnglish(value), false, String(value));
});
test('complete web addresses and email addresses alone do not trigger translation', () => {
  assert.equal(typeof A.hasEnglish, 'function');
  for (const value of ['https://example.com/English?q=hello#world', 'http://localhost:8080/hello', 'www.example.com/path', 'ftp://example.com/reports', 'file:///Users/romeo/report.txt', 'mailto:person@example.com', 'first.last+tag@example.co.uk', "o'connor@example.com", '链接：https://example.com/path，见附件。', '[资料](https://example.com/report)', 'https://en.wikipedia.org/wiki/IBM_(company)']) assert.equal(A.hasEnglish(value), false, value);
  for (const value of ['Please read https://example.com/report', 'Email first.last@example.com for details.', '[Read this](https://example.com/report)']) assert.equal(A.hasEnglish(value), true, value);
});
test('explicit code formatting is excluded without dropping English prose around it', () => {
  assert.equal(typeof A.hasEnglish, 'function');
  const tick = String.fromCharCode(96), fence = tick.repeat(3);
  for (const value of [tick + 'const value = 1' + tick, fence + 'javascript\nconsole.log("Hello");\n' + fence, '~~~python\nprint("Hello")\n~~~', '示例：' + fence + '\nEnglish code only\n' + fence, tick.repeat(2) + 'value ' + tick + ' code' + tick.repeat(2)]) assert.equal(A.hasEnglish(value), false, value);
  for (const value of ['Please run ' + tick + 'foo()' + tick, fence + 'js\nconst x = 1\n' + fence + '\nThis is the explanation.']) assert.equal(A.hasEnglish(value), true, value);
});
test('plain paths, identifiers and abbreviations are not guessed to be untranslatable', () => {
  assert.equal(typeof A.hasEnglish, 'function');
  for (const value of ['C:\\reports\\report.txt', '/Users/example/report.txt', 'const value = 1;', 'API GPU NVDA', 'value_name']) assert.equal(A.hasEnglish(value), true, value);
});
test('long English identifiers do not stall rendering while checking for email addresses', () => {
  const started = performance.now();
  assert.equal(A.hasEnglish('a'.repeat(120000) + ' @someone'), true);
  const elapsed = performance.now() - started;
  assert.ok(elapsed < 1000, `checking one long message took ${Math.round(elapsed)} ms`);
});
