/**
 * Registry of client-side voting backends. An adapter is registered by name
 * and the booth looks it up from `data-voting-backend`. Adapters shipped as a
 * separate bundle can register before or after this file loads: they write to
 * `window.Decidim.votingBackends` and dispatch the same event.
 *
 * Adapter contract (all async):
 *   prepare(ctx)        -> { canVote, alreadyVoted, receipts?, message? }
 *   cast(ctx, ballot)   -> { receipts: [{ questionId, code, verifyUrl? }] }
 *   ballot = [{ questionId: "12", responseOptionIds: ["34"] }]
 */
export const REGISTERED_EVENT = "decidim:voting-backend:registered";

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
