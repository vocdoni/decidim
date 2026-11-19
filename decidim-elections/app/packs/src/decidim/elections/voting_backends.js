/**
 * Registry of client-side voting backends. An adapter is registered by name
 * and the booth looks it up from `data-voting-backend`. Adapters shipped as a
 * separate bundle can register before or after this file loads: they write to
 * `window.Decidim.votingBackends` and dispatch the same event.
 *
 * Adapter contract (all async):
 *   prepare(ctx)      -> { canVote, alreadyVoted, receipts?, message?,
 *                          priorReceipts?, pendingQuestionIds? }
 *   cast(ctx, ballot) -> { receipts?, unconfirmed?, failed? }
 *   recheck(ctx)      -> { receipts? }   (needed only if cast reports unconfirmed)
 *
 *   ballot      = [{ questionId: "12", responseOptionIds: ["34"] }]
 *   receipts    = [{ questionId, code, verifyUrl? }]  cast and recorded
 *   unconfirmed = [{ questionId }]          outcome unknown; the voter is
 *                                           offered `recheck` before a retry
 *   failed      = [{ questionId, error? }]  not recorded; safe to cast again
 *
 * A missing list counts as empty. `priorReceipts` and `pendingQuestionIds`
 * resume a partial ballot: only the pending questions are asked.
 *
 * Besides progress/error/showPanel, the booth's `ctx` offers
 * `loadQuestions(url)` and `restart()` for questions that open after the page
 * was rendered (see `booth_live.js`).
 */
export const REGISTERED_EVENT = "decidim:voting-backend:registered";

/**
 * Normalises what an adapter's `cast()` or `recheck()` resolved to.
 *
 * @param {Object|undefined} result - the adapter's result.
 * @returns {{receipts: Array, unconfirmed: Array, failed: Array}} every list present.
 */
export const castOutcome = (result) => ({
  receipts: (result && result.receipts) || [],
  unconfirmed: (result && result.unconfirmed) || [],
  failed: (result && result.failed) || []
});

const registry = () => {
  window.Decidim = window.Decidim || {};
  window.Decidim.votingBackends = window.Decidim.votingBackends || {};

  return window.Decidim.votingBackends;
};

export const registerVotingBackend = (name, adapter) => {
  registry()[name] = adapter;
  document.dispatchEvent(new CustomEvent(REGISTERED_EVENT, { detail: { name } }));
};

export const findVotingBackend = (name, timeoutMs = 20000) => new Promise((resolve, reject) => {
  if (registry()[name]) {
    resolve(registry()[name]);
    return;
  }

  let timer = null;
  const onRegistered = (event) => {
    if (event.detail && event.detail.name === name) {
      clearTimeout(timer);
      document.removeEventListener(REGISTERED_EVENT, onRegistered);
      resolve(registry()[name]);
    }
  };

  timer = setTimeout(() => {
    document.removeEventListener(REGISTERED_EVENT, onRegistered);
    reject(new Error(`voting backend "${name}" was not registered`));
  }, timeoutMs);
  document.addEventListener(REGISTERED_EVENT, onRegistered);
});

registry();
window.Decidim.registerVotingBackend = registerVotingBackend;
