/* global jest */

const question = (id, index) => `
  <section data-booth-step="question" data-booth-question data-question-id="${id}" data-question-title="Q${id}" hidden>
    <h1 tabindex="-1">Q${id}</h1>
    <div class="response"><label data-option-title="Yes"><input type="checkbox" value="${id}0"></label></div>
    ${index > 0
    ? "<button type=\"button\" data-booth-back>back</button>"
    : ""}
    <button type="button" data-booth-next>next</button>
  </section>`;

const booth = (ids) => `
  <div data-voting-booth data-voting-backend="fake" data-config='{"questions":${JSON.stringify(ids)}}' data-i18n="{}">
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
    <section data-booth-step="receipt" hidden><ul data-booth-receipts></ul></section>
  </div>`;

const flush = async () => {
  for (let tick = 0; tick < 5; tick += 1) {
    await new Promise((resolve) => {
      setTimeout(resolve, 0);
    });
  }
};

const visible = () => Array.from(document.querySelectorAll("[data-booth-step]")).filter((step) => !step.hidden);

describe("client-side booth with questions that open later", () => {
  let adapter = null;
  let ctx = null;

  beforeEach(async () => {
    document.body.innerHTML = booth(["1"]);
    adapter = {
      prepare: jest.fn(async (context) => {
        ctx = context;

        return { canVote: true, alreadyVoted: false };
      }),
      cast: jest.fn(async () => ({ receipts: [{ questionId: "1", code: "0xaa" }], unconfirmed: [], failed: [] }))
    };
    window.Decidim = { votingBackends: { fake: adapter } };
    jest.isolateModules(() => {
      // eslint-disable-next-line global-require -- the booth starts on import, after the DOM is set up
      require("src/decidim/elections/booth");
    });
    await flush();
  });

  afterEach(() => {
    Reflect.deleteProperty(window, "fetch");
  });

  it("adds the new question in place and votes it after a restart", async () => {
    document.querySelector("[data-booth-next]").click();
    document.querySelector("[data-booth-cast]").click();
    await flush();
    expect(visible().map((step) => step.dataset.boothStep)).toEqual(["receipt"]);

    window.fetch = jest.fn().mockResolvedValue({
      ok: true,
      text: () => Promise.resolve(`<html><body>${booth(["1", "2"])}</body></html>`)
    });
    adapter.prepare.mockResolvedValueOnce({
      canVote: true,
      alreadyVoted: false,
      priorReceipts: [{ questionId: "1", code: "0xaa" }],
      pendingQuestionIds: ["2"]
    });

    const loaded = await ctx.loadQuestions("/booth");
    await ctx.restart();

    expect(loaded.questionIds).toEqual(["2"]);
    expect(adapter.prepare).toHaveBeenCalledTimes(2);
    const shown = visible();
    expect(shown).toHaveLength(1);
    expect(shown[0].dataset.questionId).toBe("2");
    // First question of this visit: nothing to go back to.
    expect(shown[0].querySelector("[data-booth-back]").style.visibility).toBe("hidden");

    shown[0].querySelector("[data-booth-next]").click();
    adapter.cast.mockResolvedValueOnce({ receipts: [{ questionId: "2", code: "0xbb" }], unconfirmed: [], failed: [] });
    document.querySelector("[data-booth-cast]").click();
    await flush();

    expect(adapter.cast).toHaveBeenLastCalledWith(ctx, [{ questionId: "2", responseOptionIds: [] }]);
    const codes = Array.from(document.querySelectorAll("[data-booth-receipts] code")).map((code) => code.textContent);
    expect(codes).toEqual(["0xaa", "0xbb"]);
  });
});
