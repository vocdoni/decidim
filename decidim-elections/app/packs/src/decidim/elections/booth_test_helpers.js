/* global jest */

// Shared DOM fixture and mount helper for the client-side booth tests.

const question = (id, index) => `
  <section data-booth-step="question" data-booth-question data-question-id="${id}" data-question-title="Q${id}" hidden>
    <h1 tabindex="-1">Q${id}</h1>
    <div class="response"><label data-option-title="Yes"><input type="checkbox" value="${id}0"></label></div>
    ${index > 0
    ? "<button type=\"button\" data-booth-back>back</button>"
    : ""}
    <button type="button" data-booth-next><span data-booth-next-label>next</span></button>
  </section>`;

const texts = JSON.stringify({
  next: "next",
  review: "review",
  // eslint-disable-next-line camelcase -- mirrors the server-side i18n key
  not_answered: "none",
  casting: "casting",
  waiting: { cast: "cast", title: "Waiting", description: "desc" }
});

export const booth = (ids) => `
  <div data-voting-booth data-voting-backend="fake" data-config='{"questions":${JSON.stringify(ids)}}' data-i18n='${texts}'>
    <div data-booth-status></div>
    <section data-booth-step="loading"></section>
    <section data-booth-step="error" hidden><div data-booth-error-message></div></section>
    <form data-booth-form>
      <div data-booth-already-recorded hidden></div>
      ${ids.map(question).join("")}
    </form>
    <section data-booth-step="confirm" hidden>
      <div data-booth-confirm-list></div>
      <button type="button" data-booth-edit>edit</button>
      <button type="button" data-booth-cast>cast</button>
    </section>
    <section data-booth-step="submit" hidden>
      <h3 data-booth-submit-title></h3><p data-booth-submit-summary></p><ul data-booth-submit-list></ul>
      <button type="button" data-booth-retry hidden></button><button type="button" data-booth-recheck hidden></button>
    </section>
    <section data-booth-step="receipt" hidden>
      <div data-booth-receipt-header></div>
      <div data-booth-waiting hidden></div>
      <ul data-booth-receipts></ul>
    </section>
  </div>`;

export const flush = async () => {
  for (let tick = 0; tick < 5; tick += 1) {
    await new Promise((resolve) => {
      setTimeout(resolve, 0);
    });
  }
};

export const visible = () => Array.from(document.querySelectorAll("[data-booth-step]")).filter((step) => !step.hidden);

/**
 * Renders a booth with the given question ids and starts it with a fake adapter.
 *
 * @param {string[]} ids - question ids to render.
 * @param {Object} state - what the adapter's first `prepare()` returns.
 * @returns {Promise<Object>} the adapter and a getter for the booth context.
 */
export const mountBooth = async (ids, state = { canVote: true, alreadyVoted: false }) => {
  let ctx = null;
  const adapter = {
    prepare: jest.fn(async (context) => {
      ctx = context;

      return state;
    }),
    cast: jest.fn(async () => ({ receipts: ids.map((id) => ({ questionId: id, code: `0x${id}` })), unconfirmed: [], failed: [] }))
  };
  document.body.innerHTML = booth(ids);
  window.Decidim = { votingBackends: { fake: adapter } };
  jest.isolateModules(() => {
    // eslint-disable-next-line global-require -- the booth starts on import, after the DOM is set up
    require("src/decidim/elections/booth");
  });
  await flush();

  return { adapter, ctx: () => ctx };
};
