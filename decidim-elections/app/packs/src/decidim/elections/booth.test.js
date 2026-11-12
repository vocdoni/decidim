/* global jest */

import { booth, flush, visible } from "src/decidim/elections/booth_test_helpers";

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
