(function (root, factory) {
  const api = factory(typeof module === 'object' && module.exports ? require('./range-summary.js') : root.ReaderRangeSummary);
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.ReaderRangeRunner = api;
})(typeof window !== 'undefined' ? window : globalThis, function (S) {
  'use strict';
  function stopped() { const error = new Error('总结已取消，已完成的分批结果与消息快照仍保留。'); error.cancelled = true; return error; }
  async function run({snapshots, options, request, checkpoint, progress, isCancelled}) {
    const check = () => { if (isCancelled()) throw stopped(); };
    const batches = S.plan(snapshots), partials = [];
    if (!batches.length) throw new Error('所选时段没有可供总结的消息。');
    async function ask(messages, info) {
      check(); progress(info);
      const response = await request(messages, info); check();
      if (typeof response !== 'string' || !response.trim()) throw new Error('模型没有返回有效总结，已完成的批次仍保留。');
      return response;
    }
    for (let index = 0; index < batches.length; index++) {
      const info = {stage:'map',batch:index+1,totalBatches:batches.length,count:snapshots.length};
      partials.push(await ask(S.mapRequest(batches[index], options), info));
      await checkpoint({stage:'map',completedBatches:partials.length,batchCount:batches.length,partials:partials.slice()}); check();
    }
    let results = partials;
    // Even a single batch gets a final synthesis: map notes are source material,
    // while the final answer applies the user's requested style and structure.
    for (let round = 1; round <= 8; round++) {
      const groups = S.reductionBatches(results), reduced = [];
      for (let index = 0; index < groups.length; index++) {
        reduced.push(await ask(S.reduceRequest(groups[index], options), {stage:'reduce',round,batch:index+1,totalBatches:groups.length,count:snapshots.length}));
        await checkpoint({stage:'reduce',round,completedBatches:batches.length,batchCount:batches.length,partials:partials.slice(),reductionCompleted:index+1}); check();
      }
      S.assertReduction(results, reduced);
      if (reduced.length === 1) return {text:reduced[0],partials,batchCount:batches.length,rounds:round};
      results = reduced;
    }
    throw new Error('模型连续汇总后内容仍然过长，已保留分批结果。请缩小时段后重试。');
  }
  return {run,stopped};
});
